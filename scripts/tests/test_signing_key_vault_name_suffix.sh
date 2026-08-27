#!/usr/bin/env bash
# Offline regression check for signing Key Vault name resolution.
#
# Purpose: assert that signing_key_vault_name prefers the Terraform output,
#          and its TF_VAR_* fallback mirrors infra/terraform/locals.tf exactly:
#          substr("kv-<project>-<environment>-<region_short>" +
#                 (global_name_suffix ? "-<global_name_suffix>" : ""), 0, 24).
#          This covers the DNS-mismatch bug where the fallback omitted the
#          global suffix and signing targeted an unsuffixed vault name.
# Usage:   ./scripts/tests/test_signing_key_vault_name_suffix.sh
#          No cloud access or credentials required.
# Inputs:  the real scripts/setup.sh source. Only the signing_key_vault_name
#          function is extracted and executed; setup.sh is not sourced whole
#          because it changes directory and touches Azure CLI env at load.
# Outputs: a pass line on stdout; non-zero exit on the first failed assertion.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETUP="${ROOT_DIR}/scripts/setup.sh"

# Extract the signing_key_vault_name definition (from its opening line to the
# first closing brace at column 0 that terminates the function body).
fn="$(awk '
  /^signing_key_vault_name\(\) \{/ { capture = 1 }
  capture { print }
  capture && /^\}/ { exit }
' "${SETUP}")"

if [[ -z "${fn}" ]]; then
  echo "could not locate signing_key_vault_name definition in setup.sh" >&2
  exit 1
fi

eval "${fn}"

export TF_VAR_project="proj"
export TF_VAR_environment="dev"
export TF_VAR_region_short="eus2"
unset TF_VAR_global_name_suffix 2>/dev/null || true

# 1) Terraform output present -> it wins verbatim, suffix logic is bypassed.
terraform() { printf '%s\n' "kv-proj-dev-eus2-l8"; }
got="$(signing_key_vault_name)"
if [[ "${got}" != "kv-proj-dev-eus2-l8" ]]; then
  echo "expected vault name from terraform output, got '${got}'" >&2
  exit 1
fi

# Stub terraform with no local state (empty output) for the fallback cases.
terraform() { return 0; }

# 2) No Terraform state, no global suffix -> plain derived name.
got="$(signing_key_vault_name)"
if [[ "${got}" != "kv-proj-dev-eus2" ]]; then
  echo "expected derived name without suffix 'kv-proj-dev-eus2', got '${got}'" >&2
  exit 1
fi

# 3) No Terraform state, global suffix set -> "-<suffix>" appended.
export TF_VAR_global_name_suffix="l8"
got="$(signing_key_vault_name)"
if [[ "${got}" != "kv-proj-dev-eus2-l8" ]]; then
  echo "expected suffixed derived name 'kv-proj-dev-eus2-l8', got '${got}'" >&2
  exit 1
fi

# 4) Long inputs -> result is truncated to 24 characters, matching substr(...,0,24).
export TF_VAR_region_short="eastus2"
export TF_VAR_global_name_suffix="longsuffix"
got="$(signing_key_vault_name)"
if [[ "${#got}" -ne 24 ]]; then
  echo "expected 24-char truncated name, got '${got}' (${#got} chars)" >&2
  exit 1
fi
if [[ "${got}" != "kv-proj-dev-eastus2-long" ]]; then
  echo "expected truncated name 'kv-proj-dev-eastus2-long', got '${got}'" >&2
  exit 1
fi

echo "signing_key_vault_name honors terraform output and suffix-aware truncated fallback ok"
