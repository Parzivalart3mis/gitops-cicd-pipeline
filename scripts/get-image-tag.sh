#!/usr/bin/env bash
# scripts/get-image-tag.sh — Print the image tag an overlay actually deploys.
#
# Reads the RENDERED manifests (kustomize build), not kustomization.yaml, so
# it reports what Kubernetes would really run, including the case where an
# images[] entry doesn't match and the base placeholder tag ships instead.
#
# Usage: scripts/get-image-tag.sh <overlay-dir> [backend|frontend]   (default backend)

set -euo pipefail

die() { echo "get-image-tag: ERROR: $*" >&2; exit 1; }

main() {
  [[ $# -ge 1 && $# -le 2 ]] || die "usage: $0 <overlay-dir> [backend|frontend]"
  local overlay="$1" app="${2:-backend}"
  [[ "${app}" == backend || "${app}" == frontend ]] || die "app must be backend or frontend"

  local ref
  ref=$(kustomize build "${overlay}" \
    | grep -E "^[[:space:]]+image:[[:space:]].*/gitops-${app}[:@]" \
    | head -n1 | awk '{print $2}') || true
  [[ -n "${ref}" ]] || die "no gitops-${app} image found in ${overlay}"
  [[ "${ref}" == *:* ]] || die "image '${ref}' has no tag"
  echo "${ref##*:}"
}

main "$@"
