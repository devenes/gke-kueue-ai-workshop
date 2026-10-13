# 05 — Speaker Demo Cheat Sheet & Live Presentation Runbook

Use this **Two-Terminal Split-Screen Runbook** when delivering a live conference talk, customer workshop, or technical deep dive covering all 6 labs.

---

## Pre-Talk Checklist (15 Minutes Before Going Live)

Run these commands once before your session so the GKE cluster is up, all three operators (`jobset`, `lws`, `kueue`) are running on `system-pool`, and the `548 MB` `pytorch/torchserve:0.12.0-cpu` image is cached on the on-demand nodes:

```bash
# 1. Verify cluster credentials, operators, and Kueue base setup
make kubeconfig
make operators-install
make base-apply
make labs-clean

# 2. Pre-warm the container image on on-demand nodes (takes ~20s once)
make lab2 && kubectl wait --for=condition=Completed jobset/pytorch-tas-same-rack -n team-a --timeout=90s
make labs-clean
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
# Starts team-a-cohort-borrower (5 vCPU, prio=1000), prints borrowed quota, then submits team-b-reclaim-owner (2.5 vCPU, prio=100)
make lab5
```
**Speaker Talking Points:**
- *"Look at the JSON printed by `make lab5`: `team-a-cq` is using `total: 5` vCPUs by **borrowing `2 vCPUs`** from `team-b-cq`, and its job has `high-prod-priority` (`1000`)."*
- *"Now `team-b` submits a job in `team-b-queue` with `low-research-priority` (`100`). Even though `100 < 1000`, `team-b-cq` is reclaiming its own nominal quota (`reclaimWithinCohort: Any`)!"*
- *"Look at the top pane: `team-a-cohort-borrower` is immediately evicted (`reason: InCohortReclamation`), `team-b-reclaim-owner` runs its 4 epochs, and then `team-a-cohort-borrower` automatically re-borrows the quota and resumes!"*

```bash
make labs-clean
```

---

### Demo 6: Multi-Pod Distributed Inference with `LeaderWorkerSet` & Cross-PodSet TAS (3 mins)
```bash
# Deploy the 2-Pod (Leader + Worker) Tensor-Parallel LeaderWorkerSet
make lab6
kubectl wait --for=condition=Ready pod/lws-tas-infer-0 -n team-a --timeout=90s
```
**Speaker Talking Points:**
- *"For multi-pod LLM inference, `LeaderWorkerSet` creates a Leader Pod (`lws-tas-infer-0`) and a Worker Pod (`lws-tas-infer-0-1`) as two separate PodSets."*
- *"By combining `kueue.x-k8s.io/podset-group-name: lws-rack-group` with `kueue.x-k8s.io/podset-required-topology: workshop.ai/topology-rack`, Kueue co-locates **both** Leader and Worker onto the exact same physical rack node!"*

```bash
# Trigger a live Tensor-Parallel AllReduce inference request across Leader + Worker:
kubectl exec -n team-a lws-tas-infer-0 -- python3 -c "import urllib.request; print(urllib.request.urlopen('http://localhost:8080/infer').read().decode())"

# Show Leader and Worker Tensor-Parallel logs:
kubectl logs -n team-a lws-tas-infer-0
kubectl logs -n team-a lws-tas-infer-0-1
make labs-clean
```
