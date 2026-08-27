#!/usr/bin/env bash
# Offline regression check for `workload proof all` build-job naming order.
#
# Purpose: assert that in setup.sh's `all)` case, the build-job run-suffix name
#          is computed only AFTER setup_run_init runs. workload_name_with_run_suffix
#          reads SETUP_RUN_DIR, which setup_run_init sets; computing the name first
#          yields an empty suffix (aks-cpu-build-proof-) and an Anyscale 400
#          "unique name" error on the second run.
# Usage:   ./scripts/tests/test_workload_all_build_name_ordering.sh
#          No cloud access or credentials required.
# Inputs:  the real scripts/setup.sh source (statically inspected; not sourced,
#          because setup.sh changes directory and touches Azure CLI env at load).
# Outputs: a pass line on stdout; non-zero exit on the first failed assertion.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETUP="${ROOT_DIR}/scripts/setup.sh"

# Extract the `all)` case block: from the `    all)` label to the terminating
# `      ;;` at the case-item indentation level (the if/else/fi inside carries
# no nested `;;`).
block="$(awk '
  /^    all\)/           { capture = 1 }
  capture               { print }
  capture && /^      ;;/ { exit }
' "${SETUP}")"

if [[ -z "${block}" ]]; then
  echo "could not locate the all) case block in setup.sh" >&2
  exit 1
fi

# Walk the block. Count setup_run_init calls seen so far; every build-job
# run-suffix assignment must be preceded by at least one setup_run_init.
result="$(awk '
  /setup_run_init/ { seen_init++ }
  /WORKLOAD_BUILD_JOB_NAME="\$\(workload_name_with_run_suffix/ {
    assignments++
    if (seen_init < 1) print "EARLY"
  }
  END { print "ASSIGN=" assignments }
' <<<"${block}")"

assignments="$(sed -n 's/^ASSIGN=//p' <<<"${result}")"
if [[ "${assignments}" == "0" || -z "${assignments}" ]]; then
  echo "expected at least one build-job run-suffix assignment in the all) block" >&2
  echo "${block}" >&2
  exit 1
fi

if grep -qx 'EARLY' <<<"${result}"; then
  echo "build-job run-suffix name is computed before setup_run_init sets SETUP_RUN_DIR" >&2
  echo "this yields an empty suffix (aks-cpu-build-proof-) and an Anyscale 400 unique-name error" >&2
  echo "${block}" >&2
  exit 1
fi

echo "workload proof all computes build-job name after setup_run_init ok"
