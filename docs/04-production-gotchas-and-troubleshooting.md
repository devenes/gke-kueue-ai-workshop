# 04 — Production Gotchas & Troubleshooting (Live GKE `v1.36` Field Notes)

During live testing of Labs 1–10 on GKE Standard `v1.36.4-gke.1391002`, we encountered and resolved thirteen subtle, real-world production issues across Kubernetes Cluster Autoscaler, Kueue `v1beta2`, `JobSet`, `LeaderWorkerSet`, PyTorch DDP Checkpointing, CEL Admission Policies, Prometheus Observability, and Cloud Storage FUSE CSI with Hierarchical Namespace (HNS).

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

- **JobSet Webhook Immutability:** When Kueue admits a `JobSet`, it mutates the Pod template inside `spec.replicatedJobs`. Re-running `kubectl apply` on an already-admitted multi-document YAML triggers `spec.replicatedJobs: Invalid value: ... field is immutable`. In [`Makefile`](../Makefile), `make lab4`, `make lab5`, and `make lab7` apply Document 1 first, wait for `Ready` Pods, and then pipe only Document 2 (`awk 'f{print} /^---$$/{f=1}'`) to `kubectl apply -f -`.
- **Helm 4 Server-Side Apply Conflict:** Helm 4 defaults to Server-Side Apply, conflicting with controller-populated webhook TLS Secrets on repeated upgrades. Guarding `operators-install` with `helm status <release> -n <ns> >/dev/null 2>&1 || helm upgrade --install ...` ensures idempotency.

---

## Gotcha 5: Zero-Build CPU PyTorch Image Selection

`docker.io/pytorch/pytorch:2.4.0-cpu` does not exist on Docker Hub, and CUDA runtime tags weigh `3.65 GB`. Using the official **`pytorch/torchserve:0.12.0-cpu`** image (**548 MB**, ships with PyTorch `2.4.0+cpu`, `/home/venv/bin/torchrun`, and `gloo`) cuts image pull times by $6.6\times$.

---

## Gotcha 6: `LeaderWorkerSet` Cross-PodSet TAS Grouping & Control-Plane CPU Sizing

### Symptom A — LWS Leader and Worker Scheduled on Different Racks
Because `LeaderWorkerSet` defines a `leaderTemplate` and a `workerTemplate`, Kueue creates a `Workload` with **two separate PodSets** (`leader` and `worker`). Setting `kueue.x-k8s.io/podset-required-topology: "workshop.ai/topology-rack"` alone only constrains each individual PodSet to a rack, allowing the Leader to land on `rack-1` and the Worker to land on `rack-2`.

**Fix ([`k8s/labs/lab6-lws-inference-tas.yaml`](../k8s/labs/lab6-lws-inference-tas.yaml)):** Pair `podset-required-topology` with `kueue.x-k8s.io/podset-group-name: "lws-rack-group"` on **both** `leaderTemplate` and `workerTemplate` so Kueue's TAS solver co-locates both PodSets onto the exact same physical rack domain.

### Symptom B — LWS & Kueue Controller Rolling Updates on `system-pool` (`e2-standard-2`)
1. The upstream `oci://registry.k8s.io/lws/charts/lws` (`0.11.1`) chart defaults to `resources.requests.cpu: 1` (`1000m`), which exceeds the remaining allocatable CPU on `system-pool` (`e2-standard-2`) when `jobset` (`500m`) and `kueue` (`500m`) are running. Furthermore, enabling GKE Workload Identity Federation (`gke-metadata-server`: `100m` CPU) and GCS FUSE CSI (`gcsfusecsi-node`: `15m` CPU) in **Lab 10** reduces free CPU on `system-pool` from `514m` to `391m`, which blocks a `RollingUpdate` surge of a `500m` `kueue-controller-manager` replica. Passing `--set resources.requests.cpu=100m` for `lws` and `--set controllerManager.manager.resources.requests.cpu=250m` for `kueue` leaves `641m` free CPU on `system-pool` so rolling restarts complete in seconds.
2. Long-running LWS inference servers hold onto Kueue `Workload` quota for `30s` (`terminationGracePeriodSeconds`) on deletion unless `SIGTERM` is handled. Adding `signal.signal(signal.SIGTERM, lambda *_: os._exit(0))` in `infer_server.py` and `terminationGracePeriodSeconds: 2` releases quota in $<2\text{s}$.

---

## Gotcha 7: Cohort Fair-Share Reclamation (`reclaimWithinCohort: Any`) vs. Workload Priority

In **Lab 5**, `team-a-cohort-borrower` runs with `high-prod-priority` (`1000`), while `team-b-reclaim-owner` is submitted with `low-research-priority` (`100`). Why does the priority `100` job preempt the priority `1000` job?
- Because `team-a-cq` is **borrowing** `2 vCPUs` of `team-b-cq`'s nominal quota, and `reclaimWithinCohort: Any` is configured on the `ClusterQueue`s.
- In Kueue, nominal quota ownership within a cohort takes precedence over cross-queue priority when `reclaimWithinCohort: Any` is set, guaranteeing that lending idle capacity never prevents the lending team from running its own workloads (`reason: InCohortReclamation`).

---

## Gotcha 8: Stateful DDP Checkpointing (`exec torchrun` PID 1, `hostPath` UID Permissions & Multi-Node Sync)

In **Lab 7**, three subtle interactions occur when implementing stateful checkpointing across distributed `JobSet` Pods:
1. **`bash -c` Swallowing `SIGTERM` Without `exec`:** When Kubernetes evicts a Pod, `kubelet` sends `SIGTERM` only to **PID 1**. If `torchrun` is invoked inside `bash -c "torchrun ..."` without `exec`, `bash` is PID 1 and does not forward `SIGTERM` to `torchrun`. Using `exec torchrun ...` promotes `torchrun` to PID 1 so `SIGTERM` reaches `train_checkpoint.py` immediately.
2. **`hostPath` (`DirectoryOrCreate`) Root Ownership vs. Non-Root Container User:** The `pytorch/torchserve:0.12.0-cpu` image defaults to user `model-server` (UID `1000`), whereas `kubelet` creates `hostPath` `DirectoryOrCreate` directories (`/var/tmp/kueue-checkpoints`) owned by `root:root` (`0755`). Setting `securityContext.runAsUser: 0` on the Pod spec prevents `PermissionError` when writing atomic checkpoint files (`tmp` + `os.replace`).
3. **Avoid `ReadWriteOnce` (`RWO`) PVCs for Multi-Node DDP Jobs:** Standard GKE `pd-balanced` PVCs only support `ReadWriteOnce` (single-node attachment) and fail with `Multi-Attach error` when Ranks 0 and 1 run on `on-demand-rack-1` and `on-demand-rack-2`. Persisting checkpoints on all ranks + synchronizing `synced_epoch` via `dist.all_reduce(local_epoch, op=dist.ReduceOp.MAX)` on startup eliminates `RWO` volume contention.

---

## Gotcha 9: Native Kubernetes CEL `ValidatingAdmissionPolicy` Expression Syntax

In **Lab 8** ([`k8s/base/governance-policy.yaml`](../k8s/base/governance-policy.yaml)), inspecting `object.metadata.labels['kueue.x-k8s.io/queue-name']` directly in CEL throws a runtime evaluation error when `metadata.labels` is omitted on the submitted resource (`no such key: labels`).
- **Fix:** Always guard map lookups in CEL with `has(object.metadata.labels) && 'kueue.x-k8s.io/queue-name' in object.metadata.labels && object.metadata.labels['kueue.x-k8s.io/queue-name'].size() > 0`.

---

## Gotcha 10: Enabling Kueue `ClusterQueue` Resource Metrics (`enableClusterQueueResources: true`) & RBAC Scraping

In **Lab 9**:
1. **Opt-In `ClusterQueue` Resource Metrics:** By default, the Kueue Helm chart (`0.16.2`) leaves `# enableClusterQueueResources: true` commented out in `kueue-manager-config`, which omits `kueue_cluster_queue_nominal_quota` and `kueue_cluster_queue_resource_usage` from `/metrics`. Enabling `enableClusterQueueResources: true` under `metrics:` in `kueue-manager-config` activates per-flavor CPU and memory gauges.
2. **HTTPS RBAC Auth on `:8443/metrics`:** Kueue's metrics service (`kueue-controller-manager-metrics-service:8443`) enforces Kubernetes SubjectAccessReview authorization (`nonResourceURLs: ["/metrics"]`). Binding the pre-installed `kueue-metrics-reader` `ClusterRole` via `ClusterRoleBinding/kueue-metrics-reader-binding` ([`k8s/base/governance-policy.yaml`](../k8s/base/governance-policy.yaml)) allows authenticated scraping via `kubectl create token kueue-controller-manager -n kueue-system`.

---

## Gotcha 11: Kueue Admission vs. GKE GCS FUSE Mutating Webhook Sidecar Resource Accounting

### Symptom
When submitting a `JobSet` with `gke-gcsfuse/volumes: "true"`, Kueue calculates `Workload` quota reservation from the `JobSet`'s Pod template **before** any Pods are created (`3 × 1250m = 3750m` CPU). Once Kueue unsuspends the `JobSet`, GKE's mutating webhook injects `gke-gcsfuse-sidecar` and `gke-gcsfuse-metadata-prefetch` as native sidecars (`initContainers` with `restartPolicy: Always`). If default webhook sidecar requests are used on 4-vCPU nodes, or if platform engineers size `ClusterQueue` quotas without accounting for the sidecar delta, Pods can get stuck `Pending (Insufficient cpu)` even after Kueue admits the `Workload`!

### Root Cause & Fix ([`k8s/labs/lab10-gcsfuse-ai-storage.yaml`](../k8s/labs/lab10-gcsfuse-ai-storage.yaml))
1. Always set explicit `gke-gcsfuse/*-request` and `gke-gcsfuse/*-limit` annotations on the Pod template (`gke-gcsfuse/cpu-request: "250m"`, `gke-gcsfuse/memory-request: "512Mi"`, `gke-gcsfuse/metadata-prefetch-cpu-request: "10m"`).
2. Account for the `+260m` CPU / `+522Mi` memory per-Pod delta (`3750m` Kueue reservation vs. `4530m` actual `kube-scheduler` Pod requests across 3 Pods) so that `2` co-located Pods (`2 × 1510m = 3020m` CPU) fit comfortably within a 4-vCPU rack node's `~3170m–3372m` free allocatable CPU.

---

## Gotcha 12: Direct Workload Identity Federation for GCS HNS Buckets (`skipCSIBucketAccessCheck: "true"`)

### Symptom
1. Annotating a Kubernetes `ServiceAccount` with `iam.gke.io/gcp-service-account: ...@PROJECT_ID.iam.gserviceaccount.com` hardcodes a GCP project ID into Kubernetes manifests and requires managing an extra IAM Service Account + `roles/iam.workloadIdentityUser` binding.
2. When binding least-privilege `roles/storage.objectUser` directly to the Kubernetes `ServiceAccount` principal (`principal://iam.googleapis.com/projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/PROJECT_ID.svc.id.goog/subject/ns/team-a/sa/lab10-gcsfuse-sa`), the CSI node driver's pre-mount bucket metadata check fails unless `storage.buckets.get` is bypassed or granted.

### Root Cause & Fix ([`terraform/network_iam.tf`](../terraform/network_iam.tf) & [`k8s/labs/lab10-gcsfuse-ai-storage.yaml`](../k8s/labs/lab10-gcsfuse-ai-storage.yaml))
1. Bind `roles/storage.objectUser` directly to the WIF `principal://...` using `data.google_project.current.number` in Terraform (`roles/storage.objectUser` includes `storage.folders.create/delete/get/list/rename` required for HNS atomic directory renames and `GetStorageLayout`).
2. Set `skipCSIBucketAccessCheck: "true"` in `csi.volumeAttributes` so `gcsfuse.csi.storage.gke.io` skips the redundant `storage.buckets.get` check while `gcsfuse` (`v3.11.2-gke.0`) automatically calls `GetStorageLayout` and enables `"Applied optimizations for bucket-type: hierarchical"`.

---

## Gotcha 13: Cross-Pod FUSE Metadata / Negative-Cache Consistency & OpenMP Thread Contention

### Symptom
1. **Cross-Pod Negative Cache:** If non-writer ranks (`Rank 1`, `Rank 2`) poll `os.path.exists("/mnt/gcsfuse/.../published_v1/model.pt")` before `Rank 0` finishes `os.rename(staging_dir, published_dir)`, `gcsfuse`'s metadata/stat cache caches a negative lookup (`ENOENT`) for `metadataCacheTTLSeconds` (`60s`), causing subsequent reads to fail with `FileNotFoundError`.
2. **Co-Located OpenMP Thread Contention:** When two PyTorch Pods co-locate on the same 4-vCPU node (`on-demand-rack-1`), PyTorch's default OpenMP thread pool (`4` threads per Pod = `8` threads total) causes severe CPU context-switching during `mmap` tensor reduction.

### Fix ([`k8s/base/pytorch-ddp-configmap.yaml`](../k8s/base/pytorch-ddp-configmap.yaml))
1. Never poll target paths across FUSE mounts before the writer completes. Instead, `Rank 0` flushes, `os.fsync()`s, closes the file, executes `os.rename(staging_dir, published_dir)`, and then all ranks cross `dist.barrier()` before `Rank 1` and `Rank 2` open `published_v1/model.pt` for the first time. The same write $\rightarrow$ `fsync` $\rightarrow$ close $\rightarrow$ `dist.barrier()` pattern is enforced before cross-rank checkpoint verification.
2. Call `torch.set_num_threads(1)` in `gcsfuse_bench.py` so co-located ranks on `rack-1` achieve deterministic `5.18x–7.18x` warm-cache read speedups without OpenMP thread thrashing.

---

## Automated Diagnostics & Regression Verification (`make preflight` & `make test-all`)

To eliminate manual troubleshooting before live workshops or after GKE upgrades, the [`scripts/`](../scripts/) directory provides two automated verification tools:
- **`make preflight` ([`scripts/preflight-check.sh`](../scripts/preflight-check.sh)):** Runs 16 health checks in ~15 seconds, auditing node readiness, topology labels (`block-1/rack-1|2`), free allocatable CPU ($\ge 3000\text{m}$ per on-demand rack), operator deployments (`jobset-controller`, `lws-controller-manager`, `kueue-controller-manager`), webhook endpoints, `v1beta2` `ClusterQueue`/`LocalQueue` `Active=True` status, CEL `ValidatingAdmissionPolicy`, ConfigMaps & direct-WIF `ServiceAccount/lab10-gcsfuse-sa`, Visibility API `PendingWorkloadsSummary`, Prometheus `:8443/metrics`, `CSIDriver/gcsfuse.csi.storage.gke.io` + `gcsfusecsi-node` DaemonSet, and the Terraform HNS GCS bucket (`HNS=True, UBLA=True`).
- **`make test-all` ([`scripts/smoke-test-all.sh`](../scripts/smoke-test-all.sh)):** Runs `make preflight` followed by an end-to-end automated execution and assertion suite across all 10 labs, cleaning up between each lab and printing a final 10/10 pass/fail summary table.

