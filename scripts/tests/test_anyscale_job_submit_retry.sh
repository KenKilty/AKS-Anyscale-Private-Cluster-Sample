#!/usr/bin/env bash
# Offline unit test for the Anyscale job-submission retry policy.
#
# Purpose: assert that should_retry_anyscale_job_submission retries only the
#          transient image-build and HTTP 500 failures, and only on attempt 1.
# Usage:   ./scripts/tests/test_anyscale_job_submit_retry.sh
#          No cloud access or credentials required.
# Inputs:  none; the test writes its own fixture logs to a temp directory.
# Outputs: a pass line on stdout; non-zero exit on the first failed assertion.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/anyscale-job-submit.sh
source "${ROOT_DIR}/scripts/lib/anyscale-job-submit.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

retryable_log="${work_dir}/retryable.log"
cat >"${retryable_log}" <<'EOF'
Error: API Exception (500) from POST /api/v2/builds/get_or_create_build_from_image_uri
Reason: Internal Server Error
EOF

non_retryable_log="${work_dir}/non-retryable.log"
cat >"${non_retryable_log}" <<'EOF'
Error: Invalid image URI specified
EOF

if ! should_retry_anyscale_job_submission "${retryable_log}" 1; then
  echo "expected retryable error to be classified as retryable" >&2
  exit 1
fi

if should_retry_anyscale_job_submission "${non_retryable_log}" 1; then
  echo "expected non-retryable error to be classified as non-retryable" >&2
  exit 1
fi

upgrade_script="$(workspace_anyscale_cli_upgrade_script)"
if [[ "${upgrade_script}" != *"anyscale>=0.26.103"* ]]; then
  echo "expected workspace CLI upgrade script to pin a new enough anyscale release" >&2
  exit 1
fi
if [[ "${upgrade_script}" != *"anyscale version"* ]]; then
  echo "expected workspace CLI upgrade script to print the installed version" >&2
  exit 1
fi

echo "anyscale job submission retry classification ok"
