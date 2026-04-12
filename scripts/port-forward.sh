#!/usr/bin/env bash
# scripts/port-forward.sh — Port-forward all demo UIs to localhost.
#
# Use this when the Kind cluster's NodePort configuration isn't working,
# or when running on a remote machine.
#
# Opens:
#   - ArgoCD UI:  http://localhost:8080
#   - Grafana:    http://localhost:3000
#   - Backend:    http://localhost:8000
#   - Frontend:   http://localhost:8888

set -euo pipefail

GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC} $*"; }

# Kill any existing port-forwards for our ports
pkill -f "kubectl port-forward" 2>/dev/null || true
sleep 1

info "Starting port-forwards..."

kubectl port-forward svc/argocd-server     -n argocd    8080:80   &>/tmp/pf-argocd.log   &
kubectl port-forward svc/grafana           -n monitoring 3000:80   &>/tmp/pf-grafana.log  &
kubectl port-forward svc/backend           -n gitops-dev 8000:8000 &>/tmp/pf-backend.log  &
kubectl port-forward svc/frontend          -n gitops-dev 8888:8080 &>/tmp/pf-frontend.log &

sleep 2

echo ""
echo -e "${BOLD}${GREEN}Port-forwards active:${NC}"
echo "  ArgoCD UI:  http://localhost:8080"
echo "  Grafana:    http://localhost:3000 (admin / gitops-demo-admin)"
echo "  Backend:    http://localhost:8000/healthz"
echo "  Frontend:   http://localhost:8888"
echo ""
echo "Press Ctrl+C to stop all port-forwards."

# Wait for any background job to exit (keeps the script alive)
wait
