#!/usr/bin/env bash
# scripts/seal-secret.sh — Helper to seal a Kubernetes Secret into a SealedSecret.
#
# Usage:
#   ./scripts/seal-secret.sh <namespace> <secret-name> <key>=<value> [<key>=<value> ...]
#
# Example:
#   ./scripts/seal-secret.sh gitops-dev app-secrets api-key=my-secret-key
#
# Prerequisites:
#   - kubeseal CLI: https://github.com/bitnami-labs/sealed-secrets#installation
#   - Sealed Secrets controller running (installed by setup-cluster.sh)
#
# Output:
#   Prints the SealedSecret YAML to stdout.
#   Redirect to a file: ./scripts/seal-secret.sh ... > k8s/overlays/dev/sealed-secret.yaml

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
success() { echo -e "${GREEN}[OK]${NC}   $*" >&2; }

[[ $# -lt 3 ]] && error "Usage: $0 <namespace> <secret-name> <key>=<value> [...]"

NAMESPACE="$1"
SECRET_NAME="$2"
shift 2

command -v kubeseal &>/dev/null || \
  error "kubeseal not found. Install: https://github.com/bitnami-labs/sealed-secrets#kubeseal"

# Build --from-literal args
LITERAL_ARGS=()
for kv in "$@"; do
  LITERAL_ARGS+=("--from-literal=${kv}")
done

success "Creating SealedSecret '${SECRET_NAME}' in namespace '${NAMESPACE}'"

# Create plain secret, pipe through kubeseal to encrypt
kubectl create secret generic "${SECRET_NAME}" \
  --namespace "${NAMESPACE}" \
  "${LITERAL_ARGS[@]}" \
  --dry-run=client -o yaml | \
kubeseal \
  --controller-namespace kube-system \
  --controller-name sealed-secrets \
  --format yaml

echo "" >&2
success "Paste the above YAML into k8s/overlays/${NAMESPACE}/sealed-secret.yaml"
success "Then commit the file — the controller will decrypt it automatically."
