#!/usr/bin/env bash
# scripts/install-observability.sh — Metrics, dashboards, logs and alerts.
#
# Called by setup-cluster.sh, or on its own via `make install-observability`.
# Installs into the `monitoring` namespace (all charts pinned in versions.env):
#   1. kube-prometheus-stack — Prometheus Operator, Prometheus, Alertmanager,
#      node-exporter, kube-state-metrics
#   2. grafana-dashboards ConfigMap — must exist BEFORE Grafana starts (the
#      chart mounts it as a required volume)
#   3. Grafana (grafana-community chart) — Prometheus + Loki datasources
#   4. Loki — log store (single binary)
#   5. Grafana Alloy — ships gitops-* pod logs to Loki
#   6. ServiceMonitor + PrometheusRules from observability/prometheus/

set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NS=monitoring
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -

step "Installing kube-prometheus-stack ${KUBE_PROMETHEUS_STACK_CHART_VERSION}"
helm_upgrade kube-prometheus-stack "${NS}" prometheus-community "${PROMETHEUS_COMMUNITY_REPO}" \
  kube-prometheus-stack "${KUBE_PROMETHEUS_STACK_CHART_VERSION}" \
  --values "${REPO_ROOT}/observability/prometheus/prometheus-values.yaml" \
  --wait --timeout 600s
success "Prometheus + Alertmanager installed"

step "Creating the grafana-dashboards ConfigMap"
kubectl create configmap grafana-dashboards \
  --namespace "${NS}" \
  --from-file="${REPO_ROOT}/observability/grafana/dashboards/" \
  --dry-run=client -o yaml | kubectl apply -f -
success "Dashboards loaded from observability/grafana/dashboards/"

step "Installing Grafana (chart ${GRAFANA_CHART_VERSION})"
helm_upgrade grafana "${NS}" grafana-community "${GRAFANA_COMMUNITY_REPO}" \
  grafana "${GRAFANA_CHART_VERSION}" \
  --values "${REPO_ROOT}/observability/grafana/grafana-values.yaml" \
  --wait --timeout 300s
# A changed dashboards ConfigMap is only re-read when the pod restarts.
kubectl rollout restart deployment/grafana -n "${NS}" >/dev/null
success "Grafana installed"

step "Installing Loki (chart ${LOKI_CHART_VERSION})"
helm_upgrade loki "${NS}" grafana-community "${GRAFANA_COMMUNITY_REPO}" \
  loki "${LOKI_CHART_VERSION}" \
  --values "${REPO_ROOT}/observability/loki/loki-values.yaml" \
  --wait --timeout 300s
success "Loki installed"

step "Installing Grafana Alloy (chart ${ALLOY_CHART_VERSION})"
helm_upgrade alloy "${NS}" grafana "${GRAFANA_REPO}" \
  alloy "${ALLOY_CHART_VERSION}" \
  --values "${REPO_ROOT}/observability/loki/alloy-values.yaml" \
  --wait --timeout 180s
success "Alloy installed — shipping gitops-* pod logs to Loki"

step "Applying ServiceMonitor and alert rules"
kubectl apply -f "${REPO_ROOT}/observability/prometheus/service-monitor.yaml"
kubectl apply -f "${REPO_ROOT}/observability/prometheus/alerts/"
success "Observability stack installed"

echo ""
echo "  Grafana: http://localhost:30300  (admin / gitops-demo-admin)"
echo "  Logs:    Grafana → Explore → Loki → {namespace=\"gitops-dev\", app=\"backend\"} | json"
