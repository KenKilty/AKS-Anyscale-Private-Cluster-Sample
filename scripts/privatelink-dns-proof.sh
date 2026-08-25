#!/usr/bin/env bash
# Anyscale control-plane Private Link DNS proof.
#
# Purpose: prove that the cloud-specific private control-plane hostname
#          (cld-<cloud-resource-id>.<zone>) resolves, from inside the VNet, to
#          the exact private endpoint IP that Terraform created.
#          This is a DNS proof only. It works BEFORE Anyscale approves the
#          cross-tenant connection; approval and a TLS probe are separate,
#          later checks. The public browser/OAuth console host
#          console.azure.anyscale.com stays on public DNS, is reported
#          separately, and must never equal the private endpoint IP.
# Usage:   ./scripts/privatelink-dns-proof.sh [--hostname FQDN]
#          Runs from the workstation and resolves through the Windows browser
#          jump host via Azure VM Run Command.
# Inputs:  --hostname or ANYSCALE_PRIVATELINK_HOSTNAME; Terraform outputs for
#          the expected private endpoint IP; cached Azure CLI auth.
# Outputs: a PRIVATELINK_DNS_PROOF_OK or PRIVATELINK_DNS_PROOF_FAIL evidence
#          line on stdout; exit 0 only when the resolved IP matches.
#
# Read-only and idempotent: it runs a single PowerShell Resolve-DnsName on the
# existing Windows browser host. It creates nothing and prints no secrets.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="${ROOT_DIR}/infra/terraform"

LOG_INFO_PREFIX="privatelink-proof"
LOG_WARN_PREFIX="privatelink-proof"
LOG_ERROR_PREFIX="privatelink-proof"
# shellcheck source=lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"
# shellcheck source=lib/timeout.sh
source "${SCRIPT_DIR}/lib/timeout.sh"
# shellcheck source=lib/anyscale-privatelink-dns-proof.sh
source "${SCRIPT_DIR}/lib/anyscale-privatelink-dns-proof.sh"

usage() {
  cat <<'USAGE'
Usage: ./scripts/privatelink-dns-proof.sh [--hostname FQDN]

Resolves the cloud-specific Anyscale Private Link hostname from the Windows
browser host (via Azure VM Run Command) and requires the answer to equal the
Terraform-reported private endpoint IP.

Options:
  --hostname FQDN   Cloud-specific control plane host to resolve, e.g.
                    cld-<cloud-resource-id>.azure.anyscale-cloud.dev. May also be
                    supplied through ANYSCALE_PRIVATELINK_HOSTNAME. Must sit
                    under the configured private DNS zone; the public console
                    host console.azure.anyscale.com is rejected.
  -h, --help        Show this help.

Environment:
  ANYSCALE_PRIVATELINK_HOSTNAME   Default for --hostname.
USAGE
}

hostname_arg="${ANYSCALE_PRIVATELINK_HOSTNAME:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname)
      [[ $# -ge 2 ]] || die "--hostname requires a value."
      hostname_arg="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

tf_output_json() {
  run_with_timeout "${SETUP_TIMEOUT_TERRAFORM_COMMAND_SECONDS:-120}" \
    terraform -chdir="${TERRAFORM_DIR}" output -json "$1"
}

privatelink_json="$(tf_output_json anyscale_privatelink)" ||
  die "Could not read the anyscale_privatelink Terraform output. Deploy the foundation first."

enabled="$(jq -r '.enabled // false' <<<"${privatelink_json}")"
[[ "${enabled}" == "true" ]] ||
  die "Private Link is disabled (enable_privatelink=false). Nothing to prove."

expected_ip="$(jq -r '.private_ip // empty' <<<"${privatelink_json}")"
[[ -n "${expected_ip}" ]] ||
  die "The anyscale_privatelink output has no private_ip. Re-check the private endpoint."

zone="$(jq -r '.dns_zone // empty' <<<"${privatelink_json}")"
[[ -n "${zone}" ]] || die "The anyscale_privatelink output has no dns_zone."

[[ -n "${hostname_arg}" ]] ||
  die "No hostname given. Pass --hostname cld-<cloud-resource-id>.${zone} or set ANYSCALE_PRIVATELINK_HOSTNAME."

privatelink_validate_hostname "${hostname_arg}" "${zone}" ||
  die "Refusing to run: the hostname must be a Private Link host under ${zone}."

browser_enabled="$(tf_output_json browser_jump_host_enabled 2>/dev/null | jq -r '. // false' 2>/dev/null || echo "false")"
[[ "${browser_enabled}" == "true" ]] ||
  die "The Windows browser host is not deployed (enable_browser_host=false). Enable it in ignored local config first."

vm_name="$(tf_output_json browser_jump_host_vm_name | jq -r '. // empty')"
[[ -n "${vm_name}" ]] || die "browser_jump_host_vm_name output is empty."

resource_group="$(tf_output_json resource_group_name | jq -r '. // empty')"
[[ -n "${resource_group}" ]] || die "resource_group_name output is empty."

log "Resolving ${hostname_arg} from ${vm_name} (expected private IP ${expected_ip})."

# Single, side-effect-free PowerShell lookup. -DnsOnly avoids NetBIOS/LLMNR
# fallbacks; we only want the VNet resolver's answer.
powershell_script="(Resolve-DnsName -Name '${hostname_arg}' -Type A -DnsOnly -ErrorAction Stop | Where-Object { \$_.IPAddress } | Select-Object -ExpandProperty IPAddress) -join ','"

run_command_json="$(run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS:-300}" \
  az vm run-command invoke \
  --name "${vm_name}" \
  --resource-group "${resource_group}" \
  --command-id RunPowerShellScript \
  --scripts "${powershell_script}" \
  --only-show-errors \
  -o json)" || die "az vm run-command invoke failed."

message="$(jq -r '.value[0].message // ""' <<<"${run_command_json}")"

resolved_ip=""
if privatelink_extract_ipv4 "${message}" >/dev/null 2>&1; then
  resolved_ip="$(privatelink_extract_ipv4 "${message}")"
fi

echo "---"
echo "Private Link DNS proof (in-VNet resolution from the Windows browser host):"
if privatelink_dns_proof_evaluate "${hostname_arg}" "${expected_ip}" "${resolved_ip}"; then
  proof_rc=0
else
  proof_rc=1
fi

echo "---"
echo "Public console distinction (informational, NOT part of the pass condition):"
echo "  ${PRIVATELINK_PUBLIC_CONSOLE_HOST} is the public browser/OAuth login console."
echo "  It stays on public DNS and must NOT be expected to resolve to ${expected_ip}."
echo "  DNS resolving privately proves the zone/records only. Approval and a TLS"
echo "  probe to ${hostname_arg}:443 are separate checks and require Anyscale to"
echo "  approve the cross-tenant connection first."

exit "${proof_rc}"
