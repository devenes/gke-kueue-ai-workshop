PROJECT_ID   ?= enes-turan-demo
REGION       ?= europe-west1
ZONE         ?= europe-west1-b
CLUSTER_NAME ?= gke-kueue-workshop

JOBSET_VERSION ?= 0.10.1
LWS_VERSION    ?= 0.11.1
KUEUE_VERSION  ?= 0.16.2

.DEFAULT_GOAL := help

.PHONY: help lint infra-init infra-plan infra-up infra-down kubeconfig operators-install base-apply status preflight test-all lab1 lab2 lab3 lab4 lab5 lab6 lab7 lab8 lab9 lab10 labs-clean

help: ## Show available workshop Make targets
	@echo "================================================================================"
	@echo " GKE Kueue AI/ML Batch Scheduling Workshop (CPU PyTorch DDP + TAS + Spot + LWS)"
	@echo "================================================================================"
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n\nTargets:\n"} /^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

lint: ## Run all static analysis checks (Terraform fmt/validate, Kustomize, Python AST, ShellCheck)
	@echo "=== 1. Terraform Format & Validate ==="
	terraform -chdir=terraform fmt -check -diff
	@test -d terraform/.terraform || terraform -chdir=terraform init -backend=false >/dev/null
	terraform -chdir=terraform validate
	@echo "=== 2. Kustomize Base Build Verification ==="
	kubectl kustomize k8s/base > /dev/null
	@echo "=== 3. Embedded Python ConfigMap AST Syntax Check ==="
	@python3 -c 'import ast, sys, yaml; \
docs = list(yaml.safe_load_all(open("k8s/base/pytorch-ddp-configmap.yaml"))); \
scripts = [(d["metadata"]["namespace"], d["metadata"]["name"], k, v) for d in docs if d and d.get("kind")=="ConfigMap" for k, v in d.get("data", {}).items() if k.endswith(".py")]; \
[ast.parse(v, filename=f"{ns}/{nm}:{k}") for ns, nm, k, v in scripts]; \
print(f"Verified valid Python 3 AST across {len(scripts)} embedded ConfigMap scripts.")'
	@echo "=== 4. Shell Script Syntax & ShellCheck ==="
	bash -n scripts/preflight-check.sh scripts/smoke-test-all.sh
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck --severity=warning scripts/preflight-check.sh scripts/smoke-test-all.sh && echo "ShellCheck passed with 0 warnings."; \
	fi
	@if command -v yamllint >/dev/null 2>&1; then \
		yamllint -c .yamllint.yaml k8s/ .github/workflows/ci.yml .yamllint.yaml && echo "yamllint passed."; \
	fi
	@echo "✅ All static analysis & lint checks passed!"

infra-init: ## Initialize Terraform providers in terraform/
	terraform -chdir=terraform init

infra-plan: ## Validate and plan GCP & GKE Terraform infrastructure
	terraform -chdir=terraform fmt -check
	terraform -chdir=terraform validate
	terraform -chdir=terraform plan

infra-up: ## Provision GCP VPC, IAM, GKE Cluster, 4 Node Pools, and HNS GCS Bucket via Terraform
	terraform -chdir=terraform apply -auto-approve

infra-down: ## Destroy all GCP & GKE infrastructure via Terraform
	@python3 -c 'import json, subprocess, urllib.parse, urllib.request; \
bucket = "$(PROJECT_ID)-kueue-ai-storage"; \
token = subprocess.check_output(["gcloud", "auth", "print-access-token"], text=True).strip(); \
headers = {"Authorization": f"Bearer {token}"}; \
items = json.loads(urllib.request.urlopen(urllib.request.Request(f"https://storage.googleapis.com/storage/v1/b/{bucket}/o", headers=headers)).read().decode()).get("items", []); \
[urllib.request.urlopen(urllib.request.Request(f"https://storage.googleapis.com/storage/v1/b/{bucket}/o/{urllib.parse.quote(o[\"name\"], safe=\"\")}", headers=headers, method="DELETE")).read() for o in items]; \
folders = sorted(json.loads(urllib.request.urlopen(urllib.request.Request(f"https://storage.googleapis.com/storage/v1/b/{bucket}/folders", headers=headers)).read().decode()).get("items", []), key=lambda f: f["name"].count("/"), reverse=True); \
[urllib.request.urlopen(urllib.request.Request(f"https://storage.googleapis.com/storage/v1/b/{bucket}/folders/{urllib.parse.quote(f[\"name\"].rstrip(\"/\"), safe=\"\")}", headers=headers, method="DELETE")).read() for f in folders]; \
print(f"Cleaned {len(items)} objects and {len(folders)} HNS folders in gs://{bucket}")' 2>/dev/null || true
	terraform -chdir=terraform destroy -auto-approve

kubeconfig: ## Fetch GKE cluster credentials into local kubeconfig
	gcloud container clusters get-credentials $(CLUSTER_NAME) --zone $(ZONE) --project $(PROJECT_ID)

operators-install: ## Install JobSet, LWS, and Kueue operators via official Helm OCI charts
	helm status jobset -n jobset-system >/dev/null 2>&1 || \
		helm upgrade --install jobset oci://registry.k8s.io/jobset/charts/jobset \
			--version $(JOBSET_VERSION) \
			--namespace jobset-system \
			--create-namespace \
			--set controller.nodeSelector.workload=system \
			--wait
	helm status lws -n lws-system >/dev/null 2>&1 || \
		helm upgrade --install lws oci://registry.k8s.io/lws/charts/lws \
			--version $(LWS_VERSION) \
			--namespace lws-system \
			--create-namespace \
			--set nodeSelector.workload=system \
			--set resources.requests.cpu=100m \
			--set resources.requests.memory=128Mi \
			--wait
	helm status kueue -n kueue-system >/dev/null 2>&1 || \
		helm upgrade --install kueue oci://registry.k8s.io/kueue/charts/kueue \
			--version $(KUEUE_VERSION) \
			--namespace kueue-system \
			--create-namespace \
			--set controllerManager.nodeSelector.workload=system \
			--set controllerManager.manager.resources.requests.cpu=250m \
			--wait
	@kubectl get configmap kueue-manager-config -n kueue-system -o json | \
		python3 -c 'import sys, json; cm=json.load(sys.stdin); cfg=cm["data"]["controller_manager_config.yaml"]; cm["data"]["controller_manager_config.yaml"]=cfg.replace("bindAddress: :8443", "bindAddress: :8443\n  enableClusterQueueResources: true") if "enableClusterQueueResources" not in cfg else cfg; json.dump(cm, sys.stdout)' | \
		kubectl apply -f -
	kubectl set resources deployment/kueue-controller-manager -n kueue-system -c manager --requests=cpu=250m,memory=512Mi
	kubectl rollout restart deployment/kueue-controller-manager -n kueue-system
	kubectl rollout status deployment/kueue-controller-manager -n kueue-system --timeout=90s

base-apply: ## Apply Namespaces, ServiceAccounts, PyTorch ConfigMaps, and Kueue v1beta2 setup via Kustomize
	kubectl apply -k k8s/base

status: ## Inspect GKE nodes (with topology labels), Queues, Workloads, ProvisioningRequests, and Pods
	@echo "=== 1. GKE Nodes & Topology Labels ==="
	kubectl get nodes -L workload,tier,workshop.ai/topology-block,workshop.ai/topology-rack
	@echo "\n=== 2. Kueue ClusterQueues & LocalQueues ==="
	kubectl get clusterqueues,localqueues -A
	@echo "\n=== 3. Kueue Workloads & AdmissionChecks ==="
	kubectl get workloads,admissionchecks -A
	@echo "\n=== 4. GKE ProvisioningRequests ==="
	kubectl get provisioningrequests -A
	@echo "\n=== 5. JobSets, LeaderWorkerSets & Pods (team-a & team-b) ==="
	kubectl get jobsets,leaderworkersets,pods -n team-a -o wide
	kubectl get jobsets,leaderworkersets,pods -n team-b -o wide

lab1: ## Run Lab 1: Submit 2x PyTorch DDP JobSets to demonstrate Gang Scheduling
	kubectl create -f k8s/labs/lab1-gang-scheduling.yaml
	kubectl create -f k8s/labs/lab1-gang-scheduling.yaml

lab2: ## Run Lab 2: Submit Topology Aware Scheduling (TAS) Same-Rack JobSet
	kubectl apply -f k8s/labs/lab2-tas-rack.yaml

lab3: ## Run Lab 3: Submit Spot Atomic Scale-Up JobSet (ProvisioningRequest 0 -> 3 nodes)
	kubectl apply -f k8s/labs/lab3-spot-atomic.yaml

lab4: ## Run Lab 4: Submit Low-Priority Research JobSet followed by High-Priority Preempting JobSet
	awk '/^---$$/{exit} {print}' k8s/labs/lab4-preemption.yaml | kubectl apply -f -
	@echo "Waiting for low-priority research-long-training pods to start running..."
	sleep 5
	kubectl wait --for=condition=Ready pod -l jobset.sigs.k8s.io/jobset-name=research-long-training -n team-a --timeout=90s
	@echo "Submitting high-priority urgent-prod-training to trigger preemption..."
	awk 'f{print} /^---$$/{f=1}' k8s/labs/lab4-preemption.yaml | kubectl apply -f -

lab5: ## Run Lab 5: Multi-Team Cohort Quota Borrowing (team-a) & Fair-Share Reclamation (team-b)
	awk '/^---$$/{exit} {print}' k8s/labs/lab5-cohort-borrowing.yaml | kubectl apply -f -
	@echo "Waiting for team-a-cohort-borrower (borrowing 2 vCPU from team-b-cq) to start running..."
	sleep 5
	kubectl wait --for=condition=Ready pod -l jobset.sigs.k8s.io/jobset-name=team-a-cohort-borrower -n team-a --timeout=90s
	@echo "=== Team A ClusterQueue Quota Reservation (3 vCPU Nominal + 2 vCPU Borrowed = 5 vCPU) ==="
	kubectl get clusterqueue team-a-cq -o jsonpath='{.status.flavorsReservation}'
	@echo "\nSubmitting team-b-reclaim-owner (priority=100) in namespace team-b to reclaim nominal cohort quota..."
	awk 'f{print} /^---$$/{f=1}' k8s/labs/lab5-cohort-borrowing.yaml | kubectl apply -f -

lab6: ## Run Lab 6: Distributed Multi-Pod Inference with LeaderWorkerSet (LWS) & Cross-PodSet TAS
	kubectl apply -f k8s/labs/lab6-lws-inference-tas.yaml

lab7: ## Run Lab 7: Stateful DDP Checkpointing & Graceful Preemption Resume (Zero Goodput Lost)
	awk '/^---$$/{exit} {print}' k8s/labs/lab7-checkpoint-resume.yaml | kubectl apply -f -
	@echo "Waiting for resumable-research-job pods to start running..."
	sleep 5
	kubectl wait --for=condition=Ready pod -l jobset.sigs.k8s.io/jobset-name=resumable-research-job -n team-a --timeout=90s
	@echo "Allowing resumable-research-job to complete ~3 epochs and persist checkpoints..."
	sleep 14
	@echo "=== Pre-Preemption Logs (resumable-research-job Rank 0) ==="
	kubectl logs -l jobset.sigs.k8s.io/jobset-name=resumable-research-job,batch.kubernetes.io/job-completion-index=0 -n team-a
	@echo "\nSubmitting urgent-checkpoint-preemptor (priority=1000) to preempt resumable-research-job..."
	awk 'f{print} /^---$$/{f=1}' k8s/labs/lab7-checkpoint-resume.yaml | kubectl apply -f -

lab8: ## Run Lab 8: CEL ValidatingAdmissionPolicy Governance & Max-Exec-Time SLA Enforcement
	@echo "=== Step 8A: Attempting to submit unlabeled-rogue-jobset (omits kueue.x-k8s.io/queue-name) ==="
	@awk '/^---$$/{exit} {print}' k8s/labs/lab8-governance-and-max-exec.yaml | kubectl apply -f - || \
		echo "✅ CEL ValidatingAdmissionPolicy successfully blocked the unlabeled rogue workload!"
	@echo "\n=== Step 8B: Submitting sla-time-bounded-job (kueue.x-k8s.io/max-exec-time-seconds: 20) ==="
	awk 'f{print} /^---$$/{f=1}' k8s/labs/lab8-governance-and-max-exec.yaml | kubectl apply -f -
	sleep 4
	@echo "=== Workload Admitted with spec.maximumExecutionTimeSeconds=20 ==="
	kubectl get workloads -n team-a -o 'custom-columns=NAME:.metadata.name,QUEUE:.spec.queueName,MAX_EXEC_SEC:.spec.maximumExecutionTimeSeconds,ACTIVE:.spec.active,ADMITTED:.status.conditions[?(@.type=="Admitted")].status'
	@echo "Waiting ~25s for 20-second SLA lease to expire and Kueue to auto-evict the runaway job..."
	sleep 25
	@echo "=== Workload Status After 20s SLA Expiration (MaximumExecutionTimeExceeded -> Active=false) ==="
	kubectl get workloads -n team-a -o 'custom-columns=NAME:.metadata.name,ACTIVE:.spec.active,EVICTED_REASON:.status.conditions[?(@.type=="Evicted")].reason,MESSAGE:.status.conditions[?(@.type=="Evicted")].message'

lab9: ## Run Lab 9: Kueue On-Demand Visibility API (Pending Queue Order) & Prometheus Metrics
	@echo "=== Step 9A: Submitting obs-occupier-job (5 vCPU) to saturate team-a-cq on-demand quota ==="
	awk 'BEGIN{doc=0} /^---$$/{doc++; next} doc==0{print}' k8s/labs/lab9-visibility-and-metrics.yaml | kubectl apply -f -
	sleep 3
	@echo "=== Step 9B: Submitting obs-queued-low (priority=100) followed by obs-queued-high (priority=1000) ==="
	awk 'BEGIN{doc=0} /^---$$/{doc++; next} doc==1{print}' k8s/labs/lab9-visibility-and-metrics.yaml | kubectl apply -f -
	sleep 2
	awk 'BEGIN{doc=0} /^---$$/{doc++; next} doc==2{print}' k8s/labs/lab9-visibility-and-metrics.yaml | kubectl apply -f -
	sleep 3
	@echo "\n=== Step 9C: Kueue Visibility API (v1beta2 PendingWorkloadsSummary on team-a-queue) ==="
	kubectl get --raw "/apis/visibility.kueue.x-k8s.io/v1beta2/namespaces/team-a/localqueues/team-a-queue/pendingworkloads" | python3 -m json.tool
	@echo "\n=== Step 9D: Scraping Kueue Prometheus Metrics (/metrics on :8443) ==="
	@TOKEN=$$(kubectl create token kueue-controller-manager -n kueue-system); \
	kubectl port-forward svc/kueue-controller-manager-metrics-service -n kueue-system 18443:8443 >/dev/null 2>&1 & \
	PF_PID=$$!; sleep 2; \
	curl -sk -H "Authorization: Bearer $$TOKEN" https://127.0.0.1:18443/metrics | \
		grep -E '^kueue_(pending_workloads|admitted_workloads_total|cluster_queue_resource_usage|cluster_queue_nominal_quota|evicted_workloads_total)\{.*team-a-cq.*replica_role="leader"'; \
	kill $$PF_PID 2>/dev/null || true

lab10: ## Run Lab 10: GCS FUSE CSI, Hierarchical Namespace (HNS), File Cache & Distributed Checkpointing
	@set -euo pipefail; \
	for cmd in terraform gcloud kubectl python3; do \
		command -v "$$cmd" >/dev/null 2>&1 || { echo "ERROR: Required CLI '$$cmd' not found in PATH." >&2; exit 1; }; \
	done; \
	echo "=== Step 10A: Resolving HNS Bucket Name from Terraform Output ==="; \
	BUCKET_NAME=$$(terraform -chdir=terraform output -raw gcs_ai_bucket_name 2>/dev/null || true); \
	if [[ -z "$$BUCKET_NAME" || "$$BUCKET_NAME" == *"Warning"* ]]; then \
		echo "ERROR: Could not resolve 'gcs_ai_bucket_name' from Terraform state in terraform/." >&2; \
		echo "Run 'make infra-init && make infra-up' first so Terraform provisions the HNS bucket." >&2; \
		exit 1; \
	fi; \
	ACTIVE_PROJECT=$$(gcloud config get-value project 2>/dev/null || true); \
	if [[ "$$ACTIVE_PROJECT" != "$(PROJECT_ID)" ]]; then \
		echo "ERROR: Active gcloud project ('$$ACTIVE_PROJECT') does not match PROJECT_ID ('$(PROJECT_ID)')." >&2; \
		exit 1; \
	fi; \
	echo "Resolved Terraform HNS Bucket: gs://$$BUCKET_NAME (Project: $$ACTIVE_PROJECT)"; \
	kubectl delete jobset lab10-gcsfuse-ai-storage -n team-a --ignore-not-found --wait=true >/dev/null 2>&1 || true; \
	TMP_MANIFEST=$$(mktemp /tmp/lab10-gcsfuse-ai-storage.XXXXXX.yaml); \
	trap 'rm -f "$$TMP_MANIFEST"' EXIT; \
	sed "s|__GCS_AI_BUCKET_NAME__|$$BUCKET_NAME|g" k8s/labs/lab10-gcsfuse-ai-storage.yaml > "$$TMP_MANIFEST"; \
	if grep -q "__GCS_AI_BUCKET_NAME__" "$$TMP_MANIFEST"; then \
		echo "ERROR: Placeholder substitution failed in $$TMP_MANIFEST" >&2; exit 1; \
	fi; \
	kubectl apply --dry-run=client -f "$$TMP_MANIFEST" >/dev/null; \
	echo "=== Step 10B: Applying Rendered Lab 10 Manifest (ServiceAccount + 3-Rank JobSet) ==="; \
	kubectl apply -f "$$TMP_MANIFEST"; \
	echo "=== Step 10C: Waiting for Kueue Workload Admission & Pod Creation ==="; \
	WL_NAME=""; \
	for _ in $$(seq 1 30); do \
		WL_NAME=$$(kubectl get workloads -n team-a -o jsonpath='{.items[?(@.metadata.ownerReferences[0].name=="lab10-gcsfuse-ai-storage")].metadata.name}' 2>/dev/null || true); \
		if [[ -n "$$WL_NAME" ]]; then break; fi; \
		sleep 1; \
	done; \
	if [[ -z "$$WL_NAME" ]]; then echo "ERROR: Kueue Workload for lab10-gcsfuse-ai-storage not created." >&2; exit 1; fi; \
	kubectl wait --for=condition=Admitted "workload/$$WL_NAME" -n team-a --timeout=90s; \
	for _ in $$(seq 1 60); do \
		POD_CNT=$$(kubectl get pods -n team-a -l jobset.sigs.k8s.io/jobset-name=lab10-gcsfuse-ai-storage --no-headers 2>/dev/null | wc -l | tr -d ' '); \
		SCHED_CNT=$$(kubectl get pods -n team-a -l jobset.sigs.k8s.io/jobset-name=lab10-gcsfuse-ai-storage -o jsonpath='{.items[*].spec.nodeName}' 2>/dev/null | wc -w | tr -d ' '); \
		if [[ "$$POD_CNT" == "3" && "$$SCHED_CNT" == "3" ]]; then break; fi; \
		sleep 2; \
	done; \
	echo "=== Step 10D: Kueue Declared Quota vs. Post-Webhook GKE Sidecar Resource Audit ==="; \
	python3 -c 'import json, subprocess, sys; \
		wl_name = sys.argv[1]; \
		kget = lambda *a: json.loads(subprocess.check_output(["kubectl", "get", *a, "-o", "json"])); \
		p_cpu = lambda v: int(str(v or "0")[:-1]) if str(v or "0").endswith("m") else (int(str(v)[:-1]) // 1000000 if str(v or "0").endswith("n") else int(float(v or 0) * 1000)); \
		p_mem = lambda v: int(str(v or "0")[:-2]) // 1024 if str(v or "0").endswith("Ki") else (int(str(v)[:-2]) if str(v or "0").endswith("Mi") else (int(str(v)[:-2]) * 1024 if str(v or "0").endswith("Gi") else int(v or 0) // (1024 * 1024))); \
		wl = kget("workload", wl_name, "-n", "team-a"); \
		cq = kget("clusterqueue", "team-a-cq"); \
		cq_res = json.dumps(cq.get("status", {}).get("flavorsReservation", [])); \
		pods = sorted(kget("pods", "-n", "team-a", "-l", "jobset.sigs.k8s.io/jobset-name=lab10-gcsfuse-ai-storage")["items"], key=lambda x: x["metadata"]["name"]); \
		ps = wl["spec"]["podSets"][0]; \
		ps_cnt = ps["count"]; \
		creq = ps["template"]["spec"]["containers"][0]["resources"]["requests"]; \
		k_cpu, k_mem = p_cpu(creq["cpu"]), p_mem(creq["memory"]); \
		kt_cpu, kt_mem = ps_cnt * k_cpu, ps_cnt * k_mem; \
		print(f"Kueue Workload ({wl_name}): {ps_cnt} pods x ({k_cpu}m CPU, {k_mem}Mi Mem) = {kt_cpu}m CPU, {kt_mem}Mi Mem"); \
		print(f"ClusterQueue team-a-cq Reservation: {cq_res}"); \
		get_ctrs = lambda p: [(c["name"] + "[init-sidecar]", c.get("resources", {}).get("requests", {})) for c in p["spec"].get("initContainers", []) if c.get("restartPolicy") == "Always"] + [(c["name"], c.get("resources", {}).get("requests", {})) for c in p["spec"].get("containers", [])]; \
		pod_stats = [(p["metadata"]["name"], p["spec"].get("nodeName", "unscheduled"), [(n, p_cpu(r.get("cpu", "0m")), p_mem(r.get("memory", "0Mi"))) for n, r in get_ctrs(p)]) for p in pods]; \
		[print(f"  Pod {pn} on {nd}: effective={sum(c[1] for c in cs)}m CPU, {sum(c[2] for c in cs)}Mi Mem -> " + ", ".join(f"{c[0]}({c[1]}m,{c[2]}Mi)" for c in cs)) for pn, nd, cs in pod_stats]; \
		at_cpu = sum(sum(c[1] for c in cs) for _, _, cs in pod_stats); \
		at_mem = sum(sum(c[2] for c in cs) for _, _, cs in pod_stats); \
		nc = {nd: sum(1 for _, n2, _ in pod_stats if n2 == nd) for _, nd, _ in pod_stats}; \
		print(f"Post-Webhook Total Across {len(pods)} Pods: {at_cpu}m CPU, {at_mem}Mi Mem (Delta: +{at_cpu - kt_cpu}m CPU, +{at_mem - kt_mem}Mi Mem)"); \
		print(f"Physical Node Placement Distribution: {nc}"); \
		(print(f"ERROR: Expected 2+1 Pod distribution across 2 rack nodes, got {nc}", file=sys.stderr), sys.exit(1)) if (len(pods) != 3 or sorted(nc.values()) != [1, 2]) else None; \
		(print(f"ERROR: Expected post-webhook Pod CPU ({at_cpu}m) > Kueue declared CPU ({kt_cpu}m)", file=sys.stderr), sys.exit(1)) if at_cpu <= kt_cpu else None' "$$WL_NAME"; \
	echo "=== Step 10E: Waiting for 3-Rank Distributed Benchmark JobSet Completion ==="; \
	kubectl wait --for=condition=Completed jobset/lab10-gcsfuse-ai-storage -n team-a --timeout=240s; \
	echo "=== Step 10F: Distributed Benchmark Logs & Integrity Verification ==="; \
	ALL_LOGS=$$(kubectl logs -n team-a -l jobset.sigs.k8s.io/jobset-name=lab10-gcsfuse-ai-storage -c pytorch --prefix=true --tail=-1); \
	echo "$$ALL_LOGS"; \
	python3 -c 'import sys; \
		logs = sys.argv[1]; \
		chk = lambda tag, sub="": [l for l in logs.splitlines() if tag in l and sub in l]; \
		errs = [m for ok, m in [ \
			(len(chk("[HNS_RENAME]", "published_exists=True")) >= 1, "Missing [HNS_RENAME] verification log"), \
			(len(chk("[CACHE_BENCH]", "tensor_payload_bytes=134217728")) == 3, "Expected 3 [CACHE_BENCH] lines"), \
			(len(chk("[MODEL_VERIFY]", "all_ranks_sha256_match=True")) == 3, "Expected 3 [MODEL_VERIFY] lines"), \
			(len(chk("[CKPT_WRITE]")) == 3, "Expected 3 [CKPT_WRITE] lines"), \
			(len(chk("[CKPT_READ_VERIFY]", "status=VALID")) == 9, "Expected 9 [CKPT_READ_VERIFY] lines (3x3)"), \
			(len(chk("[LAB10_SUCCESS]")) == 3, "Expected 3 [LAB10_SUCCESS] lines") \
		] if not ok]; \
		(print("ERROR: " + "; ".join(errs), file=sys.stderr), sys.exit(1)) if errs else print("✅ Verified: HNS atomic rename, 128 MiB mmap checksum across 3 ranks, cold/warm benchmark, and 3x3 cross-rank checkpoint shards!")' "$$ALL_LOGS"


labs-clean: ## Delete all lab JobSets and LeaderWorkerSets in namespaces team-a and team-b
	kubectl delete jobsets,leaderworkersets --all -n team-a --ignore-not-found --wait=true
	kubectl delete jobsets,leaderworkersets --all -n team-b --ignore-not-found --wait=true
	kubectl wait --for=delete pod --all -n team-a --timeout=60s 2>/dev/null || true
	kubectl wait --for=delete pod --all -n team-b --timeout=60s 2>/dev/null || true

preflight: ## Run 15-second 16-point pre-flight health check across nodes, operators, queues, CEL policy, metrics & GCS FUSE HNS
	./scripts/preflight-check.sh

test-all: ## Run end-to-end automated smoke test suite across all 10 hands-on labs
	./scripts/smoke-test-all.sh

