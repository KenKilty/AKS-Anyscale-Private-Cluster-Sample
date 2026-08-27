#!/usr/bin/env bash
# Offline regression check for jump-host execution-mode enforcement.
#
# Purpose: prove scripts/setup.sh invoke_jump_host_bootstrap forces exactly one
#          ANYSCALE_EXECUTION_MODE=jump-host into the jump-host .env after the
#          copy, mirroring scripts/modules/module-2-jump-host.sh. Without this
#          the synced .env keeps the workstation mode and Module 4 proof on the
#          jump host demands Terraform before submission.
# Usage:   ./scripts/tests/test_jump_host_env_execution_mode.sh
#          No cloud access or credentials required.
# Inputs:  the real scripts/setup.sh source (source contract) and a replica of
#          the remote enforcement snippet exercised against temp .env files.
# Outputs: a pass line on stdout; non-zero exit on the first failed assertion.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETUP="${ROOT_DIR}/scripts/setup.sh"

# --- Source contract: enforcement lives in the .env copy block of setup.sh ---
copy_block="$(awk '
  /log "Copying \.env and forcing jump-host execution mode on the VM\.\.\."/ { capture = 1 }
  capture { print }
  capture && /^  fi$/ { exit }
' "${SETUP}")"

if [[ -z "${copy_block}" ]]; then
  echo "could not locate the jump-host .env copy block in setup.sh" >&2
  exit 1
fi

grep -q "grep -q '\^ANYSCALE_EXECUTION_MODE=' '\${canonical_repo_path}/.env'" <<<"${copy_block}" ||
  {
    echo "copy block missing ANYSCALE_EXECUTION_MODE grep guard" >&2
    exit 1
  }
grep -q "sed -i 's/\^ANYSCALE_EXECUTION_MODE=.\*/ANYSCALE_EXECUTION_MODE=jump-host/'" <<<"${copy_block}" ||
  {
    echo "copy block missing ANYSCALE_EXECUTION_MODE sed rewrite" >&2
    exit 1
  }
grep -q "printf '\\\\nANYSCALE_EXECUTION_MODE=jump-host\\\\n' >> '\${canonical_repo_path}/.env'" <<<"${copy_block}" ||
  {
    echo "copy block missing ANYSCALE_EXECUTION_MODE printf append" >&2
    exit 1
  }

# --- Behavior: replicate the remote enforcement against temp .env files ------
# Portable in-place sed wrapper (GNU sed -i vs BSD sed -i '').
enforce() {
  local envfile="$1"
  if grep -q '^ANYSCALE_EXECUTION_MODE=' "${envfile}"; then
    if sed --version >/dev/null 2>&1; then
      sed -i 's/^ANYSCALE_EXECUTION_MODE=.*/ANYSCALE_EXECUTION_MODE=jump-host/' "${envfile}"
    else
      sed -i '' 's/^ANYSCALE_EXECUTION_MODE=.*/ANYSCALE_EXECUTION_MODE=jump-host/' "${envfile}"
    fi
  else
    printf '\nANYSCALE_EXECUTION_MODE=jump-host\n' >>"${envfile}"
  fi
}

count_mode() { grep -c '^ANYSCALE_EXECUTION_MODE=jump-host$' "$1"; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/jump-host-env.XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT

# 1) Absent -> exactly one enforced line appended, other keys untouched.
printf 'TF_VAR_project=proj\nOTHER=1\n' >"${tmp}/absent.env"
enforce "${tmp}/absent.env"
[[ "$(count_mode "${tmp}/absent.env")" -eq 1 ]] ||
  {
    echo "absent: expected exactly one jump-host line" >&2
    exit 1
  }
grep -q '^TF_VAR_project=proj$' "${tmp}/absent.env" ||
  {
    echo "absent: clobbered unrelated keys" >&2
    exit 1
  }

# 2) Wrong value -> rewritten in place to jump-host, still exactly one line.
printf 'ANYSCALE_EXECUTION_MODE=workstation\nOTHER=1\n' >"${tmp}/wrong.env"
enforce "${tmp}/wrong.env"
[[ "$(count_mode "${tmp}/wrong.env")" -eq 1 ]] ||
  {
    echo "wrong: expected exactly one jump-host line" >&2
    exit 1
  }
grep -q '^ANYSCALE_EXECUTION_MODE=workstation$' "${tmp}/wrong.env" &&
  {
    echo "wrong: stale workstation value remains" >&2
    exit 1
  }

# 3) Already correct -> idempotent, no duplicate line.
printf 'ANYSCALE_EXECUTION_MODE=jump-host\nOTHER=1\n' >"${tmp}/correct.env"
enforce "${tmp}/correct.env"
[[ "$(count_mode "${tmp}/correct.env")" -eq 1 ]] ||
  {
    echo "correct: enforcement is not idempotent" >&2
    exit 1
  }

echo "setup.sh forces exactly one ANYSCALE_EXECUTION_MODE=jump-host on the synced .env ok"
