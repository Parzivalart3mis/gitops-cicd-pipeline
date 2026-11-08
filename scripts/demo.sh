#!/usr/bin/env bash
# scripts/demo.sh — Interactive end-to-end demo of the GitOps loop, run locally.
#
# Shows, on the local Kind cluster:
#   1. Current state (Argo CD apps, pods, deployed tag)
#   2. Building a new backend image          (what CI's build job does)
#   3. Side-loading it into Kind              (stands in for the GHCR push)
#   4. Bumping the tag with set-image-tag.sh  (what CI's update-manifests job does)
#   5. Applying it and watching a zero-downtime rolling update
#   6. Verifying the new version at /healthz
#   7. Argo CD self-healing the cluster back to what Git declares
#
# The demo never modifies your working tree: the overlay is edited in a temp
# copy. Because the change isn't pushed to Git, Argo CD would immediately
# revert it (dev has selfHeal), so the demo pauses dev's auto-sync while the
# new version runs, then re-enables it in step 7 (and on any exit).
#
# Usage: make demo   (cluster from `make setup` must be running)

set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NAMESPACE="gitops-dev"
APP="gitops-demo-dev"
DEMO_TAG="demo-$(date +%s)"
IMAGE="${REGISTRY}/gitops-backend:${DEMO_TAG}"
WORKDIR="$(mktemp -d)"
PF_PID=""
AUTOSYNC_PAUSED=false

section() {
  echo -e "\n${BOLD}${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}${CYAN}Step $1: $2${NC}"
  echo -e "${BOLD}${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}
pause() { echo -e "\n${YELLOW}  → Press ENTER to continue...${NC}"; read -r; }

have_argocd_app() { kubectl get application "${APP}" -n argocd &>/dev/null; }

pause_autosync() {
  have_argocd_app || return 0
  kubectl patch application "${APP}" -n argocd --type merge \
    -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null
  AUTOSYNC_PAUSED=true
}

resume_autosync() {
  [[ "${AUTOSYNC_PAUSED}" == true ]] || return 0
  kubectl patch application "${APP}" -n argocd --type merge \
    -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true,"allowEmpty":false}}}}' >/dev/null
  AUTOSYNC_PAUSED=false
}

cleanup() {
  [[ -n "${PF_PID}" ]] && kill "${PF_PID}" 2>/dev/null || true
  if [[ "${AUTOSYNC_PAUSED}" == true ]]; then
    warn "Re-enabling Argo CD auto-sync for ${APP} (Git state will be restored)"
    resume_autosync || warn "Could not re-enable auto-sync; run: kubectl apply -f argocd/applications/dev.yaml"
  fi
  rm -rf "${WORKDIR}"
}
trap cleanup EXIT

for cmd in docker kind kubectl kustomize curl; do
  command -v "${cmd}" &>/dev/null || error "${cmd} is required for the demo"
done
kubectl get namespace "${NAMESPACE}" &>/dev/null \
  || error "Namespace ${NAMESPACE} not found. Run 'make setup' and wait for Argo CD to sync dev."

echo -e "${BOLD}${CYAN}GitOps CI/CD Pipeline — Live Demo${NC}"
echo "Demo image tag: ${DEMO_TAG}"
pause

# ---------------------------------------------------------------------------
section 1 "Current Argo CD and cluster state"
# ---------------------------------------------------------------------------
info "Argo CD applications:"
kubectl get applications -n argocd 2>/dev/null || warn "Argo CD not reachable"
info "Pods in ${NAMESPACE}:"
kubectl get pods -n "${NAMESPACE}"
OLD_IMAGE=$(kubectl get deployment backend -n "${NAMESPACE}" \
  -o jsonpath='{.spec.template.spec.containers[0].image}')
info "Backend image currently deployed: ${OLD_IMAGE}"
pause

# ---------------------------------------------------------------------------
section 2 "Build a new backend image (CI: build-and-push)"
# ---------------------------------------------------------------------------
info "docker build → ${IMAGE}"
docker build -f "${REPO_ROOT}/apps/backend/Dockerfile" \
  --build-arg GIT_SHA="${DEMO_TAG}" \
  -t "${IMAGE}" \
  "${REPO_ROOT}/apps/backend" 2>&1 | tail -5
success "Image built"
pause

# ---------------------------------------------------------------------------
section 3 "Load the image into Kind (stands in for pushing to GHCR)"
# ---------------------------------------------------------------------------
info "Deployments use imagePullPolicy: IfNotPresent (tags are immutable),"
info "so the kubelet uses this side-loaded image instead of pulling from GHCR."
kind load docker-image "${IMAGE}" --name "${CLUSTER_NAME}"
success "Image loaded into every Kind node"
pause

# ---------------------------------------------------------------------------
section 4 "Bump the dev overlay (CI: update-manifests)"
# ---------------------------------------------------------------------------
cp -R "${REPO_ROOT}/k8s" "${WORKDIR}/k8s"
info "CI runs scripts/set-image-tag.sh, which updates the image tag AND the"
info "git_sha that /healthz reports, in one commit. Here, on a temp copy:"
"${REPO_ROOT}/scripts/set-image-tag.sh" "${WORKDIR}/k8s/overlays/dev" "${DEMO_TAG}" backend
echo ""
diff -u "${REPO_ROOT}/k8s/overlays/dev/kustomization.yaml" "${WORKDIR}/k8s/overlays/dev/kustomization.yaml" || true
diff -u "${REPO_ROOT}/k8s/overlays/dev/patches/env-config.yaml" "${WORKDIR}/k8s/overlays/dev/patches/env-config.yaml" || true
info "In the real pipeline this diff is committed and pushed; Argo CD picks it up."
pause

# ---------------------------------------------------------------------------
section 5 "Apply and watch the rolling update (maxUnavailable: 0)"
# ---------------------------------------------------------------------------
if have_argocd_app; then
  info "Pausing Argo CD auto-sync for dev: this change isn't in Git, so"
  info "self-heal would revert it within seconds. (Restored in step 7.)"
  pause_autosync
fi
kustomize build "${WORKDIR}/k8s/overlays/dev" | kubectl apply -f - >/dev/null
info "Old pods keep serving until the new pod passes its readiness probe..."
kubectl rollout status deployment/backend -n "${NAMESPACE}" --timeout=180s
kubectl get pods -n "${NAMESPACE}" -l app=backend
pause

# ---------------------------------------------------------------------------
section 6 "Verify the new version at /healthz"
# ---------------------------------------------------------------------------
kubectl port-forward svc/backend -n "${NAMESPACE}" 9999:8000 >/dev/null 2>&1 &
PF_PID=$!
sleep 3
RESPONSE=$(curl -s http://localhost:9999/healthz || echo '{"error":"backend not reachable"}')
kill "${PF_PID}" 2>/dev/null || true
PF_PID=""
echo "  GET /healthz → ${RESPONSE}"
if grep -q "\"${DEMO_TAG}\"" <<< "${RESPONSE}"; then
  success "Version ${DEMO_TAG} is live."
else
  warn "Expected version ${DEMO_TAG} — check: kubectl describe deployment/backend -n ${NAMESPACE}"
fi
pause

# ---------------------------------------------------------------------------
section 7 "Drift correction: Argo CD restores what Git declares"
# ---------------------------------------------------------------------------
if have_argocd_app; then
  info "The cluster now differs from Git (drift). Re-enabling auto-sync:"
  resume_autosync
  info "Argo CD detects the drift and rolls back to ${OLD_IMAGE}..."
  for _ in $(seq 1 60); do
    current=$(kubectl get deployment backend -n "${NAMESPACE}" \
      -o jsonpath='{.spec.template.spec.containers[0].image}')
    [[ "${current}" == "${OLD_IMAGE}" ]] && break
    sleep 3
  done
  kubectl rollout status deployment/backend -n "${NAMESPACE}" --timeout=180s
  success "Back on ${OLD_IMAGE} — Git is the source of truth."
else
  warn "No Argo CD application found; restore Git state with: kustomize build k8s/overlays/dev | kubectl apply -f -"
fi

# ---------------------------------------------------------------------------
section 8 "Summary"
# ---------------------------------------------------------------------------
success "Demo complete!"
echo ""
echo "  You saw: build → load → set-image-tag (tag + git_sha) → rolling update"
echo "           → verified /healthz → Argo CD reverted the un-committed drift."
echo ""
echo "  The real loop: push to master → CI builds & pushes to GHCR → CI commits"
echo "  the new tag to k8s/overlays/dev → Argo CD syncs dev automatically."
