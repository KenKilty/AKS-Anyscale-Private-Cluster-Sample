#!/usr/bin/env bash
# Module 4 — Custom images for a private data plane.
#
# Purpose: thin wrapper mapping the learning-module commands onto the shared
#          custom-image implementation in setup.sh / anyscale-aks.sh. No build,
#          push, or signing logic lives here; each subcommand delegates to the
#          same path that `module 3 custom-image` and `e2e --custom-image` use.
# Usage:   ./scripts/anyscale-aks.sh module 4 {prove-failure|preflight|prepare|
#          sign|verify|sbom|sbom-proof|apply|proof}
#          Runs on the Linux jump host, where private ACR and Key Vault resolve.
# Inputs:  the synced .env including the ANYSCALE_CUSTOM_IMAGE_* values; Podman,
#          Notation, Syft, and ORAS from the Module 2 bootstrap.
# Outputs: CUSTOM_IMAGE_* proof markers on stdout; the built image, signature,
#          and SBOM in the private ACR; non-zero exit when a step fails.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DISPATCHER="${SCRIPTS_DIR}/anyscale-aks.sh"

LOG_INFO_PREFIX="module4"
LOG_WARN_PREFIX="module4"
LOG_ERROR_PREFIX="module4"
# shellcheck source=../lib/log.sh
source "${SCRIPTS_DIR}/lib/log.sh"

dispatch() {
  ANYSCALE_VIA_MODULE=1 "${DISPATCHER}" "$@"
}

usage() {
  cat <<'USAGE'
Module 4 — Custom images for a private data plane.

Usage:
  ./scripts/anyscale-aks.sh module 4 prove-failure
  ./scripts/anyscale-aks.sh module 4 preflight
  ./scripts/anyscale-aks.sh module 4 prepare
  ./scripts/anyscale-aks.sh module 4 sign
  ./scripts/anyscale-aks.sh module 4 verify
  ./scripts/anyscale-aks.sh module 4 sbom
  ./scripts/anyscale-aks.sh module 4 sbom-proof
  ./scripts/anyscale-aks.sh module 4 apply
  ./scripts/anyscale-aks.sh module 4 proof
USAGE
}

main() {
  local action="${1:-}"
  shift || true
  case "${action}" in
    prove-failure | preflight | prepare | sign | verify | sbom | sbom-proof | apply | proof)
      dispatch custom-image "${action}" "$@"
      ;;
    "" | --help | -h) usage ;;
    *) die "Unknown 'module 4' subcommand: ${action}. Run 'module 4 --help'." ;;
  esac
}

main "$@"
