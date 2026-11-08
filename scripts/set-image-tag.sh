#!/usr/bin/env bash
# scripts/set-image-tag.sh — Point an overlay at a new image tag.
#
# This is THE deployment primitive of the GitOps loop. CI (dev), promote.yml,
# rollback.yml, the Makefile and demo.sh all call it, so every path that
# changes what runs in an environment edits the same fields the same way:
#
#   1. kustomization.yaml images[].newTag     (via `kustomize edit set image`)
#   2. patches/env-config.yaml git_sha         (when the backend changes)
#   3. patches/env-config.yaml frontend_version (when the frontend changes)
#
# so /healthz and the UI always report the tag that is actually deployed.
#
# Usage: scripts/set-image-tag.sh <overlay-dir> <tag> [all|backend|frontend]
#
# Env: REGISTRY (default ghcr.io/parzivalart3mis). Must be lowercase: OCI
# repository paths are lowercase-only, and the images[] names in the
# overlays must match the lowercase names in k8s/base exactly.

set -euo pipefail

# Portable to macOS's bash 3.2 and BSD sed: no ${var,,}, no `sed -i`.

die() { echo "set-image-tag: ERROR: $*" >&2; exit 1; }

main() {
  [[ $# -ge 2 && $# -le 3 ]] || die "usage: $0 <overlay-dir> <tag> [all|backend|frontend]"

  local overlay="$1" tag="$2" which="${3:-all}"
  local registry="${REGISTRY:-ghcr.io/parzivalart3mis}"
  local kustomization="${overlay}/kustomization.yaml"
  local env_patch="${overlay}/patches/env-config.yaml"

  [[ -f "${kustomization}" ]] || die "no kustomization.yaml in '${overlay}'"
  [[ -f "${env_patch}" ]]     || die "no patches/env-config.yaml in '${overlay}'"
  [[ "${registry}" == "$(printf '%s' "${registry}" | tr '[:upper:]' '[:lower:]')" ]] || die "REGISTRY must be lowercase (got '${registry}')"
  # Docker tag grammar; also guarantees the tag is safe inside the sed below.
  [[ "${tag}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || die "invalid image tag '${tag}'"

  local apps
  case "${which}" in
    all)      apps=(backend frontend) ;;
    backend)  apps=(backend) ;;
    frontend) apps=(frontend) ;;
    *) die "third argument must be all, backend or frontend (got '${which}')" ;;
  esac

  local app image
  for app in "${apps[@]}"; do
    image="${registry}/gitops-${app}"
    # Refuse to add a brand-new images[] entry: an entry whose name doesn't
    # match the base image is silently ignored by Kustomize.
    grep -Eq "^[[:space:]-]*name: ${image}[[:space:]]*$" "${kustomization}" \
      || die "${kustomization} has no images[] entry named ${image}"
    (cd "${overlay}" && kustomize edit set image "${image}:${tag}")
    echo "set-image-tag: ${overlay}: ${image} → ${tag}"
  done

  update_key() {
    local key="$1"
    grep -Eq "^[[:space:]]+${key}:" "${env_patch}" || die "${env_patch} has no '${key}' key"
    sed -E "s/^([[:space:]]+${key}:).*/\1 \"${tag}\"/" "${env_patch}" > "${env_patch}.tmp"
    mv "${env_patch}.tmp" "${env_patch}"
  }
  [[ " ${apps[*]} " == *" backend "* ]]  && update_key git_sha
  [[ " ${apps[*]} " == *" frontend "* ]] && update_key frontend_version
  return 0
}

main "$@"
