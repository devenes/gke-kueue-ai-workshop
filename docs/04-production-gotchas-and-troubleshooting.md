# 04 — Production Gotchas & Troubleshooting (Live GKE `v1.36` Field Notes)

During live testing of Labs 1–6 on GKE Standard `v1.36.4-gke.1391002`, we encountered and resolved seven subtle, real-world production issues across Kubernetes Cluster Autoscaler, Kueue `v1beta2`, `JobSet`, `LeaderWorkerSet`, and Helm 4.

---

## Gotcha 1: GKE Cluster Autoscaler `ProvisioningClass` Naming Discrepancy

### Symptom
When configuring `ProvisioningRequestConfig` with `provisioningClassName: best-effort-atomic.autoscaling.x-k8s.io`, Kueue creates the `ProvisioningRequest`, but GKE Cluster Autoscaler never accepts or acts on it (`ACCEPTED` and `PROVISIONED` remain empty indefinitely).

### Root Cause & Fix ([`k8s/base/kueue-setup.yaml`](../k8s/base/kueue-setup.yaml))
In the upstream Kubernetes Cluster Autoscaler codebase (`autoscaling.x-k8s.io/v1`, `v1.30.2+`), the registered class constant is:
```yaml
provisioningClassName: best-effort-atomic-scale-up.autoscaling.x-k8s.io
```
With `best-effort-atomic-scale-up.autoscaling.x-k8s.io`, GKE Cluster Autoscaler transitions the `ProvisioningRequest` to `Accepted=True` and `Provisioned=True` within seconds and triggers atomic `0 -> 3` Spot node provisioning.

---

## Gotcha 2: TAS Annotations Block Spillover to Non-TAS Flavors

### Symptom
In **Lab 3**, including `kueue.x-k8s.io/podset-unconstrained-topology: "true"` on a `JobSet` blocked spillover from `on-demand-flavor` (`6 vCPU` quota) to `spot-flavor` (`9 vCPU` quota) with:
```text
Flavor "spot-flavor" does not support TopologyAwareScheduling
```

### Root Cause & Fix ([`k8s/labs/lab3-spot-atomic.yaml`](../k8s/labs/lab3-spot-atomic.yaml))
In Kueue (`v0.16+`), **any** `kueue.x-k8s.io/podset-*-topology` annotation (`required`, `preferred`, or `unconstrained`) populates `spec.podSets[*].topologyRequest` on the `Workload`, restricting evaluation exclusively to `ResourceFlavor`s that have `spec.topologyName` set. Omitting TAS annotations on workloads that should spill over to non-TAS Spot pools allows Kueue to route them directly to `spot-flavor`.

---

## Gotcha 3: Kueue `v1beta2` CRD Schema Evolution (`spec.cohort` $\rightarrow$ `spec.cohortName`)

### Symptom
1. Kueue `v0.14.1` only serves `kueue.x-k8s.io/v1beta1`.
2. On Kueue `v0.16.2` (`v1beta2`), `ClusterQueue.spec.cohort` fails strict decoding (`unknown field "spec.cohort"`).

### Fix ([`Makefile`](../Makefile) & [`k8s/base/kueue-setup.yaml`](../k8s/base/kueue-setup.yaml))
Install Kueue `v0.16.2+` and use `cohortName: "ai-org-cohort"` in `v1beta2` `ClusterQueue` manifests.

---

## Gotcha 4: `JobSet` Immutability Webhook & Helm 4 Server-Side Apply Conflicts

- **JobSet Webhook Immutability:** When Kueue admits a `JobSet`, it mutates the Pod template inside `spec.replicatedJobs`. Re-running `kubectl apply` on an already-admitted multi-document YAML triggers `spec.replicatedJobs: Invalid value: ... field is immutable`. In [`Makefile`](../Makefile), `make lab4` and `make lab5` apply Document 1 first, wait for `Ready` Pods, and then pipe only Document 2 (`awk 'f{print} /^---$$/{f=1}'`) to `kubectl apply -f -`.
- **Helm 4 Server-Side Apply Conflict:** Helm 4 defaults to Server-Side Apply, conflicting with controller-populated webhook TLS Secrets on repeated upgrades. Guarding `operators-install` with `helm status <release> -n <ns> >/dev/null 2>&1 || helm upgrade --install ...` ensures idempotency.

---

## Gotcha 5: Zero-Build CPU PyTorch Image Selection

`docker.io/pytorch/pytorch:2.4.0-cpu` does not exist on Docker Hub, and CUDA runtime tags weigh `3.65 GB`. Using the official **`pytorch/torchserve:0.12.0-cpu`** image (**548 MB**, ships with PyTorch `2.4.0+cpu`, `/home/venv/bin/torchrun`, and `gloo`) cuts image pull times by $6.6\times$.

---

## Gotcha 6: `LeaderWorkerSet` Cross-PodSet TAS Grouping & Control-Plane CPU Sizing

### Symptom A — LWS Leader and Worker Scheduled on Different Racks
Because `LeaderWorkerSet` defines a `leaderTemplate` and a `workerTemplate`, Kueue creates a `Workload` with **two separate PodSets** (`leader` and `worker`). Setting `kueue.x-k8s.io/podset-required-topology: "workshop.ai/topology-rack"` alone only constrains each individual PodSet to a rack, allowing the Leader to land on `rack-1` and the Worker to land on `rack-2`.

**Fix ([`k8s/labs/lab6-lws-inference-tas.yaml`](../k8s/labs/lab6-lws-inference-tas.yaml)):** Pair `podset-required-topology` with `kueue.x-k8s.io/podset-group-name: "lws-rack-group"` on **both** `leaderTemplate` and `workerTemplate` so Kueue's TAS solver co-locates both PodSets onto the exact same physical rack domain.

### Symptom B — LWS Controller Pending on `system-pool` & Slow Pod Termination
1. The upstream `oci://registry.k8s.io/lws/charts/lws` (`0.11.1`) chart defaults to `resources.requests.cpu: 1` (`1000m`), which exceeds the remaining `614m` allocatable CPU on `system-pool` (`e2-standard-2`) when `jobset` (`500m`) and `kueue` (`500m`) are running. Passing `--set resources.requests.cpu=100m --set resources.requests.memory=128Mi` fits all 3 operators on `system-pool`.
2. Long-running LWS inference servers hold onto Kueue `Workload` quota for `30s` (`terminationGracePeriodSeconds`) on deletion unless `SIGTERM` is handled. Adding `signal.signal(signal.SIGTERM, lambda *_: os._exit(0))` in `infer_server.py` and `terminationGracePeriodSeconds: 2` releases quota in $<2\text{s}$.

---

## Gotcha 7: Cohort Fair-Share Reclamation (`reclaimWithinCohort: Any`) vs. Workload Priority

In **Lab 5**, `team-a-cohort-borrower` runs with `high-prod-priority` (`1000`), while `team-b-reclaim-owner` is submitted with `low-research-priority` (`100`). Why does the priority `100` job preempt the priority `1000` job?
- Because `team-a-cq` is **borrowing** `2 vCPUs` of `team-b-cq`'s nominal quota, and `reclaimWithinCohort: Any` is configured on the `ClusterQueue`s.
- In Kueue, nominal quota ownership within a cohort takes precedence over cross-queue priority when `reclaimWithinCohort: Any` is set, guaranteeing that lending idle capacity never prevents the lending team from running its own workloads (`reason: InCohortReclamation`).
