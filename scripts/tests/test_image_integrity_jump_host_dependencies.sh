#!/usr/bin/env bash
# Offline regression check for image-integrity jump-host dependencies.
#
# Purpose: prove apply-ratify omits Terraform only in jump-host mode, where
#          setup.sh resolves required values through Azure and naming fallbacks.
# Usage:   ./scripts/tests/test_image_integrity_jump_host_dependencies.sh
#          No cloud access or credentials required.
# Inputs:  the real scripts/anyscale-aks.sh source.
# Outputs: a pass line on stdout; non-zero exit on the first failed assertion.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DISPATCHER="${ROOT_DIR}/scripts/anyscale-aks.sh"

dependency_block="$(awk '
  /^    image-integrity\)/ { capture = 1 }
  capture { print }
  capture && /^      ;;$/ { exit }
' "${DISPATCHER}")"

if [[ -z "${dependency_block}" ]]; then
  printf 'could not locate the image-integrity dependency block\n' >&2
  exit 1
fi

grep -q 'ANYSCALE_EXECUTION_MODE:-workstation.*jump-host' <<<"${dependency_block}" || {
  printf 'image-integrity dependencies do not distinguish jump-host mode\n' >&2
  exit 1
}
grep -q '"\${context} \${1:-}" az kubectl kubelogin jq envsubst' <<<"${dependency_block}" || {
  printf 'jump-host apply-ratify dependencies are incorrect\n' >&2
  exit 1
}
grep -q '"\${context} \${1:-}" az terraform kubectl kubelogin jq envsubst' <<<"${dependency_block}" || {
  printf 'workstation apply-ratify no longer requires Terraform\n' >&2
  exit 1
}

printf 'image-integrity apply-ratify dependencies honor jump-host mode ok\n'
