#!/usr/bin/env bash
# Trivy scan of the staged working tree, run as a pre-commit hook.
#
# Purpose: block HIGH/CRITICAL config findings and any secret from entering a
#          commit. Pre-commit stashes unstaged changes, so the tree this hook
#          sees matches the proposed commit; manual --all-files runs inspect
#          current files instead of stale index entries.
# Usage:   ./scripts/trivy-staged-scan.sh [paths...] (invoked by pre-commit).
# Inputs:  staged paths from pre-commit; trivy on PATH.
# Outputs: trivy findings on stdout; exit 1 on a finding, 0 when clean or when
#          nothing relevant is staged.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_DIR="${ROOT_DIR}/.cache/trivy"
mkdir -p "${CACHE_DIR}" "${ROOT_DIR}/.cache"

staged_dir="$(mktemp -d "${ROOT_DIR}/.cache/trivy-staged.XXXXXX")"
trap 'rm -rf "${staged_dir}"' EXIT

config_staged=false
staged_count=0
for file in "$@"; do
  case "${file}" in
    /* | ../* | */../*)
      printf 'Refusing staged path outside the repository: %s\n' "${file}" >&2
      exit 1
      ;;
  esac

  if [[ ! -f "${ROOT_DIR}/${file}" ]]; then
    continue
  fi

  mkdir -p "${staged_dir}/$(dirname "${file}")"
  cp "${ROOT_DIR}/${file}" "${staged_dir}/${file}"
  staged_count=$((staged_count + 1))

  case "${file}" in
    infra/terraform/*.tf | infra/terraform/**/*.tf | \
      infra/terraform/*.tftest.hcl | infra/terraform/**/*.tftest.hcl | \
      infra/terraform/templates/*.json | infra/terraform/templates/**/*.json | \
      workloads/*.yaml | workloads/**/*.yaml | \
      workloads/*.yml | workloads/**/*.yml | \
      *Dockerfile*)
      config_staged=true
      ;;
  esac
done

if [[ ${staged_count} -eq 0 ]]; then
  exit 0
fi

if [[ "${config_staged}" == true ]]; then
  trivy config --quiet --skip-version-check \
    --severity HIGH,CRITICAL --exit-code 1 \
    --cache-dir "${CACHE_DIR}" \
    --skip-dirs '.cache,.git,.terraform,.venv' "${ROOT_DIR}"
fi

trivy fs --quiet --skip-version-check \
  --scanners secret --exit-code 1 \
  --cache-dir "${CACHE_DIR}" "${staged_dir}"
