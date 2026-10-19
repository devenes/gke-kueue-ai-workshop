#!/usr/bin/env bash
# scripts/smoke-test-all.sh
# End-to-End Automated Smoke Test Suite for all 10 labs in the GKE Kueue AI/ML Workshop.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

declare -a LAB_NAMES=(
  "Lab 1: All-or-Nothing Gang Scheduling"
  "Lab 2: Topology Aware Scheduling (Same-Rack)"
  "Lab 3: Spot Spillover & Atomic ProvisioningRequest"
  "Lab 4: Intra-Queue Priority Preemption"
  "Lab 5: Multi-Team Cohort Borrowing & Reclamation"
  "Lab 6: LeaderWorkerSet Inference & Cross-PodSet TAS"
  "Lab 7: Stateful DDP Checkpointing & Resume"
  "Lab 8: CEL Admission Governance & Max-Exec-Time SLA"
  "Lab 9: Visibility API & Prometheus Metrics"
  "Lab 10: GCS FUSE CSI, HNS, File Cache & Checkpoints"
)
declare -a LAB_STATUS=()
declare -a LAB_DURATION=()

banner() {
  printf "\n\033[1;36m================================================================================\033[0m\n"
  printf "\033[1;36m %s\033[0m\n" "$1"
  printf "\033[1;36m================================================================================\033[0m\n"
}

record_result() {
  local idx="$1"
  local status="$2"
  local dur="$3"
  local detail="$4"
  LAB_STATUS[idx]="$status"
  LAB_DURATION[idx]="${dur}s"
  if [[ "$status" == "PASS" ]]; then
    printf "\033[32m[PASS]\033[0m %s (%ss) — %s\n" "${LAB_NAMES[$idx]}" "$dur" "$detail"
  else
    printf "\033[31m[FAIL]\033[0m %s (%ss) — %s\n" "${LAB_NAMES[$idx]}" "$dur" "$detail"
    exit 1
  fi
}

banner "Step 0: Running Pre-Flight Verification & Cleaning Workloads"
make labs-clean >/dev/null
./scripts/preflight-check.sh

SUITE_START=$(date +%s)

# ------------------------------------------------------------------------------
# LAB 1: Gang Scheduling
# ------------------------------------------------------------------------------
banner "${LAB_NAMES[0]}"
T0=$(date +%s)
make lab1
sleep 5
ADMITTED_CNT=$(kubectl get workloads -n team-a -o json | python3 -c '
import sys, json
wls = json.load(sys.stdin)["items"]
adm = [w for w in wls if any(c.get("type")=="Admitted" and c.get("status")=="True" for c in w.get("status",{}).get("conditions",[]))]
print(len(adm))
')
TOTAL_CNT=$(kubectl get workloads -n team-a --no-headers | wc -l | tr -d ' ')
make labs-clean >/dev/null
T1=$(date +%s)
if [[ "$TOTAL_CNT" == "2" && "$ADMITTED_CNT" == "1" ]]; then
  record_result 0 "PASS" "$((T1 - T0))" "1/2 JobSet admitted (4 vCPU), 2nd JobSet held suspended"
else
  record_result 0 "FAIL" "$((T1 - T0))" "Expected 2 total / 1 admitted workloads, got total=$TOTAL_CNT admitted=$ADMITTED_CNT"
fi

# ------------------------------------------------------------------------------
# LAB 2: Topology Aware Scheduling (Same-Rack)
# ------------------------------------------------------------------------------
banner "${LAB_NAMES[1]}"
T0=$(date +%s)
make lab2
sleep 4
kubectl wait --for=condition=Ready pod -l jobset.sigs.k8s.io/jobset-name=pytorch-tas-same-rack -n team-a --timeout=90s
NODES=$(kubectl get pods -n team-a -l jobset.sigs.k8s.io/jobset-name=pytorch-tas-same-rack -o jsonpath='{.items[0].spec.nodeName}:{.items[1].spec.nodeName}')
N0="${NODES%%:*}"
N1="${NODES##*:}"
make labs-clean >/dev/null
T1=$(date +%s)
if [[ -n "$N0" && "$N0" == "$N1" ]]; then
  record_result 1 "PASS" "$((T1 - T0))" "Both ranks co-located on same rack node ($N0)"
else
  record_result 1 "FAIL" "$((T1 - T0))" "Ranks placed on different nodes ($N0 vs $N1)"
fi

# ------------------------------------------------------------------------------
# LAB 3: Spot Spillover & Atomic ProvisioningRequest
# ------------------------------------------------------------------------------
banner "${LAB_NAMES[2]}"
T0=$(date +%s)
make lab3
PR_OK="false"
for _ in $(seq 1 60); do
  PR_STATE=$(kubectl get provisioningrequests -n team-a -o jsonpath='{.items[0].status.conditions[?(@.type=="Accepted")].status}:{.items[0].status.conditions[?(@.type=="Provisioned")].status}' 2>/dev/null || true)
  if [[ "$PR_STATE" == "True:True" ]]; then
    PR_OK="true"
    break
  fi
  sleep 3
done
kubectl wait --for=condition=Ready pod -l jobset.sigs.k8s.io/jobset-name=pytorch-spot-atomic-scaleup -n team-a --timeout=180s
SPOT_PODS=$(kubectl get pods -n team-a -l jobset.sigs.k8s.io/jobset-name=pytorch-spot-atomic-scaleup --field-selector=status.phase=Running -o jsonpath='{.items[*].spec.nodeSelector.tier}')
make labs-clean >/dev/null
T1=$(date +%s)
if [[ "$PR_OK" == "true" && "$SPOT_PODS" == "spot spot spot" ]]; then
  record_result 2 "PASS" "$((T1 - T0))" "ProvisioningRequest Accepted & Provisioned=True; 3/3 pods on tier=spot"
else
  record_result 2 "FAIL" "$((T1 - T0))" "PR_OK=$PR_OK, SPOT_PODS=$SPOT_PODS"
fi

# ------------------------------------------------------------------------------
# LAB 4: Intra-Queue Priority Preemption
# ------------------------------------------------------------------------------
banner "${LAB_NAMES[3]}"
T0=$(date +%s)
make lab4
sleep 5
PREEMPT_CHECK=$(kubectl get workloads -n team-a -o json | python3 -c '
import sys, json
wls = json.load(sys.stdin)["items"]
evicted = any(
    "research-long-training" in w["metadata"]["name"] and
    any(c.get("type")=="Evicted" and c.get("status")=="True" and c.get("reason")=="Preempted" for c in w.get("status",{}).get("conditions",[]))
    for w in wls
)
urgent_adm = any(
    "urgent-prod-training" in w["metadata"]["name"] and
    any(c.get("type")=="Admitted" and c.get("status")=="True" for c in w.get("status",{}).get("conditions",[]))
    for w in wls
)
print("OK" if (evicted and urgent_adm) else "FAIL")
')
make labs-clean >/dev/null
T1=$(date +%s)
if [[ "$PREEMPT_CHECK" == "OK" ]]; then
  record_result 3 "PASS" "$((T1 - T0))" "urgent-prod-training (prio=1000) preempted research-long-training (prio=100)"
else
  record_result 3 "FAIL" "$((T1 - T0))" "Intra-queue preemption check failed"
fi

# ------------------------------------------------------------------------------
# LAB 5: Multi-Team Cohort Borrowing & Reclamation
# ------------------------------------------------------------------------------
banner "${LAB_NAMES[4]}"
T0=$(date +%s)
make lab5
sleep 5
COHORT_CHECK=$(kubectl get workloads -A -o json | python3 -c '
import sys, json
wls = json.load(sys.stdin)["items"]
reclaimed = any(
    "team-a-cohort-borrower" in w["metadata"]["name"] and
    any(c.get("type")=="Preempted" and c.get("reason")=="InCohortReclamation" for c in w.get("status",{}).get("conditions",[]))
    for w in wls
)
teamb_adm = any(
    "team-b-reclaim-owner" in w["metadata"]["name"] and
    any(c.get("type")=="Admitted" and c.get("status")=="True" for c in w.get("status",{}).get("conditions",[]))
    for w in wls
)
print("OK" if (reclaimed and teamb_adm) else "FAIL")
')
make labs-clean >/dev/null
T1=$(date +%s)
if [[ "$COHORT_CHECK" == "OK" ]]; then
  record_result 4 "PASS" "$((T1 - T0))" "team-b (prio=100) reclaimed borrowed quota from team-a (prio=1000, InCohortReclamation)"
else
  record_result 4 "FAIL" "$((T1 - T0))" "Cohort reclamation check failed"
fi

# ------------------------------------------------------------------------------
# LAB 6: LeaderWorkerSet Distributed Inference & Cross-PodSet TAS
# ------------------------------------------------------------------------------
banner "${LAB_NAMES[5]}"
T0=$(date +%s)
make lab6
sleep 4
kubectl wait --for=condition=Ready pod/lws-tas-infer-0 pod/lws-tas-infer-0-1 -n team-a --timeout=90s
LWS_NODES=$(kubectl get pod lws-tas-infer-0 lws-tas-infer-0-1 -n team-a -o jsonpath='{.items[0].spec.nodeName}:{.items[1].spec.nodeName}')
LN0="${LWS_NODES%%:*}"
LN1="${LWS_NODES##*:}"
INFER_JSON=$(kubectl exec -n team-a lws-tas-infer-0 -- python3 -c "import urllib.request; print(urllib.request.urlopen('http://localhost:8080/infer').read().decode().strip())")
make labs-clean >/dev/null
T1=$(date +%s)
if [[ -n "$LN0" && "$LN0" == "$LN1" && "$INFER_JSON" == *"pytorch-tp-mlp-2shard"* ]]; then
  record_result 5 "PASS" "$((T1 - T0))" "Leader & Worker co-located on $LN0; /infer returned 2-shard TP logits"
else
  record_result 5 "FAIL" "$((T1 - T0))" "Nodes=$LWS_NODES, INFER_JSON=$INFER_JSON"
fi

# ------------------------------------------------------------------------------
# LAB 7: Stateful DDP Checkpointing & Graceful Preemption Resume
# ------------------------------------------------------------------------------
banner "${LAB_NAMES[6]}"
T0=$(date +%s)
make lab7
kubectl wait --for=condition=Completed jobset/urgent-checkpoint-preemptor -n team-a --timeout=120s
sleep 5
kubectl wait --for=condition=Completed jobset/resumable-research-job -n team-a --timeout=120s
RESUMED_LOGS=$(kubectl logs -l jobset.sigs.k8s.io/jobset-name=resumable-research-job,batch.kubernetes.io/job-completion-index=0 -n team-a)
make labs-clean >/dev/null
T1=$(date +%s)
if [[ "$RESUMED_LOGS" == *"[RESUMED FROM CHECKPOINT]"* && "$RESUMED_LOGS" == *"Completed All 8 Epochs Successfully!"* ]]; then
  RESUMED_LINE=$(echo "$RESUMED_LOGS" | grep -m1 "RESUMED FROM CHECKPOINT" || true)
  record_result 6 "PASS" "$((T1 - T0))" "$RESUMED_LINE"
else
  record_result 6 "FAIL" "$((T1 - T0))" "Missing checkpoint resume log in resumable-research-job"
fi

# ------------------------------------------------------------------------------
# LAB 8: CEL Admission Governance & Max-Exec-Time SLA Enforcement
# ------------------------------------------------------------------------------
banner "${LAB_NAMES[7]}"
T0=$(date +%s)
LAB8_OUT=$(make lab8 2>&1)
make labs-clean >/dev/null
T1=$(date +%s)
if [[ "$LAB8_OUT" == *"ValidatingAdmissionPolicy 'require-kueue-queue-name'"* && "$LAB8_OUT" == *"DeactivatedDueToMaximumExecutionTimeExceeded"* ]]; then
  record_result 7 "PASS" "$((T1 - T0))" "CEL blocked unlabeled JobSet & 20s SLA evicted runaway job"
else
  record_result 7 "FAIL" "$((T1 - T0))" "Lab 8 output did not match expected governance/SLA strings"
fi

# ------------------------------------------------------------------------------
# LAB 9: Kueue Visibility API & Prometheus Metrics
# ------------------------------------------------------------------------------
banner "${LAB_NAMES[8]}"
T0=$(date +%s)
LAB9_OUT=$(make lab9 2>&1)
make labs-clean >/dev/null
T1=$(date +%s)
if [[ "$LAB9_OUT" == *'"positionInClusterQueue": 0'* && "$LAB9_OUT" == *"kueue_cluster_queue_resource_usage"* && "$LAB9_OUT" == *"kueue_pending_workloads"* ]]; then
  record_result 8 "PASS" "$((T1 - T0))" "Visibility API verified priority jump (pos=0) & Prometheus exported queue metrics"
else
  record_result 8 "FAIL" "$((T1 - T0))" "Lab 9 output missing Visibility API or Prometheus metrics"
fi

# ------------------------------------------------------------------------------
# LAB 10: GCS FUSE CSI, HNS, Per-Pod File Cache & Distributed Checkpointing
# ------------------------------------------------------------------------------
banner "${LAB_NAMES[9]}"
T0=$(date +%s)
LAB10_OUT=""
if LAB10_OUT=$(make lab10 2>&1); then
  echo "$LAB10_OUT"
  LAB10_RC=0
else
  echo "$LAB10_OUT"
  LAB10_RC=1
fi
T1=$(date +%s)
if [[ "$LAB10_RC" -eq 0 && "$LAB10_OUT" == *"[LAB10_SUMMARY_JSON]"* && "$LAB10_OUT" == *"Lab 10 GCS FUSE + HNS + File Cache + Distributed Checkpoint Benchmark Completed Successfully!"* ]]; then
  SUMMARY_DETAIL=$(echo "$LAB10_OUT" | python3 -c '
import sys, json
for line in sys.stdin:
    if "[LAB10_SUMMARY_JSON]" in line:
        j = json.loads(line.split("[LAB10_SUMMARY_JSON]", 1)[1].strip())
        r0 = j["ranks"][0]
        rid = j["run_id"]
        ren_ms = j["hns_rename"]["rename_ms"]
        sha = j["model_sha256"][:12]
        c_ms, w_ms = r0["cold_ms"], r0["warm_ms"]
        ckpts = j["cross_rank_checkpoint_validations"]
        print(f"run={rid} HNS_rename={ren_ms}ms sha256={sha}... r0_cold={c_ms}ms/warm={w_ms}ms ckpts={ckpts}/9")
        break
')
  make labs-clean >/dev/null
  record_result 9 "PASS" "$((T1 - T0))" "$SUMMARY_DETAIL"
else
  make labs-clean >/dev/null || true
  record_result 9 "FAIL" "$((T1 - T0))" "Lab 10 E2E storage & checkpoint benchmark failed"
fi

SUITE_END=$(date +%s)
TOTAL_TIME=$((SUITE_END - SUITE_START))

echo ""
echo "================================================================================"
echo " GKE KUEUE AI WORKSHOP — 10-LAB SMOKE TEST SUMMARY (Total: ${TOTAL_TIME}s)"
echo "================================================================================"
printf "%-52s | %-6s | %-8s\n" "Lab Scenario" "Status" "Duration"
echo "--------------------------------------------------------------------------------"
for i in "${!LAB_NAMES[@]}"; do
  printf "%-52s | \033[32m%-6s\033[0m | %-8s\n" "${LAB_NAMES[$i]}" "${LAB_STATUS[$i]}" "${LAB_DURATION[$i]}"
done
echo "================================================================================"
printf " RESULT: \033[1;32m10/10 LABS PASSED (100%%)\033[0m\n"
echo "================================================================================"

