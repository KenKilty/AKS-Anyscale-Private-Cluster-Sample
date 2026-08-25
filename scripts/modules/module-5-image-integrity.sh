#!/usr/bin/env bash
# Module 5 — AKS Image Integrity (signature verification).
#
# Purpose: thin wrapper mapping the learning-module commands onto the
#          image-integrity implementation in setup.sh / anyscale-aks.sh. No
#          verification logic lives here.
#          Image Integrity is audit-only by design: unsigned images are flagged
#          non-compliant in Azure Policy but are not blocked from running.
# Usage:   ./scripts/anyscale-aks.sh module 5 {preflight|apply-ratify}
#          Runs on the Linux jump host.
# Inputs:  the synced .env; TF_VAR_enable_image_integrity=true applied by
#          Terraform; the aks-preview Azure CLI extension.
# Outputs: IMAGE_INTEGRITY_PREFLIGHT_OK and IMAGE_INTEGRITY_RATIFY_OK markers on
#          stdout; applied Ratify resources in the cluster; non-zero exit on
#          failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DISPATCHER="${SCRIPTS_DIR}/anyscale-aks.sh"

LOG_INFO_PREFIX="module5"
LOG_WARN_PREFIX="module5"
LOG_ERROR_PREFIX="module5"
# shellcheck source=../lib/log.sh
source "${SCRIPTS_DIR}/lib/log.sh"

dispatch() {
  ANYSCALE_VIA_MODULE=1 "${DISPATCHER}" "$@"
}

usage() {
  cat <<'USAGE'
Module 5 — AKS Image Integrity (signature verification).

Usage:
  ./scripts/anyscale-aks.sh module 5 preflight
  ./scripts/anyscale-aks.sh module 5 apply-ratify

preflight     Check the EnableImageIntegrityPreview feature flag and aks-preview extension.
apply-ratify  Apply the Ratify verification CRDs that point at the signing Key Vault and ACR.

Image Integrity is audit-only: unsigned images are flagged non-compliant in
Azure Policy but are not blocked from running.
USAGE
}

main() {
  local action="${1:-}"
  shift || true
  case "${action}" in
    preflight | apply-ratify)
      dispatch image-integrity "${action}" "$@"
      ;;
    "" | --help | -h) usage ;;
    *) die "Unknown 'module 5' subcommand: ${action}. Run 'module 5 --help'." ;;
  esac
}

main "$@"
