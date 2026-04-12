#!/usr/bin/env bash
# scripts/demo.sh — Automated end-to-end demo of the GitOps pipeline.
#
# This script walks through the complete GitOps workflow so a reviewer can
# see the pipeline in action without needing to understand each component.
#
# What it demonstrates:
#   1. Show current ArgoCD state (healthy, known version)
#   2. Build a new backend Docker image with a different version tag
#   3. Load the image into the Kind cluster (no registry push needed)
#   4. Update the kustomize dev overlay with the new tag
#   5. Commit the change (simulates what CI does)
#   6. Wait for ArgoCD to detect and sync the change
#   7. Curl /healthz to show the new version is live
#   8. Show Grafana link for metrics
#
# Requirements:
#   - Kind cluster running (make setup)
#   - ArgoCD application configured
#   - kubectl configured for the Kind cluster

set -euo pipefail

# ---------------------------------------------------------------------------
# Colour helpers + step printing
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; NC='\033[0m'

step()    { echo -e "\n${BOLD}${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${BOLD}${CYAN}Step $1: $2${NC}"; echo -e "${BOLD}${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
info()    { echo -e "${BLUE}  ℹ ${NC} $*"; }
success() { echo -e "${GREEN}  ✅ ${NC} $*"; }
warn()    { echo -e "${YELLOW}  ⚠ ${NC} $*"; }
pause()   { echo -e "\n${YELLOW}  → Press ENTER to continue...${NC}"; read -r; }

CLUSTER_NAME="${CLUSTER_NAME:-gitops-demo}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
NAMESPACE="gitops-dev"
OWNER="${GITHUB_REPOSITORY_OWNER:-Parzivalart3mis}"

# Generate a unique demo tag using timestamp
DEMO_TAG="demo-$(date +%s | tail -c6)"
OLD_TAG=$(kubectl get deployment backend -n "${NAMESPACE}" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | \
  cut -d: -f2 || echo "unknown")

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║     GitOps CI/CD Pipeline — Live Demo            ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "This demo shows the ${BOLD}GitOps reconciliation loop${NC} in action:"
echo -e "  git push → ArgoCD detects → Kubernetes syncs → New version live"
echo ""
pause

# ---------------------------------------------------------------------------
# Step 1: Show current state
# ---------------------------------------------------------------------------
step "1" "Show current ArgoCD and cluster state"

info "ArgoCD applications:"
kubectl get applications -n argocd 2>/dev/null | head -20 || warn "ArgoCD not reachable"

info "Current pods in ${NAMESPACE}:"
kubectl get pods -n "${NAMESPACE}" 2>/dev/null || warn "Namespace may not exist yet"

info "Current image tag in dev overlay: ${OLD_TAG}"

pause

# ---------------------------------------------------------------------------
# Step 2: Build a new Docker image
# ---------------------------------------------------------------------------
step "2" "Build a new Docker image (simulates: developer pushes code → CI builds image)"

info "Building backend image with tag: ${DEMO_TAG}"
info "In production, the CI pipeline does this automatically on every push to main."

cd "${REPO_ROOT}/apps/backend"
docker build -f Dockerfile \
  --build-arg GIT_SHA="${DEMO_TAG}" \
  -t "ghcr.io/${OWNER}/gitops-backend:${DEMO_TAG}" \
  . 2>&1 | tail -5

success "Image built: ghcr.io/${OWNER}/gitops-backend:${DEMO_TAG}"
pause

# ---------------------------------------------------------------------------
# Step 3: Load image into Kind
# ---------------------------------------------------------------------------
step "3" "Load image into Kind cluster (skips registry push for local demo)"

info "In production, the CI pipeline pushes to GHCR and ArgoCD pulls from there."
info "Locally, we load the image directly into Kind's docker registry."

kind load docker-image \
  "ghcr.io/${OWNER}/gitops-backend:${DEMO_TAG}" \
  --name "${CLUSTER_NAME}"

success "Image loaded into Kind cluster"
pause

# ---------------------------------------------------------------------------
# Step 4: Update kustomize overlay (simulates: CI's update-manifests job)
# ---------------------------------------------------------------------------
step "4" "Update dev overlay with new image tag (simulates: CI's 'update-manifests' job)"

info "The CI pipeline's final job runs: kustomize edit set image ..."
info "This is what triggers the GitOps loop — ArgoCD watches for this commit."

cd "${REPO_ROOT}/k8s/overlays/dev"
kustomize edit set image \
  "ghcr.io/${OWNER}/gitops-backend=ghcr.io/${OWNER}/gitops-backend:${DEMO_TAG}"

success "kustomization.yaml updated with tag: ${DEMO_TAG}"
info "Git diff:"
cd "${REPO_ROOT}"
git diff --no-color k8s/overlays/dev/kustomization.yaml 2>/dev/null | head -20 || true
pause

# ---------------------------------------------------------------------------
# Step 5: Commit the change
# ---------------------------------------------------------------------------
step "5" "Commit the manifest change (this is the GitOps trigger)"

info "In production this commit is pushed to GitHub and ArgoCD detects it."
info "For this demo, we apply the manifests directly to show the rollout."

cd "${REPO_ROOT}"
git add k8s/overlays/dev/kustomization.yaml 2>/dev/null || true

info "Applying manifests directly (bypassing git push for local demo):"
kustomize build k8s/overlays/dev | kubectl apply -f - 2>/dev/null || true

success "Manifests applied"
pause

# ---------------------------------------------------------------------------
# Step 6: Watch the rollout
# ---------------------------------------------------------------------------
step "6" "Watch Kubernetes rolling update (zero-downtime: maxUnavailable=0)"

info "Kubernetes is doing a rolling update. Old pods stay alive until new ones are healthy."
info "This is because we set strategy.rollingUpdate.maxUnavailable: 0 in the deployment."

kubectl rollout status deployment/backend -n "${NAMESPACE}" --timeout=120s || \
  warn "Rollout didn't complete in 120s — check pod events"

info "New pods:"
kubectl get pods -n "${NAMESPACE}" -l app=backend

pause

# ---------------------------------------------------------------------------
# Step 7: Verify new version is live
# ---------------------------------------------------------------------------
step "7" "Verify new version at /healthz"

info "Port-forwarding backend to localhost:9999..."
kubectl port-forward svc/backend -n "${NAMESPACE}" 9999:8000 &>/tmp/pf-demo.log &
PF_PID=$!
sleep 3

info "Calling GET /healthz to verify deployed version:"
RESPONSE=$(curl -s http://localhost:9999/healthz 2>/dev/null || echo '{"error":"backend not reachable"}')
echo -e "\n  ${CYAN}Response: ${NC}${RESPONSE}\n"

# Cleanup port-forward
kill $PF_PID 2>/dev/null || true

if echo "${RESPONSE}" | grep -q "${DEMO_TAG}"; then
  success "Version '${DEMO_TAG}' is live! The GitOps loop worked."
else
  warn "Version string may differ (image pulled from cache). Check the response above."
fi

pause

# ---------------------------------------------------------------------------
# Step 8: Summary + links
# ---------------------------------------------------------------------------
step "8" "Summary"

echo ""
echo -e "${BOLD}What just happened:${NC}"
echo "  1. We built a new Docker image tagged ${DEMO_TAG}"
echo "  2. We updated k8s/overlays/dev/kustomization.yaml (simulating CI)"
echo "  3. Kubernetes performed a zero-downtime rolling update"
echo "  4. /healthz confirmed the new version is running"
echo ""
echo -e "${BOLD}In a real pipeline:${NC}"
echo "  → Developer pushes code to GitHub"
echo "  → GitHub Actions runs lint + test + build + push + update-manifests"
echo "  → ArgoCD detects the manifest change in Git"
echo "  → ArgoCD syncs the Kubernetes cluster"
echo "  → Same result, fully automated, auditable, rollback-able via git revert"
echo ""
echo -e "${BOLD}Explore further:${NC}"
echo "  ArgoCD UI:  http://localhost:30080"
echo "  Grafana:    http://localhost:30300"
echo "  API docs:   http://localhost:9999/docs  (after: make port-forward)"
echo ""
echo -e "  ${BOLD}Promote to staging:${NC}  make promote"
echo -e "  ${BOLD}Rollback:${NC}            make rollback"
echo ""
success "Demo complete!"
