#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${ROOT_DIR}/infra/terraform"
TERRAFORM_CLI_CONFIG_FILE="${ROOT_DIR}/.cache/terraform-cli.tfrc"
OPENVPN_PROFILE="${ROOT_DIR}/.cache/aks-anyscale-sample-harness/p2s-vpn/openvpn-ready.ovpn"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

ensure_local_terraform_cli_config() {
  mkdir -p "${ROOT_DIR}/.cache"
  [[ -f "${TERRAFORM_CLI_CONFIG_FILE}" ]] || : > "${TERRAFORM_CLI_CONFIG_FILE}"
}

terraform_raw() {
  local output_name="$1"

  ensure_local_terraform_cli_config

  (
    cd "${TERRAFORM_DIR}"
    TF_CLI_CONFIG_FILE="${TERRAFORM_CLI_CONFIG_FILE}" terraform output -raw "${output_name}"
  )
}

load_live_values() {
  STORAGE_ACCOUNT_NAME="$(terraform_raw storage_account_name)"
  ACR_LOGIN_SERVER="$(terraform_raw acr_login_server)"
  AKS_PRIVATE_FQDN="$(terraform_raw aks_private_fqdn)"
  LOG_ANALYTICS_WORKSPACE_CUSTOMER_ID="$(terraform_raw log_analytics_workspace_customer_id)"
  REGION="$(terraform_raw location)"
  DNS_RESOLVER_INBOUND_ENDPOINT_IP="$(terraform_raw dns_resolver_inbound_endpoint_ip)"
  VPN_GATEWAY_PUBLIC_IP="$(terraform_raw vpn_gateway_public_ip)"
}

print_targets() {
  load_live_values

  printf 'VPN gateway public IP: %s\n' "${VPN_GATEWAY_PUBLIC_IP}"
  printf 'VPN DNS resolver:      %s\n' "${DNS_RESOLVER_INBOUND_ENDPOINT_IP}"
  printf 'AKS private FQDN:      %s\n' "${AKS_PRIVATE_FQDN}"
  printf 'ACR login server:      %s\n' "${ACR_LOGIN_SERVER}"
  printf 'OpenVPN profile:       %s\n' "${OPENVPN_PROFILE}"
}

connect_tunnel() {
  require_cmd sudo
  require_cmd openvpn
  [[ -f "${OPENVPN_PROFILE}" ]] || die "OpenVPN profile not found: ${OPENVPN_PROFILE}"

  print_targets
  printf '\nNext steps:\n'
  printf '  1. Enter your macOS password at the sudo prompt.\n'
  printf '  2. After sudo succeeds, this terminal may stay mostly quiet while OpenVPN connects. That is normal.\n'
  printf '  3. Open a second terminal and run:\n'
  printf '       ./p2s-vpn-proof.sh status\n'
  printf '       ./p2s-vpn-proof.sh proof\n'
  printf '  4. Disconnect with Ctrl-C here, or later run:\n'
  printf '       ./p2s-vpn-proof.sh disconnect\n\n'

  sudo -v

  printf 'sudo authentication accepted. Starting OpenVPN now...\n'
  printf 'If this terminal goes quiet, open a second terminal and run ./p2s-vpn-proof.sh status\n\n'
  exec sudo openvpn --config "${OPENVPN_PROFILE}" --verb 3
}

matching_openvpn_pids() {
  local profile_basename
  profile_basename="$(basename "${OPENVPN_PROFILE}")"
  ps -ax -o pid=,command= | awk -v profile_basename="${profile_basename}" '
    $0 ~ /(^|[[:space:]\/])openvpn([[:space:]]|$)/ && index($0, profile_basename) { print $1 }
  '
}

vpn_status() {
  require_cmd dig
  require_cmd scutil

  load_live_values
  print_targets

  local aks_answer acr_answer resolver_match connected=1 openvpn_rows

  printf '\n=== openvpn processes ===\n'
  openvpn_rows="$(ps -ax -o pid=,etime=,command= | awk -v profile_basename="$(basename "${OPENVPN_PROFILE}")" '
    $0 ~ /(^|[[:space:]\/])openvpn([[:space:]]|$)/ && index($0, profile_basename) { print }
  ')"
  if [[ -n "${openvpn_rows}" ]]; then
    printf '%s\n' "${openvpn_rows}"
    connected=0
  else
    printf 'No matching openvpn process found for %s\n' "$(basename "${OPENVPN_PROFILE}")"
  fi

  printf '\n=== macOS DNS configuration ===\n'
  resolver_match="$(scutil --dns | grep -A3 "${DNS_RESOLVER_INBOUND_ENDPOINT_IP}" || true)"
  if [[ -n "${resolver_match}" ]]; then
    printf '%s\n' "${resolver_match}"
    connected=0
  else
    printf 'Resolver %s not present in current macOS DNS config\n' "${DNS_RESOLVER_INBOUND_ENDPOINT_IP}"
  fi

  printf '\n=== system DNS answers ===\n'
  aks_answer="$(dig +short "${AKS_PRIVATE_FQDN}" || true)"
  acr_answer="$(dig +short "${ACR_LOGIN_SERVER}" || true)"
  printf '%s\n%s\n' "${AKS_PRIVATE_FQDN}" "${aks_answer:-<no answer>}"
  printf '%s\n%s\n' "${ACR_LOGIN_SERVER}" "${acr_answer:-<no answer>}"

  if [[ "${aks_answer}" == *10.* || "${acr_answer}" == *10.* ]]; then
    connected=0
  fi

  printf '\n=== status summary ===\n'
  if [[ ${connected} -eq 0 ]]; then
    printf 'VPN likely connected.\n'
  else
    printf 'VPN not detected as connected.\n'
    return 1
  fi
}

disconnect_tunnel() {
  require_cmd sudo

  local pids
  pids="$(matching_openvpn_pids)"
  if [[ -z "${pids}" ]]; then
    printf 'No matching openvpn process found for %s\n' "$(basename "${OPENVPN_PROFILE}")"
    return 0
  fi

  printf 'Stopping openvpn PIDs: %s\n' "${pids//$'\n'/ }"
  sudo kill ${pids}
}

resolve_host() {
  local dns_server="$1"
  local host="$2"
  local answer

  printf '\n=== resolving %s via %s ===\n' "${host}" "${dns_server}"
  answer="$(dig @"${dns_server}" "${host}" +short)"
  [[ -n "${answer}" ]] || die "No DNS answer for ${host} via ${dns_server}"
  printf '%s\n' "${answer}"
}

probe_url() {
  local url="$1"
  local code

  printf '\n=== probing %s ===\n' "${url}"
  code="$(curl -k -sS -o /dev/null -w '%{http_code}' --connect-timeout 20 --max-time 60 "${url}")"
  case "${code}" in
    2*|3*|4*)
      printf 'HTTP %s\n' "${code}"
      ;;
    *)
      die "Unexpected HTTP status ${code} for ${url}"
      ;;
  esac
}

run_dns_and_http_proof() {
  require_cmd terraform
  require_cmd dig
  require_cmd curl

  load_live_values
  print_targets

  local dns_server="${DNS_RESOLVER_INBOUND_ENDPOINT_IP}"
  local storage_blob_host="${STORAGE_ACCOUNT_NAME}.blob.core.windows.net"
  local storage_dfs_host="${STORAGE_ACCOUNT_NAME}.dfs.core.windows.net"
  local law_ods_host="${LOG_ANALYTICS_WORKSPACE_CUSTOMER_ID}.ods.opinsights.azure.com"
  local law_oms_host="${LOG_ANALYTICS_WORKSPACE_CUSTOMER_ID}.oms.opinsights.azure.com"
  local monitor_region_host="${REGION}.handler.control.monitor.azure.com"

  for host in \
    "${storage_blob_host}" \
    "${storage_dfs_host}" \
    "${ACR_LOGIN_SERVER}" \
    "arcmktplaceprod.azurecr.io" \
    "${AKS_PRIVATE_FQDN}" \
    "global.handler.control.monitor.azure.com" \
    "${monitor_region_host}" \
    "${law_ods_host}" \
    "${law_oms_host}" \
    "api.anyscale.com" \
    "console.azure.anyscale.com" \
    "console.anyscale.com"
  do
    resolve_host "${dns_server}" "${host}"
  done

  for url in \
    "https://${storage_blob_host}/" \
    "https://${ACR_LOGIN_SERVER}/v2/" \
    "https://arcmktplaceprod.azurecr.io/v2/" \
    "https://global.handler.control.monitor.azure.com/" \
    "https://${law_ods_host}/" \
    "https://api.anyscale.com/" \
    "https://console.azure.anyscale.com/" \
    "https://console.anyscale.com/"
  do
    probe_url "${url}"
  done
}

check_system_dns() {
  require_cmd scutil
  require_cmd nslookup

  load_live_values
  print_targets

  printf '\n=== macOS DNS configuration ===\n'
  scutil --dns | grep -A3 "${DNS_RESOLVER_INBOUND_ENDPOINT_IP}" || true

  printf '\n=== resolving via system DNS ===\n'
  nslookup "${AKS_PRIVATE_FQDN}"
  nslookup "${ACR_LOGIN_SERVER}"
}

usage() {
  cat <<'USAGE'
Usage:
  ./p2s-vpn-proof.sh connect
  ./p2s-vpn-proof.sh status
  ./p2s-vpn-proof.sh disconnect
  ./p2s-vpn-proof.sh proof
  ./p2s-vpn-proof.sh system-dns
  ./p2s-vpn-proof.sh targets

Commands:
  connect     Start OpenVPN in the foreground using the generated profile.
  status      Check whether the tunnel appears connected from process, DNS, and private-name resolution.
  disconnect  Stop a matching foreground openvpn process for this generated profile.
  proof       Run the DNS and HTTP proofs against the live deployed values.
  system-dns  Check whether macOS picked up the VPN-pushed DNS server.
  targets     Print the current live endpoints and profile path.

Recommended flow:
  1. Run ./p2s-vpn-proof.sh connect in one terminal and leave it open.
  2. Run ./p2s-vpn-proof.sh proof in another terminal.
  3. Optionally run ./p2s-vpn-proof.sh system-dns if using Tunnelblick/OpenVPN Connect.
USAGE
}

main() {
  local cmd="${1:-}"

  case "${cmd}" in
    connect)
      connect_tunnel
      ;;
    status)
      vpn_status
      ;;
    disconnect)
      disconnect_tunnel
      ;;
    proof)
      run_dns_and_http_proof
      ;;
    system-dns)
      check_system_dns
      ;;
    targets)
      print_targets
      ;;
    ""|-h|--help)
      usage
      ;;
    *)
      die "Usage: ./p2s-vpn-proof.sh {connect|status|disconnect|proof|system-dns|targets}"
      ;;
  esac
}

main "$@"