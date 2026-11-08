#!/usr/bin/env bash
# scripts/ci/validate-manifests.sh — Render every overlay and check the
# invariants whose violation previously broke deployments without any error:
#
#   1. kustomize build succeeds with no warnings (e.g. deprecated fields).
#   2. Every rendered image reference is lowercase (OCI requires it; kubelet
#      fails with InvalidImageName otherwise).
#   3. Every images[] entry in an overlay names an image that exists in
#      k8s/base. Kustomize silently ignores entries that match nothing, and
#      the base placeholder tag ships instead.
#   4. dev deploys an immutable tag, not the `latest` placeholder.
#   5. git_sha / frontend_version in each overlay's env-config patch equal
#      the deployed backend / frontend tags, so /healthz tells the truth.
#   6. Ingress hosts are unique across environments (ingress-nginx's
#      admission webhook rejects duplicate host+path).
#   7. No nginx rewrite-target annotation (without capture groups it rewrites
#      every request path to the target).
#
# Used by CI's manifests job and `make validate-manifests`.

set -euo pipefail

main() {
  local root
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  cd "${root}"

  local failed=0 tmp
  tmp="$(mktemp -d)"
  # Expanded now: ${tmp} is local to main() and gone by the time EXIT fires.
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" EXIT

  err() {
    # ::error:: renders as an annotation in GitHub Actions; plain text locally.
    echo "::error::$*"
    failed=1
  }

  local base_images
  base_images=$(grep -hE '^[[:space:]]+image:' k8s/base/*/deployment.yaml \
    | awk '{print $2}' | sed -E 's/[:@][^/]*$//' | sort -u)

  # "host env" pairs seen so far (plain string: portable to bash 3.2).
  local seen_hosts=""
  local owner
  local env overlay rendered ref repo name host be fe git_sha frontend_version

  for env in dev staging prod; do
    overlay="k8s/overlays/${env}"
    echo "=== ${env}"

    # 1. Builds cleanly, no warnings.
    if ! kustomize build "${overlay}" > "${tmp}/${env}.yaml" 2> "${tmp}/${env}.err"; then
      err "${env}: kustomize build failed"; cat "${tmp}/${env}.err"; continue
    fi
    if [[ -s "${tmp}/${env}.err" ]]; then
      err "${env}: kustomize build emitted warnings (treated as errors):"; cat "${tmp}/${env}.err"
    fi
    rendered="${tmp}/${env}.yaml"

    # 2. Lowercase image references.
    while read -r ref; do
      if [[ "${ref}" == *"@"* ]]; then repo="${ref%%@*}"; else repo="${ref%:*}"; fi
      if [[ "${repo}" != "$(printf '%s' "${repo}" | tr '[:upper:]' '[:lower:]')" ]]; then
        err "${env}: image '${ref}' is not lowercase (invalid OCI reference → InvalidImageName)"
      fi
    done < <(grep -E '^[[:space:]]+image:' "${rendered}" | awk '{print $2}')

    # 3. images[] entries must match a base image.
    while read -r name; do
      [[ -z "${name}" ]] && continue
      grep -qxF "${name}" <<< "${base_images}" \
        || err "${env}: images[] entry '${name}' matches no image in k8s/base (Kustomize ignores it)"
    done < <(awk '/^images:/{f=1; next} f && /^[^ -]/{f=0} f && /name:/{print $NF}' "${overlay}/kustomization.yaml")

    # 4./5. Tags and the version fields that report them.
    be=$(scripts/get-image-tag.sh "${overlay}" backend)
    fe=$(scripts/get-image-tag.sh "${overlay}" frontend)
    git_sha=$(awk '$1=="git_sha:"{gsub(/"/,"",$2); print $2}' "${overlay}/patches/env-config.yaml")
    frontend_version=$(awk '$1=="frontend_version:"{gsub(/"/,"",$2); print $2}' "${overlay}/patches/env-config.yaml")
    echo "    backend=${be} frontend=${fe} git_sha=${git_sha} frontend_version=${frontend_version}"

    if [[ "${env}" == dev && ( "${be}" == latest || "${fe}" == latest ) ]]; then
      err "dev: deploys the 'latest' placeholder; CI should have set an immutable SHA tag"
    fi
    if [[ "${be}" != latest && "${git_sha}" != "${be}" ]]; then
      err "${env}: git_sha '${git_sha}' does not match backend tag '${be}' (use scripts/set-image-tag.sh)"
    fi
    if [[ "${fe}" != latest && "${frontend_version}" != "${fe}" ]]; then
      err "${env}: frontend_version '${frontend_version}' does not match frontend tag '${fe}' (use scripts/set-image-tag.sh)"
    fi
    if [[ "${be}" == latest ]]; then
      echo "    note: ${env} still has the 'latest' placeholder; Gatekeeper rejects it until a SHA is promoted."
    fi

    # 6. Unique ingress hosts.
    while read -r host; do
      owner=$(awk -v h="${host}" '$1==h {print $2; exit}' <<< "${seen_hosts}")
      if [[ -n "${owner}" ]]; then
        err "${env}: ingress host '${host}' is also used by ${owner}"
      fi
      seen_hosts+="${host} ${env}"$'\n'
    done < <(grep -E '^[[:space:]]+- host:' "${rendered}" | awk '{print $3}')

    # 7. No path-clobbering rewrite.
    if grep -q 'nginx.ingress.kubernetes.io/rewrite-target' "${rendered}"; then
      err "${env}: rewrite-target annotation found; it rewrites every path to its target"
    fi
  done

  if [[ "${failed}" -ne 0 ]]; then
    echo "Manifest validation FAILED"
    return 1
  fi
  echo "Manifest validation passed"
}

main "$@"
