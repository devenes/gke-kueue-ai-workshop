PROJECT_ID   ?= enes-turan-demo
REGION       ?= europe-west1
ZONE         ?= europe-west1-b
CLUSTER_NAME ?= gke-kueue-workshop

JOBSET_VERSION ?= 0.10.1
LWS_VERSION    ?= 0.11.1
KUEUE_VERSION  ?= 0.16.2

.DEFAULT_GOAL := help

.PHONY: help infra-init infra-plan infra-up infra-down kubeconfig operators-install base-apply status lab1 lab2 lab3 lab4 lab5 lab6 labs-clean

help: ## Show available workshop Make targets
	@echo "================================================================================"
	@echo " GKE Kueue AI/ML Batch Scheduling Workshop (CPU PyTorch DDP + TAS + Spot + LWS)"
	@echo "================================================================================"
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n\nTargets:\n"} /^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

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

labs-clean: ## Delete all lab JobSets and LeaderWorkerSets in namespaces team-a and team-b
	kubectl delete jobsets,leaderworkersets --all -n team-a --ignore-not-found --wait=true
	kubectl delete jobsets,leaderworkersets --all -n team-b --ignore-not-found --wait=true
	kubectl wait --for=delete pod --all -n team-a --timeout=60s 2>/dev/null || true
	kubectl wait --for=delete pod --all -n team-b --timeout=60s 2>/dev/null || true
