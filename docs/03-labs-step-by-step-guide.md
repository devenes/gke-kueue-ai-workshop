# 03 — Step-by-Step Labs Guide (Labs 1–9)

This guide walks through each of the nine hands-on labs in [`k8s/labs/`](../k8s/labs/), explaining the manifest design, internal control-plane flow, execution commands, and verified terminal outputs from GKE `v1.36.4-gke.1391002`.

---

## Lab 1: All-or-Nothing Gang Scheduling ([`k8s/labs/lab1-gang-scheduling.yaml`](../k8s/labs/lab1-gang-scheduling.yaml))

### 1. Scenario & Objective
Distributed PyTorch `torchrun` jobs require every rank (`0 .. WORLD_SIZE-1`) to initialize simultaneously. If two 2-Pod jobs (`4 vCPUs` each) are submitted against a `6 vCPU` effective On-Demand quota (`3 vCPU` nominal + `3 vCPU` borrowed in `ai-org-cohort`), default Kubernetes would partially schedule Pods and deadlock. Kueue guarantees **all-or-nothing gang admission**: Job 1 receives `2/2` Pods immediately, while Job 2 waits in `team-a-queue` with `SUSPENDED=true` (zero Pods created) until Job 1 completes.

### 2. Manifest Breakdown
- `generateName: pytorch-ddp-gang-`: Allows submitting multiple instances via `kubectl create -f`.
- `labels.kueue.x-k8s.io/queue-name: team-a-queue`: Routes the JobSet to `team-a-cq`.
- `annotations.kueue.x-k8s.io/podset-preferred-topology: "workshop.ai/topology-block"`: Targets the TAS-enabled `on-demand-flavor` (`block-1`), allowing the 2 Pods (`2 vCPU` each = `4 vCPU` total) to span across `on-demand-rack-1` and `on-demand-rack-2`.
- Dynamic `MASTER_ADDR` resolution for `generateName`:
  ```bash
  MASTER_ADDR="$(hostname | sed 's/-[0-9]*$/-0/').$(hostname -d)"
  ```

### 3. Under-the-Hood Sequence Diagram

```mermaid
sequenceDiagram
    participant User as AI/ML Engineer
    participant JS as JobSet Webhook/Controller
    participant Kueue as Kueue Controller (team-a-cq)
    participant Sched as kube-scheduler

    User->>JS: kubectl create -f lab1-gang-scheduling.yaml (x2)
    JS-->>Kueue: JobSet 1 & JobSet 2 created (spec.suspend = true)
    Kueue->>Kueue: Evaluate team-a-cq (3 nominal + 3 borrowed = 6 vCPU max)
    Kueue->>JS: Admit JobSet 1 (4 vCPU <= 6 vCPU, set suspend = false)
    Note over Kueue,JS: JobSet 2 (4 vCPU) > remaining 2 vCPU -> Kept Suspended
    JS->>Sched: Create 2 Pods for JobSet 1 (rack-1 & rack-2)
    Sched-->>JS: 2/2 Pods Running -> torchrun AllReduce (8 Epochs)
    JS-->>Kueue: JobSet 1 Completed -> Release 4 vCPU quota
    Kueue->>JS: Automatically Admit JobSet 2 (set suspend = false)
```

### 4. Execution & Verification Commands
```bash
make lab1
kubectl get jobsets,workloads,pods -n team-a -o wide
kubectl logs -n team-a -l jobset.sigs.k8s.io/jobset-name --tail=50 -f
make labs-clean
```

### 5. Verified Live GKE Output
```text
NAME                                            TERMINALSTATE   RESTARTS   COMPLETED   SUSPENDED   AGE
jobset.jobset.x-k8s.io/pytorch-ddp-gang-n5bcl                   0                      false       16s
jobset.jobset.x-k8s.io/pytorch-ddp-gang-qcjpv                   0                      true        16s

NAME                                                          QUEUE          RESERVED IN   ADMITTED   FINISHED   AGE
workload.kueue.x-k8s.io/jobset-pytorch-ddp-gang-n5bcl-93343   team-a-queue   team-a-cq     True                  16s
workload.kueue.x-k8s.io/jobset-pytorch-ddp-gang-qcjpv-71d3d   team-a-queue                                       16s

[Rank 0/2] Initialized on Node: gke-gke-kueue-worksh-on-demand-rack-1-37786744-3n48
[Rank 1/2] Initialized on Node: gke-gke-kueue-worksh-on-demand-rack-2-c183e097-qm0n
Epoch [1/8] | World Size: 2 | Loss: 2.3555
...
Epoch [8/8] | World Size: 2 | Loss: 2.2805
Distributed Training Completed Successfully!

# Immediately after JobSet 1 finishes, JobSet 2 is automatically admitted:
NAME                                                          QUEUE          RESERVED IN   ADMITTED   FINISHED   AGE
workload.kueue.x-k8s.io/jobset-pytorch-ddp-gang-n5bcl-93343   team-a-queue   team-a-cq     True       True       96s
workload.kueue.x-k8s.io/jobset-pytorch-ddp-gang-qcjpv-71d3d   team-a-queue   team-a-cq     True                  96s
```

---

## Lab 2: Topology Aware Scheduling (TAS) — Same Rack ([`k8s/labs/lab2-tas-rack.yaml`](../k8s/labs/lab2-tas-rack.yaml))

### 1. Scenario & Objective
To minimize network hops during gradient `AllReduce`, we want both distributed PyTorch workers co-located on the **exact same rack** (`workshop.ai/topology-rack`), rather than split across `rack-1` and `rack-2`.

### 2. Manifest Breakdown
- `annotations.kueue.x-k8s.io/podset-required-topology: "workshop.ai/topology-rack"`: Instructs Kueue's TAS solver that all Pods in the PodSet **must** be placed within a single `workshop.ai/topology-rack` domain.
- `resources.requests.cpu: "1200m"` per Pod ($2 \times 1200\text{m} = 2400\text{m}$ total): Sized below a single `e2-standard-4` node's free allocatable CPU (`~3292m–3494m`) so both Pods fit onto one rack node.

### 3. Under-the-Hood Sequence Diagram

```mermaid
sequenceDiagram
    participant User as AI/ML Engineer
    participant Kueue as Kueue TAS Solver (gke-dc-topology)
    participant JS as JobSet Controller
    participant Node1 as Node: on-demand-rack-1

    User->>JS: kubectl apply -f k8s/labs/lab2-tas-rack.yaml
    JS-->>Kueue: Workload created with required="workshop.ai/topology-rack"
    Kueue->>Kueue: Check rack-1 (3494m free >= 2400m needed) -> Match!
    Kueue->>JS: Admit Workload + Inject nodeSelector (hostname = on-demand-rack-1)
    JS->>Node1: Schedule BOTH workers-0-0 and workers-0-1 onto on-demand-rack-1
    Node1-->>User: Both ranks initialize on same rack node & complete 6 epochs
```

### 4. Execution & Verification Commands
```bash
make lab2
kubectl get pods -n team-a -o wide
kubectl logs -n team-a -l jobset.sigs.k8s.io/jobset-name=pytorch-tas-same-rack --prefix=true -f
make labs-clean
```

### 5. Verified Live GKE Output
```text
NAME                                      READY   STATUS      RESTARTS   AGE   IP           NODE
pytorch-tas-same-rack-workers-0-0-6xj5v   0/1     Completed   0          42s   10.20.2.9    gke-gke-kueue-worksh-on-demand-rack-1-37786744-3n48
pytorch-tas-same-rack-workers-0-1-bs9rg   0/1     Completed   0          42s   10.20.2.10   gke-gke-kueue-worksh-on-demand-rack-1-37786744-3n48

[pod/pytorch-tas-same-rack-workers-0-1-bs9rg/pytorch] [Rank 1/2] Initialized on Node: gke-gke-kueue-worksh-on-demand-rack-1-37786744-3n48
[pod/pytorch-tas-same-rack-workers-0-0-6xj5v/pytorch] [Rank 0/2] Initialized on Node: gke-gke-kueue-worksh-on-demand-rack-1-37786744-3n48
[pod/pytorch-tas-same-rack-workers-0-0-6xj5v/pytorch] Epoch [1/6] | World Size: 2 | Loss: 2.3051
...
[pod/pytorch-tas-same-rack-workers-0-0-6xj5v/pytorch] Epoch [6/6] | World Size: 2 | Loss: 2.3340
[pod/pytorch-tas-same-rack-workers-0-0-6xj5v/pytorch] Distributed Training Completed Successfully!
```

---

## Lab 3: Spot Spillover & Atomic `ProvisioningRequest` ([`k8s/labs/lab3-spot-atomic.yaml`](../k8s/labs/lab3-spot-atomic.yaml))

### 1. Scenario & Objective
When a 3-node training job (`3 Pods x 2.5 vCPU = 7.5 vCPU`) exceeds the `on-demand-flavor` max quota (`6 vCPU`), Kueue spills the workload over to `spot-flavor` (`9 vCPU` quota). Because `spot-atomic-pool` starts at `0` nodes, Kueue's `spot-atomic-check` `AdmissionCheck` creates a GKE `ProvisioningRequest` (`best-effort-atomic-scale-up.autoscaling.x-k8s.io`). GKE Cluster Autoscaler atomically scales `spot-atomic-pool` from `0 -> 3` Spot VMs before Kueue unsuspends the `JobSet`.

### 2. Manifest Breakdown
- `parallelism: 3`, `completions: 3`, `cpu: "2500m"` per Pod (`7500m` total $> 6000\text{m}$ `on-demand-flavor` quota).
- **No TAS annotations on Pod template:** Allows Kueue to skip TAS-only `on-demand-flavor` and route cleanly to non-TAS `spot-flavor`.
- Automatic taint toleration injection: `spot-flavor` injects `tier: spot` `nodeSelector` and `spot-only=true:NoSchedule` toleration upon admission.

### 3. Under-the-Hood Sequence Diagram

```mermaid
sequenceDiagram
    participant User as AI/ML Engineer
    participant Kueue as Kueue Controller
    participant PR as ProvisioningRequest (autoscaling.x-k8s.io/v1)
    participant CA as GKE Cluster Autoscaler
    participant Spot as spot-atomic-pool (0 -> 3 VMs)

    User->>Kueue: Submit pytorch-spot-atomic-scaleup (7.5 vCPU)
    Kueue->>Kueue: 7.5 vCPU > 6 vCPU (on-demand-flavor) -> Select spot-flavor
    Kueue->>Kueue: Reserve Quota (QuotaReserved=True) & Gate on spot-atomic-check
    Kueue->>PR: Create ProvisioningRequest (best-effort-atomic-scale-up.autoscaling.x-k8s.io)
    PR->>CA: Request atomic capacity for 3x 2.5 vCPU Pods
    CA->>Spot: Atomically provision 3x e2-standard-4 Spot VMs
    Spot-->>CA: 3 Spot Nodes Ready
    CA->>PR: Set Accepted=True, Provisioned=True
    PR-->>Kueue: spot-atomic-check Ready
    Kueue->>Spot: Unsuspend JobSet + Inject tier=spot & spot-only toleration -> Run 3 Ranks
```

### 4. Execution & Verification Commands
```bash
make lab3
kubectl get provisioningrequests,workloads -n team-a -w
kubectl get nodes -L workload,tier -w
kubectl logs -n team-a -l jobset.sigs.k8s.io/jobset-name=pytorch-spot-atomic-scaleup --prefix=true -f
make labs-clean
```

### 5. Verified Live GKE Output
```text
NAME                                                                                                    ACCEPTED   PROVISIONED   FAILED   AGE
provisioningrequest.autoscaling.x-k8s.io/jobset-pytorch-spot-atomic-scaleup-6c1c9-spot-atomic-check-1   True       True                   13s

NAME                                                  STATUS   ROLES    AGE   VERSION               WORKLOAD   TIER        TOPOLOGY-BLOCK   TOPOLOGY-RACK
gke-gke-kueue-worksh-on-demand-rack-1-37786744-3n48   Ready    <none>   27m   v1.36.4-gke.1391002              on-demand   block-1          rack-1
gke-gke-kueue-worksh-on-demand-rack-2-c183e097-qm0n   Ready    <none>   27m   v1.36.4-gke.1391002              on-demand   block-1          rack-2
gke-gke-kueue-worksh-spot-atomic-pool-1101bc94-74j5   Ready    <none>   80s   v1.36.4-gke.1391002              spot                         
gke-gke-kueue-worksh-spot-atomic-pool-1101bc94-7gz5   Ready    <none>   78s   v1.36.4-gke.1391002              spot                         
gke-gke-kueue-worksh-spot-atomic-pool-1101bc94-km4r   Ready    <none>   77s   v1.36.4-gke.1391002              spot                         
gke-gke-kueue-workshop-system-pool-be3c118f-6cgc      Ready    <none>   27m   v1.36.4-gke.1391002   system                                  

[pod/pytorch-spot-atomic-scaleup-workers-0-0-ht4l6/pytorch] [Rank 0/3] Initialized on Node: gke-gke-kueue-worksh-spot-atomic-pool-1101bc94-74j5
[pod/pytorch-spot-atomic-scaleup-workers-0-1-wpz7r/pytorch] [Rank 1/3] Initialized on Node: gke-gke-kueue-worksh-spot-atomic-pool-1101bc94-7gz5
[pod/pytorch-spot-atomic-scaleup-workers-0-2-2xzwq/pytorch] [Rank 2/3] Initialized on Node: gke-gke-kueue-worksh-spot-atomic-pool-1101bc94-km4r
[pod/pytorch-spot-atomic-scaleup-workers-0-0-ht4l6/pytorch] Epoch [1/6] | World Size: 3 | Loss: 2.3637
...
[pod/pytorch-spot-atomic-scaleup-workers-0-0-ht4l6/pytorch] Epoch [6/6] | World Size: 3 | Loss: 2.3533
[pod/pytorch-spot-atomic-scaleup-workers-0-0-ht4l6/pytorch] Distributed Training Completed Successfully!
```

---

## Lab 4: Priority-Based Intra-Queue Preemption ([`k8s/labs/lab4-preemption.yaml`](../k8s/labs/lab4-preemption.yaml))

### 1. Scenario & Objective
When a long-running exploratory job (`research-long-training`, `low-research-priority: 100`, `5 vCPU`) is actively running in `team-a-cq` and an urgent production job (`urgent-prod-training`, `high-prod-priority: 1000`, `5 vCPU`) arrives in the same queue, Kueue immediately **preempts (evicts)** `research-long-training` (`withinClusterQueue: LowerPriority`), runs `urgent-prod-training` to completion, and then **automatically re-admits** `research-long-training`.

### 2. Execution & Verification Commands
```bash
make lab4
kubectl get workloads,jobsets,pods -n team-a -w
make labs-clean
```

### 3. Verified Live GKE Output
```text
NAME                                                          QUEUE          RESERVED IN   ADMITTED   FINISHED   AGE
workload.kueue.x-k8s.io/jobset-research-long-training-c88c3   team-a-queue                 False                 11s
workload.kueue.x-k8s.io/jobset-urgent-prod-training-3da6f     team-a-queue   team-a-cq     True                  4s

# Preemption Condition on jobset-research-long-training-c88c3:
type: Evicted, status: True, reason: Preempted, Preempted: InClusterQueue
message: "Preempted to accommodate a workload (UID: a2c95349-03f6-4b17-bcba-1273cb1d9e46) due to prioritization in the ClusterQueue; preemptor path: /ai-org-cohort/team-a-cq; preemptee path: /ai-org-cohort/team-a-cq"

# urgent-prod-training completes 4 epochs, then research-long-training automatically re-admits:
NAME                                                          QUEUE          RESERVED IN   ADMITTED   FINISHED   AGE
workload.kueue.x-k8s.io/jobset-research-long-training-c88c3   team-a-queue   team-a-cq     True                  43s
workload.kueue.x-k8s.io/jobset-urgent-prod-training-3da6f     team-a-queue   team-a-cq     True       True       36s
```

---

## Lab 5: Multi-Team Cohort Quota Borrowing & Reclamation ([`k8s/labs/lab5-cohort-borrowing.yaml`](../k8s/labs/lab5-cohort-borrowing.yaml))

### 1. Scenario & Objective
In a multi-tenant AI organization (`ai-org-cohort`), `team-a-cq` and `team-b-cq` each own `3 vCPU` of nominal On-Demand quota with `borrowingLimit: "3"`.
1. While `team-b` is idle, `team-a` submits `team-a-cohort-borrower` (`high-prod-priority: 1000`, requesting `5 vCPUs`). Kueue allocates `3 vCPUs` from `team-a-cq`'s nominal quota and **borrows `2 vCPUs`** from `team-b-cq`.
2. Next, `team-b` submits `team-b-reclaim-owner` (`low-research-priority: 100`, requesting `2.5 vCPUs`).
3. **Key Insight:** Even though `team-b`'s workload has **lower priority** (`100` vs. `1000`), `team-b-cq` is reclaiming its own guaranteed nominal quota (`reclaimWithinCohort: Any`). Kueue immediately preempts `team-a-cohort-borrower` (`reason: InCohortReclamation`), runs `team-b-reclaim-owner` to completion, and then automatically re-admits `team-a-cohort-borrower`!

### 2. Under-the-Hood Sequence Diagram

```mermaid
sequenceDiagram
    participant TeamA as Team A (team-a-queue)
    participant Kueue as Kueue Cohort Engine (ai-org-cohort)
    participant TeamB as Team B (team-b-queue)

    TeamA->>Kueue: Submit team-a-cohort-borrower (5 vCPU, prio=1000)
    Kueue->>TeamA: Admit! (3 vCPU nominal + 2 vCPU borrowed from team-b-cq)
    TeamB->>Kueue: Submit team-b-reclaim-owner (2.5 vCPU, prio=100)
    Note over Kueue: team-b-cq needs 2.5 vCPU of its 3 vCPU nominal quota.<br/>reclaimWithinCohort: Any overrides priority (100 vs 1000)!
    Kueue->>TeamA: Evict team-a-cohort-borrower (reason: InCohortReclamation)
    Kueue->>TeamB: Admit team-b-reclaim-owner (2.5 vCPU) -> Run 4 Epochs
    TeamB-->>Kueue: Completed -> 2.5 vCPU released in team-b-cq
    Kueue->>TeamA: Automatically Re-Admit team-a-cohort-borrower (re-borrows 2 vCPU)
```

### 3. Execution & Verification Commands
```bash
make lab5
kubectl get workloads -A -w
make labs-clean
```

### 4. Verified Live GKE Output
```text
=== Team A ClusterQueue Quota Reservation (3 vCPU Nominal + 2 vCPU Borrowed = 5 vCPU) ===
[{"name":"on-demand-flavor","resources":[{"borrowed":"2","name":"cpu","total":"5"},{"borrowed":"0","name":"memory","total":"4Gi"}]}]

Submitting team-b-reclaim-owner (priority=100) in namespace team-b to reclaim nominal cohort quota...
NAMESPACE   NAME                                                          QUEUE          RESERVED IN   ADMITTED   FINISHED   AGE
team-a      workload.kueue.x-k8s.io/jobset-team-a-cohort-borrower-f56f7   team-a-queue                 False                 14s
team-b      workload.kueue.x-k8s.io/jobset-team-b-reclaim-owner-089bf     team-b-queue   team-b-cq     True                  6s

# Preemption Condition on team-a/jobset-team-a-cohort-borrower-f56f7:
type: Preempted, status: True, reason: InCohortReclamation
message: "Preempted to accommodate a workload (UID: d3a84e9b-3a0c-450a-a339-eda42f5931f0) due to reclamation within the cohort; preemptor path: /ai-org-cohort/team-b-cq; preemptee path: /ai-org-cohort/team-a-cq"

# Once team-b-reclaim-owner finishes its 4 epochs, team-a-cohort-borrower automatically re-borrows and resumes:
NAMESPACE   NAME                                  QUEUE          RESERVED IN   ADMITTED   FINISHED   AGE
team-a      jobset-team-a-cohort-borrower-c7d66   team-a-queue   team-a-cq     True                  41s
team-b      jobset-team-b-reclaim-owner-524bb     team-b-queue   team-b-cq     True       True       32s
```

---

## Lab 6: Distributed Multi-Pod Inference with `LeaderWorkerSet` & Cross-PodSet TAS ([`k8s/labs/lab6-lws-inference-tas.yaml`](../k8s/labs/lab6-lws-inference-tas.yaml))

### 1. Scenario & Objective
Large Language Models (LLMs) that exceed a single node or socket require multi-pod **Tensor-Parallel (TP)** serving using **LeaderWorkerSet (`leaderworkerset.x-k8s.io/v1`)**, where a Leader Pod (`Rank 0`, serving HTTP `/infer`) and Worker Pod(s) (`Rank 1`, holding model tensor shards) execute synchronous `dist.broadcast` and `dist.all_reduce` operations on every forward pass.
Because LWS creates **two distinct PodSets** (`leader` and `worker`), we use Kueue's **Cross-PodSet TAS grouping** (`kueue.x-k8s.io/podset-group-name: "lws-rack-group"` + `kueue.x-k8s.io/podset-required-topology: "workshop.ai/topology-rack"`) to guarantee both the Leader Pod and Worker Pod are co-located on the **exact same physical rack node**.

### 2. Under-the-Hood Sequence Diagram

```mermaid
sequenceDiagram
    participant User as AI/ML Engineer
    participant LWS as LWS Controller
    participant Kueue as Kueue TAS Solver (podset-group-name)
    participant Leader as Pod: lws-tas-infer-0 (Rank 0)
    participant Worker as Pod: lws-tas-infer-0-1 (Rank 1)

    User->>LWS: kubectl apply -f lab6-lws-inference-tas.yaml
    LWS-->>Kueue: Create 2-PodSet Workload (group="lws-rack-group", required="topology-rack")
    Kueue->>Kueue: Co-locate BOTH leader (1000m) + worker (1000m) onto on-demand-rack-2
    Kueue->>LWS: Unsuspend Pods with nodeSelector (hostname = on-demand-rack-2)
    Leader->>Worker: torch.distributed.init_process_group("gloo") + 3 Warmup AllReduce passes
    User->>Leader: HTTP GET http://localhost:8080/infer
    Leader->>Worker: dist.broadcast(input) + dist.all_reduce(shard_logits, SUM)
    Worker-->>Leader: Synchronized TP Logits (3.75ms)
    Leader-->>User: JSON {"predicted_class": 7, "all_reduce_latency_ms": 3.757}
```

### 3. Execution & Verification Commands
```bash
make lab6
kubectl wait --for=condition=Ready pod/lws-tas-infer-0 -n team-a --timeout=90s
kubectl get pods -n team-a -o wide
kubectl exec -n team-a lws-tas-infer-0 -- python3 -c "import urllib.request; print(urllib.request.urlopen('http://localhost:8080/infer').read().decode())"
make labs-clean
```

### 4. Verified Live GKE Output
```text
NAME                READY   STATUS    RESTARTS   AGE   IP           NODE
lws-tas-infer-0     1/1     Running   0          9s    10.20.0.25   gke-gke-kueue-worksh-on-demand-rack-2-c183e097-qm0n
lws-tas-infer-0-1   1/1     Running   0          9s    10.20.0.26   gke-gke-kueue-worksh-on-demand-rack-2-c183e097-qm0n

# Live HTTP /infer response:
{"model": "pytorch-tp-mlp-2shard", "backend": "gloo", "world_size": 2, "leader_node": "gke-gke-kueue-worksh-on-demand-rack-2-c183e097-qm0n", "predicted_class": 7, "sample_logits": [0.5019, -0.2728, 0.2568, -0.2808], "all_reduce_latency_ms": 3.757}
```

---

## Lab 7: Stateful DDP Checkpointing & Graceful Preemption Resume ([`k8s/labs/lab7-checkpoint-resume.yaml`](../k8s/labs/lab7-checkpoint-resume.yaml))

### 1. Scenario & Objective
In **Lab 4** and **Lab 5**, preempted workloads restarted from Epoch 1 upon re-admission, losing their prior training compute ("badput"). **Lab 7** demonstrates **zero-goodput-loss stateful checkpointing**:
1. `resumable-research-job` (`priority=100`, `5 vCPUs`, `8` epochs) runs `exec torchrun ... /workspace/train_checkpoint.py` (`ConfigMap/pytorch-checkpoint-script`) and atomically saves `model_state_dict`, `optimizer_state_dict`, and `epoch` to `/var/tmp/kueue-checkpoints/lab7_ckpt.pt` after every epoch.
2. After completing **Epoch 4/8**, `urgent-checkpoint-preemptor` (`priority=1000`, `5 vCPUs`, `3` epochs) arrives and preempts `resumable-research-job`.
3. Once `urgent-checkpoint-preemptor` finishes its 3 epochs, Kueue automatically re-admits `resumable-research-job`. On startup, both ranks load the checkpoint, synchronize `synced_epoch = 4` via `dist.all_reduce(..., ReduceOp.MAX)`, and **resume directly at Epoch 5/8** (`Zero Goodput Lost!`).

### 2. Under-the-Hood Sequence Diagram

```mermaid
sequenceDiagram
    participant ResJob as resumable-research-job (prio=100)
    participant Ckpt as Node Checkpoint (/var/tmp/kueue-checkpoints)
    participant Kueue as Kueue Controller (team-a-cq)
    participant Urgent as urgent-checkpoint-preemptor (prio=1000)

    Kueue->>ResJob: Initial Admission (5 vCPU) -> Fresh Start (Epoch 1/8)
    ResJob->>Ckpt: Save atomic checkpoint after Epochs 1, 2, 3, 4
    Urgent->>Kueue: Submit urgent-checkpoint-preemptor (5 vCPU, prio=1000)
    Kueue->>ResJob: Preempt! Send SIGTERM (exec torchrun PID 1)
    ResJob->>Ckpt: Persist Epoch 4 state & exit cleanly
    Kueue->>Urgent: Admit urgent-checkpoint-preemptor -> Complete 3 Epochs
    Kueue->>ResJob: Automatically Re-Admit resumable-research-job!
    ResJob->>Ckpt: Load Epoch 4 state + dist.all_reduce(MAX) across ranks
    ResJob-->>Kueue: Resume from Epoch 5/8 -> Complete Epochs 5..8!
```

### 3. Execution & Verification Commands
```bash
# Starts resumable-research-job, waits for ~4 epochs, prints pre-preemption logs, and submits urgent-checkpoint-preemptor
make lab7

# Wait for urgent-checkpoint-preemptor to finish and resumable-research-job to be re-admitted
kubectl wait --for=condition=Completed jobset/urgent-checkpoint-preemptor -n team-a --timeout=120s
kubectl wait --for=condition=Ready pod -l jobset.sigs.k8s.io/jobset-name=resumable-research-job -n team-a --timeout=90s

# Inspect resumed logs proving training continued from Epoch 5/8!
kubectl logs -l jobset.sigs.k8s.io/jobset-name=resumable-research-job,batch.kubernetes.io/job-completion-index=0 -n team-a -f

# Clean up
make labs-clean
```

### 4. Verified Live GKE Output
```text
=== Pre-Preemption Logs (resumable-research-job Rank 0) ===
[Rank 0/2] Initialized on Node: gke-gke-kueue-worksh-on-demand-rack-1-37786744-3n48 | Checkpoint Path: /var/tmp/kueue-checkpoints/lab7_ckpt.pt
🆕 [FRESH START] No checkpoint found. Starting from Epoch 1/8
Epoch [1/8] | World Size: 2 | Loss: 2.3228 | 💾 Checkpoint saved (/var/tmp/kueue-checkpoints/lab7_ckpt.pt)
Epoch [2/8] | World Size: 2 | Loss: 2.3187 | 💾 Checkpoint saved (/var/tmp/kueue-checkpoints/lab7_ckpt.pt)
Epoch [3/8] | World Size: 2 | Loss: 2.3130 | 💾 Checkpoint saved (/var/tmp/kueue-checkpoints/lab7_ckpt.pt)
Epoch [4/8] | World Size: 2 | Loss: 2.3255 | 💾 Checkpoint saved (/var/tmp/kueue-checkpoints/lab7_ckpt.pt)

Submitting urgent-checkpoint-preemptor (priority=1000) to preempt resumable-research-job...
jobset.jobset.x-k8s.io/urgent-checkpoint-preemptor created

=== Final Completed Logs After Automatic Re-Admission (resumable-research-job Rank 0) ===
[Rank 0/2] Initialized on Node: gke-gke-kueue-worksh-on-demand-rack-1-37786744-3n48 | Checkpoint Path: /var/tmp/kueue-checkpoints/lab7_ckpt.pt
🔄 [RESUMED FROM CHECKPOINT] Found saved state at Epoch 4! Resuming training from Epoch 5/8 (Zero Goodput Lost!)
Epoch [5/8] | World Size: 2 | Loss: 2.3044 | 💾 Checkpoint saved (/var/tmp/kueue-checkpoints/lab7_ckpt.pt)
Epoch [6/8] | World Size: 2 | Loss: 2.3017 | 💾 Checkpoint saved (/var/tmp/kueue-checkpoints/lab7_ckpt.pt)
Epoch [7/8] | World Size: 2 | Loss: 2.2941 | 💾 Checkpoint saved (/var/tmp/kueue-checkpoints/lab7_ckpt.pt)
Epoch [8/8] | World Size: 2 | Loss: 2.3062 | 💾 Checkpoint saved (/var/tmp/kueue-checkpoints/lab7_ckpt.pt)
🎉 Distributed Training Completed All 8 Epochs Successfully! (Cleaned up /var/tmp/kueue-checkpoints/lab7_ckpt.pt)
```

---

## Lab 8: CEL `ValidatingAdmissionPolicy` Governance & `max-exec-time-seconds` SLA ([`k8s/labs/lab8-governance-and-max-exec.yaml`](../k8s/labs/lab8-governance-and-max-exec.yaml))

### 1. Scenario & Objective
Production multi-tenant AI platforms require two hard guardrails:
1. **Zero-Bypass Queue Governance (Step 8A):** Using a native Kubernetes `ValidatingAdmissionPolicy` (`require-kueue-queue-name` bound to namespaces with `kueue-governance: "enforced"`), any `JobSet` or `LeaderWorkerSet` that omits `kueue.x-k8s.io/queue-name` (`unlabeled-rogue-jobset`) is **synchronously rejected** by the Kubernetes API Server before a single Pod can be created.
2. **Maximum Execution Time SLA Enforcement (Step 8B):** By labeling `sla-time-bounded-job` with `kueue.x-k8s.io/max-exec-time-seconds: "20"`, Kueue sets `spec.maximumExecutionTimeSeconds: 20` on the `Workload`. When the job's runtime exceeds 20 seconds, Kueue automatically **evicts and deactivates** (`spec.active: false`) the runaway job with `reason: DeactivatedDueToMaximumExecutionTimeExceeded`.

### 2. Under-the-Hood Sequence Diagram

```mermaid
sequenceDiagram
    participant User as AI/ML Engineer
    participant APIServer as K8s API Server (CEL Policy)
    participant Kueue as Kueue Controller (SLA Timer)
    participant Job as JobSet: sla-time-bounded-job

    User->>APIServer: 8A: Submit unlabeled-rogue-jobset (no queue-name label)
    APIServer-->>User: DENIED! ValidatingAdmissionPolicy 'require-kueue-queue-name'
    User->>APIServer: 8B: Submit sla-time-bounded-job (queue-name + max-exec-time-seconds="20")
    APIServer->>Kueue: Allowed -> Create Workload (maximumExecutionTimeSeconds: 20)
    Kueue->>Job: Admit Workload -> Pods Running (t = 0s..20s)
    Note over Kueue,Job: t = 20s: Execution Lease Expired!
    Kueue->>Job: Evict & Deactivate Workload (spec.active = false, reason: DeactivatedDueToMaximumExecutionTimeExceeded)
```

### 3. Execution & Verification Commands
```bash
make lab8
kubectl get workloads,jobsets,pods -n team-a
make labs-clean
```

### 4. Verified Live GKE Output
```text
=== Step 8A: Attempting to submit unlabeled-rogue-jobset (omits kueue.x-k8s.io/queue-name) ===
The jobsets "unlabeled-rogue-jobset" is invalid: : ValidatingAdmissionPolicy 'require-kueue-queue-name' with binding 'require-kueue-queue-name-binding' denied request: Platform Governance Policy Violation: All JobSet and LeaderWorkerSet workloads in Kueue-managed namespaces MUST specify a non-empty 'kueue.x-k8s.io/queue-name' label.
✅ CEL ValidatingAdmissionPolicy successfully blocked the unlabeled rogue workload!

=== Step 8B: Submitting sla-time-bounded-job (kueue.x-k8s.io/max-exec-time-seconds: 20) ===
jobset.jobset.x-k8s.io/sla-time-bounded-job created

=== Workload Admitted with spec.maximumExecutionTimeSeconds=20 ===
NAME                                QUEUE          MAX_EXEC_SEC   ACTIVE   ADMITTED
jobset-sla-time-bounded-job-c73ae   team-a-queue   20             true     True

Waiting ~25s for 20-second SLA lease to expire and Kueue to auto-evict the runaway job...

=== Workload Status After 20s SLA Expiration (MaximumExecutionTimeExceeded -> Active=false) ===
NAME                                ACTIVE   EVICTED_REASON                                 MESSAGE
jobset-sla-time-bounded-job-c73ae   false    DeactivatedDueToMaximumExecutionTimeExceeded   The workload is deactivated due to exceeding the maximum execution time
```

---

## Lab 9: Kueue Visibility API & Prometheus Metrics Observability ([`k8s/labs/lab9-visibility-and-metrics.yaml`](../k8s/labs/lab9-visibility-and-metrics.yaml))

### 1. Scenario & Objective
When multiple workloads are queued waiting for capacity, AI engineers ask *"Where is my job in the queue?"* and platform SREs ask *"What is our queue depth, admission rate, and quota utilization?"*
1. `obs-occupier-job` (`5 vCPU`, `priority=1000`) is admitted first, leaving only `1 vCPU` free in `team-a-cq`'s On-Demand quota.
2. `obs-queued-low` (`4 vCPU`, `priority=100`) is submitted at `t = 22:32:13Z` and enters the pending queue.
3. `obs-queued-high` (`4 vCPU`, `priority=1000`) is submitted 3 seconds later at `t = 22:32:16Z`.
4. Querying Kueue's **On-Demand Visibility API** (`/apis/visibility.kueue.x-k8s.io/v1beta2/namespaces/team-a/localqueues/team-a-queue/pendingworkloads`) proves that `obs-queued-high` jumped ahead of `obs-queued-low` to **`positionInClusterQueue: 0`** (`positionInLocalQueue: 0`).
5. Scraping Kueue's **Prometheus `/metrics` endpoint** (`:8443/metrics`) exports live `kueue_pending_workloads`, `kueue_admitted_workloads_total`, `kueue_cluster_queue_nominal_quota`, and `kueue_cluster_queue_resource_usage` metrics.

### 2. Under-the-Hood Sequence Diagram

```mermaid
sequenceDiagram
    participant User as AI Engineer / SRE
    participant Kueue as Kueue Queue Manager
    participant VisAPI as Visibility Server (visibility.kueue.x-k8s.io/v1beta2)
    participant Prom as Prometheus Metrics (:8443/metrics)

    User->>Kueue: 1. Submit obs-occupier-job (5 vCPU, prio=1000) -> Admitted!
    User->>Kueue: 2. Submit obs-queued-low (4 vCPU, prio=100, t=13s) -> Pending
    User->>Kueue: 3. Submit obs-queued-high (4 vCPU, prio=1000, t=16s) -> Pending
    Note over Kueue: Kueue reorders pending heap:<br/>obs-queued-high (pos=0) > obs-queued-low (pos=1)
    User->>VisAPI: GET /apis/visibility.kueue.x-k8s.io/v1beta2/.../pendingworkloads
    VisAPI-->>User: PendingWorkloadsSummary (obs-queued-high=0, obs-queued-low=1)
    User->>Prom: GET https://kueue-controller-manager-metrics-service:8443/metrics
    Prom-->>User: kueue_cluster_queue_resource_usage=5, kueue_pending_workloads=2
```

### 3. Execution & Verification Commands
```bash
# Submits the 3 workloads, queries the Visibility API, and scrapes Prometheus metrics
make lab9

# Clean up
make labs-clean
```

### 4. Verified Live GKE Output
```text
=== Step 9C: Kueue Visibility API (v1beta2 PendingWorkloadsSummary on team-a-queue) ===
{
    "kind": "PendingWorkloadsSummary",
    "apiVersion": "visibility.kueue.x-k8s.io/v1beta2",
    "metadata": {},
    "items": [
        {
            "metadata": {
                "name": "jobset-obs-queued-high-9171b",
                "namespace": "team-a",
                "creationTimestamp": "2026-10-13T22:32:16Z",
                "ownerReferences": [
                    {
                        "apiVersion": "jobset.x-k8s.io/v1alpha2",
                        "kind": "JobSet",
                        "name": "obs-queued-high",
                        "uid": "d3698628-5a81-41de-99b6-875f17a532ed"
                    }
                ]
            },
            "priority": 1000,
            "localQueueName": "team-a-queue",
            "positionInClusterQueue": 0,
            "positionInLocalQueue": 0
        },
        {
            "metadata": {
                "name": "jobset-obs-queued-low-8378d",
                "namespace": "team-a",
                "creationTimestamp": "2026-10-13T22:32:13Z",
                "ownerReferences": [
                    {
                        "apiVersion": "jobset.x-k8s.io/v1alpha2",
                        "kind": "JobSet",
                        "name": "obs-queued-low",
                        "uid": "91fb9c6e-2786-437d-b1bd-4155d57712f3"
                    }
                ]
            },
            "priority": 100,
            "localQueueName": "team-a-queue",
            "positionInClusterQueue": 1,
            "positionInLocalQueue": 1
        }
    ]
}

=== Step 9D: Scraping Kueue Prometheus Metrics (/metrics on :8443) ===
kueue_admitted_workloads_total{cluster_queue="team-a-cq",priority_class="high-prod-priority",replica_role="leader"} 1
kueue_admitted_workloads_total{cluster_queue="team-a-cq",priority_class="low-research-priority",replica_role="leader"} 1
kueue_cluster_queue_nominal_quota{cluster_queue="team-a-cq",cohort="ai-org-cohort",flavor="on-demand-flavor",replica_role="leader",resource="cpu"} 3
kueue_cluster_queue_nominal_quota{cluster_queue="team-a-cq",cohort="ai-org-cohort",flavor="on-demand-flavor",replica_role="leader",resource="memory"} 8.589934592e+09
kueue_cluster_queue_nominal_quota{cluster_queue="team-a-cq",cohort="ai-org-cohort",flavor="spot-flavor",replica_role="leader",resource="cpu"} 9
kueue_cluster_queue_nominal_quota{cluster_queue="team-a-cq",cohort="ai-org-cohort",flavor="spot-flavor",replica_role="leader",resource="memory"} 2.5769803776e+10
kueue_cluster_queue_resource_usage{cluster_queue="team-a-cq",cohort="ai-org-cohort",flavor="on-demand-flavor",replica_role="leader",resource="cpu"} 5
kueue_cluster_queue_resource_usage{cluster_queue="team-a-cq",cohort="ai-org-cohort",flavor="on-demand-flavor",replica_role="leader",resource="memory"} 4.294967296e+09
kueue_cluster_queue_resource_usage{cluster_queue="team-a-cq",cohort="ai-org-cohort",flavor="spot-flavor",replica_role="leader",resource="cpu"} 0
kueue_cluster_queue_resource_usage{cluster_queue="team-a-cq",cohort="ai-org-cohort",flavor="spot-flavor",replica_role="leader",resource="memory"} 0
kueue_pending_workloads{cluster_queue="team-a-cq",replica_role="leader",status="active"} 0
kueue_pending_workloads{cluster_queue="team-a-cq",replica_role="leader",status="inadmissible"} 2
```
