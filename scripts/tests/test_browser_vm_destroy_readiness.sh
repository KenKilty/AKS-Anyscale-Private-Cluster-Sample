#!/usr/bin/env bash
# Offline regression test for browser VM teardown readiness.
#
# Purpose: verify teardown starts a stopped browser VM before Terraform removes
#          AADLoginForWindows and leaves absent or running VMs unchanged.
# Usage:   ./scripts/tests/test_browser_vm_destroy_readiness.sh
#          No cloud access or credentials required.
# Inputs:  the real helper extracted from scripts/setup.sh and mocked CLI calls.
# Outputs: a pass line on stdout; non-zero exit on the first failed assertion.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETUP="${ROOT_DIR}/scripts/setup.sh"
CALLS_FILE="$(mktemp)"
trap 'rm -f "${CALLS_FILE}"' EXIT

helper="$(awk '
  /^ensure_browser_vm_running_for_destroy\(\) \{/ { capture = 1 }
  capture { print }
  capture && /^\}$/ { exit }
' "${SETUP}")"
[[ -n "${helper}" ]] || {
  echo "could not locate ensure_browser_vm_running_for_destroy in setup.sh" >&2
  exit 1
}
eval "${helper}"

SETUP_TIMEOUT_AZURE_COMMAND_SECONDS=30
MOCK_VM_ID=""
MOCK_POWER_STATE=""

terraform_output_raw() {
  [[ "$1" == "browser_jump_host_vm_id" ]] || return 1
  printf '%s\n' "${MOCK_VM_ID}"
}

az() {
  printf '%s\n' "$*" >>"${CALLS_FILE}"
  if [[ "$1 $2" == "vm get-instance-view" ]]; then
    printf '%s\n' "${MOCK_POWER_STATE}"
  fi
}

run_with_timeout() {
  shift
  "$@"
}

log() { :; }

assert_no_start() {
  if grep -q '^vm start ' "${CALLS_FILE}"; then
    echo "browser VM must not be started for this case" >&2
    cat "${CALLS_FILE}" >&2
    exit 1
  fi
}

: >"${CALLS_FILE}"
MOCK_VM_ID=""
ensure_browser_vm_running_for_destroy
[[ ! -s "${CALLS_FILE}" ]] || {
  echo "absent browser VM must not call Azure CLI" >&2
  exit 1
}

: >"${CALLS_FILE}"
MOCK_VM_ID="/subscriptions/example/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/browser"
MOCK_POWER_STATE="PowerState/running"
ensure_browser_vm_running_for_destroy
assert_no_start

: >"${CALLS_FILE}"
MOCK_POWER_STATE="PowerState/deallocated"
ensure_browser_vm_running_for_destroy
grep -q '^vm start --ids .* --only-show-errors$' "${CALLS_FILE}" || {
  echo "deallocated browser VM must be started before destroy" >&2
  cat "${CALLS_FILE}" >&2
  exit 1
}

: >"${CALLS_FILE}"
MOCK_POWER_STATE="PowerState/stopped"
ensure_browser_vm_running_for_destroy
grep -q '^vm start --ids .* --only-show-errors$' "${CALLS_FILE}" || {
  echo "stopped browser VM must be started before destroy" >&2
  cat "${CALLS_FILE}" >&2
  exit 1
}

echo "browser VM destroy readiness handles absent, running, stopped, and deallocated states ok"
