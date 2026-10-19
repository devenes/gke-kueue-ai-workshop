#!/usr/bin/env bash
# scripts/preflight-check.sh
# Pre-flight verification script for the GKE Kueue AI/ML Batch & Inference Workshop.
# Validates nodes, topology labels, free CPU capacity, operators, webhooks,
# Kueue v1beta2 objects, CEL governance, observability endpoints, and clean state.

set -euo pipefail

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  printf "  \033[32m[PASS]\033[0m %s\n" "$1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  printf "  \033[31m[FAIL]\033[0m %s\n" "$1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

echo "================================================================================"
echo " GKE Kueue AI Workshop — Pre-Flight Environment Check"
echo "================================================================================"

echo ""
echo "1. Cluster & Node Topology Check"
SYS_NODE=$(kubectl get nodes -l workload=system -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
SYS_READY=$(kubectl get nodes -l workload=system -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
if [[ -n "$SYS_NODE" && "$SYS_READY" == "True" ]]; then
  pass "system-pool node Ready ($SYS_NODE, workload=system)"
else
  fail "system-pool node not Ready"
fi

for RACK in rack-1 rack-2; do
  RACK_NODE=$(kubectl get nodes -l "tier=on-demand,workshop.ai/topology-block=block-1,workshop.ai/topology-rack=${RACK}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  RACK_READY=$(kubectl get nodes -l "tier=on-demand,workshop.ai/topology-block=block-1,workshop.ai/topology-rack=${RACK}" -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  if [[ -n "$RACK_NODE" && "$RACK_READY" == "True" ]]; then
    pass "on-demand-${RACK} node Ready ($RACK_NODE, block-1/${RACK})"
  else
    fail "on-demand-${RACK} node missing or not Ready"
  fi
done

CPU_AUDIT=$(python3 - <<'PY'
import json, subprocess, sys

def parse_cpu_m(val):
    val = str(val)
    if val.endswith("m"):
        return int(val[:-1])
    if val.endswith("n"):
        return int(val[:-1]) // 1_000_000
    return int(float(val) * 1000)

nodes = json.loads(subprocess.check_output(["kubectl", "get", "nodes", "-l", "tier=on-demand", "-o", "json"]))["items"]
pods = json.loads(subprocess.check_output(["kubectl", "get", "pods", "-A", "-o", "json"]))["items"]

ok = True
msgs = []
for n in nodes:
    name = n["metadata"]["name"]
    rack = n["metadata"]["labels"].get("workshop.ai/topology-rack", "unknown")
    alloc_m = parse_cpu_m(n["status"]["allocatable"]["cpu"])
    req_m = 0
    for p in pods:
        if p["spec"].get("nodeName") != name:
            continue
        phase = p["status"].get("phase", "")
        if phase in ("Succeeded", "Failed"):
            continue
        for c in p["spec"].get("containers", []):
            req_m += parse_cpu_m(c.get("resources", {}).get("requests", {}).get("cpu", "0m"))
    free_m = alloc_m - req_m
    msgs.append(f"{rack}={free_m}m/{alloc_m}m")
    if free_m < 3000:
        ok = False

print(("OK:" if ok else "LOW:") + ", ".join(msgs))
PY
)
if [[ "$CPU_AUDIT" == OK:* ]]; then
  pass "Free allocatable CPU >= 3000m per on-demand rack (${CPU_AUDIT#OK:})"
else
  fail "Insufficient free allocatable CPU on on-demand racks (${CPU_AUDIT#LOW:})"
fi

echo ""
echo "2. Operators & Webhooks Check"
for ENTRY in "jobset-system:jobset-controller:jobset-webhook-service" \
             "lws-system:lws-controller-manager:lws-webhook-service" \
             "kueue-system:kueue-controller-manager:kueue-webhook-service"; do
  IFS=":" read -r NS DEPLOY SVC <<< "$ENTRY"
  AVAIL=$(kubectl get deployment "$DEPLOY" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)
  NODESEL=$(kubectl get deployment "$DEPLOY" -n "$NS" -o jsonpath='{.spec.template.spec.nodeSelector.workload}' 2>/dev/null || true)
  EP_IP=$(kubectl get endpoints "$SVC" -n "$NS" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)
  if [[ "$AVAIL" == "True" && "$NODESEL" == "system" && -n "$EP_IP" ]]; then
    pass "$NS/$DEPLOY Available=True (nodeSelector.workload=system, webhook=$EP_IP)"
  else
    fail "$NS/$DEPLOY failed check (Available=$AVAIL, nodeSelector=$NODESEL, webhook=$EP_IP)"
  fi
done

echo ""
echo "3. Kueue v1beta2 Control Plane Check"
TOPO=$(kubectl get topology gke-dc-topology -o jsonpath='{.metadata.name}' 2>/dev/null || true)
OD_FLAVOR=$(kubectl get resourceflavor on-demand-flavor -o jsonpath='{.spec.topologyName}' 2>/dev/null || true)
SPOT_FLAVOR=$(kubectl get resourceflavor spot-flavor -o jsonpath='{.metadata.name}' 2>/dev/null || true)
PRC_CLASS=$(kubectl get provisioningrequestconfig gke-atomic-cpu-config -o jsonpath='{.spec.provisioningClassName}' 2>/dev/null || true)
if [[ "$TOPO" == "gke-dc-topology" && "$OD_FLAVOR" == "gke-dc-topology" && "$SPOT_FLAVOR" == "spot-flavor" && "$PRC_CLASS" == "best-effort-atomic-scale-up.autoscaling.x-k8s.io" ]]; then
  pass "Topology (gke-dc-topology), ResourceFlavors (on-demand/spot), & ProvisioningRequestConfig verified"
else
  fail "Topology/ResourceFlavors/ProvisioningRequestConfig mismatch"
fi

AC_ACTIVE=$(kubectl get admissioncheck spot-atomic-check -o jsonpath='{.status.conditions[?(@.type=="Active")].status}' 2>/dev/null || true)
CQA_ACTIVE=$(kubectl get clusterqueue team-a-cq -o jsonpath='{.status.conditions[?(@.type=="Active")].status}' 2>/dev/null || true)
CQB_ACTIVE=$(kubectl get clusterqueue team-b-cq -o jsonpath='{.status.conditions[?(@.type=="Active")].status}' 2>/dev/null || true)
CQA_COHORT=$(kubectl get clusterqueue team-a-cq -o jsonpath='{.spec.cohortName}' 2>/dev/null || true)
CQB_COHORT=$(kubectl get clusterqueue team-b-cq -o jsonpath='{.spec.cohortName}' 2>/dev/null || true)
LQA_ACTIVE=$(kubectl get localqueue team-a-queue -n team-a -o jsonpath='{.status.conditions[?(@.type=="Active")].status}' 2>/dev/null || true)
LQB_ACTIVE=$(kubectl get localqueue team-b-queue -n team-b -o jsonpath='{.status.conditions[?(@.type=="Active")].status}' 2>/dev/null || true)
if [[ "$AC_ACTIVE" == "True" && "$CQA_ACTIVE" == "True" && "$CQB_ACTIVE" == "True" && "$LQA_ACTIVE" == "True" && "$LQB_ACTIVE" == "True" && "$CQA_COHORT" == "ai-org-cohort" && "$CQB_COHORT" == "ai-org-cohort" ]]; then
  pass "AdmissionCheck, ClusterQueues (team-a-cq & team-b-cq in ai-org-cohort), & LocalQueues Active=True"
else
  fail "Queues or AdmissionCheck not Active (AC=$AC_ACTIVE, CQA=$CQA_ACTIVE, CQB=$CQB_ACTIVE, LQA=$LQA_ACTIVE, LQB=$LQB_ACTIVE)"
fi

echo ""
echo "4. Governance, ServiceAccount & ConfigMaps Check"
NSA_GOV=$(kubectl get ns team-a -o jsonpath='{.metadata.labels.kueue-governance}' 2>/dev/null || true)
NSB_GOV=$(kubectl get ns team-b -o jsonpath='{.metadata.labels.kueue-governance}' 2>/dev/null || true)
VAP=$(kubectl get validatingadmissionpolicy require-kueue-queue-name -o jsonpath='{.metadata.name}' 2>/dev/null || true)
VAPB=$(kubectl get validatingadmissionpolicybinding require-kueue-queue-name-binding -o jsonpath='{.metadata.name}' 2>/dev/null || true)
if [[ "$NSA_GOV" == "enforced" && "$NSB_GOV" == "enforced" && "$VAP" == "require-kueue-queue-name" && "$VAPB" == "require-kueue-queue-name-binding" ]]; then
  pass "CEL ValidatingAdmissionPolicy (require-kueue-queue-name) & namespace labels (kueue-governance=enforced) active"
else
  fail "CEL ValidatingAdmissionPolicy or namespace labels missing"
fi

CM1=$(kubectl get configmap pytorch-ddp-script -n team-a -o jsonpath='{.metadata.name}' 2>/dev/null || true)
CM2=$(kubectl get configmap pytorch-ddp-script -n team-b -o jsonpath='{.metadata.name}' 2>/dev/null || true)
CM3=$(kubectl get configmap pytorch-lws-inference-script -n team-a -o jsonpath='{.metadata.name}' 2>/dev/null || true)
CM4=$(kubectl get configmap pytorch-checkpoint-script -n team-a -o jsonpath='{.metadata.name}' 2>/dev/null || true)
CM5=$(kubectl get configmap pytorch-gcsfuse-script -n team-a -o jsonpath='{.metadata.name}' 2>/dev/null || true)
KSA10=$(kubectl get serviceaccount lab10-gcsfuse-sa -n team-a -o jsonpath='{.metadata.name}' 2>/dev/null || true)
KSA10_GSA=$(kubectl get serviceaccount lab10-gcsfuse-sa -n team-a -o jsonpath='{.metadata.annotations.iam\.gke\.io/gcp-service-account}' 2>/dev/null || true)
if [[ -n "$CM1" && -n "$CM2" && -n "$CM3" && -n "$CM4" && -n "$CM5" && "$KSA10" == "lab10-gcsfuse-sa" && -z "$KSA10_GSA" ]]; then
  pass "PyTorch ConfigMaps (ddp, lws-inference, checkpoint, gcsfuse) & direct-WIF KSA (lab10-gcsfuse-sa) present"
else
  fail "One or more PyTorch ConfigMaps or direct-WIF ServiceAccount (lab10-gcsfuse-sa) missing/misconfigured"
fi

echo ""
echo "5. Observability Endpoints Check"
VIS_KIND=$(kubectl get --raw "/apis/visibility.kueue.x-k8s.io/v1beta2/namespaces/team-a/localqueues/team-a-queue/pendingworkloads" 2>/dev/null | python3 -c "import sys, json; print(json.load(sys.stdin).get('kind',''))" 2>/dev/null || true)
if [[ "$VIS_KIND" == "PendingWorkloadsSummary" ]]; then
  pass "Kueue Visibility API v1beta2 (/pendingworkloads -> PendingWorkloadsSummary) reachable"
else
  fail "Kueue Visibility API v1beta2 check failed (got: $VIS_KIND)"
fi

TOKEN=$(kubectl create token kueue-controller-manager -n kueue-system)
kubectl port-forward svc/kueue-controller-manager-metrics-service -n kueue-system 18443:8443 >/dev/null 2>&1 &
PF_PID=$!
sleep 2
METRIC_LINE=$(curl -sk -H "Authorization: Bearer $TOKEN" https://127.0.0.1:18443/metrics | grep -m1 '^kueue_cluster_queue_nominal_quota{.*team-a-cq' || true)
kill "$PF_PID" 2>/dev/null || true
wait "$PF_PID" 2>/dev/null || true
if [[ -n "$METRIC_LINE" ]]; then
  pass "Kueue Prometheus metrics (:8443/metrics) reachable & exporting kueue_cluster_queue_nominal_quota"
else
  fail "Kueue Prometheus metrics check failed"
fi

echo ""
echo "6. Cloud Storage FUSE CSI & HNS Bucket Check (Lab 10)"
CSI_DRV=$(kubectl get csidriver gcsfuse.csi.storage.gke.io -o jsonpath='{.metadata.name}' 2>/dev/null || true)
CSI_DS_DESIRED=$(kubectl get daemonset gcsfusecsi-node -n kube-system -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || true)
CSI_DS_READY=$(kubectl get daemonset gcsfusecsi-node -n kube-system -o jsonpath='{.status.numberReady}' 2>/dev/null || true)
if [[ "$CSI_DRV" == "gcsfuse.csi.storage.gke.io" && -n "$CSI_DS_READY" && "$CSI_DS_READY" == "$CSI_DS_DESIRED" && "$CSI_DS_READY" -ge 3 ]]; then
  pass "GKE Cloud Storage FUSE CSI driver active ($CSI_DRV, gcsfusecsi-node Ready=$CSI_DS_READY/$CSI_DS_DESIRED)"
else
  fail "GKE Cloud Storage FUSE CSI driver not Ready (driver=$CSI_DRV, Ready=${CSI_DS_READY:-0}/${CSI_DS_DESIRED:-0})"
fi

TF_BUCKET=$(terraform -chdir=terraform output -raw gcs_ai_bucket_name 2>/dev/null || true)
GCP_TOKEN=$(gcloud auth print-access-token 2>/dev/null || true)
BUCKET_CHECK="FAIL:unresolved"
if [[ -n "$TF_BUCKET" && "$TF_BUCKET" != *"Warning"* && -n "$GCP_TOKEN" ]]; then
  BUCKET_CHECK=$(curl -fsSL -H "Authorization: Bearer $GCP_TOKEN" "https://storage.googleapis.com/storage/v1/b/${TF_BUCKET}" 2>/dev/null | python3 -c '
import sys, json
try:
    b = json.load(sys.stdin)
    bname = b.get("name", "")
    hns = b.get("hierarchicalNamespace", {}).get("enabled", False)
    ubla = b.get("iamConfiguration", {}).get("uniformBucketLevelAccess", {}).get("enabled", False)
    loc = b.get("location", "")
    if hns and ubla:
        print(f"OK:gs://{bname} (location={loc}, HNS=True, UBLA=True)")
    else:
        print(f"FAIL:gs://{bname} (HNS={hns}, UBLA={ubla})")
except Exception as e:
    print(f"FAIL:{e}")
' 2>/dev/null || echo "FAIL:api_error")
fi
if [[ "$BUCKET_CHECK" == OK:* ]]; then
  pass "Terraform HNS Bucket verified (${BUCKET_CHECK#OK:})"
else
  fail "Terraform HNS Bucket check failed (${BUCKET_CHECK#FAIL:})"
fi

echo ""
echo "7. Clean State Check"
WORKLOAD_COUNT=$( { kubectl get jobsets,leaderworkersets,workloads -n team-a --no-headers 2>/dev/null; kubectl get jobsets,leaderworkersets,workloads -n team-b --no-headers 2>/dev/null; } | wc -l | tr -d ' ')
if [[ "$WORKLOAD_COUNT" == "0" ]]; then
  pass "Zero stale JobSets, LeaderWorkerSets, or Workloads in team-a & team-b"
else
  fail "Found $WORKLOAD_COUNT existing workload object(s) — run 'make labs-clean' before starting"
fi

echo ""
echo "================================================================================"
printf " Summary: \033[32m%d PASSED\033[0m, \033[31m%d FAILED\033[0m\n" "$PASS_COUNT" "$FAIL_COUNT"
echo "================================================================================"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi

