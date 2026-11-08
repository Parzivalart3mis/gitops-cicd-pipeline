#!/usr/bin/env bash
# scripts/setup-cluster.sh — One-command local cluster setup.
#
# Creates a Kind cluster and installs everything needed to run the GitOps
# CI/CD pipeline locally. It is IDEMPOTENT: safe to run again after a failure.
# Every component is pinned (scripts/versions.env), so each run installs the
# same thing.
#
# What it does:
#   1. Checks prerequisites (docker, kubectl, kind, kustomize, helm)
#   2. Creates a Kind cluster (1 control plane, 2 workers)
#   3. Installs the ingress-nginx controller
#   4. Installs metrics-server (required by the HorizontalPodAutoscalers)
#   5. Installs the Sealed Secrets controller
#   6. Installs OPA Gatekeeper, its ConstraintTemplates, then its Constraints
#   7. Installs the observability stack (install-observability.sh)
#   8. Installs Argo CD + the AppProject and Applications (install-argocd.sh)
#   9. Prints URLs, credentials, and the /etc/hosts line for the Ingress hosts
#
# Gatekeeper comes before Argo CD on purpose: policies are in force before
# the first application sync. Observability comes before Argo CD so the
# Prometheus Operator CRDs exist when Argo CD's ServiceMonitor is created.
#
# Usage: make setup   (or ./scripts/setup-cluster.sh)

set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# ---------------------------------------------------------------------------
# Step 1: Prerequisites
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

check_cmd docker    "Install Docker: https://docs.docker.com/get-docker/"
check_cmd kubectl   "Install kubectl: https://kubernetes.io/docs/tasks/tools/"
check_cmd kind      "Install kind: https://kind.sigs.k8s.io/docs/user/quick-start/"
check_cmd helm      "Install Helm: https://helm.sh/docs/intro/install/"
check_cmd kustomize "Install kustomize: https://kubectl.docs.kubernetes.io/installation/kustomize/"

docker info &>/dev/null || error "Docker daemon is not running. Start Docker first."

# ---------------------------------------------------------------------------
# Step 2: Kind cluster
# ---------------------------------------------------------------------------
step "Creating Kind cluster: ${CLUSTER_NAME}"

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  warn "Cluster '${CLUSTER_NAME}' already exists — skipping creation"
else
  # extraPortMappings expose the Ingress (80/443) and the Argo CD / Grafana
  # NodePorts on the host. The control-plane node carries ingress-ready=true,
  # which the kind flavour of ingress-nginx schedules onto.
  cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --config=-
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
        protocol: TCP   # Argo CD UI
      - containerPort: 30300
        hostPort: 30300
        protocol: TCP   # Grafana UI
  - role: worker
  - role: worker
EOF
  success "Kind cluster created"
fi

kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null
kubectl cluster-info --context "kind-${CLUSTER_NAME}"

# ---------------------------------------------------------------------------
# Step 3: ingress-nginx (pinned release manifest for Kind)
# ---------------------------------------------------------------------------
step "Installing ingress-nginx ${INGRESS_NGINX_VERSION}"

kubectl apply -f \
  "https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/kind/deploy.yaml"

info "Waiting for the ingress controller to be ready..."
# The controller's admission webhook rejects Ingress objects while it is
# down, so the application syncs depend on this.
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s
success "ingress-nginx ready"

# ---------------------------------------------------------------------------
# Step 4: metrics-server (HPAs have no CPU/memory metrics without it)
# ---------------------------------------------------------------------------
step "Installing metrics-server ${METRICS_SERVER_CHART_VERSION}"

# Kind's kubelets serve self-signed certificates, hence --kubelet-insecure-tls.
helm_upgrade metrics-server kube-system metrics-server "${METRICS_SERVER_REPO}" \
  metrics-server "${METRICS_SERVER_CHART_VERSION}" \
  --set 'args={--kubelet-insecure-tls}' \
  --wait --timeout 180s
success "metrics-server installed"

# ---------------------------------------------------------------------------
# Step 5: Sealed Secrets controller
# ---------------------------------------------------------------------------
step "Installing Sealed Secrets controller (chart ${SEALED_SECRETS_CHART_VERSION})"

helm_upgrade sealed-secrets kube-system sealed-secrets "${SEALED_SECRETS_REPO}" \
  sealed-secrets "${SEALED_SECRETS_CHART_VERSION}" \
  --values "${REPO_ROOT}/security/sealed-secrets/controller-values.yaml" \
  --wait --timeout 180s
success "Sealed Secrets controller installed (kube-system/sealed-secrets-controller)"

# ---------------------------------------------------------------------------
# Step 6: OPA Gatekeeper
# ---------------------------------------------------------------------------
step "Installing OPA Gatekeeper ${GATEKEEPER_CHART_VERSION}"

helm_upgrade gatekeeper gatekeeper-system gatekeeper "${GATEKEEPER_REPO}" \
  gatekeeper "${GATEKEEPER_CHART_VERSION}" \
  --wait --timeout 300s

# Templates first. Gatekeeper turns each ConstraintTemplate into a new CRD
# (e.g. K8sBlockLatestImage); a Constraint of that kind can only be created
# once the CRD exists, so applying both together fails on a fresh cluster.
info "Applying ConstraintTemplates..."
retry 5 5 kubectl apply -f "${REPO_ROOT}/security/opa-gatekeeper/templates/"

info "Waiting for Gatekeeper to create the constraint CRDs..."
kubectl wait constrainttemplates --all \
  --for=jsonpath='{.status.created}'=true --timeout=120s

info "Applying Constraints..."
retry 5 5 kubectl apply -f "${REPO_ROOT}/security/opa-gatekeeper/constraints/"
success "OPA Gatekeeper policies active"

# ---------------------------------------------------------------------------
# Step 7: Observability (Prometheus, Grafana, Loki, Alloy)
# ---------------------------------------------------------------------------
bash "${REPO_ROOT}/scripts/install-observability.sh"

# ---------------------------------------------------------------------------
# Step 8: Argo CD + AppProject + Applications
# ---------------------------------------------------------------------------
bash "${REPO_ROOT}/scripts/install-argocd.sh"

# ---------------------------------------------------------------------------
# Step 9: Summary
# ---------------------------------------------------------------------------
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null \
  || echo "run: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d")

echo ""
echo -e "${BOLD}${GREEN}============================================================${NC}"
echo -e "${BOLD}${GREEN}  Setup complete! GitOps demo cluster is ready.${NC}"
echo -e "${BOLD}${GREEN}============================================================${NC}"
echo ""
echo -e "${BOLD}URLs:${NC}"
echo "  Argo CD UI:     http://localhost:30080"
echo "  Grafana UI:     http://localhost:30300   (Prometheus + Loki datasources)"
echo "  App (dev):      http://dev.gitops.local      API: http://api.dev.gitops.local/docs"
echo ""
echo -e "${BOLD}One-time: map the Ingress hosts to localhost${NC} (needs sudo):"
echo "  echo '127.0.0.1 dev.gitops.local api.dev.gitops.local staging.gitops.local api.staging.gitops.local prod.gitops.local api.prod.gitops.local' | sudo tee -a /etc/hosts"
echo "  (or skip it and use: make port-forward)"
echo ""
echo -e "${BOLD}Credentials:${NC}"
echo "  Argo CD: admin / ${ARGOCD_PASS}"
echo "  Grafana: admin / gitops-demo-admin"
echo ""
echo -e "${BOLD}Next steps:${NC}"
echo "  1. Watch Argo CD sync dev:       kubectl get applications -n argocd -w"
echo "  2. Run the demo:                 make demo"
echo "  3. Promote dev → staging:        GitHub → Actions → Promote Environment"
echo "     then sync it:                 argocd app sync gitops-demo-staging (or the UI)"
echo ""
echo -e "${BOLD}Useful commands:${NC}"
echo "  make status      # Argo CD sync status"
echo "  make pods        # pods in every environment"
echo "  make logs        # tail backend logs"
echo ""
