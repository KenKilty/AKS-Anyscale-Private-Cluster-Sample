#!/usr/bin/env bash
# Offline unit test for the Private Link DNS proof helpers.
#
# Purpose: assert that privatelink_validate_hostname rejects the public console
#          host and off-zone names, and that privatelink_dns_proof_evaluate
#          passes only when the resolved IP equals the expected private
#          endpoint IP.
# Usage:   ./scripts/tests/test_privatelink_dns_proof.sh
#          No cloud access or credentials required.
# Inputs:  none; hostnames and IPs are supplied inline as fixtures.
# Outputs: a pass line on stdout; non-zero exit on the first failed assertion.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/anyscale-privatelink-dns-proof.sh
source "${ROOT_DIR}/scripts/lib/anyscale-privatelink-dns-proof.sh"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# --- privatelink_extract_ipv4 -------------------------------------------------
got="$(privatelink_extract_ipv4 "Name: cld-x.azure.anyscale-cloud.dev
Address: 10.50.2.7")" || fail "extract_ipv4 returned nonzero on valid input"
[[ "${got}" == "10.50.2.7" ]] || fail "extract_ipv4 expected 10.50.2.7, got ${got}"

# Rejects malformed octets and finds the first valid address.
got="$(privatelink_extract_ipv4 "999.1.1.1 then 172.16.0.9")" ||
  fail "extract_ipv4 returned nonzero when a valid address followed a bad one"
[[ "${got}" == "172.16.0.9" ]] || fail "extract_ipv4 expected 172.16.0.9, got ${got}"

if privatelink_extract_ipv4 "no address here" >/dev/null 2>&1; then
  fail "extract_ipv4 should fail when no IPv4 is present"
fi

# --- privatelink_validate_hostname -------------------------------------------
privatelink_validate_hostname "cld-abc.azure.anyscale-cloud.dev" "azure.anyscale-cloud.dev" ||
  fail "valid private host should pass validation"

if privatelink_validate_hostname "console.azure.anyscale.com" "azure.anyscale-cloud.dev" 2>/dev/null; then
  fail "public console host must be rejected"
fi

if privatelink_validate_hostname "cld-abc.example.com" "azure.anyscale-cloud.dev" 2>/dev/null; then
  fail "host outside the private zone must be rejected"
fi

if privatelink_validate_hostname "cld-abc';Write-Output injected;.azure.anyscale-cloud.dev" "azure.anyscale-cloud.dev" 2>/dev/null; then
  fail "host with unsafe non-DNS characters must be rejected"
fi

if privatelink_validate_hostname "" "azure.anyscale-cloud.dev" 2>/dev/null; then
  fail "empty host must be rejected"
fi

# --- privatelink_dns_proof_evaluate ------------------------------------------
out="$(privatelink_dns_proof_evaluate "cld-abc.azure.anyscale-cloud.dev" "10.50.2.7" "10.50.2.7")" ||
  fail "matching IPs should pass"
[[ "${out}" == *"${PRIVATELINK_DNS_PROOF_OK_MARKER}"* ]] || fail "expected OK marker, got: ${out}"
[[ "${out}" == *"private_ip=10.50.2.7"* ]] || fail "expected private_ip in OK marker, got: ${out}"

out="$(privatelink_dns_proof_evaluate "cld-abc.azure.anyscale-cloud.dev" "10.50.2.7" "20.1.2.3")" &&
  fail "mismatched IPs should fail" || true
[[ "${out}" == *"${PRIVATELINK_DNS_PROOF_FAIL_MARKER}"* ]] || fail "expected FAIL marker on mismatch, got: ${out}"
[[ "${out}" == *"expected=10.50.2.7"* && "${out}" == *"resolved=20.1.2.3"* ]] ||
  fail "expected both IPs in mismatch marker, got: ${out}"

out="$(privatelink_dns_proof_evaluate "cld-abc.azure.anyscale-cloud.dev" "10.50.2.7" "")" &&
  fail "empty resolved IP should fail" || true
[[ "${out}" == *"reason=no_dns_answer"* ]] || fail "expected no_dns_answer reason, got: ${out}"

out="$(privatelink_dns_proof_evaluate "cld-abc.azure.anyscale-cloud.dev" "" "10.50.2.7")" &&
  fail "missing expected IP should fail" || true
[[ "${out}" == *"reason=missing_expected_private_ip"* ]] ||
  fail "expected missing_expected_private_ip reason, got: ${out}"

echo "PASS: privatelink dns proof logic"
