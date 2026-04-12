# Makefile — Top-level task runner for the GitOps CI/CD pipeline project.
#
# All common operations are available as make targets.
# Run `make help` to see available commands.
#
# Prerequisites: docker, kubectl, kind, kustomize, helm
# Run `make setup` to install all dependencies on a fresh machine.

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

CLUSTER_NAME    ?= gitops-demo
NAMESPACE_DEV   ?= gitops-dev
NAMESPACE_STG   ?= gitops-staging
NAMESPACE_PROD  ?= gitops-prod
OWNER           ?= Parzivalart3mis
REGISTRY        ?= ghcr.io/$(OWNER)

# Compute the short git SHA for tagging (falls back to 'local' if not in a git repo)
GIT_SHA         := $(shell git rev-parse --short HEAD 2>/dev/null || echo local)

# Colour codes for prettier output
BOLD   := \033[1m
GREEN  := \033[0;32m
CYAN   := \033[0;36m
YELLOW := \033[1;33m
NC     := \033[0m

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
.PHONY: help
help: ## Show this help message
	@echo ""
	@echo -e "$(BOLD)GitOps CI/CD Pipeline — Available Commands$(NC)"
	@echo -e "$(CYAN)──────────────────────────────────────────────────────────$(NC)"
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_-]+:.*##/ {printf "  $(GREEN)%-22s$(NC) %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo ""

# ---------------------------------------------------------------------------
# Cluster lifecycle
# ---------------------------------------------------------------------------
.PHONY: setup
setup: ## Create local Kind cluster and install all dependencies
	@echo -e "\n$(BOLD)$(CYAN)Setting up local GitOps cluster...$(NC)"
	@chmod +x scripts/setup-cluster.sh
	@bash scripts/setup-cluster.sh

.PHONY: teardown
teardown: ## Delete the Kind cluster and clean up all resources
	@chmod +x scripts/teardown-cluster.sh
	@bash scripts/teardown-cluster.sh

.PHONY: port-forward
port-forward: ## Port-forward ArgoCD, Grafana, and app UIs to localhost
	@echo -e "$(CYAN)Starting port-forwards...$(NC)"
	@chmod +x scripts/port-forward.sh
	@bash scripts/port-forward.sh

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
.PHONY: build
build: build-backend build-frontend ## Build Docker images for both apps

.PHONY: build-backend
build-backend: ## Build the backend Docker image (multi-stage)
	@echo -e "$(CYAN)Building backend image: $(REGISTRY)/gitops-backend:$(GIT_SHA)$(NC)"
	docker build \
		-f apps/backend/Dockerfile.multistage \
		--build-arg GIT_SHA=$(GIT_SHA) \
		-t $(REGISTRY)/gitops-backend:$(GIT_SHA) \
		-t $(REGISTRY)/gitops-backend:latest \
		apps/backend
	@echo -e "$(GREEN)Backend image built: $(REGISTRY)/gitops-backend:$(GIT_SHA)$(NC)"

.PHONY: build-frontend
build-frontend: ## Build the frontend Docker image (multi-stage)
	@echo -e "$(CYAN)Building frontend image: $(REGISTRY)/gitops-frontend:$(GIT_SHA)$(NC)"
	docker build \
		-f apps/frontend/Dockerfile.multistage \
		--build-arg FRONTEND_VERSION=$(GIT_SHA) \
		-t $(REGISTRY)/gitops-frontend:$(GIT_SHA) \
		-t $(REGISTRY)/gitops-frontend:latest \
		apps/frontend
	@echo -e "$(GREEN)Frontend image built: $(REGISTRY)/gitops-frontend:$(GIT_SHA)$(NC)"

.PHONY: load-images
load-images: build ## Build and load images into Kind cluster (no registry push)
	@echo -e "$(CYAN)Loading images into Kind cluster '$(CLUSTER_NAME)'...$(NC)"
	kind load docker-image $(REGISTRY)/gitops-backend:$(GIT_SHA)  --name $(CLUSTER_NAME)
	kind load docker-image $(REGISTRY)/gitops-frontend:$(GIT_SHA) --name $(CLUSTER_NAME)
	@echo -e "$(GREEN)Images loaded$(NC)"

.PHONY: clean-images
clean-images: ## Remove local gitops-* Docker images
	@docker images --format "{{.Repository}}:{{.Tag}}" | \
		grep "gitops-" | xargs -r docker rmi || true
	@echo -e "$(GREEN)Local images cleaned$(NC)"

# ---------------------------------------------------------------------------
# Test & Lint
# ---------------------------------------------------------------------------
.PHONY: test
test: ## Run all unit tests with coverage report
	@echo -e "$(CYAN)Running backend tests...$(NC)"
	cd apps/backend && \
		pip install -q -r requirements.txt && \
		pytest src/tests/ -v --tb=short \
			--cov=src \
			--cov-report=term-missing \
			--cov-fail-under=80

.PHONY: lint
lint: ## Run linters on all code and manifests
	@echo -e "$(CYAN)Linting Python (ruff + mypy)...$(NC)"
	cd apps/backend && pip install -q ruff mypy && \
		ruff check src/ && \
		mypy src/ --ignore-missing-imports
	@echo -e "$(CYAN)Linting shell scripts (shellcheck)...$(NC)"
	shellcheck scripts/*.sh || true
	@echo -e "$(CYAN)Validating Nginx config...$(NC)"
	docker run --rm \
		-v "$(PWD)/apps/frontend/nginx.conf:/etc/nginx/nginx.conf:ro" \
		nginx:1.27.0-alpine nginx -t -c /etc/nginx/nginx.conf 2>&1 || true
	@echo -e "$(GREEN)Linting complete$(NC)"

.PHONY: scan
scan: ## Run security scans (Trivy image scan + kubesec manifest scan)
	@echo -e "$(CYAN)Running Trivy filesystem scan...$(NC)"
	trivy fs . --severity HIGH,CRITICAL --ignore-unfixed || true
	@echo -e "\n$(CYAN)Running kubesec scan on backend deployment...$(NC)"
	kubesec scan k8s/base/backend/deployment.yaml 2>/dev/null || \
		echo "(kubesec not installed — skip)"
	@echo -e "\n$(CYAN)Running kubesec scan on frontend deployment...$(NC)"
	kubesec scan k8s/base/frontend/deployment.yaml 2>/dev/null || \
		echo "(kubesec not installed — skip)"
	@echo -e "$(GREEN)Security scan complete$(NC)"

.PHONY: validate-manifests
validate-manifests: ## Run kustomize build on all overlays to verify they render
	@echo -e "$(CYAN)Validating Kustomize overlays...$(NC)"
	@for env in dev staging prod; do \
		echo -e "  Validating $$env..."; \
		kustomize build k8s/overlays/$$env > /dev/null && \
		echo -e "  $(GREEN)✅ $$env overlay is valid$(NC)"; \
	done

# ---------------------------------------------------------------------------
# Deploy
# ---------------------------------------------------------------------------
.PHONY: deploy-dev
deploy-dev: ## Deploy to dev environment (update kustomize and apply)
	@echo -e "$(CYAN)Deploying to dev (tag: $(GIT_SHA))...$(NC)"
	cd k8s/overlays/dev && \
		kustomize edit set image \
			$(REGISTRY)/gitops-backend=$(REGISTRY)/gitops-backend:$(GIT_SHA) && \
		kustomize edit set image \
			$(REGISTRY)/gitops-frontend=$(REGISTRY)/gitops-frontend:$(GIT_SHA)
	kustomize build k8s/overlays/dev | kubectl apply -f -
	kubectl rollout status deployment/backend  -n $(NAMESPACE_DEV) --timeout=120s
	kubectl rollout status deployment/frontend -n $(NAMESPACE_DEV) --timeout=120s
	@echo -e "$(GREEN)Deployed to dev: $(GIT_SHA)$(NC)"

.PHONY: promote
promote: ## Promote between environments (interactive)
	@echo ""
	@echo -e "$(BOLD)Environment Promotion$(NC)"
	@read -p "Source environment (dev/staging): " SRC; \
	read -p "Target environment (staging/prod): " TGT; \
	read -p "Image tag to promote (git SHA): " TAG; \
	echo ""; \
	echo "Promoting $$SRC → $$TGT [$$TAG]"; \
	cd k8s/overlays/$$TGT && \
		kustomize edit set image \
			$(REGISTRY)/gitops-backend=$(REGISTRY)/gitops-backend:$$TAG && \
		kustomize edit set image \
			$(REGISTRY)/gitops-frontend=$(REGISTRY)/gitops-frontend:$$TAG; \
	git add k8s/overlays/$$TGT/; \
	git commit -m "chore(promote): $$SRC → $$TGT [$$TAG]"; \
	echo -e "$(GREEN)Committed. Push to trigger ArgoCD sync: git push$(NC)"

.PHONY: rollback
rollback: ## Rollback an environment to a previous tag (interactive)
	@echo ""
	@echo -e "$(BOLD)$(YELLOW)Emergency Rollback$(NC)"
	@read -p "Environment to rollback (dev/staging/prod): " ENV; \
	read -p "Target image tag (git SHA): " TAG; \
	read -p "Reason for rollback: " REASON; \
	echo ""; \
	echo -e "$(YELLOW)Rolling back $$ENV to $$TAG...$(NC)"; \
	cd k8s/overlays/$$ENV && \
		kustomize edit set image \
			$(REGISTRY)/gitops-backend=$(REGISTRY)/gitops-backend:$$TAG && \
		kustomize edit set image \
			$(REGISTRY)/gitops-frontend=$(REGISTRY)/gitops-frontend:$$TAG; \
	git add k8s/overlays/$$ENV/; \
	git commit -m "chore(rollback): $$ENV → $$TAG reason: $$REASON"; \
	echo -e "$(GREEN)Rollback committed. Push to apply: git push$(NC)"

# ---------------------------------------------------------------------------
# ArgoCD
# ---------------------------------------------------------------------------
.PHONY: install-argocd
install-argocd: ## Install ArgoCD into the current cluster
	@chmod +x scripts/install-argocd.sh
	@bash scripts/install-argocd.sh

.PHONY: install-observability
install-observability: ## Install Prometheus + Grafana into the current cluster
	@chmod +x scripts/install-observability.sh
	@bash scripts/install-observability.sh

.PHONY: status
status: ## Show ArgoCD sync status for all environments
	@echo -e "$(BOLD)ArgoCD Application Status$(NC)"
	@kubectl get applications -n argocd \
		-o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision' \
		2>/dev/null || echo "(ArgoCD not installed)"

# ---------------------------------------------------------------------------
# Observability & Debugging
# ---------------------------------------------------------------------------
.PHONY: logs
logs: ## Tail logs from backend pods in dev (set NS=gitops-staging for other envs)
	@NS=$${NS:-$(NAMESPACE_DEV)}; \
	echo -e "$(CYAN)Tailing backend logs in $$NS...$(NC)"; \
	kubectl logs -l app=backend -n $$NS -f --max-log-requests 5

.PHONY: events
events: ## Show recent Kubernetes events in dev namespace
	kubectl get events -n $(NAMESPACE_DEV) \
		--sort-by='.lastTimestamp' | tail -30

.PHONY: pods
pods: ## Show pod status across all gitops namespaces
	@for ns in $(NAMESPACE_DEV) $(NAMESPACE_STG) $(NAMESPACE_PROD); do \
		echo -e "\n$(BOLD)Namespace: $$ns$(NC)"; \
		kubectl get pods -n $$ns 2>/dev/null || echo "  (namespace not found)"; \
	done

# ---------------------------------------------------------------------------
# Secrets
# ---------------------------------------------------------------------------
.PHONY: seal-secret
seal-secret: ## Seal a secret for an environment (interactive)
	@chmod +x scripts/seal-secret.sh
	@echo "Usage: ./scripts/seal-secret.sh <namespace> <secret-name> <key>=<value>"
	@bash scripts/seal-secret.sh

# ---------------------------------------------------------------------------
# Demo
# ---------------------------------------------------------------------------
.PHONY: demo
demo: ## Run the full automated demo (deploy → change → watch sync → verify)
	@chmod +x scripts/demo.sh
	@bash scripts/demo.sh
