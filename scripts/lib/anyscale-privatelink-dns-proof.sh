#!/usr/bin/env bash
# Pure helpers for the Anyscale control-plane Private Link DNS proof.
#
# Purpose: hold the hostname validation and pass/fail decision logic with no
#          Azure calls, so they can be unit-tested offline. The orchestration
#          that calls `az vm run-command invoke` lives in
#          scripts/privatelink-dns-proof.sh.
# Usage:   sourced; do not execute. Tested by
#          scripts/tests/test_privatelink_dns_proof.sh.
# Inputs:  hostname and resolved/expected IP arguments.
# Outputs: PRIVATELINK_DNS_PROOF_OK or PRIVATELINK_DNS_PROOF_FAIL evidence
#          lines on stdout; non-zero return on a failed proof.

# Marker strings consumed by RESULTS evidence and the test harness.
PRIVATELINK_DNS_PROOF_OK_MARKER="PRIVATELINK_DNS_PROOF_OK"
PRIVATELINK_DNS_PROOF_FAIL_MARKER="PRIVATELINK_DNS_PROOF_FAIL"

# The public browser/OAuth console host. It stays on public DNS and MUST NOT be
# expected to resolve to the private endpoint IP.
PRIVATELINK_PUBLIC_CONSOLE_HOST="console.azure.anyscale.com"

# Extract the first IPv4 address from arbitrary text (e.g. the message field of
# an `az vm run-command invoke` result, or Resolve-DnsName output). Prints the
# address on success and returns 0; prints nothing and returns 1 when none is
# found. Rejects octets > 255 so it does not accept malformed addresses.
privatelink_extract_ipv4() {
  local text="$1"
  local candidate
  for candidate in $(printf '%s\n' "${text}" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}'); do
    local ok=1 octet
    local IFS='.'
    # shellcheck disable=SC2206
    local octets=(${candidate})
    unset IFS
    for octet in "${octets[@]}"; do
      if ((10#${octet} > 255)); then
        ok=0
        break
      fi
    done
    if [[ "${ok}" -eq 1 ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

# Validate that the hostname under test is the cloud-specific private control
# plane host: it must sit under the configured private DNS zone and must not be
# the public console host. Returns 0 when valid, 1 otherwise (with a reason on
# stderr).
privatelink_validate_hostname() {
  local hostname="$1"
  local zone="$2"

  if [[ -z "${hostname}" ]]; then
    printf 'hostname is empty\n' >&2
    return 1
  fi
  if [[ "${hostname}" == "${PRIVATELINK_PUBLIC_CONSOLE_HOST}" ]]; then
    printf '%s is the public login console, not a Private Link host\n' "${hostname}" >&2
    return 1
  fi
  if [[ -z "${zone}" ]]; then
    printf 'private DNS zone is empty\n' >&2
    return 1
  fi
  if [[ ! "${hostname}" =~ ^[A-Za-z0-9.-]+$ ]]; then
    printf '%s contains characters that are not valid in a DNS hostname\n' "${hostname}" >&2
    return 1
  fi
  if [[ "${hostname}" != *".${zone}" ]]; then
    printf '%s is not under the private DNS zone %s\n' "${hostname}" "${zone}" >&2
    return 1
  fi
  return 0
}

# Compare the DNS answer for the private hostname against the Terraform-reported
# private endpoint IP. Prints the proof marker line and returns 0 only when the
# resolved IP exactly equals the expected private endpoint IP.
privatelink_dns_proof_evaluate() {
  local hostname="$1"
  local expected_ip="$2"
  local resolved_ip="$3"

  if [[ -z "${expected_ip}" ]]; then
    printf '%s hostname=%s reason=missing_expected_private_ip\n' \
      "${PRIVATELINK_DNS_PROOF_FAIL_MARKER}" "${hostname}"
    return 1
  fi
  if [[ -z "${resolved_ip}" ]]; then
    printf '%s hostname=%s reason=no_dns_answer\n' \
      "${PRIVATELINK_DNS_PROOF_FAIL_MARKER}" "${hostname}"
    return 1
  fi
  if [[ "${resolved_ip}" != "${expected_ip}" ]]; then
    printf '%s hostname=%s expected=%s resolved=%s\n' \
      "${PRIVATELINK_DNS_PROOF_FAIL_MARKER}" "${hostname}" "${expected_ip}" "${resolved_ip}"
    return 1
  fi
  printf '%s hostname=%s private_ip=%s\n' \
    "${PRIVATELINK_DNS_PROOF_OK_MARKER}" "${hostname}" "${expected_ip}"
  return 0
}
