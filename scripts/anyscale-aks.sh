#!/usr/bin/env bash
# Public command dispatcher for the Anyscale-on-AKS sample.
# Keep this file focused on routing, help text, and read-only local checks.
# Core deploy, proof, and teardown behavior is delegated to setup.sh during the refactor.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SETUP_SCRIPT="${SCRIPT_DIR}/setup.sh"
DIAGNOSE_WORKSPACE_ARTIFACTS_SCRIPT="${SCRIPT_DIR}/utility/diagnose-workspace-artifacts.py"
TIMEOUT_SELF_TEST_SCRIPT="${SCRIPT_DIR}/utility/test-timeouts.sh"
TERRAFORM_DIR="${ROOT_DIR}/infra/terraform"
MODULE_1_SCRIPT="${SCRIPT_DIR}/modules/module-1-foundation.sh"
MODULE_2_SCRIPT="${SCRIPT_DIR}/modules/module-2-jump-host.sh"
MODULE_3_SCRIPT="${SCRIPT_DIR}/modules/module-3-workload.sh"
MODULE_4_SCRIPT="${SCRIPT_DIR}/modules/module-4-custom-image.sh"
MODULE_5_SCRIPT="${SCRIPT_DIR}/modules/module-5-image-integrity.sh"
RESULTS_FILE="${ROOT_DIR}/RESULTS.md"

usage() {
  cat <<'USAGE'
Usage: ./scripts/anyscale-aks.sh COMMAND [ARGS]

Learning modules (recommended):
  module 1 {sizes|plan|apply|connect|verify|browser ...}
      Build the foundation (network, Bastion, jump hosts, DNS, egress).

  module 2 {bootstrap|sync|doctor|verify|browser verify}
      Prepare the Linux jump host and verify the optional Windows browser host.

  module 3 {deploy|verify|proof ...|browser validate|teardown}
      Deploy, verify, prove, and tear down the lab workload.

  module 4 {prove-failure|preflight|prepare|apply|proof}
      Prove the custom-image requirement and build the private-ACR image.

Compatibility commands:
  deploy [--from-scratch --yes]
      Build or reconcile Azure infrastructure, AKS bootstrap, Anyscale platform,
      compute configs, and durable workspaces.

  verify [--static|--live|--full] [--skip-observability]
      Run static and/or live validation.

  proof {cpu|gpu|pipeline|all}
      Run deterministic workload proofs. This is the public alias for the
      existing workload proof runner.

  custom-image {preflight|prepare|apply|proof|prove-failure}
      Build/push the local custom image with Podman, update workspaces, and
      prove the packaged dependency scenario.

  workload proof {cpu|gpu|pipeline|all}
      Compatibility spelling for proof commands.

  teardown [--force --yes] [--confirm-project <name>]
      Tear down with staged Terraform destroy, or use --force for a
      resource-group reset. Pass --confirm-project <name> to skip the
      interactive project-name confirmation in non-interactive runs.

  e2e [--mode workstation|jump-host] [--skip-verify] [--skip-proof] [--include-browser-precheck] [--teardown|--force-teardown --yes]
      Compose deploy, verify, proof all, and optional cleanup. jump-host mode
      runs the same Module 3 stages from inside the VNet with direct private
      AKS access.

  status
      Read-only local/Azure/Terraform status summary.

  doctor
      Check local tool and auth readiness without deploying.

  tunnel {start|status|stop} [--port PORT]
      Manage the Bastion-backed AKS API tunnel.

  browser {open|ready|status|stop} [ARGS]
      Manage Bastion-backed workspace browser helpers.

  head {open|status|stop} [ARGS]
      Manage direct workspace head-node browser helpers.

  kubeconfig {write|print|export} [--admin]
      Write or print the Bastion-backed kubeconfig.

  diagnose workspace-artifacts [ARGS]
      Capture Anyscale workspace artifact and storage-log diagnostics.

  diagrams export
      Export docs/Architecture-Diagram.drawio to docs/Architecture-Diagram.svg.

  self-test {timeouts|idempotency} [ARGS]
      Run harness self-tests.
USAGE
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

dependency_hint() {
  case "$1" in
    git) printf 'Install Git: https://git-scm.com/downloads or `brew install git`.\n' ;;
    az) printf 'Install Azure CLI: https://learn.microsoft.com/cli/azure/install-azure-cli or `brew install azure-cli`.\n' ;;
    terraform) printf 'Install Terraform: https://developer.hashicorp.com/terraform/install.\n' ;;
    kubectl) printf 'Install kubectl: https://kubernetes.io/docs/tasks/tools/ or `az aks install-cli`.\n' ;;
    kubelogin) printf 'Install kubelogin: https://azure.github.io/kubelogin/ or `brew install Azure/kubelogin/kubelogin`.\n' ;;
    helm) printf 'Install Helm: https://helm.sh/docs/intro/install/ or `brew install helm`.\n' ;;
    jq) printf 'Install jq: https://jqlang.github.io/jq/download/ or `brew install jq`.\n' ;;
    rsync) printf 'Install rsync: https://rsync.samba.org/ or `brew install rsync`.\n' ;;
    python3) printf 'Install Python 3: https://www.python.org/downloads/ or `brew install python`.\n' ;;
    uv) printf 'Install uv: https://docs.astral.sh/uv/getting-started/installation/ or `brew install uv`.\n' ;;
    curl) printf 'Install curl: https://curl.se/download.html or `brew install curl` if your system image does not include it.\n' ;;
    lsof) printf 'Install lsof or use a system image that includes it; macOS includes `/usr/sbin/lsof`.\n' ;;
    shellcheck) printf 'Install ShellCheck: https://www.shellcheck.net/ or `brew install shellcheck`. Optional lint tool.\n' ;;
    anyscale) printf 'Install the Anyscale CLI in the repo venv: `uv venv .venv && UV_CACHE_DIR="$PWD/.cache/uv-cache" uv pip install --python .venv/bin/python anyscale`.\n' ;;
    drawio) printf 'Install diagrams.net/draw.io desktop app or CLI: https://www.diagrams.net/. Required only for diagram export.\n' ;;
    podman) printf 'Install Podman yourself before custom-image prepare. On macOS: `brew install podman`, then create/start a Podman machine manually.\n' ;;
    *) printf 'Install `%s` and make sure it is on PATH.\n' "$1" ;;
  esac
}

has_drawio_cli() {
  resolve_drawio_cli >/dev/null 2>&1
}

resolve_drawio_cli() {
  local candidate
  for candidate in drawio draw.io diagramsnet diagrams.net; do
    if command -v "${candidate}" >/dev/null 2>&1; then
      command -v "${candidate}"
      return 0
    fi
  done

  local mac_app="/Applications/draw.io.app/Contents/MacOS/draw.io"
  if [[ -x "${mac_app}" ]]; then
    printf '%s\n' "${mac_app}"
    return 0
  fi

  return 1
}

check_commands() {
  local context="$1"
  shift

  local dependency missing_count=0
  local -a missing_dependencies=()

  for dependency in "$@"; do
    if [[ "${dependency}" == "anyscale" ]]; then
      [[ -x "${ROOT_DIR}/.venv/bin/anyscale" ]] && continue
    elif command -v "${dependency}" >/dev/null 2>&1; then
      continue
    fi

    missing_dependencies+=("${dependency}")
    ((missing_count += 1))
  done

  if (( missing_count == 0 )); then
    return 0
  fi

  printf 'Missing required dependencies for %s:\n' "${context}" >&2
  for dependency in "${missing_dependencies[@]}"; do
    printf '  - %s: ' "${dependency}" >&2
    dependency_hint "${dependency}" >&2
  done
  printf '\nRun `./scripts/anyscale-aks.sh doctor` for a full local readiness report.\n' >&2
  return 1
}

check_drawio_dependency() {
  local context="$1"

  if has_drawio_cli; then
    return 0
  fi

  printf 'Missing required dependency for %s:\n' "${context}" >&2
  printf '  - drawio: ' >&2
  dependency_hint drawio >&2
  return 1
}

check_dependencies_for() {
  local context="$1"
  shift

  case "${context}" in
    deploy|verify|teardown|idempotency)
      check_commands "${context}" git az terraform kubectl kubelogin helm jq rsync python3 uv anyscale curl lsof
      ;;
    proof|workload)
      if [[ "${ANYSCALE_EXECUTION_MODE:-workstation}" == "jump-host" ]]; then
        check_commands "${context}" az kubectl kubelogin helm jq rsync python3 uv anyscale curl lsof
      else
        check_commands "${context}" az terraform kubectl kubelogin helm jq rsync python3 uv anyscale curl lsof
      fi
      ;;
    custom-image)
      case "${1:-}" in
        preflight|prepare|proof)
          check_commands "${context} ${1:-}" az terraform kubectl kubelogin helm jq rsync python3 uv anyscale curl lsof podman
          ;;
        sign|verify)
          check_commands "${context} ${1:-}" az terraform jq podman notation
          ;;
        apply|prove-failure)
          check_commands "${context} ${1:-}" az terraform kubectl kubelogin helm jq rsync python3 uv anyscale curl lsof
          ;;
        *)
          check_commands "${context}" az terraform jq podman
          ;;
      esac
      ;;
    image-integrity)
      case "${1:-}" in
        apply-ratify)
          check_commands "${context} ${1:-}" az terraform kubectl kubelogin jq envsubst
          ;;
        *)
          check_commands "${context}" az
          ;;
      esac
      ;;
    e2e)
      check_commands "${context}" git az terraform kubectl kubelogin helm jq rsync python3 uv anyscale curl lsof
      ;;
    tunnel|browser|head|kubeconfig)
      check_commands "${context}" az kubectl kubelogin jq python3 curl lsof
      ;;
    diagrams)
      check_drawio_dependency "${context}"
      ;;
    diagnose)
      check_commands "${context}" az terraform jq python3 anyscale
      ;;
    self-test)
      check_commands "${context}" bash
      ;;
    *)
      return 0
      ;;
  esac
}

is_help_request() {
  [[ $# -eq 0 || "${1:-}" == "--help" || "${1:-}" == "-h" ]]
}

run_setup() {
  "${SETUP_SCRIPT}" "$@"
}

source_env_if_present() {
  if [[ -f "${ROOT_DIR}/.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/.env"
    set +a
  fi
}

resource_group_name() {
  printf 'rg-%s-%s-%s\n' \
    "${TF_VAR_project:-unknown}" \
    "${TF_VAR_environment:-unknown}" \
    "${TF_VAR_region_short:-unknown}"
}

latest_run_summary() {
  local latest_run=""

  latest_run="$(find "${ROOT_DIR}/.cache/aks-anyscale-sample-harness/runs" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -name '*-*' \
    -print 2>/dev/null | sort | tail -n 1 || true)"

  if [[ -n "${latest_run}" && -f "${latest_run}/summary.md" ]]; then
    printf '%s\n' "${latest_run#${ROOT_DIR}/}"
    return 0
  fi

  return 1
}

terraform_state_status() {
  local terraform_dir="${1:-${TERRAFORM_DIR}}"

  if [[ -f "${terraform_dir}/terraform.tfstate" ]]; then
    printf 'present\n'
  elif find "${terraform_dir}/terraform.tfstate.d" -type f -print -quit 2>/dev/null | grep -q .; then
    printf 'workspace-state-present\n'
  else
    printf 'absent\n'
  fi
}

status() {
  local resource_group=""
  local group_exists="unknown"
  local state_status="absent"
  local latest_summary=""

  source_env_if_present
  resource_group="$(resource_group_name)"

  if command -v az >/dev/null 2>&1 && [[ "${resource_group}" != *unknown* ]]; then
    group_exists="$(az group exists --name "${resource_group}" --output tsv --only-show-errors 2>/dev/null || printf 'unknown')"
  fi

  state_status="$(terraform_state_status "${TERRAFORM_DIR}")"

  printf 'project=%s\n' "${TF_VAR_project:-unknown}"
  printf 'environment=%s\n' "${TF_VAR_environment:-unknown}"
  printf 'location=%s\n' "${TF_VAR_azure_location:-unknown}"
  printf 'resource_group=%s\n' "${resource_group}"
  printf 'resource_group_exists=%s\n' "${group_exists}"
  printf 'terraform_state=%s\n' "${state_status}"

  if latest_summary="$(latest_run_summary)"; then
    printf 'latest_run_summary=%s/summary.md\n' "${latest_summary}"
  else
    printf 'latest_run_summary=none\n'
  fi
}

results_overall_status() {
  if [[ "${RESULTS_DEPLOY_STATUS}" == "FAIL" \
    || "${RESULTS_VERIFY_STATUS}" == "FAIL" \
    || "${RESULTS_CUSTOM_IMAGE_STATUS}" == "FAIL" \
    || "${RESULTS_PROOF_STATUS}" == "FAIL" \
    || "${RESULTS_TEARDOWN_STATUS}" == "FAIL" ]]; then
    printf 'FAIL\n'
  elif [[ "${RESULTS_DEPLOY_STATUS}" == "RUNNING" || "${RESULTS_DEPLOY_STATUS}" == "PENDING" \
    || "${RESULTS_VERIFY_STATUS}" == "RUNNING" || "${RESULTS_VERIFY_STATUS}" == "PENDING" \
    || "${RESULTS_CUSTOM_IMAGE_STATUS}" == "RUNNING" || "${RESULTS_CUSTOM_IMAGE_STATUS}" == "PENDING" \
    || "${RESULTS_PROOF_STATUS}" == "RUNNING" || "${RESULTS_PROOF_STATUS}" == "PENDING" \
    || "${RESULTS_TEARDOWN_STATUS}" == "RUNNING" || "${RESULTS_TEARDOWN_STATUS}" == "PENDING" ]]; then
    printf 'RUNNING\n'
  elif [[ "${RESULTS_DEPLOY_STATUS}" == "SKIP" \
    && "${RESULTS_VERIFY_STATUS}" == "SKIP" \
    && "${RESULTS_CUSTOM_IMAGE_STATUS}" == "SKIP" \
    && "${RESULTS_PROOF_STATUS}" == "SKIP" \
    && "${RESULTS_TEARDOWN_STATUS}" == "SKIP" ]]; then
    printf 'SKIP\n'
  else
    printf 'PASS\n'
  fi
}

results_evidence_lines() {
  local roots=()
  local latest_summary latest_run_dir
  local evidence_file evidence_tmp

  [[ -n "${RESULTS_RUN_DIR:-}" && -d "${RESULTS_RUN_DIR}" ]] && roots+=("${RESULTS_RUN_DIR}")
  if latest_summary="$(latest_run_summary 2>/dev/null)"; then
    latest_run_dir="${ROOT_DIR}/${latest_summary}"
    [[ -d "${latest_run_dir}" ]] && roots+=("${latest_run_dir}")
  fi

  if (( ${#roots[@]} == 0 )); then
    printf '_No evidence files have been written yet._\n'
    return 0
  fi

  evidence_tmp="$(mktemp "${TMPDIR:-/tmp}/anyscale-results-evidence.XXXXXX")"
  while IFS= read -r evidence_file; do
    [[ -n "${evidence_file}" ]] || continue
    grep -HnE 'CUSTOM_IMAGE_[A-Z_]+|IMAGE_INTEGRITY_[A-Z_]+|CPU_RAY_PROOF_OK|GPU_RAY_PROOF_OK|CPU_BUILD_JOB_PROOF_OK|GPU_TRAIN_JOB_PROOF_OK|GPU_SERVE_SERVICE_PROOF_OK|Job .* printed .*PROOF_OK|Service .* printed .*PROOF_OK|"state"[[:space:]]*:[[:space:]]*"SUCCEEDED"|service_state=RUNNING|primary_version_state=RUNNING|Workspace .* RUNNING' "${evidence_file}" 2>/dev/null >> "${evidence_tmp}" || true
  done < <(find "${roots[@]}" -type f \( -name '*.log' -o -name '*.json' -o -name 'summary.md' -o -name '*.txt' \) -print 2>/dev/null)

  if [[ -s "${evidence_tmp}" ]]; then
    sed "s#${ROOT_DIR}/##" "${evidence_tmp}" \
      | awk 'NF && !seen[$0]++ {print "- `" $0 "`"}' \
      | sed -n '1,80p'
  else
    printf '_No evidence files have been written yet._\n'
  fi
  rm -f "${evidence_tmp}"
}

teardown_fact() {
  local resource_group=""
  local group_exists="unknown"
  local state_status="absent"

  source_env_if_present
  resource_group="$(resource_group_name)"

  if command -v az >/dev/null 2>&1 && [[ "${resource_group}" != *unknown* ]]; then
    group_exists="$(az group exists --name "${resource_group}" --output tsv --only-show-errors 2>/dev/null || printf 'unknown')"
  fi

  state_status="$(terraform_state_status "${TERRAFORM_DIR}")"

  printf 'resource_group_exists=%s; terraform_state=%s' "${group_exists}" "${state_status}"
}

write_results_report() {
  local generated_at overall_status
  generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  overall_status="$(results_overall_status)"

  cat > "${RESULTS_FILE}" <<EOF
# Run Results

Generated: ${generated_at}
Started: ${RESULTS_STARTED_AT}
Command: ${RESULTS_COMMAND}
Overall: ${overall_status}

| Check | Result | Facts |
| --- | --- | --- |
| Build up | ${RESULTS_DEPLOY_STATUS} | ${RESULTS_DEPLOY_FACT} |
| Validation | ${RESULTS_VERIFY_STATUS} | ${RESULTS_VERIFY_FACT} |
| Custom image | ${RESULTS_CUSTOM_IMAGE_STATUS} | ${RESULTS_CUSTOM_IMAGE_FACT} |
| Workloads | ${RESULTS_PROOF_STATUS} | ${RESULTS_PROOF_FACT} |
| Teardown | ${RESULTS_TEARDOWN_STATUS} | ${RESULTS_TEARDOWN_FACT} |

Logs: ${RESULTS_LOG_FACT}

## Evidence From Logs

The lines below are copied from local run logs and status files so the report shows why each PASS claim is credible.

$(results_evidence_lines)
EOF
}

results_latest_summary_fact() {
  local latest_summary=""

  if latest_summary="$(latest_run_summary)"; then
    printf '%s/summary.md' "${latest_summary}"
  else
    printf 'No summary file found yet.'
  fi
}

run_e2e_step() {
  local status_var="$1"
  local fact_var="$2"
  local running_fact="$3"
  local pass_fact="$4"
  shift 4

  local exit_code=0 latest_summary="" step_log=""

  step_log="${RESULTS_RUN_DIR}/$(printf '%02d' "${RESULTS_STEP_INDEX}")-${status_var#RESULTS_}.log"
  RESULTS_STEP_INDEX=$((RESULTS_STEP_INDEX + 1))

  printf -v "${status_var}" '%s' 'RUNNING'
  printf -v "${fact_var}" '%s' "${running_fact}; log=${step_log#${ROOT_DIR}/}"
  write_results_report
  printf '[e2e] %s Log: %s\n' "${running_fact}" "${step_log#${ROOT_DIR}/}"

  set +e
  "$@" > "${step_log}" 2>&1
  exit_code=$?
  set -e

  latest_summary="$(results_latest_summary_fact)"
  RESULTS_LOG_FACT="Latest summary: ${latest_summary}; e2e logs: ${RESULTS_RUN_DIR#${ROOT_DIR}/}"

  if (( exit_code == 0 )); then
    printf -v "${status_var}" '%s' 'PASS'
    if [[ "${status_var}" == "RESULTS_TEARDOWN_STATUS" ]]; then
      printf -v "${fact_var}" '%s' "${pass_fact}; $(teardown_fact); ${latest_summary}; log=${step_log#${ROOT_DIR}/}"
    else
      printf -v "${fact_var}" '%s' "${pass_fact}; ${latest_summary}; log=${step_log#${ROOT_DIR}/}"
    fi
    printf '[e2e] %s\n' "${pass_fact}"
  else
    printf -v "${status_var}" '%s' 'FAIL'
    printf -v "${fact_var}" '%s' "exit_code=${exit_code}; ${latest_summary}; log=${step_log#${ROOT_DIR}/}"
    printf '[e2e] Step failed with exit code %s. Tail of %s:\n' "${exit_code}" "${step_log#${ROOT_DIR}/}" >&2
    tail -n 40 "${step_log}" >&2 || true
  fi

  write_results_report
  return "${exit_code}"
}

doctor() {
  local missing=0
  local command_name
  local doctor_log=""
  local required_commands=(git az terraform kubectl kubelogin helm jq rsync python3 uv curl lsof)
  local optional_commands=(shellcheck drawio podman)

  for command_name in "${required_commands[@]}"; do
    if command -v "${command_name}" >/dev/null 2>&1; then
      printf 'ok: %s\n' "${command_name}"
    else
      printf 'missing: %s\n' "${command_name}"
      printf '  '
      dependency_hint "${command_name}"
      missing=1
    fi
  done

  for command_name in "${optional_commands[@]}"; do
    if [[ "${command_name}" == "drawio" ]] && has_drawio_cli; then
      printf 'ok: %s\n' "${command_name}"
    elif [[ "${command_name}" != "drawio" ]] && command -v "${command_name}" >/dev/null 2>&1; then
      printf 'ok: %s\n' "${command_name}"
    else
      printf 'optional-missing: %s\n' "${command_name}"
      printf '  '
      dependency_hint "${command_name}"
    fi
  done

  if [[ -f "${ROOT_DIR}/.env" ]]; then
    printf 'ok: .env\n'
  else
    printf 'missing: .env\n'
    missing=1
  fi

  if [[ -x "${ROOT_DIR}/.venv/bin/anyscale" ]]; then
    printf 'ok: .venv/bin/anyscale\n'
  else
    printf 'missing: .venv/bin/anyscale\n'
    printf '  '
    dependency_hint anyscale
    missing=1
  fi

  if [[ -d "${TERRAFORM_DIR}/.terraform" ]]; then
    printf 'ok: terraform initialized\n'
  else
    printf 'missing: terraform initialized\n'
    missing=1
  fi

  printf '\nScenario readiness:\n'
  source_env_if_present
  local execution_mode="${ANYSCALE_EXECUTION_MODE:-workstation}"
  printf 'info: execution mode = %s\n' "${execution_mode}"
  if [[ "${execution_mode}" == "jump-host" ]]; then
    if az account show --query user.type -o tsv --only-show-errors 2>/dev/null | grep -q .; then
      local az_user_type
      az_user_type="$(az account show --query user.type -o tsv --only-show-errors 2>/dev/null || true)"
      printf 'ok: Azure CLI authenticated (user.type=%s)\n' "${az_user_type:-unknown}"
      if [[ "${az_user_type}" != "servicePrincipal" ]]; then
        printf '  note: jump-host expects managed-identity (servicePrincipal) auth via: az login --identity\n'
      fi
    else
      printf 'not-ready: Azure CLI authentication (jump-host)\n'
      printf '  Run on the jump host: az login --identity\n'
      missing=1
    fi
  else
    if az account show >/dev/null 2>&1; then
      printf 'ok: Azure CLI authenticated (workstation)\n'
    else
      printf 'not-ready: Azure CLI authentication (workstation)\n'
      printf '  Run: az login\n'
      missing=1
    fi
  fi
  if [[ -z "${ANYSCALE_CLI_TOKEN:-}" ]]; then
    unset ANYSCALE_CLI_TOKEN
  fi
  if [[ -x "${ROOT_DIR}/.venv/bin/anyscale" ]]; then
    if ANYSCALE_HOST="${ANYSCALE_HOST:-https://console.azure.anyscale.com}" \
      "${ROOT_DIR}/.venv/bin/anyscale" cloud list --max-items 1 --page-size 1 --no-interactive --json >/dev/null 2>&1; then
      printf 'ok: Anyscale CLI OAuth/API-key auth\n'
    else
      printf 'not-ready: Anyscale CLI OAuth/API-key auth\n'
      printf '  Run: ANYSCALE_HOST=https://console.azure.anyscale.com .venv/bin/anyscale login\n'
      missing=1
    fi
  fi

  if command -v podman >/dev/null 2>&1; then
    if podman info >/dev/null 2>&1; then
      printf 'ok: podman ready\n'
    else
      printf 'not-ready: podman installed but machine is not ready\n'
      missing=1
    fi
  fi

  # Image signing toolchain (jump-host tool; informational on the workstation).
  if command -v notation >/dev/null 2>&1; then
    if notation plugin ls 2>/dev/null | grep -q 'azure-kv'; then
      printf 'ok: notation + azure-kv plugin (image signing)\n'
    else
      printf 'not-ready: notation present but azure-kv plugin missing (image signing)\n'
      printf '  Re-run scripts/bootstrap-jump-host.sh on the jump host.\n'
    fi
  else
    printf 'info: notation not installed (image signing); installed by the jump host bootstrap\n'
  fi

  if command -v az >/dev/null 2>&1; then
    local image_integrity_feature_state
    image_integrity_feature_state="$(az feature show --namespace Microsoft.ContainerService --name EnableImageIntegrityPreview --query properties.state -o tsv --only-show-errors 2>/dev/null || echo Unknown)"
    if [[ "${image_integrity_feature_state}" == "Registered" ]]; then
      printf 'ok: EnableImageIntegrityPreview feature registered\n'
    else
      printf 'info: EnableImageIntegrityPreview feature is %s (managed by Terraform azapi_resource)\n' "${image_integrity_feature_state}"
    fi
  fi

  if [[ -f "${ROOT_DIR}/.env" && -d "${TERRAFORM_DIR}/.terraform" && -x "${SETUP_SCRIPT}" ]]; then
    doctor_log="${TMPDIR:-${ROOT_DIR}/.cache}/anyscale-custom-image-preflight.$$.log"
    if run_setup custom-image preflight >"${doctor_log}" 2>&1; then
      printf 'ok: custom-image local ACR build/push readiness\n'
    else
      printf 'not-ready: custom-image local ACR build/push readiness\n'
      sed -n '1,80p' "${doctor_log}" | sed 's/^/  /'
      missing=1
    fi
  fi

  return "${missing}"
}

e2e() {
  local skip_verify=false
  local skip_proof=false
  local run_custom_image=false
  local teardown_mode="none"
  local yes=false
  local mode="${ANYSCALE_EXECUTION_MODE:-workstation}"
  local mode_explicit=false
  local include_browser_precheck=false
  local -a original_args=("$@")

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)
        shift
        [[ $# -gt 0 ]] || die "--mode requires a value: workstation|jump-host"
        mode="$1"
        mode_explicit=true
        shift
        ;;
      --mode=*)
        mode="${1#*=}"
        mode_explicit=true
        shift
        ;;
      --include-browser-precheck)
        include_browser_precheck=true
        shift
        ;;
      --skip-verify)
        skip_verify=true
        shift
        ;;
      --skip-proof)
        skip_proof=true
        shift
        ;;
      --custom-image)
        run_custom_image=true
        shift
        ;;
      --skip-teardown)
        teardown_mode="none"
        shift
        ;;
      --teardown)
        teardown_mode="terraform"
        shift
        ;;
      --force-teardown)
        teardown_mode="force"
        shift
        ;;
      --yes|-y)
        yes=true
        shift
        ;;
      --help|-h)
        cat <<'USAGE'
Usage:
  ./scripts/anyscale-aks.sh e2e [--mode workstation|jump-host] [--custom-image]
      [--skip-verify] [--skip-proof] [--include-browser-precheck]
      [--teardown|--force-teardown --yes]

workstation mode (default): runs deploy, then verify --full, proof all, and
optional teardown.

jump-host mode: runs the same Module 3 stages from inside the VNet with direct
private AKS access. Interactive browser validation is skipped. Use
--include-browser-precheck to run non-interactive browser-host checks. The run
overwrites root RESULTS.md with a concise local summary.

Requires Module 1 applied and Module 2 bootstrapped first when using jump-host
mode.
USAGE
        return 0
        ;;
      *)
        die "Unknown e2e option: $1"
        ;;
    esac
  done

  case "${mode}" in
    workstation) ;;
    jump-host)
      export ANYSCALE_EXECUTION_MODE="jump-host"
      ;;
    *)
      die "Invalid --mode '${mode}'. Use workstation or jump-host."
      ;;
  esac
  [[ "${mode_explicit}" == true ]] && log "e2e execution mode: ${mode}"

  RESULTS_STARTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  RESULTS_COMMAND="./scripts/anyscale-aks.sh e2e ${original_args[*]}"
  RESULTS_RUN_DIR="${ROOT_DIR}/.cache/aks-anyscale-sample-harness/e2e/$(date -u '+%Y%m%dT%H%M%SZ')"
  RESULTS_STEP_INDEX=1
  RESULTS_DEPLOY_STATUS="PENDING"
  RESULTS_VERIFY_STATUS="SKIP"
  RESULTS_CUSTOM_IMAGE_STATUS="SKIP"
  RESULTS_PROOF_STATUS="SKIP"
  RESULTS_TEARDOWN_STATUS="SKIP"
  RESULTS_DEPLOY_FACT="Not started."
  RESULTS_VERIFY_FACT="Skipped by request."
  RESULTS_CUSTOM_IMAGE_FACT="Not requested. Use --custom-image to prove packaged dependency flow."
  RESULTS_PROOF_FACT="Skipped by request."
  RESULTS_TEARDOWN_FACT="Not requested. Use --teardown or --force-teardown --yes to prove cleanup."
  RESULTS_LOG_FACT="No run summary yet."
  mkdir -p "${RESULTS_RUN_DIR}"
  write_results_report

  run_e2e_step \
    RESULTS_DEPLOY_STATUS \
    RESULTS_DEPLOY_FACT \
    "Deploy is running." \
    "Deploy completed." \
    run_setup deploy || return $?

  if [[ "${skip_verify}" != true ]]; then
    run_e2e_step \
      RESULTS_VERIFY_STATUS \
      RESULTS_VERIFY_FACT \
      "Full verification is running." \
      "Full verification completed." \
      run_setup verify --full || return $?
  fi

  if [[ "${run_custom_image}" == true ]]; then
    run_e2e_step \
      RESULTS_CUSTOM_IMAGE_STATUS \
      RESULTS_CUSTOM_IMAGE_FACT \
      "Custom image flow is running." \
      "Custom image expected-failure, build, workspace update, and dependency proof completed." \
      custom_image_e2e_stage || return $?
  fi

  if [[ "${skip_proof}" != true ]]; then
    run_e2e_step \
      RESULTS_PROOF_STATUS \
      RESULTS_PROOF_FACT \
      "All workload proofs are running." \
      "All workload proofs completed." \
      run_setup workload proof all || return $?
  fi

  if [[ "${include_browser_precheck}" == true ]]; then
    log "Running non-interactive browser-host prerequisite checks (interactive browser validation is skipped)."
    bash "${MODULE_1_SCRIPT}" browser verify || warn "Browser-host precheck reported issues; see docs/modules/browser-access.md."
  fi

  if [[ "${teardown_mode}" != "none" ]]; then
    log "Note: interactive browser validation was skipped. To inspect console-launched workspace/service URLs, rerun without --teardown or run 'module 3 browser validate' before teardown."
  fi

  case "${teardown_mode}" in
    none)
      ;;
    terraform)
      source_env_if_present
      run_e2e_step \
        RESULTS_TEARDOWN_STATUS \
        RESULTS_TEARDOWN_FACT \
        "Terraform teardown is running." \
        "Terraform teardown completed." \
        run_setup teardown --confirm-project "${TF_VAR_project:-}" || return $?
      ;;
    force)
      if [[ "${yes}" == true ]]; then
        run_e2e_step \
          RESULTS_TEARDOWN_STATUS \
          RESULTS_TEARDOWN_FACT \
          "Force teardown is running." \
          "Force teardown completed." \
          run_setup teardown --force --yes || return $?
      else
        run_e2e_step \
          RESULTS_TEARDOWN_STATUS \
          RESULTS_TEARDOWN_FACT \
          "Force teardown is running." \
          "Force teardown completed." \
          run_setup teardown --force || return $?
      fi
      ;;
    *)
      die "Unknown teardown mode: ${teardown_mode}"
      ;;
  esac

  write_results_report
}

custom_image_e2e_stage() {
  run_setup custom-image prove-failure
  if ! run_setup custom-image preflight; then
    cat >&2 <<'EOF'

[e2e] Custom image prepare requires private network reachability to the ACR:
      - Bastion remains the AKS API path for kubectl/Terraform/Helm.
      - Run this stage from an in-VNet jump host with private DNS so the
        private ACR login and data endpoints resolve and are reachable.

      Resume with:
        ./scripts/anyscale-aks.sh custom-image prepare
        ANYSCALE_CUSTOM_IMAGE_ENABLED=true ./scripts/anyscale-aks.sh custom-image apply
        ANYSCALE_CUSTOM_IMAGE_ENABLED=true ./scripts/anyscale-aks.sh custom-image proof
        ./scripts/anyscale-aks.sh proof all
EOF
    return 1
  fi
  run_setup custom-image prepare
  ANYSCALE_CUSTOM_IMAGE_ENABLED=true run_setup custom-image apply
  ANYSCALE_CUSTOM_IMAGE_ENABLED=true run_setup custom-image proof
}

proof() {
  local target="${1:-}"

  case "${target}" in
    ""|--help|-h)
      cat <<'USAGE'
Usage:
  ./scripts/anyscale-aks.sh proof {cpu|gpu|pipeline|all} [--command-timeout-seconds N]

Targets:
  cpu       Durable CPU workspace proof.
  gpu       Durable GPU workspace proof.
  pipeline  CPU build job, GPU train job, and GPU Serve proof.
  all       CPU, GPU, and full build/train/serve pipeline.
USAGE
      return 0
      ;;
    cpu|gpu|pipeline|all)
      shift
      run_setup workload proof "${target}" "$@"
      ;;
    build|train|serve)
      die "proof ${target} is planned but not yet implemented as an isolated target; use proof pipeline or proof all."
      ;;
    *)
      die "Usage: ./scripts/anyscale-aks.sh proof {cpu|gpu|pipeline|all}"
      ;;
  esac
}

custom_image() {
  local action="${1:-}"
  case "${action}" in
    preflight|prepare|sign|verify|apply|proof|prove-failure)
      shift
      run_setup custom-image "${action}" "$@"
      ;;
    --help|-h|"")
      cat <<'USAGE'
Usage:
  ./scripts/anyscale-aks.sh custom-image preflight
  ./scripts/anyscale-aks.sh custom-image prepare
  ./scripts/anyscale-aks.sh custom-image sign
  ./scripts/anyscale-aks.sh custom-image verify
  ./scripts/anyscale-aks.sh custom-image prove-failure
  ./scripts/anyscale-aks.sh custom-image apply
  ./scripts/anyscale-aks.sh custom-image proof

preflight     Check local Podman, private DNS, ACR push role, and ACR auth.
prepare       Build and push the custom image with Podman.
sign          Sign the pushed image with Notation + the Key Vault certificate.
verify        Verify the image signature locally with Notation.
prove-failure Prove the standard image cannot runtime-install the dependency.
apply         Update durable workspaces to use the custom image.
proof         Prove the packaged dependency is available on the custom image.
USAGE
      ;;
    *)
      die "Usage: ./scripts/anyscale-aks.sh custom-image {preflight|prepare|sign|verify|apply|proof|prove-failure}"
      ;;
  esac
}

image_integrity() {
  local action="${1:-}"
  case "${action}" in
    preflight|apply-ratify)
      shift
      run_setup image-integrity "${action}" "$@"
      ;;
    --help|-h|"")
      cat <<'USAGE'
Usage:
  ./scripts/anyscale-aks.sh image-integrity preflight
  ./scripts/anyscale-aks.sh image-integrity apply-ratify

preflight     Check the EnableImageIntegrityPreview feature flag and aks-preview extension.
apply-ratify  Apply the Ratify verification CRDs (KeyManagementProvider/Store/Verifier).

Note: AKS Image Integrity is audit-only. Unsigned images are flagged
non-compliant in Azure Policy but are not blocked from running.
USAGE
      ;;
    *)
      die "Usage: ./scripts/anyscale-aks.sh image-integrity {preflight|apply-ratify}"
      ;;
  esac
}

tunnel() {
  local action="${1:-}"
  case "${action}" in
    start|status|stop)
      run_setup bastion-tunnel "$@"
      ;;
    --help|-h|"")
      cat <<'USAGE'
Usage:
  ./scripts/anyscale-aks.sh tunnel start [--port PORT]
  ./scripts/anyscale-aks.sh tunnel status
  ./scripts/anyscale-aks.sh tunnel stop
USAGE
      ;;
    *)
      die "Usage: ./scripts/anyscale-aks.sh tunnel {start|status|stop} [--port PORT]"
      ;;
  esac
}

browser() {
  local action="${1:-}"
  case "${action}" in
    open)
      shift
      run_setup workspace-browser-open start "$@"
      ;;
    ready)
      shift
      run_setup workspace-browser-ready start "$@"
      ;;
    status)
      run_setup workspace-browser-open status
      ;;
    stop)
      shift
      run_setup workspace-browser-open stop "$@"
      ;;
    --help|-h|"")
      cat <<'USAGE'
Usage:
  ./scripts/anyscale-aks.sh browser open --session-id ses_xxx [ARGS]
  ./scripts/anyscale-aks.sh browser ready --session-id ses_xxx [ARGS]
  ./scripts/anyscale-aks.sh browser status
  ./scripts/anyscale-aks.sh browser stop [--keep-network]
USAGE
      ;;
    *)
      die "Usage: ./scripts/anyscale-aks.sh browser {open|ready|status|stop}"
      ;;
  esac
}

head() {
  local action="${1:-}"
  case "${action}" in
    open)
      shift
      run_setup workspace-head-open start "$@"
      ;;
    status)
      run_setup workspace-head-open status
      ;;
    stop)
      shift
      run_setup workspace-head-open stop "$@"
      ;;
    --help|-h|"")
      cat <<'USAGE'
Usage:
  ./scripts/anyscale-aks.sh head open --session-id ses_xxx [ARGS]
  ./scripts/anyscale-aks.sh head status
  ./scripts/anyscale-aks.sh head stop [--keep-forward]
USAGE
      ;;
    *)
      die "Usage: ./scripts/anyscale-aks.sh head {open|status|stop}"
      ;;
  esac
}

kubeconfig() {
  local action="${1:-}"
  case "${action}" in
    write)
      shift
      run_setup kubeconfig-bastion "$@"
      ;;
    print)
      shift
      run_setup kubeconfig-bastion --print-path "$@"
      ;;
    export)
      shift
      run_setup kubeconfig-bastion --export "$@"
      ;;
    --help|-h|"")
      cat <<'USAGE'
Usage:
  ./scripts/anyscale-aks.sh kubeconfig write [--admin]
  ./scripts/anyscale-aks.sh kubeconfig print [--admin]
  ./scripts/anyscale-aks.sh kubeconfig export [--admin]
USAGE
      ;;
    *)
      die "Usage: ./scripts/anyscale-aks.sh kubeconfig {write|print|export} [--admin]"
      ;;
  esac
}

diagrams() {
  local action="${1:-}"
  case "${action}" in
    export)
      local source_diagram="${ROOT_DIR}/docs/Architecture-Diagram.drawio"
      local output_diagram="${ROOT_DIR}/docs/Architecture-Diagram.svg"
      local drawio_bin
      [[ -f "${source_diagram}" ]] || die "Missing diagram source: ${source_diagram}"
      drawio_bin="$(resolve_drawio_cli)" || die "No draw.io/diagrams.net CLI was found. Install the diagrams.net desktop/CLI, then rerun: ./scripts/anyscale-aks.sh diagrams export"
      if "${drawio_bin}" --export --format svg --output "${output_diagram}" "${source_diagram}" 2>/dev/null; then
        printf 'Exported %s\n' "${output_diagram#${ROOT_DIR}/}"
      else
        "${drawio_bin}" -x -f svg -o "${output_diagram}" "${source_diagram}"
        printf 'Exported %s\n' "${output_diagram#${ROOT_DIR}/}"
      fi
      ;;
    --help|-h|"")
      printf 'Usage: ./scripts/anyscale-aks.sh diagrams export\n'
      ;;
    *)
      die "Usage: ./scripts/anyscale-aks.sh diagrams export"
      ;;
  esac
}

self_test() {
  local target="${1:-}"
  case "${target}" in
    timeouts)
      shift
      bash "${TIMEOUT_SELF_TEST_SCRIPT}" "$@"
      ;;
    idempotency)
      shift
      run_setup idempotency "$@"
      ;;
    --help|-h|"")
      cat <<'USAGE'
Usage:
  ./scripts/anyscale-aks.sh self-test timeouts
  ./scripts/anyscale-aks.sh self-test idempotency [ARGS]
USAGE
      ;;
    *)
      die "Usage: ./scripts/anyscale-aks.sh self-test {timeouts|idempotency}"
      ;;
  esac
}

diagnose() {
  local target="${1:-}"
  local python_bin="${ROOT_DIR}/.venv/bin/python"

  case "${target}" in
    workspace-artifacts)
      shift
      if [[ ! -x "${python_bin}" ]]; then
        python_bin="python3"
      fi
      "${python_bin}" "${DIAGNOSE_WORKSPACE_ARTIFACTS_SCRIPT}" "$@"
      ;;
    --help|-h|"")
      cat <<'USAGE'
Usage:
  ./scripts/anyscale-aks.sh diagnose workspace-artifacts [ARGS]

Runs the workspace artifact diagnostic utility with the repo virtualenv Python
when available, falling back to python3.
USAGE
      ;;
    *)
      die "Usage: ./scripts/anyscale-aks.sh diagnose workspace-artifacts [ARGS]"
      ;;
  esac
}

maybe_emit_jump_host_hint() {
  # When running compatibility aliases in jump-host execution mode, point the
  # operator at the equivalent module-3 learning command. Skip the hint when the
  # caller already used a module-N wrapper (it re-enters through this dispatcher).
  if [[ "${ANYSCALE_VIA_MODULE:-0}" == "1" ]]; then
    return 0
  fi
  if [[ "${ANYSCALE_EXECUTION_MODE:-workstation}" == "jump-host" ]]; then
    case "$1" in
      deploy) warn "Hint: the jump-host workflow uses './scripts/anyscale-aks.sh module 3 deploy'." ;;
      verify) warn "Hint: the jump-host workflow uses './scripts/anyscale-aks.sh module 3 verify --full'." ;;
      teardown) warn "Hint: the jump-host workflow uses './scripts/anyscale-aks.sh module 3 teardown'." ;;
    esac
  fi
}

module_command() {
  local module_number="${1:-}"
  shift || true
  case "${module_number}" in
    1)
      bash "${MODULE_1_SCRIPT}" "$@"
      ;;
    2)
      bash "${MODULE_2_SCRIPT}" "$@"
      ;;
    3)
      bash "${MODULE_3_SCRIPT}" "$@"
      ;;
    4)
      bash "${MODULE_4_SCRIPT}" "$@"
      ;;
    5)
      bash "${MODULE_5_SCRIPT}" "$@"
      ;;
    ""|--help|-h)
      cat <<'USAGE'
Usage: ./scripts/anyscale-aks.sh module {1|2|3|4|5} SUBCOMMAND [ARGS]

  module 1  Build the foundation and connect to the jump hosts.
  module 2  Prepare the Linux jump host and verify the optional browser host.
  module 3  Deploy, verify, prove, and tear down the lab workload.
  module 4  Prove the custom-image requirement, build, sign, and prove the private-ACR image.
  module 5  Enable and verify AKS Image Integrity (signature verification).

Run `module N --help` for each module's subcommands.
USAGE
      ;;
    *)
      die "Unknown module '${module_number}'. Use module {1|2|3|4|5}."
      ;;
  esac
}

main() {
  local command_name="${1:-}"

  case "${command_name}" in
    ""|--help|-h)
      usage
      ;;
    module)
      shift
      module_command "$@"
      ;;
    deploy|verify|teardown|idempotency)
      shift
      maybe_emit_jump_host_hint "${command_name}"
      is_help_request "$@" || check_dependencies_for "${command_name}"
      run_setup "${command_name}" "$@"
      ;;
    proof)
      shift
      is_help_request "$@" || check_dependencies_for proof
      proof "$@"
      ;;
    custom-image)
      shift
      is_help_request "$@" || check_dependencies_for custom-image "$@"
      custom_image "$@"
      ;;
    image-integrity)
      shift
      is_help_request "$@" || check_dependencies_for image-integrity "$@"
      image_integrity "$@"
      ;;
    workload)
      shift
      is_help_request "$@" || check_dependencies_for workload
      run_setup workload "$@"
      ;;
    e2e)
      shift
      is_help_request "$@" || check_dependencies_for e2e
      e2e "$@"
      ;;
    status)
      shift
      [[ $# -eq 0 ]] || die "status does not accept arguments."
      status
      ;;
    doctor)
      shift
      [[ $# -eq 0 ]] || die "doctor does not accept arguments."
      doctor
      ;;
    tunnel)
      shift
      is_help_request "$@" || check_dependencies_for tunnel
      tunnel "$@"
      ;;
    browser)
      shift
      is_help_request "$@" || check_dependencies_for browser
      browser "$@"
      ;;
    head)
      shift
      is_help_request "$@" || check_dependencies_for head
      head "$@"
      ;;
    kubeconfig)
      shift
      is_help_request "$@" || check_dependencies_for kubeconfig
      kubeconfig "$@"
      ;;
    diagnose)
      shift
      is_help_request "$@" || check_dependencies_for diagnose
      diagnose "$@"
      ;;
    diagrams)
      shift
      is_help_request "$@" || check_dependencies_for diagrams
      diagrams "$@"
      ;;
    self-test)
      shift
      is_help_request "$@" || check_dependencies_for self-test
      self_test "$@"
      ;;
    *)
      die "Usage: ./scripts/anyscale-aks.sh COMMAND [ARGS]"
      ;;
  esac
}

main "$@"
