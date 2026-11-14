.DEFAULT_GOAL := help
SHELL := /bin/bash
.ONESHELL:

REGION      ?= us-west-2
PROJECT     ?= llm-d-eks-lab
CLUSTER     ?= $(PROJECT)
TF          ?= terraform
# Set AUTO=-auto-approve to apply without the interactive prompt. Needed when
# driving make non-interactively: with -input=false and no -auto-approve,
# terraform errors out rather than prompting.
AUTO        ?=
# Passed to 10-cluster so the nightly reaper's IAM role gets an EKS access
# entry. Comes from the 00-bootstrap github_reaper_role_arn output.
REAPER_ROLE_ARN ?=
BOOTSTRAP   := terraform/00-bootstrap
CLUSTER_DIR := terraform/10-cluster
INFER_DIR   := terraform/20-inference

# Pinned to llm-d v1.0.0. Keep aligned with the table in README.md.
export LLMD_VERSION        ?= v1.0.0
export GATEWAY_API_VERSION ?= v1.6.2
export GAIE_VERSION        ?= v1.6.2
export ISTIO_VERSION       ?= 1.29.4
export ROUTER_CHART        ?= oci://ghcr.io/llm-d/charts/llm-d-router-standalone
export SIM_IMAGE           ?= ghcr.io/llm-d/llm-d-inference-sim:v1.0.0
export VLLM_IMAGE          ?= docker.io/vllm/vllm-openai:v0.30.0

##@ Help

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS=":.*##"; printf "\nllm-d-eks-lab\n"} \
	/^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2 } \
	/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0,5) }' $(MAKEFILE_LIST)
	@echo ""

##@ Cost & safety

.PHONY: prices
prices: ## Re-measure current spot prices for the instance types this project uses
	@./scripts/prices.sh $(REGION)

.PHONY: cost
cost: ## Actual spend to date, attributed by the Project tag
	@start=$$(date -u -v-30d +%Y-%m-%d 2>/dev/null || date -u -d '30 days ago' +%Y-%m-%d)
	@end=$$(date -u +%Y-%m-%d)
	@aws ce get-cost-and-usage --region us-east-1 \
	  --time-period Start=$$start,End=$$end \
	  --granularity MONTHLY --metrics UnblendedCost \
	  --filter '{"Tags":{"Key":"Project","Values":["$(PROJECT)"]}}' \
	  --group-by Type=DIMENSION,Key=SERVICE \
	  --query 'ResultsByTime[].Groups[].{Service:Keys[0],USD:Metrics.UnblendedCost.Amount}' \
	  --output table

.PHONY: quota
quota: ## Show G/VT GPU quota and any pending increase requests
	@echo "== current limits ($(REGION)) — note: denominated in vCPUs; g6e.xlarge is 4, multi-GPU shapes need 48+"
	@aws service-quotas list-service-quotas --service-code ec2 --region $(REGION) \
	  --query 'Quotas[?contains(QuotaName,`G and VT`)].{Code:QuotaCode,Name:QuotaName,vCPUs:Value}' \
	  --output table
	@echo "== what the current spot limit buys (4 vCPU per xlarge GPU node)"
	@aws service-quotas get-service-quota --service-code ec2 --quota-code L-3819A6DF \
	  --region $(REGION) --query 'Quota.Value' --output text | \
	  awk '{n=int($$1/4); print "   "$$1" vCPU = "n" x g6e.xlarge (1x L40S 44GB each); multi-GPU needs 48+"}'
	@echo "== pending requests"
	@aws service-quotas list-requested-service-quota-change-history \
	  --service-code ec2 --region $(REGION) \
	  --query 'RequestedQuotas[].{Name:QuotaName,Desired:DesiredValue,Status:Status,Case:CaseId}' \
	  --output table

.PHONY: whats-running
whats-running: ## Anything in this account currently costing money for this project
	@echo "== EKS clusters"; aws eks list-clusters --region $(REGION) --query clusters --output text
	@echo "== EC2 instances"; aws ec2 describe-instances --region $(REGION) \
	  --filters Name=instance-state-name,Values=running,pending \
	  --query 'Reservations[].Instances[].{Type:InstanceType,Id:InstanceId,Life:InstanceLifecycle}' --output table
	@echo "== load balancers"; aws elbv2 describe-load-balancers --region $(REGION) \
	  --query 'LoadBalancers[].{Name:LoadBalancerName,Type:Type}' --output table
	@echo "== NAT gateways (should be empty — they are the big leak)"
	@aws ec2 describe-nat-gateways --region $(REGION) \
	  --filter Name=state,Values=available --query 'NatGateways[].NatGatewayId' --output text

##@ Deploy (CI)

# Deploys run in GitHub Actions, never from a workstation. The local apply
# targets below refuse to run unless ALLOW_LOCAL=1 (break-glass only).
define require_ci
	@if [ -z "$(ALLOW_LOCAL)" ]; then \
	  echo "Deploys run in CI. Edit deploy/tier and push, or: make deploy TIER=<none|sim|small|gpu|kimi>"; \
	  echo "Break-glass local apply: ALLOW_LOCAL=1 make $@"; \
	  exit 1; \
	fi
endef

TIER ?= from-file

.PHONY: deploy
deploy: ## Run the deploy workflow in CI (TIER=none|sim|small|gpu|kimi, default deploy/tier) and follow it
	@gh workflow run deploy.yml -f tier=$(TIER)
	@sleep 5
	@gh run watch $$(gh run list --workflow deploy.yml --limit 1 --json databaseId --jq '.[0].databaseId') --exit-status

.PHONY: destroy
destroy: ## Run the destroy workflow in CI: tear down ALL billable infra (asks you to confirm)
	@read -p "Destroy the cluster and everything on it? Type 'destroy': " c; \
	[ "$$c" = destroy ] || { echo "Aborted."; exit 1; }; \
	gh workflow run destroy.yml -f confirm=destroy
	@sleep 5
	@gh run watch $$(gh run list --workflow destroy.yml --limit 1 --json databaseId --jq '.[0].databaseId') --exit-status

.PHONY: kubeconfig
kubeconfig: ## Point local kubectl at the cluster (context alias: llm-d-eks-lab)
	@# --region is explicit: the CLI default region may differ from the
	@# cluster's, and then update-kubeconfig reports "No cluster found".
	@aws eks update-kubeconfig --region $(REGION) --name $(CLUSTER) --alias $(CLUSTER) >/dev/null
	@kubectl config use-context $(CLUSTER) >/dev/null
	@echo "kubectl context: $(CLUSTER) (region $(REGION))"
	@kubectl get nodes

##@ Bootstrap

.PHONY: bootstrap
bootstrap: ## Create the remote state bucket and CI roles (the one layer applied locally)
	@acct=$$(aws sts get-caller-identity --query Account --output text); \
	cd $(BOOTSTRAP) && $(TF) init -input=false \
	  -backend-config="bucket=$(PROJECT)-tfstate-$$acct" -backend-config="region=$(REGION)" && \
	  $(TF) apply -input=false $(AUTO) -var region=$(REGION) -var project=$(PROJECT)

##@ Cluster

# Bucket comes from the bootstrap layer's output, so the two stay in sync
# without a hardcoded name in version control.
STATE_BUCKET = $(PROJECT)-tfstate-$(shell aws sts get-caller-identity --query Account --output text 2>/dev/null)

.PHONY: cluster-init
cluster-init: ## Init 10-cluster against the bootstrap state bucket
	@if [ -z "$(STATE_BUCKET)" ]; then \
	  echo "No state bucket found — run 'make bootstrap' first."; exit 1; fi
	@echo "Using state bucket: $(STATE_BUCKET)"
	cd $(CLUSTER_DIR) && $(TF) init -input=false -reconfigure \
	  -backend-config="bucket=$(STATE_BUCKET)" \
	  -backend-config="region=$(REGION)"

.PHONY: cluster-plan
cluster-plan: cluster-init ## Plan 10-cluster
	cd $(CLUSTER_DIR) && $(TF) plan -input=false \
	  -var region=$(REGION) -var project=$(PROJECT)

.PHONY: cluster
cluster: ## Apply 10-cluster (~16 min, starts the $0.185/hr base cost) — CI only
	$(require_ci)
	@$(MAKE) --no-print-directory cluster-init
	cd $(CLUSTER_DIR) && $(TF) apply -input=false $(AUTO) \
	  -var region=$(REGION) -var project=$(PROJECT) \
	  $(if $(REAPER_ROLE_ARN),-var reaper_role_arn=$(REAPER_ROLE_ARN),)
	@echo ""
	@cd $(CLUSTER_DIR) && $(TF) output -raw kubeconfig_command && echo ""

##@ Tiers

.PHONY: sim-local
sim-local: ## T0 ($0): kind + llm-d-inference-sim on your laptop
	@./local/up.sh

.PHONY: sim-local-down
sim-local-down: ## Delete the T0 kind cluster
	@./local/down.sh

# All EKS tiers are the same Terraform with a different tfvars file.
define apply_tier
	$(require_ci)
	@if [ -z "$(STATE_BUCKET)" ]; then echo "No state bucket — run 'make bootstrap' first."; exit 1; fi
	cd $(INFER_DIR) && $(TF) init -input=false -reconfigure \
	  -backend-config="bucket=$(STATE_BUCKET)" -backend-config="region=$(REGION)"
	cd $(INFER_DIR) && $(TF) apply -input=false $(AUTO) \
	  -var-file=tiers/$(1).tfvars \
	  -var region=$(REGION) -var project=$(PROJECT) -var state_bucket=$(STATE_BUCKET)
	@echo ""
	@cd $(INFER_DIR) && $(TF) output -raw test_command && echo "" && echo ""
endef

.PHONY: sim-eks
sim-eks: cluster ## T1 ($0.19/hr): EKS + llm-d-inference-sim, no GPU
	$(call apply_tier,sim)

.PHONY: gpu-small
gpu-small: cluster ## T2 ($0.62-1.05/hr): Qwen3.5-4B on g6.xlarge (L4)
	$(call apply_tier,small)

.PHONY: gpu
gpu: cluster ## T3 ($2.03-3.88/hr): Qwen3.6-27B-FP8 on g6e.xlarge (L40S) <- default
	@$(MAKE) --no-print-directory preflight-gpu
	$(call apply_tier,gpu)

.PHONY: kimi
kimi: cluster ## Kimi-Dev-72B on g7e.12xlarge (2x 96GB), on-demand, ~$8.29/hr, 1 replica
	@$(MAKE) --no-print-directory preflight-kimi
	$(call apply_tier,kimi)

.PHONY: preflight-kimi
preflight-kimi: ## Check on-demand G/VT quota covers one 48 vCPU node
	@set -e; \
	limit=$$(aws service-quotas get-service-quota --service-code ec2 \
	  --quota-code L-DB2E81BA --region $(REGION) --query 'Quota.Value' --output text 2>/dev/null || echo 0); \
	limit=$${limit%%.*}; \
	limit=$${limit:-0}; \
	if [ "$$limit" -lt 48 ]; then \
	  echo "G/VT on-demand quota is $$limit vCPU in $(REGION) — one g7e.12xlarge needs 48."; \
	  echo "Nothing would launch. Run 'make quota' and request an increase."; \
	  exit 1; \
	fi; \
	echo "G/VT on-demand quota: $$limit vCPU — enough for one g7e.12xlarge (48 vCPU, 2x 96GB)."

.PHONY: preflight-gpu
preflight-gpu: ## Check GPU quota is sufficient before spending 20 minutes
	@set -e; \
	limit=$$(aws service-quotas get-service-quota --service-code ec2 \
	  --quota-code L-3819A6DF --region $(REGION) --query 'Quota.Value' --output text 2>/dev/null || echo 0); \
	limit=$${limit%%.*}; \
	limit=$${limit:-0}; \
	if [ "$$limit" -lt 4 ]; then \
	  echo "G/VT spot quota is $$limit vCPU in $(REGION) — one g6e.xlarge needs 4."; \
	  echo "Nothing would launch. Run 'make quota' and request an increase."; \
	  exit 1; \
	fi; \
	nodes=$$((limit / 4)); \
	echo "G/VT spot quota: $$limit vCPU = $$nodes x g6e.xlarge (1x L40S 44GB each)."; \
	if [ "$$nodes" -lt 2 ]; then \
	  echo "NOTE: only $$nodes node fits, so there is no scale-out to observe."; \
	fi

.PHONY: load
load: ## Fire k6 at the endpoint and watch replicas scale
	@url="$(BASE_URL)"; \
	if [ -z "$$url" ]; then \
	  url=$$(cd $(INFER_DIR) 2>/dev/null && $(TF) output -raw endpoint 2>/dev/null || true); \
	  if [ -n "$$url" ]; then url="http://$$url"; else url="http://localhost:8080"; fi; \
	fi; \
	model=$$(cd $(INFER_DIR) 2>/dev/null && $(TF) output -raw model 2>/dev/null || echo "Qwen/Qwen3.5-4B"); \
	echo "Load target: $$url  model: $$model"; \
	if command -v k6 >/dev/null; then \
	  BASE_URL="$$url" MODEL="$$model" k6 run loadgen/k6.js; \
	else \
	  echo "k6 not installed; running it in a container instead"; \
	  docker run --rm -i --network host \
	    -e BASE_URL="$$url" -e MODEL="$$model" \
	    grafana/k6 run - < loadgen/k6.js; \
	fi

.PHONY: watch
watch: ## Watch autoscaling and node provisioning live
	@watch -n 2 'kubectl -n llm-d get scaledobject,hpa,pods 2>/dev/null; echo; kubectl get nodes -L llm-d-eks-lab/role,karpenter.sh/capacity-type,node.kubernetes.io/instance-type 2>/dev/null'

##@ Teardown

.PHONY: down
down: ## Destroy the inference layer only — GPU gone, cluster warm ($0.185/hr)
	@if [ -z "$(STATE_BUCKET)" ]; then echo "No state bucket found."; exit 1; fi
	cd $(INFER_DIR) && $(TF) destroy -input=false -auto-approve \
	  -var region=$(REGION) -var project=$(PROJECT) -var state_bucket=$(STATE_BUCKET)

.PHONY: nuke
nuke: ## Destroy everything except remote state — $0.00/hr
	-cd $(INFER_DIR) && $(TF) destroy -input=false -auto-approve \
	  -var region=$(REGION) -var project=$(PROJECT) -var state_bucket=$(STATE_BUCKET)
	cd $(CLUSTER_DIR) && $(TF) destroy -input=false -auto-approve \
	  -var region=$(REGION) -var project=$(PROJECT)
	@echo ""
	@echo "Verifying nothing is still billing:"
	@$(MAKE) --no-print-directory whats-running

##@ Checks

.PHONY: fmt validate lint
fmt: ## terraform fmt across all layers
	$(TF) fmt -recursive terraform/

validate: ## terraform validate across all layers
	@for d in $(BOOTSTRAP) $(CLUSTER_DIR) $(INFER_DIR); do \
	  [ -f "$$d/versions.tf" ] || continue; \
	  echo "== $$d"; \
	  (cd $$d && $(TF) init -backend=false -input=false >/dev/null && $(TF) validate) || exit 1; \
	done

lint: ## Lint Terraform with tflint if installed
	@command -v tflint >/dev/null && tflint --recursive terraform/ || echo "tflint not installed, skipping"
