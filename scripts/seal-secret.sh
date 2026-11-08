#!/usr/bin/env bash
# scripts/seal-secret.sh — Create a SealedSecret for an environment and
# register it with that environment's overlay.
#
# Usage:
#   scripts/seal-secret.sh <env> <secret-name> <key>=<value>|<key>=@<file> [...]
#   make seal-secret ENV=dev NAME=app-secrets DATA="api-key=@./api-key.txt"
#
#   <env>  dev | staging | prod  (namespace gitops-<env>)
#   key=@file reads the value from a file, which keeps it out of your shell
#   history and the process list. Prefer it for real secrets.
#
# What it does:
#   1. builds the Secret client-side (kubectl create secret --dry-run=client),
#   2. encrypts it with kubeseal against the in-cluster controller
#      (kube-system/sealed-secrets-controller); the plaintext never touches
#      disk or Git,
#   3. writes k8s/overlays/<env>/<secret-name>.sealedsecret.yaml,
#   4. adds that file to the overlay's kustomization resources.
# Then commit and push; Argo CD applies it and the controller decrypts it.
#
# The ciphertext only decrypts in the cluster that sealed it (each fresh Kind
# cluster has a new key), so re-run this after recreating the cluster.

set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  echo "Usage: $0 <dev|staging|prod> <secret-name> <key>=<value>|<key>=@<file> [...]" >&2
  exit 1
}

[[ $# -ge 3 ]] || usage
ENV_NAME="$1"
SECRET_NAME="$2"
shift 2

case "${ENV_NAME}" in
  dev|staging|prod) ;;
  *) error "environment must be dev, staging or prod (got '${ENV_NAME}')" ;;
esac
[[ "${SECRET_NAME}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
  || error "secret name must be a lowercase DNS label (got '${SECRET_NAME}')"

command -v kubeseal &>/dev/null \
  || error "kubeseal not found. Install: https://github.com/bitnami-labs/sealed-secrets#kubeseal"
command -v kustomize &>/dev/null || error "kustomize not found"

NAMESPACE="gitops-${ENV_NAME}"
OVERLAY="${REPO_ROOT}/k8s/overlays/${ENV_NAME}"
OUT_FILE="${SECRET_NAME}.sealedsecret.yaml"

DATA_ARGS=()
for kv in "$@"; do
  [[ "${kv}" == *=* ]] || error "expected key=value or key=@file, got '${kv}'"
  key="${kv%%=*}"
  value="${kv#*=}"
  if [[ "${value}" == @* ]]; then
    [[ -f "${value#@}" ]] || error "file not found: ${value#@}"
    DATA_ARGS+=("--from-file=${key}=${value#@}")
  else
    DATA_ARGS+=("--from-literal=${key}=${value}")
  fi
done

info "Sealing secret '${SECRET_NAME}' for namespace '${NAMESPACE}'..."
kubectl create secret generic "${SECRET_NAME}" \
  --namespace "${NAMESPACE}" \
  "${DATA_ARGS[@]}" \
  --dry-run=client -o yaml \
| kubeseal \
    --controller-namespace kube-system \
    --controller-name sealed-secrets-controller \
    --format yaml \
  > "${OVERLAY}/${OUT_FILE}.tmp"
mv "${OVERLAY}/${OUT_FILE}.tmp" "${OVERLAY}/${OUT_FILE}"
success "Wrote k8s/overlays/${ENV_NAME}/${OUT_FILE}"

(cd "${OVERLAY}" && kustomize edit add resource "${OUT_FILE}")
success "Registered it in k8s/overlays/${ENV_NAME}/kustomization.yaml"

echo ""
echo "Next:"
echo "  git add k8s/overlays/${ENV_NAME}/ && git commit -m 'chore(secrets): seal ${SECRET_NAME} for ${ENV_NAME}' && git push"
if [[ "${ENV_NAME}" != dev ]]; then
  echo "  argocd app sync gitops-demo-${ENV_NAME}   # ${ENV_NAME} doesn't auto-sync"
fi
echo "  Reference it from a Deployment via env.valueFrom.secretKeyRef (name: ${SECRET_NAME})."
