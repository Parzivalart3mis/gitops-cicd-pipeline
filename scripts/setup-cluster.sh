#!/usr/bin/env bash
# scripts/setup-cluster.sh — One-command local cluster setup.
#
# This script creates a Kind cluster and installs all dependencies needed to
# run the GitOps CI/CD pipeline locally. It is IDEMPOTENT — safe to run
# multiple times without side effects.
#
# What it does:
#   1. Checks prerequisites (docker, kubectl, kind, kustomize, helm)
#   2. Creates a Kind cluster (1 control plane, 2 workers)
#   3. Installs Nginx Ingress controller
#   4. Installs ArgoCD via Helm
#   5. Installs Bitnami Sealed Secrets controller
#   6. Installs Prometheus + Grafana via Helm
#   7. Applies OPA Gatekeeper + constraint templates
#   8. Applies ArgoCD Application CRDs
#   9. Prints a summary with all URLs, credentials, and next steps
#
# Usage:
#   chmod +x scripts/setup-cluster.sh
#   ./scripts/setup-cluster.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}${CYAN}▶ $*${NC}"; }

CLUSTER_NAME="${CLUSTER_NAME:-gitops-demo}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Step 0: Check prerequisites
# ---------------------------------------------------------------------------
step "Checking prerequisites"

check_cmd() {
  local cmd="$1" hint="$2"
  if command -v "$cmd" &>/dev/null; then
    success "$cmd found: $(command -v "$cmd")"
  else
    error "$cmd not found. $hint"
  fi
}

check_cmd docker  "Install Docker: https://docs.docker.com/get-docker/"
check_cmd kubectl "Install kubectl: https://kubernetes.io/docs/tasks/tools/"
check_cmd kind    "Install kind: https://kind.sigs.k8s.io/docs/user/quick-start/"
check_cmd helm    "Install Helm: https://helm.sh/docs/intro/install/"
check_cmd kustomize "Install kustomize: https://kubectl.docs.kubernetes.io/installation/kustomize/"

# Check Docker is running
docker info &>/dev/null || error "Docker daemon is not running. Start Docker first."

# ---------------------------------------------------------------------------
# Step 1: Create Kind cluster
# ---------------------------------------------------------------------------
step "Creating Kind cluster: ${CLUSTER_NAME}"

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  warn "Cluster '${CLUSTER_NAME}' already exists — skipping creation"
else
  cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --config=-
# Kind cluster config: 1 control plane + 2 worker nodes.
# extraPortMappings expose NodePort services to localhost.
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
      - containerPort: 30080
        hostPort: 30080
        protocol: TCP   # ArgoCD UI
      - containerPort: 30300
        hostPort: 30300
        protocol: TCP   # Grafana UI
  - role: worker
  - role: worker
EOF
  success "Kind cluster created"
fi

kubectl cluster-info --context "kind-${CLUSTER_NAME}"

# ---------------------------------------------------------------------------
# Step 2: Install Nginx Ingress Controller
# ---------------------------------------------------------------------------
step "Installing Nginx Ingress Controller"

kubectl apply -f \
  "https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml" \
  --dry-run=client 2>/dev/null || true

kubectl apply -f \
  "https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml"

info "Waiting for Nginx Ingress to be ready (up to 60s)..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=60s || warn "Ingress controller may not be ready yet — continue anyway"

success "Nginx Ingress Controller installed"

# ---------------------------------------------------------------------------
# Step 3: Install ArgoCD
# ---------------------------------------------------------------------------
step "Installing ArgoCD"

helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update argo 2>/dev/null || true

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --values "${REPO_ROOT}/argocd/install/argocd-values.yaml" \
  --wait \
  --timeout 300s

success "ArgoCD installed"
info "ArgoCD UI: http://localhost:30080"
info "ArgoCD admin password: $(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d 2>/dev/null || echo '<run: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d>')"

# ---------------------------------------------------------------------------
# Step 4: Install Sealed Secrets
# ---------------------------------------------------------------------------
step "Installing Sealed Secrets controller"

helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets 2>/dev/null || true
helm repo update sealed-secrets 2>/dev/null || true

helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace kube-system \
  --values "${REPO_ROOT}/security/sealed-secrets/controller-values.yaml" \
  --wait \
  --timeout 120s

success "Sealed Secrets controller installed"

# ---------------------------------------------------------------------------
# Step 5: Install Prometheus + Grafana (kube-prometheus-stack)
# ---------------------------------------------------------------------------
step "Installing Prometheus + Grafana (kube-prometheus-stack)"

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update prometheus-community 2>/dev/null || true

kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values "${REPO_ROOT}/observability/prometheus/prometheus-values.yaml" \
  --timeout 300s \
  --wait || warn "kube-prometheus-stack install took longer than expected — may still be starting"

# Install Grafana separately
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update grafana 2>/dev/null || true

helm upgrade --install grafana grafana/grafana \
  --namespace monitoring \
  --values "${REPO_ROOT}/observability/grafana/grafana-values.yaml" \
  --wait \
  --timeout 120s

# Apply custom alert rules
kubectl apply -f "${REPO_ROOT}/observability/prometheus/alerts/deployment-alerts.yaml" \
  --namespace monitoring 2>/dev/null || true
kubectl apply -f "${REPO_ROOT}/observability/prometheus/alerts/app-alerts.yaml" \
  --namespace monitoring 2>/dev/null || true
kubectl apply -f "${REPO_ROOT}/observability/prometheus/service-monitor.yaml" \
  --namespace monitoring 2>/dev/null || true

success "Prometheus + Grafana installed"
info "Grafana UI: http://localhost:30300 (admin / gitops-demo-admin)"

# ---------------------------------------------------------------------------
# Step 6: Install OPA Gatekeeper
# ---------------------------------------------------------------------------
step "Installing OPA Gatekeeper"

helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts 2>/dev/null || true
helm repo update gatekeeper 2>/dev/null || true

helm upgrade --install gatekeeper gatekeeper/gatekeeper \
  --namespace gatekeeper-system --create-namespace \
  --wait \
  --timeout 120s

info "Waiting for Gatekeeper webhooks to be ready..."
sleep 15  # give webhook time to register

# Apply constraint templates and constraints
for f in "${REPO_ROOT}/security/opa-gatekeeper/constraints/"*.yaml; do
  info "Applying OPA constraint: $(basename "$f")"
  kubectl apply -f "$f" || warn "Failed to apply $f — Gatekeeper may still be starting"
done

success "OPA Gatekeeper installed"

# ---------------------------------------------------------------------------
# Step 7: Apply ArgoCD AppProject and Applications
# ---------------------------------------------------------------------------
step "Applying ArgoCD AppProject and Application CRDs"

# Note: these reference the real GitHub repo. For local demo, ArgoCD will
# show them as OutOfSync until you update the repoURL to your fork.
kubectl apply -f "${REPO_ROOT}/argocd/projects/gitops-project.yaml"

info "Applying ArgoCD Applications (dev auto-syncs, staging/prod are manual)..."
kubectl apply -f "${REPO_ROOT}/argocd/applications/dev.yaml"
kubectl apply -f "${REPO_ROOT}/argocd/applications/staging.yaml"
kubectl apply -f "${REPO_ROOT}/argocd/applications/prod.yaml"

success "ArgoCD Applications configured"

# ---------------------------------------------------------------------------
# Step 8: Print summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}${GREEN}============================================================${NC}"
echo -e "${BOLD}${GREEN}  Setup complete! GitOps demo cluster is ready.${NC}"
echo -e "${BOLD}${GREEN}============================================================${NC}"
echo ""
echo -e "${BOLD}URLs:${NC}"
echo "  ArgoCD UI:      http://localhost:30080"
echo "  Grafana UI:     http://localhost:30300"
echo ""
echo -e "${BOLD}Credentials:${NC}"
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "run: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d")
echo "  ArgoCD:  admin / ${ARGOCD_PASS}"
echo "  Grafana: admin / gitops-demo-admin"
echo ""
echo -e "${BOLD}Next steps:${NC}"
echo "  1. Ensure repoURL in argocd/applications/*.yaml points to your GitHub repo"
echo "  2. Push the repo to GitHub to trigger the CI pipeline"
echo "  3. Watch ArgoCD auto-sync dev:   kubectl get apps -n argocd -w"
echo "  4. Run the demo:                 make demo"
echo "  5. Port-forward all UIs:         make port-forward"
echo ""
echo -e "${BOLD}Useful commands:${NC}"
echo "  kubectl get pods -A                    # all pods"
echo "  kubectl get apps -n argocd             # ArgoCD applications"
echo "  argocd app list                        # (requires argocd CLI)"
echo "  make status                            # ArgoCD sync status"
echo "  make logs                              # tail pod logs"
echo ""
