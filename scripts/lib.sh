#!/usr/bin/env bash
# scripts/lib.sh — Shared helpers for the cluster scripts. Source it:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# Provides REPO_ROOT, the pinned versions from versions.env, logging helpers,
# and helm_upgrade.

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${LIB_DIR}/.." && pwd)"
export REPO_ROOT

# shellcheck source=scripts/versions.env
source "${LIB_DIR}/versions.env"

# Lowercase registry path: OCI repository names must be lowercase, and it has
# to match the image names in k8s/base exactly.
REGISTRY="${REGISTRY:-ghcr.io/parzivalart3mis}"
CLUSTER_NAME="${CLUSTER_NAME:-gitops-demo}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'
# shellcheck disable=SC2034  # used by demo.sh, which sources this file
MAGENTA='\033[0;35m'
BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}${CYAN}▶ $*${NC}"; }

# helm_upgrade <release> <namespace> <repo-name> <repo-url> <chart> <version> [helm args...]
#
# Installs or upgrades a pinned chart. Charts are referenced as
# <repo-name>/<chart> (never a bare chart name, which Helm resolves as a
# local directory first), and `repo add --force-update` repairs a repo alias
# that still points at an old URL (e.g. sealed-secrets' bitnami-labs URL,
# which now 404s).
helm_upgrade() {
  local release="$1" namespace="$2" repo_name="$3" repo_url="$4" chart="$5" version="$6"
  shift 6
  helm repo add "${repo_name}" "${repo_url}" --force-update >/dev/null
  helm upgrade --install "${release}" "${repo_name}/${chart}" \
    --version "${version}" \
    --namespace "${namespace}" --create-namespace \
    "$@"
}

# retry <attempts> <delay-seconds> <command...>
retry() {
  local attempts="$1" delay="$2" n=1
  shift 2
  until "$@"; do
    if (( n >= attempts )); then return 1; fi
    warn "Attempt ${n}/${attempts} failed; retrying in ${delay}s: $*"
    sleep "${delay}"
    n=$(( n + 1 ))
  done
}
