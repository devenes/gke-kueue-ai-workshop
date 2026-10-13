PROJECT_ID   ?= enes-turan-demo
REGION       ?= europe-west1
ZONE         ?= europe-west1-b
CLUSTER_NAME ?= gke-kueue-workshop

JOBSET_VERSION ?= 0.10.1
LWS_VERSION    ?= 0.11.1
KUEUE_VERSION  ?= 0.16.2

.DEFAULT_GOAL := help

.PHONY: help lint infra-init infra-plan infra-up infra-down kubeconfig operators-install base-apply status preflight test-all lab1 lab2 lab3 lab4 lab5 lab6 lab7 lab8 lab9 labs-clean

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

infra-up: ## Provision GCP VPC, IAM, GKE Cluster, and 4 Node Pools via Terraform
	terraform -chdir=terraform apply -auto-approve

infra-down: ## Destroy all GCP & GKE infrastructure via Terraform
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
			--wait
	@kubectl get configmap kueue-manager-config -n kueue-system -o json | \
		python3 -c 'import sys, json; cm=json.load(sys.stdin); cfg=cm["data"]["controller_manager_config.yaml"]; cm["data"]["controller_manager_config.yaml"]=cfg.replace("bindAddress: :8443", "bindAddress: :8443\n  enableClusterQueueResources: true") if "enableClusterQueueResources" not in cfg else cfg; json.dump(cm, sys.stdout)' | \
		kubectl apply -f -
	kubectl rollout restart deployment/kueue-controller-manager -n kueue-system
	kubectl rollout status deployment/kueue-controller-manager -n kueue-system --timeout=90s

base-apply: ## Apply Namespaces, PyTorch DDP/LWS ConfigMaps, and Kueue v1beta2 setup via Kustomize
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

labs-clean: ## Delete all lab JobSets and LeaderWorkerSets in namespaces team-a and team-b
	kubectl delete jobsets,leaderworkersets --all -n team-a --ignore-not-found --wait=true
	kubectl delete jobsets,leaderworkersets --all -n team-b --ignore-not-found --wait=true
	kubectl wait --for=delete pod --all -n team-a --timeout=60s 2>/dev/null || true
	kubectl wait --for=delete pod --all -n team-b --timeout=60s 2>/dev/null || true

preflight: ## Run 15-second pre-flight health check across nodes, operators, queues, CEL policy, and metrics
	./scripts/preflight-check.sh

test-all: ## Run end-to-end automated smoke test suite across all 9 hands-on labs
	./scripts/smoke-test-all.sh
