#!/usr/bin/env bash
# scripts/install-argocd.sh — Standalone ArgoCD installation helper.
# Called by setup-cluster.sh but can also be run independently.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }

info "Adding ArgoCD Helm repo..."
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update argo

info "Creating argocd namespace..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

info "Installing ArgoCD via Helm..."
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --values "${REPO_ROOT}/argocd/install/argocd-values.yaml" \
  --wait --timeout 300s

info "Applying AppProject and Applications..."
kubectl apply -f "${REPO_ROOT}/argocd/projects/gitops-project.yaml"
kubectl apply -f "${REPO_ROOT}/argocd/applications/dev.yaml"
kubectl apply -f "${REPO_ROOT}/argocd/applications/staging.yaml"
kubectl apply -f "${REPO_ROOT}/argocd/applications/prod.yaml"

PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)

success "ArgoCD installed!"
echo ""
echo "  URL:      http://localhost:30080"
echo "  Username: admin"
echo "  Password: ${PASS}"
