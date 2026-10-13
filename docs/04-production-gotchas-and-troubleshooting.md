# 04 — Production Gotchas & Troubleshooting (Live GKE `v1.36` Field Notes)

During live testing of this workshop on GKE Standard `v1.36.4-gke.1391002`, we encountered and resolved five subtle, real-world production issues across Kubernetes Cluster Autoscaler, Kueue `v1beta2`, JobSet webhooks, and Helm 4. Keep this guide handy when running Kueue in production.

---

## Gotcha 1: GKE Cluster Autoscaler `ProvisioningClass` Naming Discrepancy

### Symptom
When configuring `ProvisioningRequestConfig` with `provisioningClassName: best-effort-atomic.autoscaling.x-k8s.io` (as written in several public docs), Kueue creates the `ProvisioningRequest`, but GKE Cluster Autoscaler never accepts or acts on it (`ACCEPTED` and `PROVISIONED` remain empty indefinitely).

### Root Cause
In the upstream Kubernetes Cluster Autoscaler codebase (`autoscaling.x-k8s.io/v1`), the actual constant registered by the atomic scale-up processor (`supported from Cluster Autoscaler v1.30.2+`) is:
```text
best-effort-atomic-scale-up.autoscaling.x-k8s.io
```
Any `ProvisioningRequest` whose `spec.provisioningClassName` omits `-scale-up` is silently ignored by the Cluster Autoscaler loop.

### Fix ([`k8s/base/kueue-setup.yaml`](../k8s/base/kueue-setup.yaml))
```yaml
apiVersion: kueue.x-k8s.io/v1beta2
kind: ProvisioningRequestConfig
metadata:
  name: gke-atomic-cpu-config
spec:
  provisioningClassName: best-effort-atomic-scale-up.autoscaling.x-k8s.io
  managedResources:
  - cpu
  - memory
```
With `best-effort-atomic-scale-up.autoscaling.x-k8s.io`, GKE Cluster Autoscaler transitions the `ProvisioningRequest` to `Accepted=True` and `Provisioned=True` within seconds and triggers atomic `0 -> 3` Spot node provisioning.

---

## Gotcha 2: TAS Annotations Block Spillover to Non-TAS Flavors

### Symptom
In **Lab 3**, when `lab3-spot-atomic.yaml` included the Pod annotation:
```yaml
annotations:
  kueue.x-k8s.io/podset-unconstrained-topology: "true"
```
Kueue refused to spill the `7.5 vCPU` workload over to `spot-flavor` (`9 vCPU` quota) and left the `Workload` pending with:
```text
couldn't assign flavors to pod set workers: Flavor "spot-flavor" does not support TopologyAwareScheduling, insufficient quota for cpu in flavor on-demand-flavor, previously considered podsets requests (0) + current podset request (7500m) > maximum capacity (6)
```

### Root Cause
In Kueue (`v0.16+`), **any** `kueue.x-k8s.io/podset-*-topology` annotation (`required`, `preferred`, **or** `unconstrained`) populates `spec.podSets[*].topologyRequest` on the Kueue `Workload`. Once `topologyRequest` is non-nil, Kueue restricts flavor evaluation exclusively to `ResourceFlavor` objects that have `spec.topologyName` configured. Because `spot-flavor` does not have a `topologyName`, Kueue rejects `spot-flavor`.

### Fix ([`k8s/labs/lab3-spot-atomic.yaml`](../k8s/labs/lab3-spot-atomic.yaml))
Omit all `kueue.x-k8s.io/podset-*-topology` annotations on workloads that should be eligible to run on non-TAS flavors (`spot-flavor`). When no TAS annotation is present, Kueue skips TAS-only `on-demand-flavor` (`Flavor "on-demand-flavor" supports only TopologyAwareScheduling`) and routes the workload directly to `spot-flavor`.

---

## Gotcha 3: Kueue `v1beta2` CRD Schema Evolution (`spec.cohort` $\rightarrow$ `spec.cohortName`)

### Symptom
1. Installing Kueue `v0.14.1` fails when applying `apiVersion: kueue.x-k8s.io/v1beta2` manifests (`no matches for kind "ClusterQueue" in version "kueue.x-k8s.io/v1beta2"`), because `v1beta2` was introduced in Kueue `v0.16.x`.
2. On Kueue `v0.16.2`, applying a `v1beta2` `ClusterQueue` with `spec.cohort: "ai-org-cohort"` fails with:
   ```text
   ClusterQueue in version "v1beta2" cannot be handled as a ClusterQueue: strict decoding error: unknown field "spec.cohort"
   ```

### Fix ([`Makefile`](../Makefile) & [`k8s/base/kueue-setup.yaml`](../k8s/base/kueue-setup.yaml))
- Use `KUEUE_VERSION ?= 0.16.2` (or newer) for `kueue.x-k8s.io/v1beta2` support.
- Use `cohortName: "ai-org-cohort"` under `ClusterQueue.spec` in `v1beta2`.

---

## Gotcha 4: JobSet Immutability Webhook & Helm 4 Server-Side Apply Conflicts

### Symptom A — JobSet Webhook Error on Multi-Doc Re-Apply
When `lab4-preemption.yaml` (containing both `research-long-training` and `urgent-prod-training`) was applied a second time after `research-long-training` was already admitted and running, `kubectl apply -f k8s/labs/lab4-preemption.yaml` failed with:
```text
admission webhook "validate-jobset-x-k8s-io-v1alpha2-jobset.x-k8s.io" denied the request: spec.replicatedJobs: Invalid value: ... field is immutable
```
**Root Cause & Fix:** When Kueue admits a `JobSet`, it mutates the Pod template inside `spec.replicatedJobs` (injecting `nodeSelector` and topology constraints). Re-running `kubectl apply` on the already-admitted first document attempts to overwrite those mutated fields. In [`Makefile`](../Makefile), `make lab4` applies Document 1 (`research-long-training`), waits for its Pods to become `Ready`, and then pipes **only Document 2** (`urgent-prod-training`) to `kubectl apply -f -`.

### Symptom B — Helm 4 Server-Side Apply Conflict on Webhook Certs
Running `helm upgrade --install jobset ...` a second time with Helm `v4.3.0` fails with:
```text
conflict occurred while applying object jobset-system/jobset-webhook-server-cert /v1, Kind=Secret: Apply failed with 4 conflicts: conflicts with "jobset"
```
**Root Cause & Fix:** Helm 4 defaults to Server-Side Apply, and the `jobset` controller populates `.data.{ca.crt,tls.crt,tls.key}` on its Secret after startup. Guarding `operators-install` in [`Makefile`](../Makefile) with `helm status <release> -n <ns> >/dev/null 2>&1 || helm upgrade --install ...` ensures idempotent execution.

---

## Gotcha 5: Zero-Build CPU PyTorch Image Selection

### Symptom
- `docker.io/pytorch/pytorch:2.4.0-cpu` does not exist on Docker Hub (`ErrImagePull: not found`).
- Official `pytorch/pytorch:2.4.0-cuda12.1-cudnn9-runtime` images weigh **3.65 GB**, adding significant image pull latency whenever new Spot nodes spin up in Lab 3.

### Fix
Use the official **`pytorch/torchserve:0.12.0-cpu`** image published by the `pytorch` organization on Docker Hub:
- **Size:** Only **548 MB** ($6.6\times$ smaller than CUDA runtime tags).
- **Pre-installed Stack:** Ships with PyTorch `2.4.0+cpu`, `/home/venv/bin/torchrun` in `PATH`, and `torch.distributed` `gloo` support enabled out of the box.
