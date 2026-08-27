#!/usr/bin/env bash
# Offline regression check for parseable Anyscale job status output.
#
# Purpose: prove scripts/setup.sh uses the supported JSON output flag so CLI
#          deprecation warnings do not prevent jq from reading job state and ID.
# Usage:   ./scripts/tests/test_anyscale_job_status_json.sh
#          No cloud access or credentials required.
# Inputs:  the real scripts/setup.sh source and temporary status fixtures.
# Outputs: a pass line on stdout; non-zero exit on the first failed assertion.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETUP="${ROOT_DIR}/scripts/setup.sh"

status_block="$(awk '
  /"\$\{cli_bin\}" job status/ { capture = 1 }
  capture { print }
  capture && />"\$\{status_log\}" 2>&1 \|\| true/ { exit }
' "${SETUP}")"

if [[ -z "${status_block}" ]]; then
  printf 'could not locate the Anyscale job status block in setup.sh\n' >&2
  exit 1
fi

grep -q -- '--output json' <<<"${status_block}" || {
  printf 'job status block must use --output json\n' >&2
  exit 1
}

grep -q -- '--json' <<<"${status_block}" && {
  printf 'job status block still uses deprecated --json\n' >&2
  exit 1
}

service_status_blocks="$(grep -A 6 '"\${cli_bin}" service status' "${SETUP}")"
[[ "$(grep -c -- '--output json' <<<"${service_status_blocks}")" -eq 3 ]] || {
  printf 'every service status block must use --output json\n' >&2
  exit 1
}
grep -q -- '--json' <<<"${service_status_blocks}" && {
  printf 'a service status block still uses deprecated --json\n' >&2
  exit 1
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/anyscale-job-status.XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT

cat >"${tmp}/contaminated.json" <<'EOF'
Warning: --json is deprecated; use -o json instead.
{"id":"prodjob_test","state":"SUCCEEDED","runs":[{"state":"SUCCEEDED"}]}
EOF

if jq -e . "${tmp}/contaminated.json" >/dev/null 2>&1; then
  printf 'warning-prefixed status fixture unexpectedly parsed as JSON\n' >&2
  exit 1
fi

cat >"${tmp}/clean.json" <<'EOF'
{"id":"prodjob_test","state":"SUCCEEDED","runs":[{"state":"SUCCEEDED"}]}
EOF

[[ "$(jq -r '.state // empty' "${tmp}/clean.json")" == "SUCCEEDED" ]] || {
  printf 'clean status fixture did not expose the job state\n' >&2
  exit 1
}
[[ "$(jq -r '.id // empty' "${tmp}/clean.json")" == "prodjob_test" ]] || {
  printf 'clean status fixture did not expose the job ID\n' >&2
  exit 1
}

printf 'Anyscale job status JSON remains parseable for marker fallback ok\n'
