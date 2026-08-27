#!/usr/bin/env bash
# Offline regression check for the Container Insights zero-record classification.
#
# Purpose: prove scripts/setup.sh validate_observability still FAILS when
#          ContainerLogV2 returns no records (never downgraded to PASS) and that
#          the failure explains how to distinguish ingestion latency from an
#          Azure Monitor ODS service-side rejection (HTTP 403 MaODSRequest).
# Usage:   ./scripts/tests/test_observability_ods_rejection_classification.sh
#          No cloud access or credentials required.
# Inputs:  the real scripts/setup.sh source (statically inspected; not sourced,
#          because setup.sh changes directory and touches Azure CLI env at load).
# Outputs: a pass line on stdout; non-zero exit on the first failed assertion.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETUP="${ROOT_DIR}/scripts/setup.sh"

# Extract validate_observability, from its definition to the terminating brace.
block="$(awk '
  /^validate_observability\(\) \{/ { capture = 1 }
  capture { print }
  capture && /^\}$/ { exit }
' "${SETUP}")"

if [[ -z "${block}" ]]; then
  echo "could not locate validate_observability in setup.sh" >&2
  exit 1
fi

# The zero-record branch must still be a hard failure (die), not a PASS/return.
if ! grep -Eq 'container_rows.*-eq 0' <<<"${block}"; then
  echo "validate_observability must test the ContainerLogV2 zero-record case" >&2
  echo "${block}" >&2
  exit 1
fi

zero_record_die="$(awk '
  /container_rows.*-eq 0/ { capture = 1 }
  capture { print }
  capture && /die / { exit }
' <<<"${block}")"

if ! grep -q 'die ' <<<"${zero_record_die}"; then
  echo "zero-record ContainerLogV2 case must call die (must not downgrade to PASS)" >&2
  echo "${block}" >&2
  exit 1
fi

# The failure must identify both the documented latency window and the ODS 403
# diagnostic without claiming that zero records alone prove either cause.
for token in '15 minutes' '403' 'MaODSRequest' 'ODS' 'service-side'; do
  if ! grep -qF "${token}" <<<"${zero_record_die}"; then
    echo "zero-record diagnostic must classify the Azure ODS rejection (missing: ${token})" >&2
    echo "${zero_record_die}" >&2
    exit 1
  fi
done

# The old wait-and-retry-only wording must not be the message.
if grep -q 'Run this again after Azure Monitor ingestion catches up' <<<"${zero_record_die}"; then
  echo "zero-record diagnostic must not imply transient ingestion lag is the only cause" >&2
  echo "${zero_record_die}" >&2
  exit 1
fi

echo "validate_observability fails on empty ContainerLogV2 and explains ODS 403 diagnosis ok"
