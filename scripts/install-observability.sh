#!/usr/bin/env bash
# scripts/install-observability.sh — Install Prometheus + Grafana + Loki stack.
# Called by setup-cluster.sh but can also be run independently.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }

info "Adding Helm repos..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update

kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

info "Installing kube-prometheus-stack..."
helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values "${REPO_ROOT}/observability/prometheus/prometheus-values.yaml" \
  --timeout 300s

info "Installing Grafana..."
helm upgrade --install grafana grafana/grafana \
  --namespace monitoring \
  --values "${REPO_ROOT}/observability/grafana/grafana-values.yaml" \
  --wait --timeout 120s

info "Applying alert rules..."
kubectl apply -f "${REPO_ROOT}/observability/prometheus/alerts/" --namespace monitoring

success "Observability stack installed!"
echo "  Grafana: http://localhost:30300 (admin / gitops-demo-admin)"
