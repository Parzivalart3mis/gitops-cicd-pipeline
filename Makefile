# Makefile — Top-level task runner for the GitOps CI/CD pipeline project.
#
# All common operations are available as make targets.
# Run `make help` to see available commands.
#
# Prerequisites: docker, kubectl, kind, kustomize, helm
# Run `make setup` to create the local cluster and install everything.

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

CLUSTER_NAME    ?= gitops-demo
NAMESPACE_DEV   ?= gitops-dev
NAMESPACE_STG   ?= gitops-staging
NAMESPACE_PROD  ?= gitops-prod
# Must be lowercase: OCI repository paths are lowercase-only, and the names
# must match the images in k8s/base exactly.
OWNER           ?= parzivalart3mis
REGISTRY        ?= ghcr.io/$(OWNER)
export REGISTRY

# Compute the short git SHA for tagging (falls back to 'local' if not in a git repo)
GIT_SHA         := $(shell git rev-parse --short HEAD 2>/dev/null || echo local)

HOSTS_LINE := 127.0.0.1 dev.gitops.local api.dev.gitops.local staging.gitops.local api.staging.gitops.local prod.gitops.local api.prod.gitops.local

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
	@bash scripts/setup-cluster.sh

.PHONY: teardown
teardown: ## Delete the Kind cluster and clean up all resources
	@bash scripts/teardown-cluster.sh

.PHONY: port-forward
port-forward: ## Port-forward Argo CD, Grafana, and app UIs to localhost
	@bash scripts/port-forward.sh

.PHONY: hosts
hosts: ## Print the /etc/hosts line for the Ingress hostnames
	@echo "Add this line to /etc/hosts (e.g. with: echo '<line>' | sudo tee -a /etc/hosts):"
	@echo ""
	@echo "$(HOSTS_LINE)"

.PHONY: install-argocd
install-argocd: ## Install Argo CD into the current cluster
	@bash scripts/install-argocd.sh

.PHONY: install-observability
install-observability: ## Install Prometheus, Grafana, Loki and Alloy into the current cluster
	@bash scripts/install-observability.sh

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
.PHONY: build
build: build-backend build-frontend ## Build Docker images for both apps

.PHONY: build-backend
build-backend: ## Build the backend Docker image (multi-stage; runs the tests)
	docker build \
		-f apps/backend/Dockerfile.multistage \
		--build-arg GIT_SHA=$(GIT_SHA) \
		-t $(REGISTRY)/gitops-backend:$(GIT_SHA) \
		apps/backend

.PHONY: build-frontend
build-frontend: ## Build the frontend Docker image (multi-stage)
	docker build \
		-f apps/frontend/Dockerfile.multistage \
		--build-arg FRONTEND_VERSION=$(GIT_SHA) \
		-t $(REGISTRY)/gitops-frontend:$(GIT_SHA) \
		apps/frontend

.PHONY: load-images
load-images: build ## Build and load images into Kind (no registry push)
	kind load docker-image $(REGISTRY)/gitops-backend:$(GIT_SHA)  --name $(CLUSTER_NAME)
	kind load docker-image $(REGISTRY)/gitops-frontend:$(GIT_SHA) --name $(CLUSTER_NAME)

.PHONY: clean-images
clean-images: ## Remove local gitops-* Docker images
	@docker images --format "{{.Repository}}:{{.Tag}}" | \
		grep "gitops-" | xargs -r docker rmi || true

# ---------------------------------------------------------------------------
# Quality gates (the same checks CI runs)
# ---------------------------------------------------------------------------
.PHONY: test
test: ## Run backend unit tests with the 80% coverage gate
	cd apps/backend && \
		pip install -q -r requirements-dev.txt && \
		pytest src/tests/ -v --tb=short \
			--cov=src \
			--cov-report=term-missing \
			--cov-fail-under=80

.PHONY: lint
lint: ## Lint Python (ruff, mypy), shell scripts (shellcheck) and the Nginx config
	cd apps/backend && pip install -q -r requirements-dev.txt && ruff check src/ && mypy src/
	shellcheck --severity=warning -x scripts/*.sh scripts/ci/*.sh apps/frontend/entrypoint.sh
	docker build -q -f apps/frontend/Dockerfile.multistage -t gitops-frontend:lint apps/frontend >/dev/null
	docker run --rm -e BACKEND_UPSTREAM=http://127.0.0.1:8000 gitops-frontend:lint nginx -t

.PHONY: validate-manifests
validate-manifests: ## Render all overlays and check image names, tags, hosts
	@bash scripts/ci/validate-manifests.sh

.PHONY: scan
scan: ## Security scans: Trivy (fs), pip-audit, kubesec — each skipped if not installed
	@if command -v trivy >/dev/null; then \
		trivy fs --config security/trivy/trivy-config.yaml . ; \
	else echo "(trivy not installed — skipped)"; fi
	@if command -v pip-audit >/dev/null; then \
		pip-audit --strict -r apps/backend/requirements-dev.txt ; \
	else echo "(pip-audit not installed — skipped; pip install -r apps/backend/requirements-dev.txt)"; fi
	@if command -v kubesec >/dev/null; then \
		for app in backend frontend; do kubesec scan k8s/base/$$app/deployment.yaml; done ; \
	else echo "(kubesec not installed — skipped)"; fi

# ---------------------------------------------------------------------------
# Deploy / promote / rollback (local equivalents of the GitHub workflows)
# ---------------------------------------------------------------------------
.PHONY: deploy-dev
deploy-dev: load-images ## Build, load into Kind, point dev at the current commit, and apply directly
	bash scripts/set-image-tag.sh k8s/overlays/dev $(GIT_SHA)
	kustomize build k8s/overlays/dev | kubectl apply -f -
	kubectl rollout status deployment/backend  -n $(NAMESPACE_DEV) --timeout=180s
	kubectl rollout status deployment/frontend -n $(NAMESPACE_DEV) --timeout=180s
	@echo -e "$(YELLOW)Note: Argo CD self-heals dev back to Git within minutes."
	@echo -e "Commit and push k8s/overlays/dev/ to keep this version (or use 'make demo').$(NC)"

.PHONY: promote
promote: ## Promote the tag running in one environment to the next (interactive)
	@read -r -p "Source environment (dev/staging): " SRC; \
	case "$$SRC" in dev) TGT=staging ;; staging) TGT=prod ;; \
		*) echo "Source must be dev or staging"; exit 1 ;; esac; \
	TAG=$$(bash scripts/get-image-tag.sh k8s/overlays/$$SRC backend); \
	if [[ "$$TAG" == latest ]]; then echo "$$SRC has no SHA tag deployed yet"; exit 1; fi; \
	echo "Promoting $$SRC → $$TGT [$$TAG]"; \
	bash scripts/set-image-tag.sh k8s/overlays/$$TGT "$$TAG"; \
	git add k8s/overlays/$$TGT/; \
	git commit -m "chore(promote): $$SRC → $$TGT [$$TAG]"; \
	echo -e "$(GREEN)Committed. Push to master, then sync: argocd app sync gitops-demo-$$TGT$(NC)"

.PHONY: rollback
rollback: ## Roll an environment back to a previous tag (interactive)
	@read -r -p "Environment to roll back (dev/staging/prod): " ENV; \
	case "$$ENV" in dev|staging|prod) ;; *) echo "Unknown environment"; exit 1 ;; esac; \
	read -r -p "Target image tag (git short SHA): " TAG; \
	[[ "$$TAG" =~ ^[0-9a-f]{7,40}$$ ]] || { echo "Tag must be a git SHA"; exit 1; }; \
	read -r -p "Reason for rollback: " REASON; \
	echo -e "$(YELLOW)Rolling back $$ENV to $$TAG...$(NC)"; \
	bash scripts/set-image-tag.sh k8s/overlays/$$ENV "$$TAG"; \
	git add k8s/overlays/$$ENV/; \
	git commit -m "chore(rollback): $$ENV → $$TAG" -m "Reason: $$REASON"; \
	echo -e "$(GREEN)Rollback committed. Push to master to apply.$(NC)"

# ---------------------------------------------------------------------------
# Observability helpers
# ---------------------------------------------------------------------------
.PHONY: status
status: ## Show Argo CD sync status for all environments
	@kubectl get applications -n argocd \
		-o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision' \
		2>/dev/null || echo "(Argo CD not installed)"

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
# Secrets & demo
# ---------------------------------------------------------------------------
.PHONY: seal-secret
seal-secret: ## Seal a secret: make seal-secret ENV=dev NAME=app-secrets DATA="api-key=@./key.txt"
	@if [[ -z "$(ENV)" || -z "$(NAME)" || -z "$(DATA)" ]]; then \
		echo 'Usage: make seal-secret ENV=<dev|staging|prod> NAME=<secret-name> DATA="key=value [key2=@file ...]"'; \
		exit 1; \
	fi
	@bash scripts/seal-secret.sh "$(ENV)" "$(NAME)" $(DATA)

.PHONY: demo
demo: ## Run the interactive end-to-end demo (build → deploy → verify → self-heal)
	@bash scripts/demo.sh
