.DEFAULT_GOAL := help
SHELL := /bin/bash
.ONESHELL:

REGION      ?= us-west-2
PROJECT     ?= llm-d-eks-lab
CLUSTER     ?= $(PROJECT)
TF          ?= terraform
# Set AUTO=-auto-approve to apply without the interactive prompt (bootstrap and
# break-glass only).
AUTO        ?=
BOOTSTRAP   := terraform/00-bootstrap
CLUSTER_DIR := terraform/10-cluster
CONFIG      := deploy/config.yaml

##@ Help

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS=":.*##"; printf "\nllm-d-eks-lab\n"} \
	/^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2 } \
	/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0,5) }' $(MAKEFILE_LIST)
	@echo ""

##@ Desired state (git) — every change here is a commit + push; CI and Argo CD do the rest

# Edit one key of deploy/config.yaml, commit it, push it.
define set_config
	@set -e; \
	git diff --quiet -- $(CONFIG) || { echo "$(CONFIG) has uncommitted changes — commit or revert them first."; exit 1; }; \
	sed -i.bak 's/^$(1): .*/$(1): $(2)/' $(CONFIG) && rm -f $(CONFIG).bak; \
	if git diff --quiet -- $(CONFIG); then echo "$(1) is already $(2)."; exit 0; fi; \
	git add $(CONFIG) && git commit -q -m "deploy: $(1) $(2)" && git push -q; \
	echo "Pushed $(1): $(2). Follow it with: make follow"
endef

.PHONY: tier
tier: ## Run a tier: make tier TIER=none|sim|small|gpu|kimi (commits deploy/config.yaml)
	@case "$(TIER)" in none|sim|small|gpu|kimi) ;; *) echo "TIER must be none|sim|small|gpu|kimi"; exit 1 ;; esac
	$(call set_config,tier,$(TIER))

.PHONY: cluster-on
cluster-on: ## Allow CI to create/keep the EKS cluster (~$0.26/hr from then on)
	$(call set_config,cluster,true)

.PHONY: cluster-off
cluster-off: ## Stop CI from (re)creating the cluster — then run `make destroy`
	$(call set_config,cluster,false)

.PHONY: follow
follow: ## Follow the latest deploy workflow run
	@gh run watch $$(gh run list --workflow deploy.yml --limit 1 --json databaseId --jq '.[0].databaseId') --exit-status

.PHONY: deploy
deploy: ## Re-run the deploy workflow (reconcile Terraform + verify Argo CD) and follow it
	@gh workflow run deploy.yml
	@sleep 5
	@$(MAKE) --no-print-directory follow

.PHONY: destroy
destroy: ## Run the destroy workflow: tear down ALL billable infra (asks you to confirm)
	@read -p "Destroy the cluster and everything on it? Type 'destroy': " c; \
	[ "$$c" = destroy ] || { echo "Aborted."; exit 1; }; \
	gh workflow run destroy.yml -f confirm=destroy
	@sleep 5
	@gh run watch $$(gh run list --workflow destroy.yml --limit 1 --json databaseId --jq '.[0].databaseId') --exit-status

##@ Cluster access

.PHONY: kubeconfig
kubeconfig: ## Point local kubectl at the EKS cluster (context alias: llm-d-eks-lab)
	@# --region is explicit: the CLI default region may differ from the
	@# cluster's, and then update-kubeconfig reports "No cluster found".
	@aws eks update-kubeconfig --region $(REGION) --name $(CLUSTER) --alias $(CLUSTER) >/dev/null
	@kubectl config use-context $(CLUSTER) >/dev/null
	@echo "kubectl context: $(CLUSTER) (region $(REGION))"
	@kubectl get nodes

.PHONY: argocd-ui
argocd-ui: ## Open the Argo CD UI of the current kubectl context on http://localhost:8090
	@echo "user: admin   password: $$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
	@echo "http://localhost:8090  (Ctrl-C to stop)"
	@kubectl -n argocd port-forward svc/argocd-server 8090:80

.PHONY: apps
apps: ## Argo CD application status in the current kubectl context
	@kubectl -n argocd get applications.argoproj.io

.PHONY: watch
watch: ## Watch autoscaling and node provisioning live
	@watch -n 2 'kubectl -n llm-d get scaledobject,hpa,pods 2>/dev/null; echo; kubectl get nodes -L llm-d-eks-lab/role,karpenter.sh/capacity-type,node.kubernetes.io/instance-type 2>/dev/null'

.PHONY: load
load: ## Fire k6 at the model endpoint (EKS NLB, or BASE_URL=...) and watch replicas scale
	@tier=$$(awk '/^tier:/{print $$2}' $(CONFIG)); \
	[ "$$tier" = none ] && tier=sim; \
	model=$$(awk '/^model:/{print $$2}' gitops/tiers/$$tier.yaml); \
	url="$(BASE_URL)"; \
	if [ -z "$$url" ]; then \
	  host=$$(kubectl -n llm-d get svc llm-d-public -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null); \
	  if [ -n "$$host" ]; then url="http://$$host"; else url="http://localhost:18080"; fi; \
	fi; \
	echo "Load target: $$url  model: $$model"; \
	if command -v k6 >/dev/null; then \
	  BASE_URL="$$url" MODEL="$$model" k6 run loadgen/k6.js; \
	else \
	  echo "k6 not installed; running it in a container instead"; \
	  docker run --rm -i --network host -e BASE_URL="$$url" -e MODEL="$$model" grafana/k6 run - < loadgen/k6.js; \
	fi

##@ Local, free — the same GitOps stack on kind

.PHONY: argocd-local
argocd-local: ## kind + Argo CD syncing this repo's branch (TIER=sim default). $0
	@./local/argocd-up.sh

.PHONY: argocd-local-down
argocd-local-down: ## Delete the local kind cluster
	@./local/argocd-down.sh

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
quota: ## Show G/VT GPU quota (spot and on-demand) and pending increase requests
	@echo "== current limits ($(REGION)) — denominated in vCPUs"
	@aws service-quotas list-service-quotas --service-code ec2 --region $(REGION) \
	  --query 'Quotas[?contains(QuotaName,`G and VT`)].{Code:QuotaCode,Name:QuotaName,vCPUs:Value}' \
	  --output table
	@echo "== what the tiers need: small/gpu 4 spot vCPU per replica; kimi 48 on-demand vCPU"
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

##@ Bootstrap & break-glass

.PHONY: bootstrap
bootstrap: ## Apply 00-bootstrap: state bucket + CI deploy role (the one layer applied locally)
	@acct=$$(aws sts get-caller-identity --query Account --output text); \
	cd $(BOOTSTRAP) && $(TF) init -input=false \
	  -backend-config="bucket=$(PROJECT)-tfstate-$$acct" -backend-config="region=$(REGION)" && \
	  $(TF) apply -input=false $(AUTO) -var region=$(REGION) -var project=$(PROJECT)

STATE_BUCKET = $(PROJECT)-tfstate-$(shell aws sts get-caller-identity --query Account --output text 2>/dev/null)

.PHONY: cluster-plan
cluster-plan: ## Read-only: plan 10-cluster from your machine
	cd $(CLUSTER_DIR) && $(TF) init -input=false -reconfigure \
	  -backend-config="bucket=$(STATE_BUCKET)" -backend-config="region=$(REGION)" && \
	  $(TF) plan -input=false -var region=$(REGION) -var project=$(PROJECT)

.PHONY: cluster-apply-local
cluster-apply-local: ## BREAK-GLASS: apply 10-cluster locally (requires ALLOW_LOCAL=1)
	@[ -n "$(ALLOW_LOCAL)" ] || { echo "Deploys run in CI (make cluster-on / make deploy). Break-glass: ALLOW_LOCAL=1 make $@"; exit 1; }
	cd $(CLUSTER_DIR) && $(TF) init -input=false -reconfigure \
	  -backend-config="bucket=$(STATE_BUCKET)" -backend-config="region=$(REGION)" && \
	  $(TF) apply -input=false $(AUTO) -var region=$(REGION) -var project=$(PROJECT)

##@ Checks

.PHONY: render fmt validate lint
render: ## Render + schema-validate every GitOps chart, tier and environment (no cluster)
	@./scripts/render-check.sh

fmt: ## terraform fmt across all layers
	$(TF) fmt -recursive terraform/

validate: ## terraform validate across all layers, then `make render`
	@for d in $(BOOTSTRAP) $(CLUSTER_DIR); do \
	  echo "== $$d"; \
	  (cd $$d && $(TF) init -backend=false -input=false >/dev/null && $(TF) validate) || exit 1; \
	done
	@$(MAKE) --no-print-directory render

lint: ## Lint Terraform with tflint if installed
	@command -v tflint >/dev/null && tflint --recursive terraform/ || echo "tflint not installed, skipping"
