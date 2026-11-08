#!/usr/bin/env bash
# scripts/ci/push-overlay-change.sh — Commit an image-tag change to an
# overlay and push it, safely, from a GitHub Actions job.
#
# Used by ci.yml (dev), promote.yml and rollback.yml. Each attempt:
#   1. resets to the LATEST tip of $BRANCH (not the commit the workflow was
#      triggered on, which may be stale by now),
#   2. re-applies the change with scripts/set-image-tag.sh,
#   3. commits and pushes; if another workflow pushed in between, the push is
#      rejected and the loop starts over on the new tip.
# Re-applying rather than rebasing means two concurrent writers can never
# leave a conflicted or half-applied overlay behind.
#
# Usage: scripts/ci/push-overlay-change.sh <env> <tag> <all|backend|frontend>
#
# Env:
#   BRANCH          branch to push to (required)
#   COMMIT_MESSAGE  commit message (required). Passed through the
#                   environment so free-text workflow inputs never become
#                   shell syntax.
#   SOURCE_SHA      optional: the commit the tag was built from. If the
#                   overlay already runs a tag built from a NEWER commit
#                   (a descendant of SOURCE_SHA), nothing is pushed, so a
#                   slow CI run for an older commit can't roll dev back.
#                   Needs full history (actions/checkout fetch-depth: 0).

set -euo pipefail

die() { echo "push-overlay-change: ERROR: $*" >&2; exit 1; }

# All logic lives in main(): bash parses a function completely before running
# it, so the `git reset --hard` below can safely replace this file on disk.
main() {
  [[ $# -eq 3 ]] || die "usage: $0 <env> <tag> <all|backend|frontend>"
  local env="$1" tag="$2" which="$3"
  : "${BRANCH:?BRANCH must be set}"
  : "${COMMIT_MESSAGE:?COMMIT_MESSAGE must be set}"

  local overlay="k8s/overlays/${env}"
  [[ -d "${overlay}" ]] || die "unknown environment '${env}'"

  git config user.name  "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

  local attempt current current_commit
  for attempt in 1 2 3 4 5; do
    git fetch --quiet origin "${BRANCH}"
    git reset --quiet --hard "origin/${BRANCH}"

    if [[ -n "${SOURCE_SHA:-}" ]]; then
      current=$(scripts/get-image-tag.sh "${overlay}" backend)
      if current_commit=$(git rev-parse --quiet --verify "${current}^{commit}" 2>/dev/null) \
         && [[ "${current_commit}" != "$(git rev-parse "${SOURCE_SHA}")" ]] \
         && git merge-base --is-ancestor "${SOURCE_SHA}" "${current_commit}"; then
        echo "push-overlay-change: ${env} already runs ${current}, built from a newer commit than ${SOURCE_SHA:0:7}; nothing to do."
        return 0
      fi
    fi

    scripts/set-image-tag.sh "${overlay}" "${tag}" "${which}"
    git add -- "${overlay}"
    if git diff --cached --quiet; then
      echo "push-overlay-change: ${env} is already at ${tag}; nothing to commit."
      return 0
    fi

    git commit --quiet -m "${COMMIT_MESSAGE}"
    if git push --quiet origin "HEAD:refs/heads/${BRANCH}"; then
      echo "push-overlay-change: pushed $(git rev-parse --short HEAD) to ${BRANCH} (${env} → ${tag})."
      return 0
    fi

    echo "push-overlay-change: push rejected (attempt ${attempt}/5): ${BRANCH} moved; retrying on the new tip." >&2
    sleep $(( attempt * 5 ))
  done

  die "could not push after 5 attempts. If ${BRANCH} is a protected branch, the workflow token must be allowed to bypass protection (see docs/TROUBLESHOOTING.md)."
}

main "$@"
