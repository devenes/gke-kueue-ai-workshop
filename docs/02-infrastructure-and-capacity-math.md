# 02 — Infrastructure & Capacity Math: Terraform & GKE Design

This document details the infrastructure design in [`terraform/`](../terraform/) and the capacity engineering math behind our GKE node pools, multi-team cohort quotas, and lab resource requests across Labs 1–9.

---

## 1. Strict Separation of Concerns (Infra vs. Kubernetes)

This repository enforces a strict **two-layer architecture**:

| Layer | Directory / Tooling | Provider / Mechanism | Scope |
| :--- | :--- | :--- | :--- |
| **Layer 1: Cloud Infrastructure** | [`terraform/`](../terraform/) | **100% `hashicorp/google` (`~> 6.0`)** | GCP APIs, Custom VPC, Secondary Subnets, Node IAM Service Account, Zonal GKE Standard Cluster (`europe-west1-b`), and 4 Node Pools with declarative labels/taints. |
| **Layer 2: Kubernetes & Batch Orchestration** | [`k8s/`](../k8s/) & [`Makefile`](../Makefile) | **Helm OCI + Kustomize + `kubectl`** | Upstream `jobset` (`0.10.1`), `lws` (`0.11.1`), and `kueue` (`0.16.2`) operators, `kueue.x-k8s.io/v1beta2` scheduling primitives, CEL `ValidatingAdmissionPolicy`, and Labs 1–9 manifests. |

---

## 2. Node Pool Architecture & Real Allocatable CPU Math

### The 4 Node Pools

| Node Pool Name | Machine Type | Scaling / Count | Node Labels | Taints | Purpose |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`system-pool`** | `e2-standard-2`<br>(2 vCPU, 8 GB) | Fixed: `1` | `workload=system` | None | Hosts `jobset-controller` (`500m`), `kueue-controller-manager` (`500m`), and `lws-controller-manager` (`100m`) via `nodeSelector`. |
| **`on-demand-rack-1`** | `e2-standard-4`<br>(4 vCPU, 16 GB) | Fixed: `1` | `tier=on-demand`<br>`workshop.ai/topology-block=block-1`<br>`workshop.ai/topology-rack=rack-1` | None | Rack 1 capacity for `on-demand-flavor` (TAS enabled). |
| **`on-demand-rack-2`** | `e2-standard-4`<br>(4 vCPU, 16 GB) | Fixed: `1` | `tier=on-demand`<br>`workshop.ai/topology-block=block-1`<br>`workshop.ai/topology-rack=rack-2` | None | Rack 2 capacity for `on-demand-flavor` (TAS enabled). |
| **`spot-atomic-pool`** | `e2-standard-4`<br>(4 vCPU, 16 GB, Spot) | Autoscaled: `0 -> 3`<br>(`location_policy=ANY`) | `tier=spot` | `spot-only=true:NoSchedule` | Atomic scale-up pool for `spot-flavor` via GKE `ProvisioningRequest`. |

### Live GKE `v1.36` Node Allocatable CPU Audit

From our live `kubectl describe nodes` audit on GKE `v1.36.4-gke.1391002`:

$$
\begin{aligned}
\text{System Pool Free CPU (`e2-standard-2`)} &= 1930\text{m (Allocatable)} - 1416\text{m (System + 3 Operators)} = \mathbf{514\text{m}} \\
\text{Rack 1 Free CPU (`e2-standard-4`)} &= 3920\text{m (Allocatable)} - 426\text{m (System Pods)} = \mathbf{3494\text{m}} \ (\approx 3.49\text{ vCPU}) \\
\text{Rack 2 Free CPU (`e2-standard-4`)} &= 3920\text{m (Allocatable)} - 628\text{m (System Pods)} = \mathbf{3292\text{m}} \ (\approx 3.29\text{ vCPU}) \\
\text{Total On-Demand Free CPU} &= 3494\text{m} + 3292\text{m} = \mathbf{6786\text{m}} \ (\approx 6.78\text{ vCPU})
\end{aligned}
$$

> [!IMPORTANT]
> **Right-Sizing Operator Requests on `system-pool`:**
> The upstream `lws` Helm chart defaults to `resources.requests.cpu: 1` (`1000m`), which would exceed the `614m` remaining CPU on `system-pool` (`e2-standard-2`) after `jobset` (`500m`) and `kueue` (`500m`) are scheduled. Setting `--set resources.requests.cpu=100m --set resources.requests.memory=128Mi` for `lws` allows all three operators (`jobset`, `lws`, and `kueue`) to run comfortably on a single `e2-standard-2` control-plane node while leaving `0m` operator overhead on the `on-demand` worker nodes.

---

## 3. Multi-Team Cohort Quota Math (`ai-org-cohort`)

Both `team-a-cq` and `team-b-cq` belong to `cohortName: "ai-org-cohort"`:

| ClusterQueue | Flavor | `nominalQuota` | `borrowingLimit` | Effective Max (When Peer Idle) | Preemption / Reclamation Policy |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`team-a-cq`** | `on-demand-flavor` | `3` vCPU / `8Gi` | `3` vCPU / `8Gi` | **`6` vCPU / `16Gi`** | `reclaimWithinCohort: Any`<br>`withinClusterQueue: LowerPriority`<br>`borrowWithinCohort: LowerPriority` |
| **`team-a-cq`** | `spot-flavor` | `9` vCPU / `24Gi` | `0` (`lendingLimit: 0`) | **`9` vCPU / `24Gi`** | Dedicated to `team-a-cq` with `spot-atomic-check` |
| **`team-b-cq`** | `on-demand-flavor` | `3` vCPU / `8Gi` | `3` vCPU / `8Gi` | **`6` vCPU / `16Gi`** | `reclaimWithinCohort: Any`<br>`withinClusterQueue: LowerPriority` |
| **`team-b-cq`** | `spot-flavor` | `0` vCPU / `0` | `0` vCPU / `0` | **`0`** | N/A |

### Why This Split Preserves 100% Backward Compatibility
- In **Labs 1–4** and **Labs 6–9**, `team-b` has no active workloads, so `team-a-cq` transparently borrows up to `3 vCPUs` from `team-b-cq`, giving `team-a` the exact same **`6 vCPU` effective On-Demand quota** (`3` nominal + `3` borrowed).
- In **Lab 5**, when `team-a` runs a `5 vCPU` job (`3` nominal + `2` borrowed) and `team-b` submits a `2.5 vCPU` job into `team-b-queue`, `team-b-cq` reclaims its lent `2 vCPUs` (`reclaimWithinCohort: Any`), preempting `team-a`'s borrowing workload even though `team-b`'s job has a lower `WorkloadPriorityClass` (`100` vs. `1000`).

---

## 4. End-to-End Capacity Matrix Across Labs 1–9

| Lab Scenario | Workload Kind | Pods $\times$ CPU Request | Total CPU | Scheduling & Quota Math |
| :--- | :--- | :--- | :--- | :--- |
| **Lab 1: Gang Scheduling** | `JobSet` (`team-a`) | $2 \times 2000\text{m}$ | **$4000\text{m}$** | **JobSet 1 (`4000m`)** uses `3000m` nominal + `1000m` borrowed (`1` Pod per rack). **JobSet 2 (`4000m`)** sees only `2000m` remaining in the cohort and waits suspended. |
| **Lab 2: TAS Same-Rack** | `JobSet` (`team-a`) | $2 \times 1200\text{m}$ | **$2400\text{m}$** | Both Pods co-locate on **one** rack node (`podset-required-topology: workshop.ai/topology-rack`, $2400\text{m} \le 3292\text{m}$). |
| **Lab 3: Spot Atomic Scale-Up** | `JobSet` (`team-a`) | $3 \times 2500\text{m}$ | **$7500\text{m}$** | Exceeds `on-demand-flavor` max (`6000m`); routes to `spot-flavor` (`9000m` quota) and scales `spot-atomic-pool` `0 -> 3` VMs atomically. |
| **Lab 4: Intra-Queue Preemption** | `JobSet` (`team-a`) | $2 \times 2500\text{m}$ | **$5000\text{m}$** | `urgent-prod-training` (`prio=1000`, `5000m`) preempts `research-long-training` (`prio=100`, `5000m`) inside `team-a-cq`. |
| **Lab 5: Cohort Reclamation** | `JobSet` (`team-a` & `team-b`) | Team A: $2 \times 2500\text{m}$<br>Team B: $1 \times 2500\text{m}$ | **$5000\text{m}$**<br>**$2500\text{m}$** | Team A borrows `2000m` from `team-b-cq`. When Team B submits a `2500m` job (`prio=100`), `team-b-cq` reclaims its nominal quota and preempts Team A (`prio=1000`). |
| **Lab 6: LWS Cross-PodSet TAS** | `LeaderWorkerSet` (`team-a`) | $1\text{ Leader} \times 1000\text{m}$<br>$+ 1\text{ Worker} \times 1000\text{m}$ | **$2000\text{m}$** | `podset-group-name: "lws-rack-group"` + `podset-required-topology: "workshop.ai/topology-rack"` co-locates both Leader and Worker Pods ($2000\text{m} \le 3292\text{m}$) on the exact same rack node. |
| **Lab 7: Checkpoint & Resume** | `JobSet` (`team-a`) | Resumable: $2 \times 2500\text{m}$<br>Preemptor: $2 \times 2500\text{m}$ | **$5000\text{m}$**<br>**$5000\text{m}$** | `resumable-research-job` saves checkpoints at Epochs 1–4, gets preempted by `urgent-checkpoint-preemptor` (`5000m`), and resumes from **Epoch 5/8** upon re-admission. |
| **Lab 8: CEL & Max-Exec-Time** | `JobSet` (`team-a`) | $2 \times 1500\text{m}$ | **$3000\text{m}$** | Unlabeled `JobSet` is rejected at admission by CEL `ValidatingAdmissionPolicy`; labeled `sla-time-bounded-job` (`3000m`) is auto-evicted & deactivated after `20s`. |
| **Lab 9: Visibility & Metrics** | `JobSet` (`team-a`) | Occupier: $2 \times 2500\text{m}$<br>Queued Low: $2 \times 2000\text{m}$<br>Queued High: $2 \times 2000\text{m}$ | **$5000\text{m}$**<br>**$4000\text{m}$**<br>**$4000\text{m}$** | `obs-occupier-job` reserves `5000m` (`1000m` left); `obs-queued-low` (`4000m`, `prio=100`) and `obs-queued-high` (`4000m`, `prio=1000`) queue behind it, with `obs-queued-high` jumping to Position `0`. |
