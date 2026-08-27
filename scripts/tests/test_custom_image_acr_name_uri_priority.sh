#!/usr/bin/env bash
# Offline regression check for custom-image ACR name resolution priority.
#
# Purpose: assert that custom_image_acr_name gives an explicit
#          ANYSCALE_CUSTOM_IMAGE_URI highest priority so the DNS preflight checks
#          the same registry the image is pushed to (including any ACR suffix),
#          and still falls back to the Terraform output and the TF_VAR_* derived
#          name when no URI is set.
# Usage:   ./scripts/tests/test_custom_image_acr_name_uri_priority.sh
#          No cloud access or credentials required.
# Inputs:  the real scripts/setup.sh source. Only the custom_image_acr_name
#          function is extracted and executed; setup.sh is not sourced whole
#          because it changes directory and touches Azure CLI env at load.
# Outputs: a pass line on stdout; non-zero exit on the first failed assertion.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETUP="${ROOT_DIR}/scripts/setup.sh"

# Extract the custom_image_acr_name definition (from its opening line to the
# first closing brace at column 0 that terminates the function body).
fn="$(awk '
  /^custom_image_acr_name\(\) \{/ { capture = 1 }
  capture { print }
  capture && /^\}/ { exit }
' "${SETUP}")"

if [[ -z "${fn}" ]]; then
  echo "could not locate custom_image_acr_name definition in setup.sh" >&2
  exit 1
fi

eval "${fn}"

# Deterministic-derived fallback name for the assertions below.
export TF_VAR_project="proj"
export TF_VAR_environment="dev"
export TF_VAR_region_short="eus2"
derived="cr${TF_VAR_project}${TF_VAR_environment}${TF_VAR_region_short}"

# Stub terraform so the Terraform-output branch is controllable and no real CLI
# is invoked. Default: no local state (empty output).
terraform() { return 0; }

# 1) Explicit suffixed image URI wins and its ACR name is extracted.
export ANYSCALE_CUSTOM_IMAGE_URI="crprojdeveus2suffix.azurecr.io/anyscale/custom:1.0"
got="$(custom_image_acr_name)"
if [[ "${got}" != "crprojdeveus2suffix" ]]; then
  echo "expected suffixed ACR name from image URI, got '${got}'" >&2
  exit 1
fi

# 2) No URI, Terraform output present -> use the Terraform login server's host.
unset ANYSCALE_CUSTOM_IMAGE_URI
terraform() { printf '%s\n' "crprojdeveus2tf.azurecr.io"; }
got="$(custom_image_acr_name)"
if [[ "${got}" != "crprojdeveus2tf" ]]; then
  echo "expected ACR name from terraform output, got '${got}'" >&2
  exit 1
fi

# 3) No URI, no Terraform state -> deterministic TF_VAR_* derived name.
terraform() { return 0; }
got="$(custom_image_acr_name)"
if [[ "${got}" != "${derived}" ]]; then
  echo "expected derived ACR name '${derived}', got '${got}'" >&2
  exit 1
fi

echo "custom_image_acr_name honors ANYSCALE_CUSTOM_IMAGE_URI, terraform, and derived fallbacks ok"
