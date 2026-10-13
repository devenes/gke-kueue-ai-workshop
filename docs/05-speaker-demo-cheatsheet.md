# 05 — Speaker Demo Cheat Sheet & Live Presentation Runbook

Use this **Two-Terminal Split-Screen Runbook** when delivering a live conference talk, customer workshop, or technical deep dive.

---

## Pre-Talk Checklist (15 Minutes Before Going Live)

Run these commands once before your session so the GKE cluster is up, operators are running, and the `548 MB` `pytorch/torchserve:0.12.0-cpu` image is cached on the on-demand nodes:

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
echo '\n=== 2. KUEUE WORKLOADS & PROVISIONING REQUESTS (team-a) ===' && \
kubectl get workloads,provisioningrequests -n team-a && \
echo '\n=== 3. POD PLACEMENT (team-a) ===' && \
kubectl get pods -n team-a -o wide"
```

---

## Live Demo Script (Bottom Terminal — Driver)

### Intro: Show the Architecture (2 mins)
```bash
make status
```
**Speaker Talking Points:**
- *"Look at section 1 in the top pane: we have `system-pool` hosting Kueue and JobSet, and two on-demand rack nodes (`rack-1` and `rack-2`) inside `block-1` with declarative `workshop.ai/topology-*` labels injected directly via Terraform."*
- *"Notice there are currently zero `spot` nodes—`spot-atomic-pool` is scaled to zero until needed."*
- *"Our `ClusterQueue` (`team-a-cq`) gives Team A `6 vCPUs` of On-Demand quota and `9 vCPUs` of Spot quota."*

---

### Demo 1: All-or-Nothing Gang Scheduling (3 mins)
```bash
# Submit two 4-vCPU distributed PyTorch JobSets back-to-back against a 6-vCPU On-Demand quota
make lab1
```
**Speaker Talking Points (while watching Top Terminal):**
- *"Each JobSet needs 2 Pods $\times$ 2 vCPUs = 4 vCPUs (`8 vCPUs` total across both jobs), but our On-Demand quota is only `6 vCPUs`."*
- *"In default Kubernetes, both jobs could partially schedule 1 Pod each and deadlock inside `torchrun` rendezvous."*
- *"Look at `KUEUE WORKLOADS`: JobSet 1 (`ADMITTED=True`) immediately gets 2/2 Pods across `rack-1` and `rack-2`. JobSet 2 stays `SUSPENDED=true` with zero Pods created—no wasted resources, no deadlock."*

```bash
# Stream Rank 0 training logs until JobSet 1 finishes and JobSet 2 auto-starts
kubectl logs -n team-a -l jobset.sigs.k8s.io/jobset-name --tail=20 -f
```
- *"As soon as Epoch 8 finishes on JobSet 1, watch the top pane: Kueue automatically reclaims the 4 vCPUs and admits JobSet 2!"*

```bash
make labs-clean
```

---

### Demo 2: Topology Aware Scheduling — Same Rack Placement (3 mins)
```bash
# Submit a 2-worker JobSet with podset-required-topology: workshop.ai/topology-rack
make lab2
```
**Speaker Talking Points (while watching Top Terminal):**
- *"In distributed training, `AllReduce` gradient synchronization is bottlenecked by network hops between racks."*
- *"Even though both `rack-1` and `rack-2` are idle, `lab2-tas-rack.yaml` specifies `kueue.x-k8s.io/podset-required-topology: workshop.ai/topology-rack`."*
- *"Look at `POD PLACEMENT` (`NODE` column) in the top pane: Kueue's TAS solver forced **both** `workers-0-0` and `workers-0-1` onto the **exact same physical rack node** (`on-demand-rack-1`)!"*

```bash
kubectl logs -n team-a -l jobset.sigs.k8s.io/jobset-name=pytorch-tas-same-rack --prefix=true -f
make labs-clean
```

---

### Demo 3: Spot Spillover & Atomic `ProvisioningRequest` (4 mins)
```bash
# Submit a 3-worker JobSet (3 x 2.5 vCPU = 7.5 vCPU > 6 vCPU On-Demand quota)
make lab3
```
**Speaker Talking Points (while watching Top Terminal):**
- *"This job needs `7.5 vCPUs` across 3 workers—exceeding our `6 vCPU` On-Demand quota. Kueue automatically spills it over to `spot-flavor` (`9 vCPU` quota)."*
- *"Because `spot-flavor` has our `spot-atomic-check` AdmissionCheck attached, Kueue does **not** create Pending Pods one by one. Instead, look at `PROVISIONING REQUESTS` in the top pane: Kueue created a `ProvisioningRequest` with `best-effort-atomic-scale-up.autoscaling.x-k8s.io`."*
- *"GKE Cluster Autoscaler marks `ACCEPTED=True, PROVISIONED=True` and scales `spot-atomic-pool` from `0 -> 3` Spot VMs atomically. Only after all 3 Spot nodes are ready does Kueue unsuspend the JobSet and inject the `spot-only=true:NoSchedule` toleration!"*

```bash
# Once the 3 pods are Running on the 3 new Spot nodes:
kubectl logs -n team-a -l jobset.sigs.k8s.io/jobset-name=pytorch-spot-atomic-scaleup --prefix=true -f
make labs-clean
```

---

### Demo 4: Priority-Based Preemption & Auto-Recovery (3 mins)
```bash
# Starts low-priority research-long-training (prio=100), waits for Running pods, then submits urgent-prod-training (prio=1000)
make lab4
```
**Speaker Talking Points (while watching Top Terminal):**
- *"First, our exploratory job (`research-long-training`, priority `100`, 50 epochs) claims `5 vCPUs` of our `6 vCPU` On-Demand quota and starts training."*
- *"Now `make lab4` submits `urgent-prod-training` (priority `1000`, 4 epochs), which requires `5 vCPUs` on the On-Demand TAS block."*
- *"Look at the top pane right now: Kueue immediately **preempts** `research-long-training` (`ADMITTED=False`, `Evicted=True / Preempted`), terminates its Pods, and admits `urgent-prod-training`!"*

```bash
# Inspect the exact Preempted condition while urgent-prod-training runs:
kubectl get workload -n team-a -l kueue.x-k8s.io/job-uid -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{.status.conditions}{"\n\n"}{end}'
```
- *"Wait 20 seconds for `urgent-prod-training` to finish its 4 epochs... and look at the top pane: `research-long-training` is **automatically re-admitted** by Kueue without any human intervention!"*

```bash
make labs-clean
```
