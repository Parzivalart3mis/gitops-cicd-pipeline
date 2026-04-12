#!/usr/bin/env bash
# scripts/teardown-cluster.sh — Clean teardown of the local Kind cluster.
#
# Deletes the Kind cluster and all associated Docker resources.
# Safe to run multiple times.

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-gitops-demo}"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

echo "This will DELETE the Kind cluster '${CLUSTER_NAME}' and all its data."
read -r -p "Are you sure? (yes/no): " confirm
[[ "$confirm" == "yes" ]] || { echo "Aborted."; exit 0; }

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  kind delete cluster --name "${CLUSTER_NAME}"
  success "Cluster '${CLUSTER_NAME}' deleted"
else
  warn "Cluster '${CLUSTER_NAME}' not found — nothing to delete"
fi

# Remove local Docker images built for this demo (optional)
read -r -p "Also remove local gitops-* Docker images? (yes/no): " rm_images
if [[ "$rm_images" == "yes" ]]; then
  docker images --format "{{.Repository}}:{{.Tag}}" | grep "gitops-" | \
    xargs -r docker rmi || warn "No local gitops-* images found"
  success "Local images removed"
fi

echo ""
success "Teardown complete. Run ./scripts/setup-cluster.sh to start fresh."
