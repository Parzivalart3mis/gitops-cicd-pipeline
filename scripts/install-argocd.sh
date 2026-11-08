#!/usr/bin/env bash
# scripts/install-argocd.sh — Install Argo CD and register the applications.
#
# Called by setup-cluster.sh, or on its own via `make install-argocd`.
#   1. Installs the pinned argo/argo-cd chart with argocd/install/argocd-values.yaml
#   2. Enables the controller ServiceMonitor if the Prometheus Operator CRDs
#      exist (feeds the ArgoCDAppOutOfSync alert)
#   3. Applies the AppProject and the dev/staging/prod Applications
#      (argocd/applications/; NOT the ApplicationSet, which is an alternative)

set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

step "Installing Argo CD (chart ${ARGOCD_CHART_VERSION})"

extra_args=()
if kubectl get crd servicemonitors.monitoring.coreos.com &>/dev/null; then
  info "Prometheus Operator CRDs found — enabling the Argo CD metrics ServiceMonitor"
  extra_args+=(--set controller.metrics.serviceMonitor.enabled=true)
else
  warn "Prometheus Operator CRDs not found — Argo CD metrics won't be scraped (run install-observability.sh first)"
fi

helm_upgrade argocd argocd argo "${ARGOCD_REPO}" argo-cd "${ARGOCD_CHART_VERSION}" \
  --values "${REPO_ROOT}/argocd/install/argocd-values.yaml" \
  ${extra_args[@]+"${extra_args[@]}"} \
  --wait --timeout 600s
success "Argo CD installed"

info "Applying AppProject and Applications..."
kubectl apply -f "${REPO_ROOT}/argocd/projects/gitops-project.yaml"
kubectl apply -f "${REPO_ROOT}/argocd/applications/"
success "Applications registered: dev (auto-sync), staging and prod (manual sync)"

PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "<not available>")
echo ""
echo "  Argo CD UI: http://localhost:30080  (or: make port-forward → http://localhost:8080)"
echo "  Login:      admin / ${PASS}"
