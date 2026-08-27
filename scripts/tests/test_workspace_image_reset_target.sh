#!/usr/bin/env bash
# Offline regression check for workspace image-reset targeting.
#
# Purpose: assert that when the custom image is disabled, setup.sh resets the
#          standard (CPU-only) Anyscale image only on the CPU workspace and
#          never forces it onto aks-gpu-workspace, which must keep its
#          compute-config default (CUDA) image.
# Usage:   ./scripts/tests/test_workspace_image_reset_target.sh
#          No cloud access or credentials required.
# Inputs:  the real scripts/setup.sh source (statically inspected; not sourced,
#          because setup.sh changes directory and touches Azure CLI env at load).
# Outputs: a pass line on stdout; non-zero exit on the first failed assertion.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETUP="${ROOT_DIR}/scripts/setup.sh"

# Extract the target-image decision block: from the ensure_registered_workspace
# definition to the first `create_status=0` that terminates the block.
block="$(awk '
  /ensure_registered_workspace\(\) \{/ { capture = 1 }
  capture { print }
  capture && /create_status=0/ { exit }
' "${SETUP}")"

if [[ -z "${block}" ]]; then
  echo "could not locate ensure_registered_workspace decision block in setup.sh" >&2
  exit 1
fi

# Walk the decision block and map each target_image_uri assignment to the branch
# keyword (if/elif/else) that most recently opened. Portable across BSD/GNU awk.
result="$(awk '
  /^[[:space:]]*if[[:space:]]+custom_image_enabled/          { branch = "if-custom" }
  /elif \[\[ "\$\{workspace_name\}" == "\$\{cpu_workspace_name\}" \]\]/ { branch = "elif-cpu" }
  /^[[:space:]]*else[[:space:]]*$/                           { branch = "else" }
  /target_image_uri="\$\{ANYSCALE_STANDARD_IMAGE_URI\}"/     { print "STANDARD=" branch }
  /target_image_uri=""/                                      { print "EMPTY=" branch }
' <<<"${block}")"

standard_lines="$(grep -c '^STANDARD=' <<<"${result}" || true)"
if [[ "${standard_lines}" != "1" ]]; then
  echo "expected exactly one standard-image assignment, found ${standard_lines}" >&2
  echo "${block}" >&2
  exit 1
fi

if ! grep -qx 'STANDARD=elif-cpu' <<<"${result}"; then
  echo "standard (CPU-only) image must be assigned only under the CPU-workspace elif" >&2
  echo "${block}" >&2
  exit 1
fi

if ! grep -qx 'EMPTY=else' <<<"${result}"; then
  echo "the else (GPU) branch must leave target_image_uri empty so no image drift is forced" >&2
  echo "${block}" >&2
  exit 1
fi

echo "workspace image reset targets CPU workspace only; GPU image untouched ok"
