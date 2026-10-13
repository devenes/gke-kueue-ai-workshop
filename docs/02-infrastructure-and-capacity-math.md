# 02 — Infrastructure & Capacity Math: Terraform & GKE Design

This document details the infrastructure design in [`terraform/`](../terraform/) and the capacity engineering math behind our GKE node pools and Kueue quotas.

---

## 1. Strict Separation of Concerns (Infra vs. Kubernetes)

A common anti-pattern in platform engineering is mixing cloud infrastructure resources (`google_container_cluster`) and in-cluster Kubernetes CRDs (`ClusterQueue`, `Topology`) inside the same Terraform state using the `kubernetes`, `helm`, or `kubectl` Terraform providers. When a cluster is recreated or when CRD webhooks fail, the unified Terraform state deadlocks.

This repository enforces a **two-layer architecture**:

| Layer | Directory / Tooling | Provider / Mechanism | Scope |
| :--- | :--- | :--- | :--- |
| **Layer 1: Cloud Infrastructure** | [`terraform/`](../terraform/) | **100% `hashicorp/google` (`~> 6.0`)** | GCP APIs, Custom VPC, Secondary Subnets, Node IAM Service Account, Zonal GKE Standard Cluster (`europe-west1-b`), and 4 Node Pools with declarative labels/taints. |
| **Layer 2: Kubernetes & Batch Orchestration** | [`k8s/`](../k8s/) & [`Makefile`](../Makefile) | **Helm OCI + Kustomize + `kubectl`** | Upstream `jobset` (`0.10.1`) and `kueue` (`0.16.2`) operators, `kueue.x-k8s.io/v1beta2` scheduling primitives, and `JobSet` lab manifests. |

---

## 2. Why Zonal GKE Standard over GKE Autopilot?

1. **Deterministic Rack-Level Topology Aware Scheduling (TAS):**
   In GKE Autopilot, nodes are managed dynamically per workload, preventing us from pre-labeling two distinct rack pools (`on-demand-rack-1` and `on-demand-rack-2`) to demonstrate same-rack vs. cross-rack placement on pre-warmed capacity.
2. **Instant Sub-Second Admission for Labs 1, 2, and 4:**
   Pre-provisioning `2x e2-standard-4` on-demand nodes allows Labs 1, 2, and 4 to execute in seconds without waiting for VM creation, while **Lab 3** specifically isolates `0 -> 3` atomic VM provisioning on the `spot-atomic-pool`.
3. **Single-Zone Cost & Quota Efficiency (`europe-west1-b`):**
   Deploying a Zonal cluster in `europe-west1-b` avoids multiplying node counts and CPU quotas by $3\times$ across three availability zones.

---

## 3. Declarative Custom Topology Labels (`workshop.ai/topology-*`)

The Google Kubernetes Engine API forbids user-defined `node_config.labels` that use reserved Google prefixes such as `cloud.google.com/` (e.g., `cloud.google.com/gke-topology-block`).

To make Kueue Topology Aware Scheduling work **100% declaratively out of the box** without running imperative `kubectl label node` scripts after cluster creation, [`terraform/gke.tf`](../terraform/gke.tf) provisions the on-demand rack pools via `for_each = toset(["rack-1", "rack-2"])` with custom domain labels:

```hcl
resource "google_container_node_pool" "on_demand_tas" {
  for_each   = toset(["rack-1", "rack-2"])
  name       = "on-demand-${each.key}"
  ...
  node_config {
    machine_type = "e2-standard-4"
    labels = {
      "tier"                       = "on-demand"
      "workshop.ai/topology-block" = "block-1"
      "workshop.ai/topology-rack"  = each.key
    }
  }
}
```

These labels map directly to the `Topology` CRD in [`k8s/base/kueue-setup.yaml`](../k8s/base/kueue-setup.yaml):

```yaml
apiVersion: kueue.x-k8s.io/v1beta2
kind: Topology
metadata:
  name: gke-dc-topology
spec:
  levels:
  - nodeLabel: "workshop.ai/topology-block"
  - nodeLabel: "workshop.ai/topology-rack"
  - nodeLabel: "kubernetes.io/hostname"
```

---

## 4. Node Pool Architecture & Real Allocatable CPU Math

### The 4 Node Pools

| Node Pool Name | Machine Type | Scaling / Count | Node Labels | Taints | Purpose |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`system-pool`** | `e2-standard-2`<br>(2 vCPU, 8 GB) | Fixed: `1` | `workload=system` | None | Hosts `jobset-controller` (`500m`) and `kueue-controller-manager` (`500m`) via `nodeSelector`. |
| **`on-demand-rack-1`** | `e2-standard-4`<br>(4 vCPU, 16 GB) | Fixed: `1` | `tier=on-demand`<br>`workshop.ai/topology-block=block-1`<br>`workshop.ai/topology-rack=rack-1` | None | Rack 1 capacity for `on-demand-flavor` (TAS enabled). |
| **`on-demand-rack-2`** | `e2-standard-4`<br>(4 vCPU, 16 GB) | Fixed: `1` | `tier=on-demand`<br>`workshop.ai/topology-block=block-1`<br>`workshop.ai/topology-rack=rack-2` | None | Rack 2 capacity for `on-demand-flavor` (TAS enabled). |
| **`spot-atomic-pool`** | `e2-standard-4`<br>(4 vCPU, 16 GB, Spot) | Autoscaled: `0 -> 3`<br>(`location_policy=ANY`) | `tier=spot` | `spot-only=true:NoSchedule` | Atomic scale-up pool for `spot-flavor` via GKE `ProvisioningRequest`. |

### Live GKE `v1.36` Node Allocatable CPU Audit

On an `e2-standard-4` node (4000m raw vCPU), Kubernetes reserves `80m` for kubelet/OS overhead (`Allocatable: 3920m`), and GKE system DaemonSets (`fluentbit-gke`, `gke-metrics-agent`, `netd`, `kube-proxy`, `pdcsi-node`) consume `426m–628m` per node.

From our live `kubectl describe nodes -l tier=on-demand` audit on GKE `v1.36.4-gke.1391002`:

$$
\begin{aligned}
\text{Rack 1 Free CPU} &= 3920\text{m (Allocatable)} - 426\text{m (System Pods)} = \mathbf{3494\text{m}} \ (\approx 3.49\text{ vCPU}) \\
\text{Rack 2 Free CPU} &= 3920\text{m (Allocatable)} - 628\text{m (System Pods)} = \mathbf{3292\text{m}} \ (\approx 3.29\text{ vCPU}) \\
\text{Total On-Demand Free CPU} &= 3494\text{m} + 3292\text{m} = \mathbf{6786\text{m}} \ (\approx 6.78\text{ vCPU})
\end{aligned}
$$

> [!IMPORTANT]
> **Why Pinning Operators to `system-pool` Matters:**
> Both `jobset-controller` and `kueue-controller-manager` request `500m` CPU each (`1000m` total). If allowed to schedule onto `on-demand-rack-1` or `on-demand-rack-2`, a rack node's free CPU drops to `~2290m`, causing 2-Pod same-rack jobs (`2400m`) or `2500m` worker pods to fail scheduling with `Insufficient cpu`. Pinning both operators to `workload=system` preserves the full `3292m–3494m` per-node budget for AI/ML workloads.

### How Workshop Quotas & Lab Requests Align with Real Node Math

With `on-demand-flavor` nominal quota set to **`6000m` (`6` vCPU)** and `spot-flavor` nominal quota set to **`9000m` (`9` vCPU)**:

| Lab Scenario | Pods $\times$ CPU Request | Total CPU | Scheduling & Quota Math |
| :--- | :--- | :--- | :--- |
| **Lab 1: Gang Scheduling** | $2 \times 2000\text{m}$ | **$4000\text{m}$** | **JobSet 1 (`4000m`)** fits inside `on-demand-flavor` (`6000m` quota), placing 1 Pod (`2000m` $\le 3292\text{m}$) on each rack. **JobSet 2 (`4000m`)** sees only `2000m` remaining quota and waits in `team-a-queue` as a suspended gang. |
| **Lab 2: TAS Same-Rack** | $2 \times 1200\text{m}$ | **$2400\text{m}$** | Both Pods must co-locate on **one** rack node (`podset-required-topology: workshop.ai/topology-rack`). Since $2400\text{m} \le 3292\text{m}$, both Pods fit simultaneously on a single `e2-standard-4` node (`on-demand-rack-1`). |
| **Lab 3: Spot Atomic Scale-Up** | $3 \times 2500\text{m}$ | **$7500\text{m}$** | Exceeds `on-demand-flavor` quota ($7500\text{m} > 6000\text{m}$). Spills over to `spot-flavor` (`9000m` quota), triggering a `ProvisioningRequest` that scales `spot-atomic-pool` from `0 -> 3` nodes ($1 \times 2500\text{m}$ Pod per Spot node). |
| **Lab 4: Priority Preemption** | $2 \times 2500\text{m}$ | **$5000\text{m}$** | `research-long-training` (`5000m`) occupies `on-demand-flavor` ($1 \times 2500\text{m}$ Pod per rack). When `urgent-prod-training` (`5000m`, `priority=1000`) arrives, $5000\text{m} + 5000\text{m} > 6000\text{m}$, forcing Kueue to preempt `research-long-training`. |
