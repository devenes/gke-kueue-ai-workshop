# 05 — Speaker Demo Cheat Sheet & Live Presentation Runbook

Use this **Two-Terminal Split-Screen Runbook** when delivering a live conference talk, customer workshop, or technical deep dive covering all 9 labs.

---

## Pre-Talk Checklist (15 Minutes Before Going Live)

Run these commands once before your session to verify the GKE cluster, operators, queues, CEL policies, observability endpoints, and image caches:

```bash
# 1. Verify cluster credentials, operators, and Kueue base setup
make kubeconfig
make operators-install
make base-apply
make labs-clean

# 2. Run the 15-second 14-point Pre-Flight Check (must show 14 PASSED, 0 FAILED)
make preflight

# 3. (Optional Rehearsal) Run the full 9-lab automated E2E smoke test (~3.5 mins)
make test-all
```

### Expected `make preflight` Output
```text
================================================================================
 GKE Kueue AI Workshop — Pre-Flight Environment Check
================================================================================

1. Cluster & Node Topology Check
  [PASS] system-pool node Ready (gke-gke-kueue-workshop-system-pool-be3c118f-6cgc, workload=system)
  [PASS] on-demand-rack-1 node Ready (gke-gke-kueue-worksh-on-demand-rack-1-37786744-3n48, block-1/rack-1)
  [PASS] on-demand-rack-2 node Ready (gke-gke-kueue-worksh-on-demand-rack-2-c183e097-qm0n, block-1/rack-2)
  [PASS] Free allocatable CPU >= 3000m per on-demand rack (rack-1=3450m/3920m, rack-2=3335m/3920m)

2. Operators & Webhooks Check
  [PASS] jobset-system/jobset-controller Available=True (nodeSelector.workload=system, webhook=10.20.1.4)
  [PASS] lws-system/lws-controller-manager Available=True (nodeSelector.workload=system, webhook=10.20.1.8)
  [PASS] kueue-system/kueue-controller-manager Available=True (nodeSelector.workload=system, webhook=10.20.1.10)

3. Kueue v1beta2 Control Plane Check
  [PASS] Topology (gke-dc-topology), ResourceFlavors (on-demand/spot), & ProvisioningRequestConfig verified
  [PASS] AdmissionCheck, ClusterQueues (team-a-cq & team-b-cq in ai-org-cohort), & LocalQueues Active=True

4. Governance & ConfigMaps Check
  [PASS] CEL ValidatingAdmissionPolicy (require-kueue-queue-name) & namespace labels (kueue-governance=enforced) active
  [PASS] PyTorch ConfigMaps (pytorch-ddp-script, pytorch-lws-inference-script, pytorch-checkpoint-script) present

5. Observability Endpoints Check
  [PASS] Kueue Visibility API v1beta2 (/pendingworkloads -> PendingWorkloadsSummary) reachable
  [PASS] Kueue Prometheus metrics (:8443/metrics) reachable & exporting kueue_cluster_queue_nominal_quota

6. Clean State Check
  [PASS] Zero stale JobSets, LeaderWorkerSets, or Workloads in team-a & team-b

================================================================================
 Summary: 14 PASSED, 0 FAILED
================================================================================
```

### Expected `make test-all` Summary Table
```text
================================================================================
 GKE KUEUE AI WORKSHOP — 9-LAB SMOKE TEST SUMMARY (Total: 286s)
================================================================================
Lab Scenario                                         | Status | Duration
--------------------------------------------------------------------------------
Lab 1: All-or-Nothing Gang Scheduling                | PASS   | 9s      
Lab 2: Topology Aware Scheduling (Same-Rack)         | PASS   | 9s      
Lab 3: Spot Spillover & Atomic ProvisioningRequest   | PASS   | 95s     
Lab 4: Intra-Queue Priority Preemption               | PASS   | 15s     
Lab 5: Multi-Team Cohort Borrowing & Reclamation     | PASS   | 15s     
Lab 6: LeaderWorkerSet Inference & Cross-PodSet TAS  | PASS   | 14s     
Lab 7: Stateful DDP Checkpointing & Resume           | PASS   | 79s     
Lab 8: CEL Admission Governance & Max-Exec-Time SLA  | PASS   | 32s     
Lab 9: Visibility API & Prometheus Metrics           | PASS   | 17s     
================================================================================
 RESULT: 9/9 LABS PASSED (100%)
================================================================================
```

---

## Split-Screen Terminal Layout

Arrange your terminal window into **Top (Live Observer)** and **Bottom (Command Driver)** panes:

### Top Terminal — Live Cluster Observer (`watch`)
Run this single `watch` loop in the top pane and leave it running throughout the entire presentation:

```bash
watch -n 2 "echo '=== 1. NODES & TOPOLOGY ===' && \
kubectl get nodes -L workload,tier,workshop.ai/topology-block,workshop.ai/topology-rack && \
echo '\n=== 2. KUEUE WORKLOADS & PROVISIONING REQUESTS (team-a & team-b) ===' && \
kubectl get workloads,provisioningrequests -A && \
echo '\n=== 3. POD PLACEMENT (team-a & team-b) ===' && \
kubectl get pods -n team-a -o wide && kubectl get pods -n team-b -o wide"
```

---

## Live Demo Script (Bottom Terminal — Driver)

### Intro: Show the Architecture (2 mins)
```bash
make status
```
**Speaker Talking Points:**
- *"Look at section 1 in the top pane: we have `system-pool` hosting JobSet, LeaderWorkerSet, and Kueue, plus two on-demand rack nodes (`rack-1` and `rack-2`) inside `block-1` with declarative `workshop.ai/topology-*` labels injected via Terraform."*
- *"Notice our two ClusterQueues (`team-a-cq` and `team-b-cq`) share the `ai-org-cohort`: each team owns `3 vCPUs` nominal On-Demand quota and can borrow up to `3 vCPUs` when the other team is idle (`6 vCPUs` effective max)."*

---

### Demo 1: All-or-Nothing Gang Scheduling (3 mins)
```bash
make lab1
kubectl logs -n team-a -l jobset.sigs.k8s.io/jobset-name --tail=20 -f
make labs-clean
```
**Speaker Talking Points:**
- *"Each JobSet needs `4 vCPUs` (`2x2 vCPU` pods). While `team-b` is idle, `team-a-cq` has `6 vCPUs` available (`3` nominal + `3` borrowed). JobSet 1 is admitted immediately (`2/2` pods), while JobSet 2 stays `SUSPENDED=true` as an all-or-nothing gang until JobSet 1 finishes."*

---

### Demo 2: Topology Aware Scheduling — Same Rack Placement (3 mins)
```bash
make lab2
kubectl logs -n team-a -l jobset.sigs.k8s.io/jobset-name=pytorch-tas-same-rack --prefix=true -f
make labs-clean
```
**Speaker Talking Points:**
- *"`lab2-tas-rack.yaml` sets `kueue.x-k8s.io/podset-required-topology: workshop.ai/topology-rack`. Look at the `NODE` column in the top pane: Kueue's TAS solver placed **both** distributed workers onto the **exact same physical rack node** (`on-demand-rack-1`)."*

---

### Demo 3: Spot Spillover & Atomic `ProvisioningRequest` (4 mins)
```bash
make lab3
kubectl logs -n team-a -l jobset.sigs.k8s.io/jobset-name=pytorch-spot-atomic-scaleup --prefix=true -f
make labs-clean
```
**Speaker Talking Points:**
- *"This 3-worker job requests `7.5 vCPUs`, exceeding `on-demand-flavor`'s `6 vCPU` capacity. Kueue routes it to `spot-flavor` and creates a `ProvisioningRequest` (`best-effort-atomic-scale-up.autoscaling.x-k8s.io`)."*
- *"Watch `spot-atomic-pool` scale from `0 -> 3` Spot VMs atomically before Kueue unsuspends the JobSet."*

---

### Demo 4: Intra-Queue Priority Preemption (3 mins)
```bash
make lab4
make labs-clean
```
**Speaker Talking Points:**
- *"Inside `team-a-cq`, `urgent-prod-training` (`priority=1000`) immediately preempts `research-long-training` (`priority=100`, `withinClusterQueue: LowerPriority`), finishes its 4 epochs, and Kueue automatically re-admits the research job."*

---

### Demo 5: Multi-Team Cohort Borrowing & Reclamation (`team-a` vs. `team-b`) (3 mins)
```bash
make lab5
make labs-clean
```
**Speaker Talking Points:**
- *"`team-a-cq` is using `total: 5` vCPUs by **borrowing `2 vCPUs`** from `team-b-cq` with `high-prod-priority` (`1000`)."*
- *"When `team-b` submits a job in `team-b-queue` with `low-research-priority` (`100`), `team-b-cq` reclaims its nominal quota (`reclaimWithinCohort: Any`), preempting `team-a` (`reason: InCohortReclamation`) despite `100 < 1000`!"*

---

### Demo 6: Multi-Pod Distributed Inference with `LeaderWorkerSet` & Cross-PodSet TAS (3 mins)
```bash
make lab6
kubectl wait --for=condition=Ready pod/lws-tas-infer-0 -n team-a --timeout=90s
kubectl exec -n team-a lws-tas-infer-0 -- python3 -c "import urllib.request; print(urllib.request.urlopen('http://localhost:8080/infer').read().decode())"
make labs-clean
```
**Speaker Talking Points:**
- *"By combining `kueue.x-k8s.io/podset-group-name: lws-rack-group` with `kueue.x-k8s.io/podset-required-topology: workshop.ai/topology-rack`, Kueue co-locates **both** the LWS Leader PodSet and Worker PodSet onto the exact same physical rack node for sub-4ms Tensor-Parallel `AllReduce`!"*

---

### Demo 7: Stateful DDP Checkpointing & Zero-Goodput-Loss Preemption Resume (3 mins)
```bash
make lab7
kubectl wait --for=condition=Completed jobset/urgent-checkpoint-preemptor -n team-a --timeout=120s
kubectl wait --for=condition=Ready pod -l jobset.sigs.k8s.io/jobset-name=resumable-research-job -n team-a --timeout=90s
kubectl logs -l jobset.sigs.k8s.io/jobset-name=resumable-research-job,batch.kubernetes.io/job-completion-index=0 -n team-a -f
make labs-clean
```
**Speaker Talking Points:**
- *"`resumable-research-job` saves atomic PyTorch checkpoints at the end of Epochs 1–4 before getting preempted by `urgent-checkpoint-preemptor`."*
- *"When Kueue automatically re-admits `resumable-research-job`, look at the logs: `🔄 [RESUMED FROM CHECKPOINT] Found saved state at Epoch 4! Resuming training from Epoch 5/8 (Zero Goodput Lost!)` — it completes Epochs 5..8 without repeating a single completed epoch!"*

---

### Demo 8: CEL `ValidatingAdmissionPolicy` Governance & `max-exec-time-seconds` SLA (2 mins)
```bash
make lab8
make labs-clean
```
**Speaker Talking Points:**
- *"First, Step 8A submits `unlabeled-rogue-jobset` without a `kueue.x-k8s.io/queue-name` label — Kubernetes' native CEL `ValidatingAdmissionPolicy` rejects it immediately at the API server!"*
- *"Next, Step 8B submits `sla-time-bounded-job` with `kueue.x-k8s.io/max-exec-time-seconds: 20`. After 20 seconds of runtime, Kueue automatically evicts and deactivates the runaway job (`DeactivatedDueToMaximumExecutionTimeExceeded`)."*

---

### Demo 9: Kueue Visibility API & Prometheus Metrics Observability (2 mins)
```bash
make lab9
make labs-clean
```
**Speaker Talking Points:**
- *"`obs-occupier-job` saturates `team-a-cq`. Then `obs-queued-low` (`priority=100`) is submitted first, followed 2 seconds later by `obs-queued-high` (`priority=1000`)."*
- *"Querying Kueue's `v1beta2` Visibility API (`/pendingworkloads`) shows `obs-queued-high` jumped to `positionInClusterQueue: 0` ahead of `obs-queued-low` (`positionInClusterQueue: 1`), while Prometheus `:8443/metrics` reports `kueue_cluster_queue_resource_usage=5` and `kueue_pending_workloads=2`."*

---

## Post-Talk Teardown

Once your session concludes, clean up all Kubernetes workloads and destroy the GCP infrastructure:

```bash
make labs-clean
make infra-down
gcloud container clusters list --project=enes-turan-demo
```
