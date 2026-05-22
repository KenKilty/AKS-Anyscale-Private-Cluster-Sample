#!/usr/bin/env bash
###############################################################################
# Idempotent orchestrator for the private AKS / Anyscale sample environment.
#
# Usage:
#   ./scripts/setup.sh deploy [--from-scratch --yes]
#   ./scripts/setup.sh verify [--static|--live|--full] [--skip-observability]
#   ./scripts/setup.sh workload proof {cpu|gpu|all}
#   ./scripts/setup.sh idempotency [--skip-workload] [--include-teardown|--include-force-teardown --i-understand-this-deletes-azure-resources]
#   ./scripts/setup.sh teardown [--force] [--yes]
###############################################################################
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
TERRAFORM_DIR="${ROOT_DIR}/infra/terraform"
GENERATED_TFVARS="${TERRAFORM_DIR}/terraform.auto.tfvars.json"
CACHE_DIR="${ROOT_DIR}/.cache"

LOG_INFO_PREFIX="setup"
# shellcheck source=./lib/log.sh
source "${ROOT_DIR}/scripts/lib/log.sh"
# shellcheck source=./lib/timeout.sh
source "${ROOT_DIR}/scripts/lib/timeout.sh"

cd "${TERRAFORM_DIR}"

HARNESS_DIR="${CACHE_DIR}/aks-anyscale-sample-harness"
VALIDATION_REPORT_ROOT="${CACHE_DIR}/focused-validation"
DEFAULT_BASTION_TUNNEL_PORT="64430"
DEFAULT_ANYSCALE_HOST="https://console.azure.anyscale.com"
ANYSCALE_CLOUD_TEARDOWN_SCRIPT="${ROOT_DIR}/scripts/lib/anyscale-cloud-teardown.sh"

SETUP_TIMEOUT_TERRAFORM_INIT_SECONDS="${SETUP_TIMEOUT_TERRAFORM_INIT_SECONDS:-900}"
SETUP_TIMEOUT_TERRAFORM_VALIDATE_SECONDS="${SETUP_TIMEOUT_TERRAFORM_VALIDATE_SECONDS:-600}"
SETUP_TIMEOUT_TERRAFORM_TEST_SECONDS="${SETUP_TIMEOUT_TERRAFORM_TEST_SECONDS:-1200}"
SETUP_TIMEOUT_TERRAFORM_PLAN_SECONDS="${SETUP_TIMEOUT_TERRAFORM_PLAN_SECONDS:-1800}"
SETUP_TIMEOUT_TERRAFORM_APPLY_SECONDS="${SETUP_TIMEOUT_TERRAFORM_APPLY_SECONDS:-7200}"
SETUP_TIMEOUT_TERRAFORM_DESTROY_SECONDS="${SETUP_TIMEOUT_TERRAFORM_DESTROY_SECONDS:-7200}"
SETUP_TIMEOUT_P2S_VPN_PROFILE_SECONDS="${SETUP_TIMEOUT_P2S_VPN_PROFILE_SECONDS:-900}"
SETUP_TIMEOUT_HELM_SECONDS="${SETUP_TIMEOUT_HELM_SECONDS:-900}"
SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS="${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS:-180}"
SETUP_TIMEOUT_ANYSCALE_WORKSPACE_WAIT_SECONDS="${SETUP_TIMEOUT_ANYSCALE_WORKSPACE_WAIT_SECONDS:-1800}"
SETUP_TIMEOUT_ANYSCALE_WORKSPACE_COMMAND_SECONDS="${SETUP_TIMEOUT_ANYSCALE_WORKSPACE_COMMAND_SECONDS:-900}"
SETUP_TIMEOUT_AZURE_EXTENSION_SECONDS="${SETUP_TIMEOUT_AZURE_EXTENSION_SECONDS:-300}"
SETUP_TIMEOUT_AZURE_COMMAND_SECONDS="${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS:-180}"
SETUP_TIMEOUT_KUBECTL_READY_SECONDS="${SETUP_TIMEOUT_KUBECTL_READY_SECONDS:-20}"

P2S_DEFAULT_GATEWAY_SUBNET_CIDR="10.50.1.64/27"
P2S_DEFAULT_CLIENT_ADDRESS_SPACE='["172.16.201.0/24"]'
P2S_DEFAULT_GATEWAY_SKU="VpnGw1AZ"

FOCUSED_VALIDATION_RUN_ID=""
FOCUSED_VALIDATION_RESULTS=()
FOCUSED_VALIDATION_PASS_COUNT=0
FOCUSED_VALIDATION_FAIL_COUNT=0
FOCUSED_VALIDATION_SKIP_COUNT=0
ANYSCALE_WORKSPACE_WAIT_RESULT=""
DEPLOY_E2E_STARTED_TUNNEL=0
SETUP_RUN_DIR=""
SETUP_STAGE_LOG_DIR=""
SETUP_STAGE_INDEX=0
SETUP_STAGE_TOTAL=0
SETUP_STAGE_RESULTS=()
WORKLOAD_LAST_HEAD_POD=""

escape_env_double_quoted() {
  printf '%s' "$1" | sed 's/[\\"]/\\&/g'
}

shell_join() {
  local joined=""
  local arg

  for arg in "$@"; do
    printf -v joined '%s%q ' "${joined}" "${arg}"
  done

  printf '%s\n' "${joined% }"
}

write_export_env_script() {
  local output_file="$1"
  shift

  : > "${output_file}"

  local env_spec env_name env_value
  for env_spec in "$@"; do
    [[ "${env_spec}" == *=* ]] || die "Expected environment assignment in KEY=VALUE form, got '${env_spec}'."
    env_name="${env_spec%%=*}"
    env_value="${env_spec#*=}"
    [[ "${env_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "Invalid environment variable name '${env_name}'."
    printf 'export %s=%q\n' "${env_name}" "${env_value}" >> "${output_file}"
  done
}

set_env_file_var() {
  local name="$1"
  local value="$2"
  local escaped_value tmp_file

  escaped_value="$(escape_env_double_quoted "${value}")"
  mkdir -p "${CACHE_DIR}"
  tmp_file="${CACHE_DIR}/.env.sync.$$"

  awk -v name="${name}" -v line="${name}=\"${escaped_value}\"" '
    index($0, name "=") == 1 { print line; updated = 1; next }
    { print }
    END {
      if (!updated) {
        print line
      }
    }
  ' "${ENV_FILE}" > "${tmp_file}"

  mv "${tmp_file}" "${ENV_FILE}"
}

export_kubeconfig_env() {
  local kubeconfig_path="$1"

  export KUBECONFIG="${kubeconfig_path}"
  export KUBE_CONFIG_PATH="${kubeconfig_path}"
}

resource_group_name() {
  printf 'rg-%s-%s-%s\n' \
    "${TF_VAR_project}" \
    "${TF_VAR_environment}" \
    "${TF_VAR_region_short}"
}

target_aks_cluster_name() {
  printf 'aks-%s-%s-%s\n' \
    "${TF_VAR_project}" \
    "${TF_VAR_environment}" \
    "${TF_VAR_region_short}"
}

aks_cluster_exists_for_target() {
  local resource_group cluster_name

  resource_group="$(resource_group_name)"
  cluster_name="$(target_aks_cluster_name)"

  run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" \
    az aks show \
      --resource-group "${resource_group}" \
      --name "${cluster_name}" \
      --query name \
      --output tsv \
      --only-show-errors >/dev/null 2>&1
}

default_anyscale_host() {
  printf '%s\n' "${DEFAULT_ANYSCALE_HOST}"
}

# Anyscale uses three related identifiers for the same cloud:
# - cloud resource name: the short leaf name under the resource group
# - cloud name: the canonical path expected by the Anyscale CLI env var
# - cloud ARM id: the Azure resource ID used by az/terraform import flows
default_anyscale_cloud_name() {
  printf '/subscriptions/%s/resourcegroups/%s/providers/anyscale.platform/clouds/%s\n' \
    "${TF_VAR_azure_subscription_id}" \
    "$(resource_group_name)" \
    "$(default_anyscale_cloud_resource_name)"
}

default_anyscale_cloud_resource_name() {
  printf '%s-%s-%s\n' \
    "${TF_VAR_project}" \
    "${TF_VAR_environment}" \
    "${TF_VAR_region_short}"
}

default_anyscale_cloud_arm_id() {
  printf '/subscriptions/%s/resourceGroups/%s/providers/Anyscale.Platform/clouds/%s\n' \
    "${TF_VAR_azure_subscription_id}" \
    "$(resource_group_name)" \
    "$(default_anyscale_cloud_resource_name)"
}

anyscale_cloud_resource_azure_id() {
  local resource_group cloud_name
  resource_group="$(resource_group_name)"
  cloud_name="$(default_anyscale_cloud_resource_name)"

  printf '/subscriptions/%s/resourceGroups/%s/providers/Anyscale.Platform/clouds/%s/cloudResources/default\n' \
    "${TF_VAR_azure_subscription_id}" \
    "${resource_group}" \
    "${cloud_name}"
}

sync_anyscale_cli_env() {
  local derived_cloud_name derived_cloud_resource_name derived_cloud_arm_id
  local cloud_resource_azure_id live_cloud_deployment_id

  [[ -n "${TF_VAR_project:-}" ]] || return 0
  [[ -n "${TF_VAR_environment:-}" ]] || return 0
  [[ -n "${TF_VAR_region_short:-}" ]] || return 0
  [[ -n "${TF_VAR_azure_subscription_id:-}" ]] || return 0

  if [[ -z "${ANYSCALE_HOST:-}" || "${ANYSCALE_HOST}" == "https://console.anyscale.com" ]]; then
    ANYSCALE_HOST="$(default_anyscale_host)"
    export ANYSCALE_HOST
    set_env_file_var "ANYSCALE_HOST" "${ANYSCALE_HOST}"
    log "Auto-populated ANYSCALE_HOST=${ANYSCALE_HOST}"
  fi

  derived_cloud_name="$(default_anyscale_cloud_name)"
  derived_cloud_resource_name="$(default_anyscale_cloud_resource_name)"
  derived_cloud_arm_id="$(default_anyscale_cloud_arm_id)"
  if [[ -z "${ANYSCALE_CLOUD_NAME:-}" || "${ANYSCALE_CLOUD_NAME}" == "my-aks-cloud" || "${ANYSCALE_CLOUD_NAME}" == "${derived_cloud_resource_name}" || "${ANYSCALE_CLOUD_NAME}" == "${derived_cloud_arm_id}" ]]; then
    ANYSCALE_CLOUD_NAME="${derived_cloud_name}"
    export ANYSCALE_CLOUD_NAME
    set_env_file_var "ANYSCALE_CLOUD_NAME" "${ANYSCALE_CLOUD_NAME}"
    log "Auto-populated ANYSCALE_CLOUD_NAME=${ANYSCALE_CLOUD_NAME}"
  fi

  command -v az >/dev/null 2>&1 || return 0

  cloud_resource_azure_id="$(anyscale_cloud_resource_azure_id)"
  live_cloud_deployment_id="$(run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" az resource show \
    --ids "${cloud_resource_azure_id}" \
    --query 'properties.cloudResourceId' \
    --output tsv \
    --only-show-errors 2>/dev/null || true)"

  if [[ -n "${live_cloud_deployment_id}" && "${live_cloud_deployment_id}" != "${ANYSCALE_CLOUD_DEPLOYMENT_ID:-}" ]]; then
    ANYSCALE_CLOUD_DEPLOYMENT_ID="${live_cloud_deployment_id}"
    export ANYSCALE_CLOUD_DEPLOYMENT_ID
    set_env_file_var "ANYSCALE_CLOUD_DEPLOYMENT_ID" "${ANYSCALE_CLOUD_DEPLOYMENT_ID}"
    log "Auto-populated ANYSCALE_CLOUD_DEPLOYMENT_ID from Azure resource ${ANYSCALE_CLOUD_NAME}"
  fi
}

clear_anyscale_cloud_deployment_id() {
  [[ -f "${ENV_FILE}" ]] || return 0
  [[ -n "${ANYSCALE_CLOUD_DEPLOYMENT_ID:-}" ]] || return 0

  ANYSCALE_CLOUD_DEPLOYMENT_ID=""
  export ANYSCALE_CLOUD_DEPLOYMENT_ID
  set_env_file_var "ANYSCALE_CLOUD_DEPLOYMENT_ID" ""
  log "Cleared ANYSCALE_CLOUD_DEPLOYMENT_ID after Anyscale cloud removal"
}

canonicalize_gpu_pool_configs_json() {
  local raw_value="$1"
  local candidate_json

  if candidate_json="$(jq -c . <<<"${raw_value}" 2>/dev/null)"; then
    printf '%s\n' "${candidate_json}"
    return 0
  fi

  candidate_json="$(printf '%s' "${raw_value}" \
    | sed -E 's/([{,])([A-Za-z0-9_]+):/\1"\2":/g' \
    | sed -E 's/"(name|vm_size|product_name|gpu_count)":([A-Za-z0-9_.-]+)/"\1":"\2"/g')"

  jq -c . <<<"${candidate_json}" 2>/dev/null || return 1
}

normalize_gpu_pool_configs_min_count() {
  [[ -n "${TF_VAR_gpu_pool_configs:-}" ]] || return 0

  local canonical_gpu_pool_configs normalized_gpu_pool_configs
  canonical_gpu_pool_configs="$(canonicalize_gpu_pool_configs_json "${TF_VAR_gpu_pool_configs}")" \
    || die "TF_VAR_gpu_pool_configs must be valid JSON or Terraform-style object syntax."
  normalized_gpu_pool_configs="$(jq -c 'with_entries(.value.min_count |= (if . < 1 then 1 else . end))' <<<"${canonical_gpu_pool_configs}")"

  if [[ "${normalized_gpu_pool_configs}" != "${TF_VAR_gpu_pool_configs}" ]]; then
    TF_VAR_gpu_pool_configs="${normalized_gpu_pool_configs}"
    export TF_VAR_gpu_pool_configs
    set_env_file_var "TF_VAR_gpu_pool_configs" "${TF_VAR_gpu_pool_configs}"
    log "Normalized TF_VAR_gpu_pool_configs so every GPU pool min_count is at least 1"
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command '$1' not found on PATH."
}

load_env() {
  [[ -f "${ENV_FILE}" ]] || die "Missing ${ENV_FILE}. Copy .env-template to .env and fill in the required values."
  # shellcheck disable=SC1090
  set -a
  source "${ENV_FILE}"
  set +a

  if [[ -z "${ANYSCALE_HOST:-}" ]]; then
    ANYSCALE_HOST="$(default_anyscale_host)"
    export ANYSCALE_HOST
  fi
}

require_env_var() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "Missing required environment variable ${name} in ${ENV_FILE}."
}

p2s_vpn_enabled() {
  [[ "${TF_VAR_enable_p2s_vpn:-false}" == "true" ]]
}

p2s_vpn_artifact_dir() {
  ensure_harness_dir
  printf '%s/p2s-vpn\n' "${HARNESS_DIR}"
}

p2s_vpn_cert_dir() {
  printf '%s/certs\n' "$(p2s_vpn_artifact_dir)"
}

p2s_vpn_package_zip_path() {
  printf '%s/azure-vpn-client-profile.zip\n' "$(p2s_vpn_artifact_dir)"
}

p2s_vpn_unpack_dir() {
  printf '%s/unpacked\n' "$(p2s_vpn_artifact_dir)"
}

p2s_vpn_ready_ovpn_path() {
  printf '%s/openvpn-ready.ovpn\n' "$(p2s_vpn_artifact_dir)"
}

p2s_vpn_summary_path() {
  printf '%s/README.txt\n' "$(p2s_vpn_artifact_dir)"
}

p2s_vpn_lab_root_name() {
  printf '%s-%s-%s-p2s-root\n' \
    "${TF_VAR_project}" \
    "${TF_VAR_environment}" \
    "${TF_VAR_region_short}"
}

p2s_vpn_lab_client_name() {
  printf '%s-%s-%s-p2s-operator\n' \
    "${TF_VAR_project}" \
    "${TF_VAR_environment}" \
    "${TF_VAR_region_short}"
}

p2s_vpn_lab_root_key_path() {
  printf '%s/%s.key\n' "$(p2s_vpn_cert_dir)" "$(p2s_vpn_lab_root_name)"
}

p2s_vpn_lab_root_cert_path() {
  printf '%s/%s.crt\n' "$(p2s_vpn_cert_dir)" "$(p2s_vpn_lab_root_name)"
}

p2s_vpn_lab_client_key_path() {
  printf '%s/%s.key\n' "$(p2s_vpn_cert_dir)" "$(p2s_vpn_lab_client_name)"
}

p2s_vpn_lab_client_csr_path() {
  printf '%s/%s.csr\n' "$(p2s_vpn_cert_dir)" "$(p2s_vpn_lab_client_name)"
}

p2s_vpn_lab_client_cert_path() {
  printf '%s/%s.crt\n' "$(p2s_vpn_cert_dir)" "$(p2s_vpn_lab_client_name)"
}

p2s_vpn_lab_client_p12_path() {
  printf '%s/%s.p12\n' "$(p2s_vpn_cert_dir)" "$(p2s_vpn_lab_client_name)"
}

p2s_vpn_lab_client_extfile_path() {
  printf '%s/%s.ext\n' "$(p2s_vpn_cert_dir)" "$(p2s_vpn_lab_client_name)"
}

p2s_vpn_lab_serial_path() {
  printf '%s/%s.srl\n' "$(p2s_vpn_cert_dir)" "$(p2s_vpn_lab_root_name)"
}

render_p2s_trusted_root_certificates_json() {
  local certificate_name="$1"
  local certificate_path="$2"

  python3 - "${certificate_name}" "${certificate_path}" <<'PY'
import json
import pathlib
import sys

name = sys.argv[1]
certificate_path = pathlib.Path(sys.argv[2])
body = "".join(
    line.strip()
    for line in certificate_path.read_text().splitlines()
    if "BEGIN CERTIFICATE" not in line and "END CERTIFICATE" not in line and line.strip()
)
print(json.dumps([{"name": name, "public_cert_data": body}], separators=(",", ":")))
PY
}

ensure_p2s_subnet_defaults() {
  p2s_vpn_enabled || return 0

  TF_VAR_subnet_cidrs="$(jq -c --arg gateway_cidr "${P2S_DEFAULT_GATEWAY_SUBNET_CIDR}" '. + {gateway: (.gateway // $gateway_cidr)}' <<<"${TF_VAR_subnet_cidrs}")"
  export TF_VAR_subnet_cidrs
}

ensure_p2s_lab_certificates() {
  local cert_dir root_name client_name root_key_path root_cert_path client_key_path client_csr_path client_cert_path client_p12_path client_extfile_path serial_path previous_umask

  p2s_vpn_enabled || return 0

  if [[ -n "${TF_VAR_p2s_trusted_root_certificates:-}" && "${TF_VAR_p2s_trusted_root_certificates}" != "[]" ]]; then
    return 0
  fi

  require_cmd openssl
  require_cmd python3

  cert_dir="$(p2s_vpn_cert_dir)"
  root_name="$(p2s_vpn_lab_root_name)"
  client_name="$(p2s_vpn_lab_client_name)"
  root_key_path="$(p2s_vpn_lab_root_key_path)"
  root_cert_path="$(p2s_vpn_lab_root_cert_path)"
  client_key_path="$(p2s_vpn_lab_client_key_path)"
  client_csr_path="$(p2s_vpn_lab_client_csr_path)"
  client_cert_path="$(p2s_vpn_lab_client_cert_path)"
  client_p12_path="$(p2s_vpn_lab_client_p12_path)"
  client_extfile_path="$(p2s_vpn_lab_client_extfile_path)"
  serial_path="$(p2s_vpn_lab_serial_path)"

  mkdir -p "${cert_dir}"
  previous_umask="$(umask)"
  umask 077

  if [[ ! -s "${root_key_path}" || ! -s "${root_cert_path}" ]]; then
    log "Generating local lab root certificate for P2S VPN under ${cert_dir}"
    openssl req -x509 -nodes -newkey rsa:2048 \
      -keyout "${root_key_path}" \
      -out "${root_cert_path}" \
      -days 3650 \
      -sha256 \
      -subj "/CN=${root_name}" >/dev/null 2>&1
  fi

  if [[ ! -s "${client_key_path}" || ! -s "${client_cert_path}" ]]; then
    log "Generating local lab client certificate for P2S VPN under ${cert_dir}"
    openssl req -nodes -newkey rsa:2048 \
      -keyout "${client_key_path}" \
      -out "${client_csr_path}" \
      -subj "/CN=${client_name}" >/dev/null 2>&1

    cat > "${client_extfile_path}" <<'EOF'
basicConstraints=CA:FALSE
extendedKeyUsage=clientAuth
keyUsage=digitalSignature,keyEncipherment
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EOF

    openssl x509 -req \
      -in "${client_csr_path}" \
      -CA "${root_cert_path}" \
      -CAkey "${root_key_path}" \
      -CAcreateserial \
      -CAserial "${serial_path}" \
      -out "${client_cert_path}" \
      -days 825 \
      -sha256 \
      -extfile "${client_extfile_path}" >/dev/null 2>&1
  fi

  if [[ ! -s "${client_p12_path}" ]]; then
    openssl pkcs12 -export \
      -inkey "${client_key_path}" \
      -in "${client_cert_path}" \
      -certfile "${root_cert_path}" \
      -out "${client_p12_path}" \
      -passout pass: >/dev/null 2>&1
  fi

  umask "${previous_umask}"

  TF_VAR_p2s_trusted_root_certificates="$(render_p2s_trusted_root_certificates_json "${root_name}" "${root_cert_path}")"
  export TF_VAR_p2s_trusted_root_certificates
}

find_p2s_openvpn_profile() {
  local unpack_dir="$1"
  find "${unpack_dir}" -type f -name '*.ovpn' | LC_ALL=C sort | head -n1
}

extract_first_url_from_json() {
  local raw_payload

  raw_payload="$(cat)"

  python3 - "${raw_payload}" <<'PY'
import json
import re
import sys

raw_payload = sys.argv[1].strip()
if not raw_payload:
    raise SystemExit(1)

if re.match(r"^https?://", raw_payload):
    print(raw_payload)
    raise SystemExit(0)

try:
    payload = json.loads(raw_payload)
except json.JSONDecodeError:
    match = re.search(r"https?://\S+", raw_payload)
    if match:
        print(match.group(0).rstrip('"\','))
        raise SystemExit(0)
    raise SystemExit(1)

queue = [payload]
while queue:
  current = queue.pop(0)
  if isinstance(current, dict):
    queue.extend(current.values())
    continue
  if isinstance(current, list):
    queue.extend(current)
    continue
  if isinstance(current, str) and re.match(r"^https?://", current.strip()):
    print(current.strip())
    raise SystemExit(0)

raise SystemExit(1)
PY
}

download_and_unpack_p2s_profile() {
  local profile_url="$1"
  local zip_path unpack_dir

  zip_path="$(p2s_vpn_package_zip_path)"
  unpack_dir="$(p2s_vpn_unpack_dir)"
  mkdir -p "$(p2s_vpn_artifact_dir)"

  python3 - "${profile_url}" "${zip_path}" "${unpack_dir}" <<'PY'
import pathlib
import shutil
import sys
import urllib.request
import zipfile

profile_url = sys.argv[1]
zip_path = pathlib.Path(sys.argv[2])
unpack_dir = pathlib.Path(sys.argv[3])

zip_path.parent.mkdir(parents=True, exist_ok=True)
urllib.request.urlretrieve(profile_url, zip_path)

if unpack_dir.exists():
    shutil.rmtree(unpack_dir)
unpack_dir.mkdir(parents=True, exist_ok=True)

with zipfile.ZipFile(zip_path) as archive:
    archive.extractall(unpack_dir)
PY
}

build_ready_openvpn_profile() {
  local source_profile_path="$1"
  local output_profile_path="$2"
  local dns_servers_json="$3"
  local client_cert_path="$4"
  local client_key_path="$5"
  local root_cert_path="$6"

  python3 - "${source_profile_path}" "${output_profile_path}" "${dns_servers_json}" "${client_cert_path}" "${client_key_path}" "${root_cert_path}" <<'PY'
import json
import pathlib
import sys

source_path = pathlib.Path(sys.argv[1])
output_path = pathlib.Path(sys.argv[2])
dns_servers = json.loads(sys.argv[3])
client_cert_path = pathlib.Path(sys.argv[4])
client_key_path = pathlib.Path(sys.argv[5])
root_cert_path = pathlib.Path(sys.argv[6])

source_lines = source_path.read_text().splitlines()
result_lines = []
skip_block = None

for line in source_lines:
    stripped = line.strip()

    if skip_block is not None:
        if stripped == f"</{skip_block}>":
            skip_block = None
        continue

    if stripped in {"<cert>", "<key>"}:
        skip_block = stripped[1:-1]
        continue

    if stripped == "persist-key":
      continue

    if stripped.startswith("cert ") or stripped.startswith("key ") or stripped.startswith("dhcp-option DNS "):
        continue

    result_lines.append(line)

for dns_server in dns_servers:
    result_lines.append(f"dhcp-option DNS {dns_server}")

has_ca_block = any(line.strip() == "<ca>" or line.strip().startswith("ca ") for line in result_lines)
if not has_ca_block and root_cert_path.exists():
    result_lines.append("<ca>")
    result_lines.extend(root_cert_path.read_text().splitlines())
    result_lines.append("</ca>")

if client_cert_path.exists() and client_key_path.exists():
    result_lines.append("<cert>")
    result_lines.extend(client_cert_path.read_text().splitlines())
    result_lines.append("</cert>")
    result_lines.append("<key>")
    result_lines.extend(client_key_path.read_text().splitlines())
    result_lines.append("</key>")

output_path.parent.mkdir(parents=True, exist_ok=True)
output_path.write_text("\n".join(result_lines) + "\n")
PY
}

write_p2s_vpn_summary() {
  local profile_url="$1"
  local source_profile_path="$2"
  local dns_servers_json="$3"
  local client_address_space_json="$4"
  local resource_group="$5"
  local gateway_name="$6"
  local summary_path artifact_dir ready_profile client_p12_path client_cert_path client_key_path root_cert_path

  summary_path="$(p2s_vpn_summary_path)"
  artifact_dir="$(p2s_vpn_artifact_dir)"
  ready_profile="$(p2s_vpn_ready_ovpn_path)"
  client_p12_path="$(p2s_vpn_lab_client_p12_path)"
  client_cert_path="$(p2s_vpn_lab_client_cert_path)"
  client_key_path="$(p2s_vpn_lab_client_key_path)"
  root_cert_path="$(p2s_vpn_lab_root_cert_path)"

  {
    printf 'Azure P2S VPN artifacts\n'
    printf '======================\n\n'
    printf 'Resource group: %s\n' "${resource_group}"
    printf 'VPN gateway:    %s\n' "${gateway_name}"
    printf 'Profile URL:    %s\n\n' "${profile_url}"
    printf 'Artifact directory: %s\n' "${artifact_dir}"
    printf 'Downloaded zip:     %s\n' "$(p2s_vpn_package_zip_path)"
    printf 'Unpacked package:   %s\n' "$(p2s_vpn_unpack_dir)"
    printf 'Source .ovpn:       %s\n' "${source_profile_path:-<not found>}"
    printf 'Ready .ovpn:        %s\n\n' "${ready_profile}"
    printf 'Client address pool: %s\n' "$(jq -r 'join(", ")' <<<"${client_address_space_json}")"
    printf 'Client DNS servers:  %s\n\n' "$(jq -r 'join(", ")' <<<"${dns_servers_json}")"

    if [[ -f "${client_cert_path}" && -f "${client_key_path}" ]]; then
      printf 'Local lab client certificate: %s\n' "${client_cert_path}"
      printf 'Local lab client key:         %s\n' "${client_key_path}"
      printf 'Local lab PKCS#12 bundle:     %s\n' "${client_p12_path}"
      printf 'Local lab root certificate:   %s\n\n' "${root_cert_path}"
      printf 'macOS/OpenVPN path:\n'
      printf '  Import %s into Tunnelblick or OpenVPN Connect.\n\n' "${ready_profile}"
    else
      printf 'No local lab client certificate was generated because a custom TF_VAR_p2s_trusted_root_certificates value was supplied.\n'
      printf 'Provide a client certificate that chains to the configured root before importing %s.\n\n' "${ready_profile}"
    fi

    printf 'Regenerate the Azure package later with:\n'
    printf '  az network vnet-gateway vpn-client generate -g %s -n %s --authentication-method EAPTLS --processor-architecture Amd64\n' "${resource_group}" "${gateway_name}"
  } > "${summary_path}"
}

generate_p2s_vpn_artifacts() {
  local contract_json enabled resource_group gateway_name dns_servers_json client_address_space_json generate_json show_url_json profile_url source_profile ready_profile client_cert_path client_key_path root_cert_path

  load_env
  sync_anyscale_cli_env
  require_cmd az
  require_cmd jq
  require_cmd python3

  contract_json="$(terraform output -json p2s_vpn_contract 2>/dev/null || true)"
  [[ -n "${contract_json}" ]] || {
    log "Terraform output p2s_vpn_contract is not available yet. Skipping VPN client artifacts."
    return 0
  }

  enabled="$(jq -r '.enabled // false' <<<"${contract_json}")"
  if [[ "${enabled}" != "true" ]]; then
    log "P2S VPN is disabled. Skipping VPN client artifact generation."
    return 0
  fi

  ensure_p2s_lab_certificates

  resource_group="$(terraform_output_raw resource_group_name)"
  gateway_name="$(terraform_output_raw vpn_gateway_name)"
  dns_servers_json="$(jq -c '.client_dns_servers // []' <<<"${contract_json}")"
  client_address_space_json="$(jq -c '.client_address_space // []' <<<"${contract_json}")"

  [[ -n "${resource_group}" && -n "${gateway_name}" && "${gateway_name}" != "null" ]] || die "P2S VPN is enabled, but Terraform outputs are missing the VPN gateway identity."

  log "Generating Azure VPN client package for gateway ${gateway_name}"
  generate_json="$(run_with_timeout "${SETUP_TIMEOUT_P2S_VPN_PROFILE_SECONDS}" az network vnet-gateway vpn-client generate \
    --resource-group "${resource_group}" \
    --name "${gateway_name}" \
    --authentication-method EAPTLS \
    --processor-architecture Amd64 \
    --output json \
    --only-show-errors)"
  profile_url="$(extract_first_url_from_json <<<"${generate_json}" || true)"

  if [[ -z "${profile_url}" ]]; then
    log "Azure CLI did not return a profile URL directly; retrying with show-url"
    show_url_json="$(run_with_timeout "${SETUP_TIMEOUT_P2S_VPN_PROFILE_SECONDS}" az network vnet-gateway vpn-client show-url \
      --resource-group "${resource_group}" \
      --name "${gateway_name}" \
      --output json \
      --only-show-errors)"
    profile_url="$(extract_first_url_from_json <<<"${show_url_json}" || true)"
  fi

  [[ -n "${profile_url}" ]] || die "Azure CLI did not return a VPN client profile URL for gateway ${gateway_name}."

  download_and_unpack_p2s_profile "${profile_url}"

  source_profile="$(find_p2s_openvpn_profile "$(p2s_vpn_unpack_dir)" || true)"
  [[ -n "${source_profile}" ]] || die "Downloaded Azure VPN client package does not contain an .ovpn profile."

  ready_profile="$(p2s_vpn_ready_ovpn_path)"
  client_cert_path="$(p2s_vpn_lab_client_cert_path)"
  client_key_path="$(p2s_vpn_lab_client_key_path)"
  root_cert_path="$(p2s_vpn_lab_root_cert_path)"

  build_ready_openvpn_profile \
    "${source_profile}" \
    "${ready_profile}" \
    "${dns_servers_json}" \
    "${client_cert_path}" \
    "${client_key_path}" \
    "${root_cert_path}"

  write_p2s_vpn_summary \
    "${profile_url}" \
    "${source_profile}" \
    "${dns_servers_json}" \
    "${client_address_space_json}" \
    "${resource_group}" \
    "${gateway_name}"

  log "P2S VPN artifacts are ready under $(p2s_vpn_artifact_dir)"
  log "Use $(p2s_vpn_ready_ovpn_path) with an OpenVPN client on macOS or Linux."
}

render_tfvars() {
  load_env

  local required_env_vars=(
    TF_VAR_azure_subscription_id
    TF_VAR_azure_tenant_id
    TF_VAR_project
    TF_VAR_environment
    TF_VAR_azure_location
    TF_VAR_region_short
    TF_VAR_aks_sku_tier
    TF_VAR_system_vm_size
    TF_VAR_cpu_vm_size
    TF_VAR_service_cidr
    TF_VAR_dns_service_ip
    TF_VAR_anyscale_operator_namespace
    TF_VAR_anyscale_operator_serviceaccount
    TF_VAR_storage_replication_type
    TF_VAR_ampls_ingestion_access_mode
    TF_VAR_ampls_query_access_mode
    TF_VAR_container_insights_data_collection_interval
    TF_VAR_container_insights_namespace_filtering_mode
    TF_VAR_anyscale_operator_identity
    TF_VAR_vnet_address_space
    TF_VAR_subnet_cidrs
    TF_VAR_dns_forwarding_rules
    TF_VAR_anyscale_fqdns
    TF_VAR_azure_identity_fqdns
    TF_VAR_azure_monitor_fqdns
    TF_VAR_container_registry_fqdns
    TF_VAR_availability_zones
    TF_VAR_system_node_pool_min_count
    TF_VAR_system_node_pool_max_count
    TF_VAR_gpu_pool_configs
    TF_VAR_kubernetes_version
    TF_VAR_storage_cors_rule
    TF_VAR_acr_zone_redundancy_enabled
    TF_VAR_log_analytics_retention_days
    TF_VAR_log_analytics_internet_ingestion_enabled
    TF_VAR_log_analytics_internet_query_enabled
    TF_VAR_ampls_enabled
    TF_VAR_container_insights_v2_enabled
    TF_VAR_container_insights_streams
    TF_VAR_container_insights_namespaces
    TF_VAR_terraform_managed_diagnostic_settings_enabled
    TF_VAR_tags
  )

  local env_name
  for env_name in "${required_env_vars[@]}"; do
    require_env_var "${env_name}"
  done

  TF_VAR_enable_p2s_vpn="${TF_VAR_enable_p2s_vpn:-false}"
  TF_VAR_vpn_gateway_sku="${TF_VAR_vpn_gateway_sku:-${P2S_DEFAULT_GATEWAY_SKU}}"
  TF_VAR_p2s_client_address_space="${TF_VAR_p2s_client_address_space:-${P2S_DEFAULT_CLIENT_ADDRESS_SPACE}}"
  TF_VAR_p2s_client_dns_servers="${TF_VAR_p2s_client_dns_servers:-[]}"
  TF_VAR_p2s_trusted_root_certificates="${TF_VAR_p2s_trusted_root_certificates:-[]}"

  export TF_VAR_enable_p2s_vpn
  export TF_VAR_vpn_gateway_sku
  export TF_VAR_p2s_client_address_space
  export TF_VAR_p2s_client_dns_servers
  export TF_VAR_p2s_trusted_root_certificates

  normalize_gpu_pool_configs_min_count
  sync_anyscale_cli_env
  ensure_p2s_subnet_defaults
  ensure_p2s_lab_certificates

  if [[ -z "${TF_VAR_anyscale_cli_token:-}" && -n "${ANYSCALE_CLI_TOKEN:-}" ]]; then
    TF_VAR_anyscale_cli_token="${ANYSCALE_CLI_TOKEN}"
    export TF_VAR_anyscale_cli_token
  fi

  jq -n \
    --arg azure_subscription_id "${TF_VAR_azure_subscription_id}" \
    --arg azure_tenant_id "${TF_VAR_azure_tenant_id}" \
    --arg project "${TF_VAR_project}" \
    --arg environment "${TF_VAR_environment}" \
    --arg azure_location "${TF_VAR_azure_location}" \
    --arg region_short "${TF_VAR_region_short}" \
    --argjson enable_p2s_vpn "${TF_VAR_enable_p2s_vpn}" \
    --arg vpn_gateway_sku "${TF_VAR_vpn_gateway_sku}" \
    --arg aks_sku_tier "${TF_VAR_aks_sku_tier}" \
    --arg system_vm_size "${TF_VAR_system_vm_size}" \
    --arg cpu_vm_size "${TF_VAR_cpu_vm_size}" \
    --arg service_cidr "${TF_VAR_service_cidr}" \
    --arg dns_service_ip "${TF_VAR_dns_service_ip}" \
    --arg anyscale_operator_namespace "${TF_VAR_anyscale_operator_namespace}" \
    --arg anyscale_operator_serviceaccount "${TF_VAR_anyscale_operator_serviceaccount}" \
    --arg storage_replication_type "${TF_VAR_storage_replication_type}" \
    --arg ampls_ingestion_access_mode "${TF_VAR_ampls_ingestion_access_mode}" \
    --arg ampls_query_access_mode "${TF_VAR_ampls_query_access_mode}" \
    --arg container_insights_data_collection_interval "${TF_VAR_container_insights_data_collection_interval}" \
    --arg container_insights_namespace_filtering_mode "${TF_VAR_container_insights_namespace_filtering_mode}" \
    --argjson anyscale_operator_identity "${TF_VAR_anyscale_operator_identity}" \
    --argjson vnet_address_space "${TF_VAR_vnet_address_space}" \
    --argjson subnet_cidrs "${TF_VAR_subnet_cidrs}" \
    --argjson dns_forwarding_rules "${TF_VAR_dns_forwarding_rules}" \
    --argjson anyscale_fqdns "${TF_VAR_anyscale_fqdns}" \
    --argjson azure_identity_fqdns "${TF_VAR_azure_identity_fqdns}" \
    --argjson azure_monitor_fqdns "${TF_VAR_azure_monitor_fqdns}" \
    --argjson container_registry_fqdns "${TF_VAR_container_registry_fqdns}" \
    --argjson availability_zones "${TF_VAR_availability_zones}" \
    --argjson system_node_pool_min_count "${TF_VAR_system_node_pool_min_count}" \
    --argjson system_node_pool_max_count "${TF_VAR_system_node_pool_max_count}" \
    --argjson gpu_pool_configs "${TF_VAR_gpu_pool_configs}" \
    --argjson kubernetes_version "${TF_VAR_kubernetes_version}" \
    --argjson storage_cors_rule "${TF_VAR_storage_cors_rule}" \
    --argjson acr_zone_redundancy_enabled "${TF_VAR_acr_zone_redundancy_enabled}" \
    --argjson log_analytics_retention_days "${TF_VAR_log_analytics_retention_days}" \
    --argjson log_analytics_internet_ingestion_enabled "${TF_VAR_log_analytics_internet_ingestion_enabled}" \
    --argjson log_analytics_internet_query_enabled "${TF_VAR_log_analytics_internet_query_enabled}" \
    --argjson ampls_enabled "${TF_VAR_ampls_enabled}" \
    --argjson container_insights_v2_enabled "${TF_VAR_container_insights_v2_enabled}" \
    --argjson container_insights_streams "${TF_VAR_container_insights_streams}" \
    --argjson container_insights_namespaces "${TF_VAR_container_insights_namespaces}" \
    --argjson terraform_managed_diagnostic_settings_enabled "${TF_VAR_terraform_managed_diagnostic_settings_enabled}" \
    --argjson p2s_client_address_space "${TF_VAR_p2s_client_address_space}" \
    --argjson p2s_client_dns_servers "${TF_VAR_p2s_client_dns_servers}" \
    --argjson p2s_trusted_root_certificates "${TF_VAR_p2s_trusted_root_certificates}" \
    --argjson tags "${TF_VAR_tags}" \
    --arg anyscale_cli_token "${TF_VAR_anyscale_cli_token:-}" \
    '{
      azure_subscription_id: $azure_subscription_id,
      azure_tenant_id: $azure_tenant_id,
      project: $project,
      environment: $environment,
      azure_location: $azure_location,
      region_short: $region_short,
      enable_p2s_vpn: $enable_p2s_vpn,
      vpn_gateway_sku: $vpn_gateway_sku,
      aks_sku_tier: $aks_sku_tier,
      system_vm_size: $system_vm_size,
      cpu_vm_size: $cpu_vm_size,
      service_cidr: $service_cidr,
      dns_service_ip: $dns_service_ip,
      anyscale_operator_namespace: $anyscale_operator_namespace,
      anyscale_operator_serviceaccount: $anyscale_operator_serviceaccount,
      storage_replication_type: $storage_replication_type,
      ampls_ingestion_access_mode: $ampls_ingestion_access_mode,
      ampls_query_access_mode: $ampls_query_access_mode,
      container_insights_data_collection_interval: $container_insights_data_collection_interval,
      container_insights_namespace_filtering_mode: $container_insights_namespace_filtering_mode,
      anyscale_operator_identity: $anyscale_operator_identity,
      vnet_address_space: $vnet_address_space,
      subnet_cidrs: $subnet_cidrs,
      dns_forwarding_rules: $dns_forwarding_rules,
      anyscale_fqdns: $anyscale_fqdns,
      azure_identity_fqdns: $azure_identity_fqdns,
      azure_monitor_fqdns: $azure_monitor_fqdns,
      container_registry_fqdns: $container_registry_fqdns,
      availability_zones: $availability_zones,
      system_node_pool_min_count: $system_node_pool_min_count,
      system_node_pool_max_count: $system_node_pool_max_count,
      gpu_pool_configs: $gpu_pool_configs,
      kubernetes_version: $kubernetes_version,
      storage_cors_rule: $storage_cors_rule,
      acr_zone_redundancy_enabled: $acr_zone_redundancy_enabled,
      log_analytics_retention_days: $log_analytics_retention_days,
      log_analytics_internet_ingestion_enabled: $log_analytics_internet_ingestion_enabled,
      log_analytics_internet_query_enabled: $log_analytics_internet_query_enabled,
      ampls_enabled: $ampls_enabled,
      container_insights_v2_enabled: $container_insights_v2_enabled,
      container_insights_streams: $container_insights_streams,
      container_insights_namespaces: $container_insights_namespaces,
      terraform_managed_diagnostic_settings_enabled: $terraform_managed_diagnostic_settings_enabled,
      p2s_client_address_space: $p2s_client_address_space,
      p2s_client_dns_servers: $p2s_client_dns_servers,
      p2s_trusted_root_certificates: $p2s_trusted_root_certificates,
      tags: $tags,
      anyscale_cli_token: (if $anyscale_cli_token == "" then null else $anyscale_cli_token end)
    }' > "${GENERATED_TFVARS}"

  log "Rendered ${GENERATED_TFVARS}"
}

terraform_output_raw() {
  terraform output -raw "$1"
}

terraform_output_json() {
  terraform output -json "$1"
}

anyscale_platform_deployment_name() {
  printf 'dep-anyscale-%s-%s-%s\n' \
    "${TF_VAR_project}" \
    "${TF_VAR_environment}" \
    "${TF_VAR_region_short}"
}

anyscale_platform_deployment_resource_id() {
  local resource_group deployment_name
  resource_group="$(resource_group_name)"
  deployment_name="$(anyscale_platform_deployment_name)"

  printf '/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Resources/deployments/%s\n' \
    "${TF_VAR_azure_subscription_id}" \
    "${resource_group}" \
    "${deployment_name}"
}

anyscale_platform_enabled() {
  if [[ -z "${TF_VAR_anyscale_platform:-}" ]]; then
    return 0
  fi

  jq -e 'if type == "object" and has("enabled") then .enabled else true end' <<<"${TF_VAR_anyscale_platform}" >/dev/null 2>&1
}

ensure_anyscale_marketplace_agreement_accepted() {
  # Marketplace agreements are subscription-scoped and survive resource-group
  # teardowns, so they live outside Terraform state. Check current acceptance,
  # skip silently if already accepted, otherwise prompt the user (or auto-accept
  # when --yes was supplied) and call az to record acceptance.
  local publisher="anyscale1750870039553"
  local offer="anyscale-operator-aks"
  local plan="anyscale-operator"
  local terms_json accepted license_link privacy_link prompt_response

  anyscale_platform_enabled || return 0

  terms_json="$(run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" az vm image terms show \
    --subscription "${TF_VAR_azure_subscription_id}" \
    --publisher "${publisher}" \
    --offer "${offer}" \
    --plan "${plan}" \
    --only-show-errors 2>/dev/null || true)"

  if [[ -n "${terms_json}" ]]; then
    accepted="$(jq -r '.accepted // false' <<<"${terms_json}" 2>/dev/null || echo "false")"
    if [[ "${accepted}" == "true" ]]; then
      return 0
    fi
    license_link="$(jq -r '.licenseTextLink // ""' <<<"${terms_json}" 2>/dev/null || echo "")"
    privacy_link="$(jq -r '.privacyPolicyLink // ""' <<<"${terms_json}" 2>/dev/null || echo "")"
  fi

  log "Anyscale operator marketplace agreement has not been accepted on subscription ${TF_VAR_azure_subscription_id}"
  log "  Publisher: ${publisher}"
  log "  Offer:     ${offer}"
  log "  Plan:      ${plan}"
  [[ -n "${license_link}" ]] && log "  Terms:     ${license_link}"
  [[ -n "${privacy_link}" ]] && log "  Privacy:   ${privacy_link}"

  if [[ "${DEPLOY_FORCE_YES:-false}" == true ]]; then
    log "Auto-accepting marketplace agreement (--yes supplied)"
  else
    printf 'Accept the Anyscale marketplace agreement? [y/N]: '
    IFS= read -r prompt_response || die "Marketplace agreement is required for the Anyscale operator AKS extension."
    case "${prompt_response}" in
      y|Y|yes|YES|Yes) ;;
      *) die "Marketplace agreement not accepted; cannot install the Anyscale operator AKS extension. Re-run when ready to accept." ;;
    esac
  fi

  log "Recording marketplace agreement acceptance on subscription ${TF_VAR_azure_subscription_id}"
  run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" az vm image terms accept \
    --subscription "${TF_VAR_azure_subscription_id}" \
    --publisher "${publisher}" \
    --offer "${offer}" \
    --plan "${plan}" \
    --only-show-errors >/dev/null
}

ensure_anyscale_platform_deployment_state() {
  local resource_address="azapi_resource.anyscale_platform[0]"
  local resource_group deployment_name deployment_id

  anyscale_platform_enabled || return 0

  resource_group="$(resource_group_name)"
  deployment_name="$(anyscale_platform_deployment_name)"
  deployment_id="$(anyscale_platform_deployment_resource_id)"

  if terraform state show "${resource_address}" >/dev/null 2>&1; then
    return 0
  fi

  if run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" az deployment group show \
    --resource-group "${resource_group}" \
    --name "${deployment_name}" \
    --only-show-errors >/dev/null 2>&1; then
    log "Importing existing Anyscale ARM deployment into Terraform state"
    terraform import "${resource_address}" "${deployment_id}" >/dev/null
  fi
}

ensure_harness_dir() {
  mkdir -p "${HARNESS_DIR}"
}

harness_state_file() {
  ensure_harness_dir
  printf '%s/%s\n' "${HARNESS_DIR}" "$1"
}

bastion_tunnel_pidfile() {
  harness_state_file "bastion-tunnel.pid"
}

bastion_tunnel_portfile() {
  harness_state_file "bastion-tunnel.port"
}

bastion_tunnel_logfile() {
  harness_state_file "bastion-tunnel.log"
}

workspace_browser_tunnel_pidfile() {
  harness_state_file "workspace-browser-tunnel.pid"
}

workspace_browser_tunnel_http_portfile() {
  harness_state_file "workspace-browser-tunnel.http-port"
}

workspace_browser_tunnel_https_portfile() {
  harness_state_file "workspace-browser-tunnel.https-port"
}

workspace_browser_tunnel_hostfile() {
  harness_state_file "workspace-browser-tunnel.host"
}

workspace_browser_tunnel_logfile() {
  harness_state_file "workspace-browser-tunnel.log"
}

workspace_head_forward_pidfile() {
  harness_state_file "workspace-head-forward.pid"
}

workspace_head_forward_dashboard_portfile() {
  harness_state_file "workspace-head-forward.dashboard-port"
}

workspace_head_forward_http_portfile() {
  harness_state_file "workspace-head-forward.http-port"
}

workspace_head_forward_sessionfile() {
  harness_state_file "workspace-head-forward.session"
}

workspace_head_forward_logfile() {
  harness_state_file "workspace-head-forward.log"
}

workspace_browser_app_pidfile() {
  harness_state_file "workspace-browser-app.pid"
}

workspace_browser_app_browserfile() {
  harness_state_file "workspace-browser-app.browser"
}

workspace_browser_app_urlfile() {
  harness_state_file "workspace-browser-app.url"
}

workspace_browser_app_hostfile() {
  harness_state_file "workspace-browser-app.host"
}

workspace_browser_app_logfile() {
  harness_state_file "workspace-browser-app.log"
}

workspace_browser_proxy_pidfile() {
  harness_state_file "workspace-browser-proxy.pid"
}

workspace_browser_proxy_portfile() {
  harness_state_file "workspace-browser-proxy.port"
}

workspace_browser_proxy_logfile() {
  harness_state_file "workspace-browser-proxy.log"
}

workspace_browser_proxy_pacfile() {
  harness_state_file "workspace-browser-proxy.pac"
}

workspace_browser_proxy_script_path() {
  harness_state_file "workspace-browser-proxy.py"
}

workspace_browser_profile_dir() {
  ensure_harness_dir
  printf '%s/workspace-browser-profile\n' "${HARNESS_DIR}"
}

bastion_kubeconfig_path() {
  harness_state_file "kubeconfig.bastion"
}

bastion_admin_kubeconfig_path() {
  harness_state_file "kubeconfig.bastion.admin"
}

terraform_state_backup_path() {
  local label="$1"
  local timestamp

  timestamp="$(date -u +"%Y%m%dT%H%M%SZ")"
  harness_state_file "terraform.tfstate.${label}.${timestamp}.backup"
}

pid_from_file() {
  local pid_file="$1"
  [[ -f "${pid_file}" ]] || return 0
  tr -d '[:space:]' < "${pid_file}"
}

pid_is_running() {
  local pid="${1:-}"
  [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null
}

listener_is_ready() {
  local port="$1"
  lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1
}

wait_for_local_listener() {
  local port="$1"
  local attempts="${2:-30}"
  local attempt

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if listener_is_ready "${port}"; then
      return 0
    fi
    sleep 1
  done

  return 1
}

listener_pids() {
  local port="$1"
  lsof -t -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null || true
}

first_listener_pid() {
  local port="$1"
  local listener_pid

  for listener_pid in $(listener_pids "${port}"); do
    [[ -n "${listener_pid}" ]] || continue
    printf '%s\n' "${listener_pid}"
    return 0
  done

  return 1
}

pid_command_line() {
  local pid="$1"
  ps -p "${pid}" -o command= 2>/dev/null || true
}

pid_is_bastion_tunnel() {
  local pid="$1"
  local command_line

  command_line="$(pid_command_line "${pid}")"
  [[ "${command_line}" == *"azure.cli network bastion tunnel"* ]]
}

port_listeners_are_bastion_tunnels() {
  local port="$1"
  local listener_pid found=false

  for listener_pid in $(listener_pids "${port}"); do
    [[ -n "${listener_pid}" ]] || continue
    found=true
    if ! pid_is_bastion_tunnel "${listener_pid}"; then
      return 1
    fi
  done

  [[ "${found}" == true ]]
}

pid_is_workspace_browser_tunnel() {
  local pid="$1"
  local command_line

  command_line="$(pid_command_line "${pid}")"
  [[ "${command_line}" == *"kubectl"* ]] \
    && [[ "${command_line}" == *"port-forward"* ]] \
    && [[ "${command_line}" == *"ingress-nginx-controller"* ]]
}

port_listeners_are_workspace_browser_tunnels() {
  local port="$1"
  local listener_pid found=false

  for listener_pid in $(listener_pids "${port}"); do
    [[ -n "${listener_pid}" ]] || continue
    found=true
    if ! pid_is_workspace_browser_tunnel "${listener_pid}"; then
      return 1
    fi
  done

  [[ "${found}" == true ]]
}

wait_for_listener_shutdown() {
  local port="$1"
  local attempts="${2:-10}"
  local attempt

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if ! listener_is_ready "${port}"; then
      return 0
    fi
    sleep 1
  done

  return 1
}

stop_bastion_listeners_on_port() {
  local port="$1"
  local listener_pid stopped=false

  for listener_pid in $(listener_pids "${port}"); do
    [[ -n "${listener_pid}" ]] || continue
    if ! pid_is_bastion_tunnel "${listener_pid}"; then
      continue
    fi
    kill "${listener_pid}" 2>/dev/null || true
    stopped=true
  done

  if [[ "${stopped}" == true ]]; then
    wait_for_listener_shutdown "${port}" 10 || true
    return 0
  fi

  return 1
}

stop_workspace_browser_tunnel_listeners_on_port() {
  local port="$1"
  local listener_pid stopped=false

  for listener_pid in $(listener_pids "${port}"); do
    [[ -n "${listener_pid}" ]] || continue
    if ! pid_is_workspace_browser_tunnel "${listener_pid}"; then
      continue
    fi
    kill "${listener_pid}" 2>/dev/null || true
    stopped=true
  done

  if [[ "${stopped}" == true ]]; then
    wait_for_listener_shutdown "${port}" 10 || true
    return 0
  fi

  return 1
}

workspace_browser_app_pids() {
  local profile_dir browser_pid command_line

  profile_dir="$(workspace_browser_profile_dir)"
  for browser_pid in $(pgrep -f firefox 2>/dev/null || true); do
    [[ -n "${browser_pid}" ]] || continue
    command_line="$(pid_command_line "${browser_pid}")"
    [[ "${command_line}" == *"${profile_dir}"* ]] || continue
    printf '%s\n' "${browser_pid}"
  done
}

workspace_browser_app_is_running() {
  local browser_pid

  for browser_pid in $(workspace_browser_app_pids); do
    [[ -n "${browser_pid}" ]] || continue
    return 0
  done

  return 1
}

stop_workspace_browser_app_processes() {
  local browser_pid stopped=false

  for browser_pid in $(workspace_browser_app_pids); do
    [[ -n "${browser_pid}" ]] || continue
    kill "${browser_pid}" 2>/dev/null || true
    stopped=true
  done

  if [[ "${stopped}" == true ]]; then
    sleep 1
    for browser_pid in $(workspace_browser_app_pids); do
      [[ -n "${browser_pid}" ]] || continue
      kill -9 "${browser_pid}" 2>/dev/null || true
    done
    return 0
  fi

  return 1
}

workspace_browser_proxy_pids() {
  local proxy_pid script_path command_line

  script_path="$(workspace_browser_proxy_script_path)"
  for proxy_pid in $(pgrep -f -- "${script_path}" 2>/dev/null || true); do
    [[ -n "${proxy_pid}" ]] || continue
    command_line="$(pid_command_line "${proxy_pid}")"
    [[ "${command_line}" == *"${script_path}"* ]] || continue
    printf '%s\n' "${proxy_pid}"
  done
}

workspace_browser_proxy_is_running() {
  local proxy_pid

  for proxy_pid in $(workspace_browser_proxy_pids); do
    [[ -n "${proxy_pid}" ]] || continue
    return 0
  done

  return 1
}

stop_workspace_browser_proxy_processes() {
  local proxy_pid stopped=false

  for proxy_pid in $(workspace_browser_proxy_pids); do
    [[ -n "${proxy_pid}" ]] || continue
    kill "${proxy_pid}" 2>/dev/null || true
    stopped=true
  done

  if [[ "${stopped}" == true ]]; then
    sleep 1
    for proxy_pid in $(workspace_browser_proxy_pids); do
      [[ -n "${proxy_pid}" ]] || continue
      kill -9 "${proxy_pid}" 2>/dev/null || true
    done
    return 0
  fi

  return 1
}

kubectl_readyz() {
  local kubeconfig_file="${1:-}"

  if [[ -n "${kubeconfig_file}" ]]; then
    KUBECONFIG="${kubeconfig_file}" kubectl --request-timeout="${SETUP_TIMEOUT_KUBECTL_READY_SECONDS}s" get --raw=/readyz >/dev/null
    return 0
  fi

  kubectl --request-timeout="${SETUP_TIMEOUT_KUBECTL_READY_SECONDS}s" get --raw=/readyz >/dev/null
}

clear_runtime_files() {
  rm -f "$@"
}

focused_validation_report_dir() {
  printf '%s/%s\n' "${VALIDATION_REPORT_ROOT}" "${FOCUSED_VALIDATION_RUN_ID}"
}

focused_validation_display_path() {
  local path="$1"
  if [[ "${path}" == "${ROOT_DIR}"/* ]]; then
    printf '%s\n' "${path#${ROOT_DIR}/}"
    return 0
  fi
  printf '%s\n' "${path}"
}

reset_focused_validation_run() {
  FOCUSED_VALIDATION_RUN_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
  FOCUSED_VALIDATION_RESULTS=()
  FOCUSED_VALIDATION_PASS_COUNT=0
  FOCUSED_VALIDATION_FAIL_COUNT=0
  FOCUSED_VALIDATION_SKIP_COUNT=0
  mkdir -p "$(focused_validation_report_dir)"
}

record_focused_validation_result() {
  local status="$1"
  local check_id="$2"
  local label="$3"
  local logfile="$4"

  FOCUSED_VALIDATION_RESULTS+=("${status}|${check_id}|${label}|${logfile}")
  case "${status}" in
    PASS) ((FOCUSED_VALIDATION_PASS_COUNT+=1)) ;;
    FAIL) ((FOCUSED_VALIDATION_FAIL_COUNT+=1)) ;;
    SKIP) ((FOCUSED_VALIDATION_SKIP_COUNT+=1)) ;;
  esac
}

run_focused_validation_check() {
  local check_id="$1"
  local label="$2"
  shift 2

  local logfile display_logfile
  logfile="$(focused_validation_report_dir)/${check_id}.log"
  display_logfile="$(focused_validation_display_path "${logfile}")"

  printf '\n==> %s\n' "${label}"
  local exit_code
  set +e
  ( set -e; "$@" ) 2>&1 | tee "${logfile}"
  exit_code=${PIPESTATUS[0]}
  set -e

  if [[ "${exit_code}" -eq 0 ]]; then
    record_focused_validation_result "PASS" "${check_id}" "${label}" "${display_logfile}"
    printf '[PASS] %s\n' "${label}"
    return 0
  fi

  record_focused_validation_result "FAIL" "${check_id}" "${label}" "${display_logfile}"
  printf '[FAIL] %s\n' "${label}"
  printf '       log: %s\n' "${display_logfile}"
  return 1
}

skip_focused_validation_check() {
  local check_id="$1"
  local label="$2"
  local reason="$3"
  local logfile display_logfile

  logfile="$(focused_validation_report_dir)/${check_id}.log"
  display_logfile="$(focused_validation_display_path "${logfile}")"
  printf '%s\n' "${reason}" > "${logfile}"
  record_focused_validation_result "SKIP" "${check_id}" "${label}" "${display_logfile}"
  printf '[SKIP] %s\n' "${label}"
  printf '       reason: %s\n' "${reason}"
}

write_focused_validation_summary() {
  local summary_file display_summary_file result status check_id label logfile
  summary_file="$(focused_validation_report_dir)/summary.txt"
  display_summary_file="$(focused_validation_display_path "${summary_file}")"

  {
    printf 'Focused validation run: %s\n' "${FOCUSED_VALIDATION_RUN_ID}"
    printf '%-6s %-36s %s\n' "STATUS" "CHECK" "LOG"
    printf '%-6s %-36s %s\n' "------" "------------------------------------" "---"
    for result in "${FOCUSED_VALIDATION_RESULTS[@]}"; do
      IFS='|' read -r status check_id label logfile <<<"${result}"
      printf '%-6s %-36s %s\n' "${status}" "${label}" "${logfile}"
    done
    printf '\npass=%s fail=%s skip=%s\n' \
      "${FOCUSED_VALIDATION_PASS_COUNT}" \
      "${FOCUSED_VALIDATION_FAIL_COUNT}" \
      "${FOCUSED_VALIDATION_SKIP_COUNT}"
  } | tee "${summary_file}"

  log "Focused validation summary written to ${display_summary_file}"
}

ensure_bastion_extensions() {
  log "Ensuring az aks-preview + bastion extensions"
  run_with_timeout "${SETUP_TIMEOUT_AZURE_EXTENSION_SECONDS}" az extension add --name aks-preview --upgrade --yes --only-show-errors >/dev/null 2>&1 || true
  run_with_timeout "${SETUP_TIMEOUT_AZURE_EXTENSION_SECONDS}" az extension add --name bastion --upgrade --yes --only-show-errors >/dev/null 2>&1 || true
}

ensure_helm_test_repositories() {
  command -v helm >/dev/null 2>&1 || return 0

  log "Ensuring Helm repositories required by Terraform tests"
  helm repo add nvdp https://nvidia.github.io/k8s-device-plugin >/dev/null 2>&1 || true
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
  run_with_timeout "${SETUP_TIMEOUT_HELM_SECONDS}" helm repo update nvdp ingress-nginx >/dev/null
}

resolve_aks_context() {
  local field="$1"
  terraform_output_raw "${field}"
}

resolve_aks_cluster_id() {
  local rg cluster
  rg="$(resolve_aks_context resource_group_name)"
  cluster="$(resolve_aks_context aks_cluster_name)"
  [[ -n "${rg}" && -n "${cluster}" ]] || die "Terraform outputs are missing. Run ./scripts/setup.sh deploy first."
  run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" az aks show --resource-group "${rg}" --name "${cluster}" --query id -o tsv --only-show-errors
}

use_bastion_kubeconfig_if_present() {
  local kubeconfig_file pidfile portfile pid port current_server
  kubeconfig_file="$(bastion_kubeconfig_path)"

  pidfile="$(bastion_tunnel_pidfile)"
  portfile="$(bastion_tunnel_portfile)"
  pid="$(pid_from_file "${pidfile}")"
  port="$(cat "${portfile}" 2>/dev/null || true)"

  if [[ -f "${kubeconfig_file}" && -n "${port}" ]] \
    && pid_is_running "${pid}" \
    && listener_is_ready "${port}"; then
    current_server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
    if [[ ! "${current_server}" =~ ^https://(127\.0\.0\.1|localhost):[0-9]+/?$ ]]; then
      export_kubeconfig_env "${kubeconfig_file}"
    fi
  elif [[ -z "${KUBECONFIG:-}" && -f "${kubeconfig_file}" ]]; then
    export_kubeconfig_env "${kubeconfig_file}"
  fi
}

require_cluster_kubectl_access() {
  require_cmd kubectl
  use_bastion_kubeconfig_if_present
  ensure_kubelogin_kubeconfig
  kubectl_readyz >/dev/null 2>&1 || die "kubectl cannot reach the cluster. Re-run ./scripts/setup.sh deploy or ./scripts/setup.sh verify --live so the orchestrator can refresh Bastion access."
}

workspace_browser_session_suffix() {
  local value="${1:-}"

  [[ -n "${value}" ]] || die "A session id or session host is required."

  value="${value#https://}"
  value="${value#http://}"
  value="${value%%/*}"

  case "${value}" in
    session-*.i.azure.anyscaleuserdata.com)
      value="${value#session-}"
      value="${value%%.i.azure.anyscaleuserdata.com}"
      ;;
    vscode-session-*.i.azure.anyscaleuserdata.com)
      value="${value#vscode-session-}"
      value="${value%%.i.azure.anyscaleuserdata.com}"
      ;;
    serve-session-*.i.azure.anyscaleuserdata.com)
      value="${value#serve-session-}"
      value="${value%%.i.azure.anyscaleuserdata.com}"
      ;;
  esac

  case "${value}" in
    ses_*) value="${value#ses_}" ;;
    ses-*) value="${value#ses-}" ;;
  esac

  value="${value//_/-}"
  [[ -n "${value}" ]] || die "Could not derive a session suffix from '${1}'."
  printf '%s\n' "${value}"
}

workspace_browser_primary_host() {
  local session_suffix="$1"
  printf 'session-%s.i.azure.anyscaleuserdata.com\n' "${session_suffix}"
}

workspace_browser_session_id() {
  local value="${1:-}"
  local session_suffix

  [[ -n "${value}" ]] || die "A session id or session host is required."

  case "${value}" in
    ses_*)
      printf '%s\n' "${value}"
      return 0
      ;;
    ses-*)
      printf 'ses_%s\n' "${value#ses-}"
      return 0
      ;;
  esac

  session_suffix="$(workspace_browser_session_suffix "${value}")"
  printf 'ses_%s\n' "${session_suffix//-/_}"
}

workspace_browser_hosts_entry() {
  local session_suffix="$1"
  printf '127.0.0.1 session-%s.i.azure.anyscaleuserdata.com vscode-session-%s.i.azure.anyscaleuserdata.com serve-session-%s.i.azure.anyscaleuserdata.com\n' \
    "${session_suffix}" \
    "${session_suffix}" \
    "${session_suffix}"
}

print_workspace_browser_tunnel_details() {
  local host="$1"
  local http_port="$2"
  local https_port="$3"
  local session_suffix

  session_suffix="$(workspace_browser_session_suffix "${host}")"

  printf 'session_host=%s\n' "${host}"
  printf 'http_port=%s\n' "${http_port}"
  printf 'https_port=%s\n' "${https_port}"
  printf 'hosts_entry=%s\n' "$(workspace_browser_hosts_entry "${session_suffix}")"
  printf 'browser_url=https://%s:%s/\n' "${host}" "${https_port}"
  printf 'http_probe=curl -I -H "Host: %s" http://127.0.0.1:%s/\n' "${host}" "${http_port}"
  printf 'https_probe=curl -k -I --resolve "%s:%s:127.0.0.1" "https://%s:%s/"\n' "${host}" "${https_port}" "${host}" "${https_port}"
}

print_workspace_head_forward_details() {
  local session_id="$1"
  local dashboard_port="$2"
  local http_port="$3"

  printf 'session_id=%s\n' "${session_id}"
  printf 'dashboard_port=%s\n' "${dashboard_port}"
  printf 'session_http_port=%s\n' "${http_port}"
  printf 'dashboard_url=http://127.0.0.1:%s/\n' "${dashboard_port}"
  printf 'session_http_url=http://127.0.0.1:%s/\n' "${http_port}"
  printf 'dashboard_probe=curl -I http://127.0.0.1:%s/\n' "${dashboard_port}"
  printf 'session_http_probe=curl -I http://127.0.0.1:%s/\n' "${http_port}"
}

path_as_file_uri() {
  local target_path="$1"

  python3 - "$target_path" <<'PY'
import pathlib
import sys

print(pathlib.Path(sys.argv[1]).resolve().as_uri())
PY
}

workspace_browser_auth_url() {
  require_cmd python3

  local session_id="$1"
  local host="$2"

  python3 - "$session_id" "$host" <<'PY'
import base64
import json
import secrets
import sys

session_id = sys.argv[1]
host = sys.argv[2]
relay_state = base64.b64encode(
  json.dumps(
    {
      "original_href": f"https://{host}/",
      "nonce": secrets.token_hex(32),
      "via_edge": "",
    },
    separators=(",", ":"),
  ).encode()
).decode().rstrip("=")

print(
  f"https://console.azure.anyscale.com/cluster_auth/{session_id}?relay_state={relay_state}&theme=light"
)
PY
}

write_workspace_browser_proxy_script() {
  local script_path

  script_path="$(workspace_browser_proxy_script_path)"
  cat > "${script_path}" <<'PY'
#!/usr/bin/env python3
import argparse
import selectors
import socket
import socketserver
import sys
import urllib.parse


def build_allowed_hosts(session_suffix):
    return {
        f"session-{session_suffix}.i.azure.anyscaleuserdata.com",
        f"vscode-session-{session_suffix}.i.azure.anyscaleuserdata.com",
        f"serve-session-{session_suffix}.i.azure.anyscaleuserdata.com",
    }


class ProxyHandler(socketserver.StreamRequestHandler):
    allowed_hosts = set()
    local_http_port = 18081
    local_https_port = 18443

    def handle(self):
        request_line = self.rfile.readline().decode("iso-8859-1").strip()
        if not request_line:
            return

        parts = request_line.split()
        if len(parts) != 3:
            self.send_error(400, b"Bad Request")
            return

        method, target, version = parts
        headers = self.read_headers()

        try:
            if method.upper() == "CONNECT":
                self.handle_connect(target)
            else:
                self.handle_http(method, target, version, headers)
        except Exception:
            self.send_error(502, b"Bad Gateway")

    def read_headers(self):
        headers = []
        while True:
            line = self.rfile.readline()
            if line in (b"\r\n", b"\n", b""):
                break
            headers.append(line)
        return headers

    def resolve_target(self, host, port):
        if host not in self.allowed_hosts:
            return None
        if port in (80, self.local_http_port):
            return ("127.0.0.1", self.local_http_port)
        if port in (443, self.local_https_port):
            return ("127.0.0.1", self.local_https_port)
        return None

    def handle_connect(self, target):
        if ":" not in target:
            self.send_error(400, b"CONNECT target missing port")
            return

        host, port_str = target.rsplit(":", 1)
        upstream_target = self.resolve_target(host, int(port_str))
        if upstream_target is None:
            self.send_error(403, b"Forbidden")
            return

        upstream = socket.create_connection(upstream_target, timeout=10)
        self.connection.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        self.tunnel(self.connection, upstream)

    def handle_http(self, method, target, version, headers):
        parsed = urllib.parse.urlsplit(target)
        host = parsed.hostname
        port = parsed.port or 80
        upstream_target = self.resolve_target(host, port)
        if upstream_target is None:
            self.send_error(403, b"Forbidden")
            return

        path = urllib.parse.urlunsplit(("", "", parsed.path or "/", parsed.query, parsed.fragment))
        request_head = f"{method} {path} {version}\r\n".encode("iso-8859-1")
        upstream = socket.create_connection(upstream_target, timeout=10)
        upstream.sendall(request_head)
        for header in headers:
            upstream.sendall(header)
        upstream.sendall(b"\r\n")
        self.tunnel(self.connection, upstream)

    def tunnel(self, client, upstream):
        selector = selectors.DefaultSelector()
        selector.register(client, selectors.EVENT_READ, upstream)
        selector.register(upstream, selectors.EVENT_READ, client)
        sockets = [client, upstream]
        try:
            while True:
                events = selector.select(timeout=30)
                if not events:
                    break
                for key, _ in events:
                    source = key.fileobj
                    dest = key.data
                    data = source.recv(65536)
                    if not data:
                        return
                    dest.sendall(data)
        finally:
            for sock in sockets:
                try:
                    sock.close()
                except OSError:
                    pass

    def send_error(self, code, message):
        response = (
            f"HTTP/1.1 {code} Error\r\n"
            f"Content-Length: {len(message)}\r\n"
            "Connection: close\r\n\r\n"
        ).encode("iso-8859-1") + message
        self.connection.sendall(response)


class ThreadingTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen-port", type=int, required=True)
    parser.add_argument("--session-suffix", required=True)
    parser.add_argument("--local-http-port", type=int, required=True)
    parser.add_argument("--local-https-port", type=int, required=True)
    args = parser.parse_args()

    ProxyHandler.allowed_hosts = build_allowed_hosts(args.session_suffix)
    ProxyHandler.local_http_port = args.local_http_port
    ProxyHandler.local_https_port = args.local_https_port

    with ThreadingTCPServer(("127.0.0.1", args.listen_port), ProxyHandler) as server:
        server.serve_forever()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
PY
  chmod +x "${script_path}"
}

write_workspace_browser_proxy_pac() {
  local session_suffix="$1"
  local proxy_port="$2"
  local pac_path

  pac_path="$(workspace_browser_proxy_pacfile)"
  cat > "${pac_path}" <<EOF
function FindProxyForURL(url, host) {
  if (host == "session-${session_suffix}.i.azure.anyscaleuserdata.com" ||
      host == "vscode-session-${session_suffix}.i.azure.anyscaleuserdata.com" ||
      host == "serve-session-${session_suffix}.i.azure.anyscaleuserdata.com") {
    return "PROXY 127.0.0.1:${proxy_port}";
  }
  return "DIRECT";
}
EOF
}

start_workspace_browser_proxy() {
  require_cmd python3

  local session_suffix="$1"
  local http_port="$2"
  local https_port="$3"
  local proxy_port="18777"
  local requested_proxy_port candidate_proxy_port proxy_pid logfile script_path

  requested_proxy_port="${proxy_port}"
  if listener_is_ready "${proxy_port}"; then
    for ((candidate_proxy_port = proxy_port + 1; candidate_proxy_port <= proxy_port + 20; candidate_proxy_port++)); do
      if ! listener_is_ready "${candidate_proxy_port}"; then
        proxy_port="${candidate_proxy_port}"
        warn "Local proxy port ${requested_proxy_port} is already in use; using ${proxy_port} instead."
        break
      fi
    done
  fi

  write_workspace_browser_proxy_script
  write_workspace_browser_proxy_pac "${session_suffix}" "${proxy_port}"

  logfile="$(workspace_browser_proxy_logfile)"
  script_path="$(workspace_browser_proxy_script_path)"
  : > "${logfile}"

  nohup python3 "${script_path}" \
    --listen-port "${proxy_port}" \
    --session-suffix "${session_suffix}" \
    --local-http-port "${http_port}" \
    --local-https-port "${https_port}" > "${logfile}" 2>&1 &
  proxy_pid="$!"

  if ! wait_for_local_listener "${proxy_port}" 30; then
    kill "${proxy_pid}" 2>/dev/null || true
    tail -20 "${logfile}" >&2 || true
    die "Workspace browser proxy did not open on port ${proxy_port}."
  fi

  printf '%s\n' "${proxy_pid}" > "$(workspace_browser_proxy_pidfile)"
  printf '%s\n' "${proxy_port}" > "$(workspace_browser_proxy_portfile)"
  printf 'proxy_port=%s\n' "${proxy_port}"
  printf 'proxy_pac=%s\n' "$(workspace_browser_proxy_pacfile)"
}

detect_workspace_browser_binary() {
  local requested_browser="${1:-firefox}"
  local app_path binary_path

  case "${requested_browser}" in
    firefox)
      for app_path in \
        "/Volumes/External SSD/Apps/Firefox.app" \
        "/Applications/Firefox.app" \
        "/Applications/Firefox Developer Edition.app" \
        "/Applications/Firefox Nightly.app" \
        "/Applications/LibreWolf.app"; do
        [[ -d "${app_path}" ]] || continue
        if [[ "${app_path}" == *"LibreWolf.app" ]]; then
          binary_path="${app_path}/Contents/MacOS/librewolf"
        else
          binary_path="${app_path}/Contents/MacOS/firefox"
        fi
        if [[ -x "${binary_path}" ]]; then
          printf '%s\n' "${binary_path}"
          return 0
        fi
      done
      ;;
    *)
      die "Unknown browser '${requested_browser}'. Use firefox."
      ;;
  esac

  die "Firefox was not found. Expected it under /Volumes/External SSD/Apps/Firefox.app or a standard /Applications Firefox install."
}

write_workspace_browser_user_prefs() {
  local pac_uri="$1"
  local profile_dir

  profile_dir="$(workspace_browser_profile_dir)"
  cat > "${profile_dir}/user.js" <<EOF
user_pref("app.normandy.first_run", false);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.tabs.warnOnClose", false);
user_pref("browser.aboutConfig.showWarning", false);
user_pref("browser.startup.homepage", "about:blank");
user_pref("browser.startup.page", 0);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("network.captive-portal-service.enabled", false);
user_pref("network.proxy.type", 2);
user_pref("network.proxy.autoconfig_url", "${pac_uri}");
user_pref("network.proxy.autoconfig_retry_interval_min", 1);
user_pref("network.proxy.no_proxies_on", "");
EOF
}

print_workspace_browser_app_details() {
  local browser_binary="$1"
  local browser_url="$2"
  local host="$3"
  local proxy_port="${4:-}"
  local pac_file="${5:-}"

  printf 'browser_binary=%s\n' "${browser_binary}"
  printf 'browser_profile=%s\n' "$(workspace_browser_profile_dir)"
  printf 'browser_url=%s\n' "${browser_url}"
  printf 'session_host=%s\n' "${host}"
  [[ -n "${proxy_port}" ]] && printf 'browser_proxy_port=%s\n' "${proxy_port}"
  [[ -n "${pac_file}" ]] && printf 'browser_proxy_pac=%s\n' "${pac_file}"
}

workspace_browser_tunnel() {
  require_cmd curl
  require_cmd kubectl
  require_cmd lsof

  local action="start"
  shift || true

  local pidfile http_portfile https_portfile hostfile logfile pid http_port https_port host session_value
  local ingress_name listener_pid launcher_pid http_status https_status tracked_http_port tracked_https_port tracked_host
  pidfile="$(workspace_browser_tunnel_pidfile)"
  http_portfile="$(workspace_browser_tunnel_http_portfile)"
  https_portfile="$(workspace_browser_tunnel_https_portfile)"
  hostfile="$(workspace_browser_tunnel_hostfile)"
  logfile="$(workspace_browser_tunnel_logfile)"
  http_port="18081"
  https_port="18443"
  host=""
  session_value=""

  case "${action}" in
    start)
      local requested_bastion_port candidate_bastion_port
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --session-id|--cluster-id|--session-host|--host)
            [[ $# -ge 2 ]] || die "$1 requires a value."
            session_value="$2"
            shift 2
            ;;
          --http-port)
            [[ $# -ge 2 ]] || die "--http-port requires a value."
            http_port="$2"
            shift 2
            ;;
          --https-port)
            [[ $# -ge 2 ]] || die "--https-port requires a value."
            https_port="$2"
            shift 2
            ;;
          --help|-h)
            cat <<'USAGE'
Usage:
  ./scripts/setup.sh workspace-browser-tunnel start --session-id ses_xxx [--http-port 18081] [--https-port 18443]
  ./scripts/setup.sh workspace-browser-tunnel status
  ./scripts/setup.sh workspace-browser-tunnel stop

Requires kubectl access to the private AKS cluster, usually via:
  ./scripts/setup.sh bastion-tunnel start
  eval "$(./scripts/setup.sh kubeconfig-bastion --export)"

Starts a local port-forward to ingress-nginx so a browser on this Mac can reach
the private session hostname after adding the printed /etc/hosts entry.
USAGE
            return 0
            ;;
          *)
            die "Unknown workspace-browser-tunnel option: $1"
            ;;
        esac
      done

      [[ -n "${session_value}" ]] || die "workspace-browser-tunnel start requires --session-id or --session-host."

      require_cluster_kubectl_access

      host="$(workspace_browser_primary_host "$(workspace_browser_session_suffix "${session_value}")")"
      ingress_name="ses-$(workspace_browser_session_suffix "${session_value}")-head"

      kubectl -n anyscale-operator get ingress "${ingress_name}" >/dev/null 2>&1 \
        || die "Ingress ${ingress_name} was not found in namespace anyscale-operator. Confirm the session is still live before tunneling it."
      kubectl -n ingress-nginx get service ingress-nginx-controller >/dev/null 2>&1 \
        || die "Service ingress-nginx/ingress-nginx-controller was not found."

      pid="$(pid_from_file "${pidfile}")"
      tracked_http_port="$(cat "${http_portfile}" 2>/dev/null || true)"
      tracked_https_port="$(cat "${https_portfile}" 2>/dev/null || true)"
      tracked_host="$(cat "${hostfile}" 2>/dev/null || true)"

      if pid_is_running "${pid}" \
        && [[ -n "${tracked_http_port}" && -n "${tracked_https_port}" ]] \
        && listener_is_ready "${tracked_http_port}" \
        && listener_is_ready "${tracked_https_port}" \
        && port_listeners_are_workspace_browser_tunnels "${tracked_http_port}" \
        && port_listeners_are_workspace_browser_tunnels "${tracked_https_port}"; then
        if [[ "${tracked_http_port}" != "${http_port}" || "${tracked_https_port}" != "${https_port}" ]]; then
          log "Restarting existing workspace browser tunnel on ports ${tracked_http_port}/${tracked_https_port} to use ${http_port}/${https_port}"
          kill "${pid}" 2>/dev/null || true
          stop_workspace_browser_tunnel_listeners_on_port "${tracked_http_port}" || true
          if [[ "${tracked_https_port}" != "${tracked_http_port}" ]]; then
            stop_workspace_browser_tunnel_listeners_on_port "${tracked_https_port}" || true
          fi
          clear_runtime_files "${pidfile}" "${http_portfile}" "${https_portfile}" "${hostfile}"
        else
          printf '%s\n' "${host}" > "${hostfile}"
          log "Workspace browser tunnel already running on 127.0.0.1:${http_port} and 127.0.0.1:${https_port}"
          print_workspace_browser_tunnel_details "${host}" "${http_port}" "${https_port}"
          printf 'log file: %s\n' "${logfile}"
          return 0
        fi
      fi

      if listener_is_ready "${http_port}"; then
        if ! port_listeners_are_workspace_browser_tunnels "${http_port}"; then
          die "Local HTTP port ${http_port} is already in use. Pick another with --http-port."
        fi
        stop_workspace_browser_tunnel_listeners_on_port "${http_port}" || true
      fi
      if listener_is_ready "${https_port}"; then
        if ! port_listeners_are_workspace_browser_tunnels "${https_port}"; then
          die "Local HTTPS port ${https_port} is already in use. Pick another with --https-port."
        fi
        stop_workspace_browser_tunnel_listeners_on_port "${https_port}" || true
      fi
      if listener_is_ready "${http_port}" || listener_is_ready "${https_port}"; then
        die "Requested local browser-tunnel ports are still in use after cleanup. Pick different ports."
      fi

      : > "${logfile}"
      log "Starting workspace browser tunnel for ${host} on 127.0.0.1:${http_port}/${https_port}"
      nohup kubectl -n ingress-nginx port-forward service/ingress-nginx-controller "${http_port}:80" "${https_port}:443" > "${logfile}" 2>&1 &
      launcher_pid="$!"

      if ! wait_for_local_listener "${http_port}" 30 || ! wait_for_local_listener "${https_port}" 30; then
        kill "${launcher_pid}" 2>/dev/null || true
        stop_workspace_browser_tunnel_listeners_on_port "${http_port}" || true
        stop_workspace_browser_tunnel_listeners_on_port "${https_port}" || true
        clear_runtime_files "${pidfile}" "${http_portfile}" "${https_portfile}" "${hostfile}"
        tail -20 "${logfile}" >&2 || true
        die "Workspace browser tunnel did not open on ports ${http_port}/${https_port}."
      fi

      listener_pid="$(first_listener_pid "${http_port}" 2>/dev/null || true)"
      [[ -n "${listener_pid}" ]] || die "Workspace browser tunnel opened but no listener PID was found."

      printf '%s\n' "${listener_pid}" > "${pidfile}"
      printf '%s\n' "${http_port}" > "${http_portfile}"
      printf '%s\n' "${https_port}" > "${https_portfile}"
      printf '%s\n' "${host}" > "${hostfile}"

      http_status="$(curl -sS -o /dev/null -w '%{http_code}' -H "Host: ${host}" "http://127.0.0.1:${http_port}/" || true)"
      https_status="$(curl -skS -o /dev/null -w '%{http_code}' --resolve "${host}:${https_port}:127.0.0.1" "https://${host}:${https_port}/" || true)"
      if [[ "${http_status}" == "000" ]]; then
        warn "HTTP probe to ${host} via 127.0.0.1:${http_port} failed. Check ${logfile}."
      else
        printf 'http_status=%s\n' "${http_status}"
      fi
      if [[ "${https_status}" == "000" ]]; then
        warn "HTTPS probe to ${host} via 127.0.0.1:${https_port} failed. Check ${logfile}."
      else
        printf 'https_status=%s\n' "${https_status}"
      fi

      log "Workspace browser tunnel ready"
      print_workspace_browser_tunnel_details "${host}" "${http_port}" "${https_port}"
      printf 'log file: %s\n' "${logfile}"
      ;;
    status)
      pid="$(pid_from_file "${pidfile}")"
      http_port="$(cat "${http_portfile}" 2>/dev/null || true)"
      https_port="$(cat "${https_portfile}" 2>/dev/null || true)"
      host="$(cat "${hostfile}" 2>/dev/null || true)"

      if [[ -n "${http_port}" && -n "${https_port}" && -n "${host}" ]] \
        && listener_is_ready "${http_port}" \
        && listener_is_ready "${https_port}" \
        && port_listeners_are_workspace_browser_tunnels "${http_port}" \
        && port_listeners_are_workspace_browser_tunnels "${https_port}"; then
        pid="$(first_listener_pid "${http_port}" 2>/dev/null || true)"
        [[ -n "${pid}" ]] && printf '%s\n' "${pid}" > "${pidfile}"
        printf 'status=running\n'
        printf 'pid=%s\n' "${pid}"
        print_workspace_browser_tunnel_details "${host}" "${http_port}" "${https_port}"
        printf 'log=%s\n' "${logfile}"
        return 0
      fi

      clear_runtime_files "${pidfile}" "${http_portfile}" "${https_portfile}" "${hostfile}"
      printf 'status=stopped\n'
      printf 'log=%s\n' "${logfile}"
      return 1
      ;;
    stop)
      local stopped=false
      pid="$(pid_from_file "${pidfile}")"
      http_port="$(cat "${http_portfile}" 2>/dev/null || true)"
      https_port="$(cat "${https_portfile}" 2>/dev/null || true)"

      if pid_is_running "${pid}"; then
        kill "${pid}" 2>/dev/null || true
        stopped=true
      fi
      if [[ -n "${http_port}" ]] && stop_workspace_browser_tunnel_listeners_on_port "${http_port}"; then
        stopped=true
      fi
      if [[ -n "${https_port}" && "${https_port}" != "${http_port}" ]] && stop_workspace_browser_tunnel_listeners_on_port "${https_port}"; then
        stopped=true
      fi

      if [[ "${stopped}" == true ]]; then
        log "Stopped workspace browser tunnel${http_port:+ on 127.0.0.1:${http_port}/${https_port}}"
      else
        warn "No running workspace browser tunnel found."
      fi

      clear_runtime_files "${pidfile}" "${http_portfile}" "${https_portfile}" "${hostfile}"
      ;;
    *)
      die "Usage: ./scripts/setup.sh workspace-browser-tunnel {start|status|stop}"
      ;;
  esac
}

workspace_head_forward() {
  require_cmd kubectl
  require_cmd lsof

  local action="start"
  if [[ $# -gt 0 && ! "$1" =~ ^- ]]; then
    action="$1"
    shift || true
  fi

  local pidfile dashboard_portfile http_portfile sessionfile logfile pid dashboard_port http_port session_value session_id service_name listener_pid launcher_pid tracked_dashboard_port tracked_http_port tracked_session
  pidfile="$(workspace_head_forward_pidfile)"
  dashboard_portfile="$(workspace_head_forward_dashboard_portfile)"
  http_portfile="$(workspace_head_forward_http_portfile)"
  sessionfile="$(workspace_head_forward_sessionfile)"
  logfile="$(workspace_head_forward_logfile)"
  dashboard_port="18265"
  http_port="18080"
  session_value=""

  case "${action}" in
    start)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --session-id|--cluster-id|--session-host|--host)
            [[ $# -ge 2 ]] || die "$1 requires a value."
            session_value="$2"
            shift 2
            ;;
          --dashboard-port)
            [[ $# -ge 2 ]] || die "--dashboard-port requires a value."
            dashboard_port="$2"
            shift 2
            ;;
          --http-port)
            [[ $# -ge 2 ]] || die "--http-port requires a value."
            http_port="$2"
            shift 2
            ;;
          --help|-h)
            cat <<'USAGE'
Usage:
  ./scripts/setup.sh workspace-head-forward --session-id ses_xxx [--dashboard-port 18265] [--http-port 18080]
  ./scripts/setup.sh workspace-head-forward status
  ./scripts/setup.sh workspace-head-forward stop

Starts or reuses the Bastion-backed kubeconfig path and port-forwards the live
session head service directly to localhost. This bypasses the Anyscale
cluster_auth browser flow and exposes the Ray Dashboard on 127.0.0.1.
USAGE
            return 0
            ;;
          *)
            die "Unknown workspace-head-forward option: $1"
            ;;
        esac
      done

      [[ -n "${session_value}" ]] || die "workspace-head-forward start requires --session-id or --session-host."

      bastion_tunnel start --port "64435"
      export_kubeconfig_env "$(kubeconfig_bastion --print-path)"
      require_cluster_kubectl_access

      session_id="$(workspace_browser_session_id "${session_value}")"
      service_name="${session_id//_/-}-head"

      kubectl -n anyscale-operator get service "${service_name}" >/dev/null 2>&1 \
        || die "Service ${service_name} was not found in namespace anyscale-operator. Confirm the session is still live before forwarding it."

      pid="$(pid_from_file "${pidfile}")"
      tracked_dashboard_port="$(cat "${dashboard_portfile}" 2>/dev/null || true)"
      tracked_http_port="$(cat "${http_portfile}" 2>/dev/null || true)"
      tracked_session="$(cat "${sessionfile}" 2>/dev/null || true)"

      if pid_is_running "${pid}" \
        && [[ -n "${tracked_dashboard_port}" && -n "${tracked_http_port}" ]] \
        && listener_is_ready "${tracked_dashboard_port}" \
        && listener_is_ready "${tracked_http_port}"; then
        if [[ "${tracked_dashboard_port}" == "${dashboard_port}" && "${tracked_http_port}" == "${http_port}" && "${tracked_session}" == "${session_id}" ]]; then
          log "Workspace head port-forward already running on 127.0.0.1:${dashboard_port} and 127.0.0.1:${http_port}"
          print_workspace_head_forward_details "${session_id}" "${dashboard_port}" "${http_port}"
          printf 'log file: %s\n' "${logfile}"
          return 0
        fi

        kill "${pid}" 2>/dev/null || true
        [[ -n "${tracked_dashboard_port}" ]] && stop_workspace_browser_tunnel_listeners_on_port "${tracked_dashboard_port}" || true
        if [[ -n "${tracked_http_port}" && "${tracked_http_port}" != "${tracked_dashboard_port}" ]]; then
          stop_workspace_browser_tunnel_listeners_on_port "${tracked_http_port}" || true
        fi
        clear_runtime_files "${pidfile}" "${dashboard_portfile}" "${http_portfile}" "${sessionfile}"
      fi

      if listener_is_ready "${dashboard_port}"; then
        die "Local dashboard port ${dashboard_port} is already in use. Pick another with --dashboard-port."
      fi
      if listener_is_ready "${http_port}"; then
        die "Local HTTP port ${http_port} is already in use. Pick another with --http-port."
      fi

      : > "${logfile}"
      log "Starting workspace head port-forward for ${service_name} on 127.0.0.1:${dashboard_port}/${http_port}"
      nohup kubectl -n anyscale-operator port-forward service/"${service_name}" "${dashboard_port}:8265" "${http_port}:80" > "${logfile}" 2>&1 &
      launcher_pid="$!"

      if ! wait_for_local_listener "${dashboard_port}" 30 || ! wait_for_local_listener "${http_port}" 30; then
        kill "${launcher_pid}" 2>/dev/null || true
        [[ -n "${dashboard_port}" ]] && stop_workspace_browser_tunnel_listeners_on_port "${dashboard_port}" || true
        [[ -n "${http_port}" && "${http_port}" != "${dashboard_port}" ]] && stop_workspace_browser_tunnel_listeners_on_port "${http_port}" || true
        clear_runtime_files "${pidfile}" "${dashboard_portfile}" "${http_portfile}" "${sessionfile}"
        tail -20 "${logfile}" >&2 || true
        die "Workspace head port-forward did not open on ports ${dashboard_port}/${http_port}."
      fi

      listener_pid="$(first_listener_pid "${dashboard_port}" 2>/dev/null || true)"
      [[ -n "${listener_pid}" ]] || die "Workspace head port-forward opened but no listener PID was found."

      printf '%s\n' "${listener_pid}" > "${pidfile}"
      printf '%s\n' "${dashboard_port}" > "${dashboard_portfile}"
      printf '%s\n' "${http_port}" > "${http_portfile}"
      printf '%s\n' "${session_id}" > "${sessionfile}"

      print_workspace_head_forward_details "${session_id}" "${dashboard_port}" "${http_port}"
      printf 'log file: %s\n' "${logfile}"
      ;;
    status)
      pid="$(pid_from_file "${pidfile}")"
      dashboard_port="$(cat "${dashboard_portfile}" 2>/dev/null || true)"
      http_port="$(cat "${http_portfile}" 2>/dev/null || true)"
      session_id="$(cat "${sessionfile}" 2>/dev/null || true)"

      if [[ -n "${dashboard_port}" && -n "${http_port}" && -n "${session_id}" ]] \
        && pid_is_running "${pid}" \
        && listener_is_ready "${dashboard_port}" \
        && listener_is_ready "${http_port}"; then
        printf 'status=running\n'
        printf 'pid=%s\n' "${pid}"
        print_workspace_head_forward_details "${session_id}" "${dashboard_port}" "${http_port}"
        printf 'log=%s\n' "${logfile}"
        return 0
      fi

      printf 'status=stopped\n'
      printf 'log=%s\n' "${logfile}"
      return 1
      ;;
    stop)
      local stopped=false
      pid="$(pid_from_file "${pidfile}")"
      dashboard_port="$(cat "${dashboard_portfile}" 2>/dev/null || true)"
      http_port="$(cat "${http_portfile}" 2>/dev/null || true)"

      if pid_is_running "${pid}"; then
        kill "${pid}" 2>/dev/null || true
        stopped=true
      fi
      if [[ -n "${dashboard_port}" ]] && stop_workspace_browser_tunnel_listeners_on_port "${dashboard_port}"; then
        stopped=true
        log "Stopped workspace head port-forward on 127.0.0.1:${dashboard_port}/${http_port}"
      elif [[ -n "${http_port}" && "${http_port}" != "${dashboard_port}" ]] && stop_workspace_browser_tunnel_listeners_on_port "${http_port}"; then
        stopped=true
        log "Stopped workspace head port-forward on 127.0.0.1:${dashboard_port}/${http_port}"
      fi
      if [[ "${stopped}" != true ]]; then
        warn "No workspace head port-forward was running."
      fi
      if [[ -n "${http_port}" && "${http_port}" != "${dashboard_port}" ]]; then
        stop_workspace_browser_tunnel_listeners_on_port "${http_port}" || true
      fi
      clear_runtime_files "${pidfile}" "${dashboard_portfile}" "${http_portfile}" "${sessionfile}"
      ;;
    *)
      die "Usage: ./scripts/setup.sh workspace-head-forward {start|status|stop}"
      ;;
  esac
}

workspace_head_open() {
  local action="start"
  if [[ $# -gt 0 && ! "$1" =~ ^- ]]; then
    action="$1"
    shift || true
  fi

  local session_value=""
  local session_id=""
  local session_suffix=""
  local browser_name="firefox"
  local browser_binary=""
  local browser_url=""
  local logfile=""
  local launcher_pid=""
  local profile_dir=""
  local dashboard_port="18265"
  local http_port="18080"
  local ingress_http_port="18081"
  local ingress_https_port="18443"
  local pac_uri=""
  local proxy_port=""
  local proxy_pac=""
  local keep_forward=false

  case "${action}" in
    start)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --session-id|--cluster-id|--session-host|--host)
            [[ $# -ge 2 ]] || die "$1 requires a value."
            session_value="$2"
            shift 2
            ;;
          --browser)
            [[ $# -ge 2 ]] || die "--browser requires a value."
            browser_name="$2"
            shift 2
            ;;
          --dashboard-port)
            [[ $# -ge 2 ]] || die "--dashboard-port requires a value."
            dashboard_port="$2"
            shift 2
            ;;
          --http-port)
            [[ $# -ge 2 ]] || die "--http-port requires a value."
            http_port="$2"
            shift 2
            ;;
          --ingress-http-port)
            [[ $# -ge 2 ]] || die "--ingress-http-port requires a value."
            ingress_http_port="$2"
            shift 2
            ;;
          --ingress-https-port)
            [[ $# -ge 2 ]] || die "--ingress-https-port requires a value."
            ingress_https_port="$2"
            shift 2
            ;;
          --help|-h)
            cat <<'USAGE'
Usage:
  ./scripts/setup.sh workspace-head-open --session-id ses_xxx [--browser firefox] [--dashboard-port 18265] [--http-port 18080] [--ingress-http-port 18081] [--ingress-https-port 18443]
  ./scripts/setup.sh workspace-head-open status
  ./scripts/setup.sh workspace-head-open stop [--keep-forward]

Starts or reuses the direct head-service port-forward and the local ingress
tunnel, configures a Firefox-only PAC proxy so embedded dashboard tiles that
reference the private session host route through localhost, and launches a
separate temporary Firefox profile directly to the local Ray Dashboard
fallback.
USAGE
            return 0
            ;;
          *)
            die "Unknown workspace-head-open option: $1"
            ;;
        esac
      done

      [[ -n "${session_value}" ]] || die "workspace-head-open start requires --session-id or --session-host."

      workspace_head_forward start --session-id "${session_value}" --dashboard-port "${dashboard_port}" --http-port "${http_port}"
      workspace_browser_ready start --session-id "${session_value}" --http-port "${ingress_http_port}" --https-port "${ingress_https_port}"

      session_id="$(workspace_browser_session_id "${session_value}")"
      session_suffix="$(workspace_browser_session_suffix "${session_value}")"
      browser_url="http://127.0.0.1:${dashboard_port}/"
      browser_binary="$(detect_workspace_browser_binary "${browser_name}")"
      logfile="$(workspace_browser_app_logfile)"
      profile_dir="$(workspace_browser_profile_dir)"

      if workspace_browser_app_is_running; then
        stop_workspace_browser_app_processes || true
      fi
      rm -rf "${profile_dir}"
      mkdir -p "${profile_dir}"
      : > "${logfile}"

      if workspace_browser_proxy_is_running; then
        stop_workspace_browser_proxy_processes || true
      fi
      start_workspace_browser_proxy "${session_suffix}" "${ingress_http_port}" "${ingress_https_port}"
      proxy_port="$(cat "$(workspace_browser_proxy_portfile)" 2>/dev/null || true)"
      proxy_pac="$(workspace_browser_proxy_pacfile)"
      pac_uri="$(path_as_file_uri "${proxy_pac}")"
      write_workspace_browser_user_prefs "${pac_uri}"

      log "Launching temporary browser profile with ${browser_binary}"
      nohup "${browser_binary}" \
        -no-remote \
        -new-instance \
        -profile "${profile_dir}" \
        "${browser_url}" > "${logfile}" 2>&1 &
      launcher_pid="$!"

      sleep 2
      workspace_browser_app_is_running || die "The temporary browser did not stay running. Check ${logfile}."

      printf '%s\n' "${launcher_pid}" > "$(workspace_browser_app_pidfile)"
      printf '%s\n' "${browser_binary}" > "$(workspace_browser_app_browserfile)"
      printf '%s\n' "${browser_url}" > "$(workspace_browser_app_urlfile)"
      printf '%s\n' "ray-dashboard-${session_id}" > "$(workspace_browser_app_hostfile)"

      print_workspace_head_forward_details "${session_id}" "${dashboard_port}" "${http_port}"
      print_workspace_browser_app_details "${browser_binary}" "${browser_url}" "ray-dashboard-${session_id}" "${proxy_port}" "${proxy_pac}"
      printf 'browser_log=%s\n' "${logfile}"
      ;;
    status)
      workspace_head_forward status || true
      if workspace_browser_app_is_running; then
        browser_binary="$(cat "$(workspace_browser_app_browserfile)" 2>/dev/null || true)"
        browser_url="$(cat "$(workspace_browser_app_urlfile)" 2>/dev/null || true)"
        session_value="$(cat "$(workspace_browser_app_hostfile)" 2>/dev/null || true)"
        printf 'browser_status=running\n'
        print_workspace_browser_app_details "${browser_binary}" "${browser_url}" "${session_value}"
        printf 'browser_log=%s\n' "$(workspace_browser_app_logfile)"
        return 0
      fi

      printf 'browser_status=stopped\n'
      printf 'browser_log=%s\n' "$(workspace_browser_app_logfile)"
      return 1
      ;;
    stop)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --keep-forward)
            keep_forward=true
            shift
            ;;
          --help|-h)
            cat <<'USAGE'
Usage:
  ./scripts/setup.sh workspace-head-open stop [--keep-forward]

Stops the temporary browser profile and, by default, also stops the backing
head-service forward. Use --keep-forward if you only want to close the browser.
USAGE
            return 0
            ;;
          *)
            die "Unknown workspace-head-open stop option: $1"
            ;;
        esac
      done

      if stop_workspace_browser_app_processes; then
        log "Stopped temporary browser profile"
      else
        warn "No temporary browser profile was running."
      fi
      rm -rf "$(workspace_browser_profile_dir)"
      clear_runtime_files \
        "$(workspace_browser_app_pidfile)" \
        "$(workspace_browser_app_browserfile)" \
        "$(workspace_browser_app_urlfile)" \
        "$(workspace_browser_app_hostfile)"

      if stop_workspace_browser_proxy_processes; then
        log "Stopped Firefox workspace proxy"
      else
        warn "No Firefox workspace proxy was running."
      fi
      clear_runtime_files \
        "$(workspace_browser_proxy_pidfile)" \
        "$(workspace_browser_proxy_portfile)" \
        "$(workspace_browser_proxy_pacfile)" \
        "$(workspace_browser_proxy_script_path)"

      if [[ "${keep_forward}" != true ]]; then
        workspace_browser_ready stop --keep-bastion || true
        workspace_head_forward stop || true
      fi
      ;;
    *)
      die "Usage: ./scripts/setup.sh workspace-head-open {start|status|stop}"
      ;;
  esac
}

workspace_browser_ready() {
  local action="start"
  if [[ $# -gt 0 && ! "$1" =~ ^- ]]; then
    action="$1"
    shift || true
  fi

  local session_value=""
  local bastion_port="64435"
  local http_port="18081"
  local https_port="18443"
  local keep_bastion=false
  local kubeconfig_path=""
  local browser_status=0
  local bastion_status=0

  case "${action}" in
    start)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --session-id|--cluster-id|--session-host|--host)
            [[ $# -ge 2 ]] || die "$1 requires a value."
            session_value="$2"
            shift 2
            ;;
          --bastion-port)
            [[ $# -ge 2 ]] || die "--bastion-port requires a value."
            bastion_port="$2"
            shift 2
            ;;
          --http-port)
            [[ $# -ge 2 ]] || die "--http-port requires a value."
            http_port="$2"
            shift 2
            ;;
          --https-port)
            [[ $# -ge 2 ]] || die "--https-port requires a value."
            https_port="$2"
            shift 2
            ;;
          --help|-h)
            cat <<'USAGE'
Usage:
  ./scripts/setup.sh workspace-browser-ready --session-id ses_xxx [--bastion-port 64435] [--http-port 18081] [--https-port 18443]
  ./scripts/setup.sh workspace-browser-ready status
  ./scripts/setup.sh workspace-browser-ready stop [--keep-bastion]

Single-command equivalent of:
  ./scripts/setup.sh bastion-tunnel start --port 64435
  eval "$(./scripts/setup.sh kubeconfig-bastion --export)"
  ./scripts/setup.sh workspace-browser-tunnel start --session-id ses_xxx

The command starts or reuses the Bastion tunnel, writes a Bastion-backed
kubeconfig, exports it for the current process, and starts the local browser
tunnel to ingress-nginx.
USAGE
            return 0
            ;;
          *)
            die "Unknown workspace-browser-ready option: $1"
            ;;
        esac
      done

      [[ -n "${session_value}" ]] || die "workspace-browser-ready start requires --session-id or --session-host."

      requested_bastion_port="${bastion_port}"
      if listener_is_ready "${bastion_port}" && ! port_listeners_are_bastion_tunnels "${bastion_port}"; then
        for ((candidate_bastion_port = bastion_port + 1; candidate_bastion_port <= bastion_port + 20; candidate_bastion_port++)); do
          if ! listener_is_ready "${candidate_bastion_port}"; then
            bastion_port="${candidate_bastion_port}"
            warn "Local port ${requested_bastion_port} is already in use; using Bastion port ${bastion_port} instead."
            break
          fi
        done
      fi
      [[ -n "${bastion_port}" ]] || die "Could not determine a Bastion tunnel port."

      bastion_tunnel start --port "${bastion_port}"
      kubeconfig_path="$(kubeconfig_bastion --print-path)"
      export_kubeconfig_env "${kubeconfig_path}"
      printf 'kubeconfig=%s\n' "${kubeconfig_path}"
      workspace_browser_tunnel start --session-id "${session_value}" --http-port "${http_port}" --https-port "${https_port}"
      ;;
    status)
      bastion_tunnel status || bastion_status=$?
      browser_status=0
      workspace_browser_tunnel status || browser_status=$?
      if (( bastion_status != 0 || browser_status != 0 )); then
        return 1
      fi
      ;;
    stop)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --keep-bastion)
            keep_bastion=true
            shift
            ;;
          --help|-h)
            cat <<'USAGE'
Usage:
  ./scripts/setup.sh workspace-browser-ready stop [--keep-bastion]

Stops the local browser tunnel and, by default, also stops the reusable Bastion
tunnel started for it. Use --keep-bastion if you still need kubectl access.
USAGE
            return 0
            ;;
          *)
            die "Unknown workspace-browser-ready stop option: $1"
            ;;
        esac
      done

      workspace_browser_tunnel stop || true
      if [[ "${keep_bastion}" != true ]]; then
        bastion_tunnel stop || true
      fi
      ;;
    *)
      die "Usage: ./scripts/setup.sh workspace-browser-ready {start|status|stop}"
      ;;
  esac
}

workspace_browser_open() {
  local action="start"
  if [[ $# -gt 0 && ! "$1" =~ ^- ]]; then
    action="$1"
    shift || true
  fi

  local session_value=""
  local session_id=""
  local browser_name="firefox"
  local browser_binary=""
  local browser_url=""
  local host=""
  local session_suffix=""
  local profile_dir=""
  local logfile=""
  local launcher_pid=""
  local bastion_port="64435"
  local http_port="18081"
  local https_port="18443"
  local keep_network=false
  local pac_uri=""
  local proxy_port=""
  local proxy_pac=""

  case "${action}" in
    start)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --session-id|--cluster-id|--session-host|--host)
            [[ $# -ge 2 ]] || die "$1 requires a value."
            session_value="$2"
            shift 2
            ;;
          --browser)
            [[ $# -ge 2 ]] || die "--browser requires a value."
            browser_name="$2"
            shift 2
            ;;
          --bastion-port)
            [[ $# -ge 2 ]] || die "--bastion-port requires a value."
            bastion_port="$2"
            shift 2
            ;;
          --http-port)
            [[ $# -ge 2 ]] || die "--http-port requires a value."
            http_port="$2"
            shift 2
            ;;
          --https-port)
            [[ $# -ge 2 ]] || die "--https-port requires a value."
            https_port="$2"
            shift 2
            ;;
          --help|-h)
            cat <<'USAGE'
Usage:
  ./scripts/setup.sh workspace-browser-open --session-id ses_xxx [--browser firefox] [--bastion-port 64435] [--http-port 18081] [--https-port 18443]
  ./scripts/setup.sh workspace-browser-open status
  ./scripts/setup.sh workspace-browser-open stop [--keep-network]

Starts the Bastion-backed browser workflow and launches a separate temporary
Firefox profile with its own PAC-configured local proxy for the private session
hostname. This avoids permanent /etc/hosts changes on the Mac and avoids
touching other browser instances.
USAGE
            return 0
            ;;
          *)
            die "Unknown workspace-browser-open option: $1"
            ;;
        esac
      done

      [[ -n "${session_value}" ]] || die "workspace-browser-open start requires --session-id or --session-host."

      workspace_browser_ready start --session-id "${session_value}" --bastion-port "${bastion_port}" --http-port "${http_port}" --https-port "${https_port}"

      session_id="$(workspace_browser_session_id "${session_value}")"
      session_suffix="$(workspace_browser_session_suffix "${session_value}")"
      host="$(workspace_browser_primary_host "${session_suffix}")"
      browser_url="$(workspace_browser_auth_url "${session_id}" "${host}")"
      browser_binary="$(detect_workspace_browser_binary "${browser_name}")"
      logfile="$(workspace_browser_app_logfile)"
      profile_dir="$(workspace_browser_profile_dir)"

      if workspace_browser_app_is_running; then
        stop_workspace_browser_app_processes || true
      fi
      rm -rf "${profile_dir}"
      mkdir -p "${profile_dir}"
      : > "${logfile}"

      if workspace_browser_proxy_is_running; then
        stop_workspace_browser_proxy_processes || true
      fi
      start_workspace_browser_proxy "${session_suffix}" "${http_port}" "${https_port}"
      proxy_port="$(cat "$(workspace_browser_proxy_portfile)" 2>/dev/null || true)"
      proxy_pac="$(workspace_browser_proxy_pacfile)"
      pac_uri="$(path_as_file_uri "${proxy_pac}")"
      write_workspace_browser_user_prefs "${pac_uri}"

      log "Launching temporary browser profile with ${browser_binary}"
      nohup "${browser_binary}" \
        -no-remote \
        -new-instance \
        -profile "${profile_dir}" \
        "${browser_url}" > "${logfile}" 2>&1 &
      launcher_pid="$!"

      sleep 2
      workspace_browser_app_is_running || die "The temporary browser did not stay running. Check ${logfile}."

      printf '%s\n' "${launcher_pid}" > "$(workspace_browser_app_pidfile)"
      printf '%s\n' "${browser_binary}" > "$(workspace_browser_app_browserfile)"
      printf '%s\n' "${browser_url}" > "$(workspace_browser_app_urlfile)"
      printf '%s\n' "${host}" > "$(workspace_browser_app_hostfile)"

      print_workspace_browser_app_details "${browser_binary}" "${browser_url}" "${host}" "${proxy_port}" "${proxy_pac}"
      printf 'browser_log=%s\n' "${logfile}"
      ;;
    status)
      workspace_browser_ready status || true
      if workspace_browser_app_is_running && workspace_browser_proxy_is_running; then
        browser_binary="$(cat "$(workspace_browser_app_browserfile)" 2>/dev/null || true)"
        browser_url="$(cat "$(workspace_browser_app_urlfile)" 2>/dev/null || true)"
        host="$(cat "$(workspace_browser_app_hostfile)" 2>/dev/null || true)"
        proxy_port="$(cat "$(workspace_browser_proxy_portfile)" 2>/dev/null || true)"
        proxy_pac="$(workspace_browser_proxy_pacfile)"
        printf 'browser_status=running\n'
        print_workspace_browser_app_details "${browser_binary}" "${browser_url}" "${host}" "${proxy_port}" "${proxy_pac}"
        printf 'browser_log=%s\n' "$(workspace_browser_app_logfile)"
        return 0
      fi

      printf 'browser_status=stopped\n'
      printf 'browser_log=%s\n' "$(workspace_browser_app_logfile)"
      return 1
      ;;
    stop)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --keep-network)
            keep_network=true
            shift
            ;;
          --help|-h)
            cat <<'USAGE'
Usage:
  ./scripts/setup.sh workspace-browser-open stop [--keep-network]

Stops the temporary browser profile and, by default, also removes the backing
local Bastion/browser tunnel workflow. Use --keep-network if you only want to
close the temporary browser and keep the tunnel running.
USAGE
            return 0
            ;;
          *)
            die "Unknown workspace-browser-open stop option: $1"
            ;;
        esac
      done

      if stop_workspace_browser_app_processes; then
        log "Stopped temporary browser profile"
      else
        warn "No temporary browser profile was running."
      fi
      rm -rf "$(workspace_browser_profile_dir)"
      clear_runtime_files \
        "$(workspace_browser_app_pidfile)" \
        "$(workspace_browser_app_browserfile)" \
        "$(workspace_browser_app_urlfile)" \
        "$(workspace_browser_app_hostfile)"

      if stop_workspace_browser_proxy_processes; then
        log "Stopped Firefox workspace proxy"
      else
        warn "No Firefox workspace proxy was running."
      fi
      clear_runtime_files \
        "$(workspace_browser_proxy_pidfile)" \
        "$(workspace_browser_proxy_portfile)" \
        "$(workspace_browser_proxy_pacfile)" \
        "$(workspace_browser_proxy_script_path)"

      if [[ "${keep_network}" != true ]]; then
        workspace_browser_ready stop || true
      fi
      ;;
    *)
      die "Usage: ./scripts/setup.sh workspace-browser-open {start|status|stop}"
      ;;
  esac
}

anyscale_cli_bin() {
  printf '%s/.venv/bin/anyscale\n' "${ROOT_DIR}"
}

require_anyscale_cli() {
  local cli_bin
  cli_bin="$(anyscale_cli_bin)"
  [[ -x "${cli_bin}" ]] || die "Anyscale CLI not found at ${cli_bin}. Install it with uv and the repo-local .venv first."
}

azure_login_command() {
  local -a cmd=(az login)
  local command_display

  if [[ -n "${TF_VAR_azure_tenant_id:-}" ]]; then
    cmd+=(--tenant "${TF_VAR_azure_tenant_id}")
  fi

  printf -v command_display '%q ' "${cmd[@]}"
  printf '%s\n' "${command_display% }"
}

ensure_azure_cli_login() {
  local az_account_error login_command prompt_response

  if az_account_error="$(az account show --only-show-errors 2>&1 >/dev/null)"; then
    return 0
  fi

  login_command="$(azure_login_command)"

  if [[ "${az_account_error}" == *".azure/azureProfile.json"* && "${az_account_error}" == *"Operation not permitted"* ]]; then
    die "Azure CLI auth context exists, but this shell cannot read ~/.azure/azureProfile.json. Re-run from a terminal with access to your existing az session, or use an unsandboxed shell."
  fi

  if [[ -t 0 && -t 1 ]]; then
    warn "Azure CLI is not logged in for this shell."
    warn "Run ${login_command} in this terminal, then press Enter to retry."

    while true; do
      printf 'Press Enter after Azure CLI login, or type "abort" to exit: ' >&2
      IFS= read -r prompt_response || die "Azure CLI login is required. Run: ${login_command}"

      case "${prompt_response}" in
        "")
          ;;
        abort)
          die "Azure CLI login is required. Run: ${login_command}"
          ;;
        *)
          warn "Unrecognized response '${prompt_response}'. Press Enter after Azure CLI login or type 'abort'."
          continue
          ;;
      esac

      if az account show --only-show-errors >/dev/null 2>&1; then
        return 0
      fi

      warn "Azure CLI login is still unavailable in this shell."
      warn "Run ${login_command} and retry."
    done
  fi

  die "Azure CLI login is required. Run: ${login_command}"
}

###############################################################################
preflight() {
  log "Checking required CLI tools..."
  for tool_name in az terraform kubectl kubelogin helm jq; do require_cmd "${tool_name}"; done
  render_tfvars

  log "Checking az login..."
  ensure_azure_cli_login

  local sub_id
  sub_id="${TF_VAR_azure_subscription_id}"
  log "Setting active subscription to ${sub_id}"
  az account set --subscription "${sub_id}" --only-show-errors
}

###############################################################################
tf_init() {
  render_tfvars
  log "terraform init"
  run_with_timeout "${SETUP_TIMEOUT_TERRAFORM_INIT_SECONDS}" terraform init -input=false
}

###############################################################################
validate() {
  render_tfvars
  log "terraform fmt"
  run_with_timeout "${SETUP_TIMEOUT_TERRAFORM_VALIDATE_SECONDS}" terraform fmt -recursive -check
  log "terraform validate"
  run_with_timeout "${SETUP_TIMEOUT_TERRAFORM_VALIDATE_SECONDS}" terraform validate
  ensure_helm_test_repositories
  log "terraform test (plan-only)"
  run_with_timeout "${SETUP_TIMEOUT_TERRAFORM_TEST_SECONDS}" terraform test -filter=tests/plan.tftest.hcl
  log "terraform test (identity contract)"
  run_with_timeout "${SETUP_TIMEOUT_TERRAFORM_TEST_SECONDS}" terraform test -filter=tests/identity_contract.tftest.hcl
  log "terraform test (private-mode contract)"
  run_with_timeout "${SETUP_TIMEOUT_TERRAFORM_TEST_SECONDS}" terraform test -filter=tests/private_mode.tftest.hcl
}

###############################################################################
plan() {
  render_tfvars
  ensure_anyscale_marketplace_agreement_accepted
  ensure_anyscale_platform_deployment_state
  log "terraform plan -> tfplan"
  run_with_timeout "${SETUP_TIMEOUT_TERRAFORM_PLAN_SECONDS}" terraform plan -input=false -out=tfplan
}

###############################################################################
apply() {
  render_tfvars
  ensure_anyscale_marketplace_agreement_accepted
  ensure_anyscale_platform_deployment_state
  if [[ ! -f tfplan ]]; then plan; fi
  log "terraform apply tfplan (this will take ~20 min - Azure Firewall + AKS)"
  run_with_timeout "${SETUP_TIMEOUT_TERRAFORM_APPLY_SECONDS}" terraform apply -auto-approve tfplan
  sync_anyscale_cli_env
  rm -f tfplan
}

setup_run_init() {
  local run_name="$1"
  local stage_total="$2"
  local run_id

  run_id="$(date -u +%Y%m%dT%H%M%SZ)"
  SETUP_RUN_DIR="${HARNESS_DIR}/runs/${run_id}-${run_name}"
  SETUP_STAGE_LOG_DIR="${SETUP_RUN_DIR}/logs"
  SETUP_STAGE_INDEX=0
  SETUP_STAGE_TOTAL="${stage_total}"
  SETUP_STAGE_RESULTS=()

  mkdir -p "${SETUP_STAGE_LOG_DIR}"
  printf 'stage\tresult\tduration_seconds\tlog\n' > "${SETUP_RUN_DIR}/stages.tsv"
  log "Run logs: ${SETUP_RUN_DIR}"
}

run_stage() {
  local stage_name="$1"
  shift

  local log_file start_epoch end_epoch duration exit_code
  SETUP_STAGE_INDEX=$((SETUP_STAGE_INDEX + 1))
  log_file="${SETUP_STAGE_LOG_DIR}/$(printf '%02d' "${SETUP_STAGE_INDEX}")-${stage_name}.log"
  start_epoch="$(date +%s)"

  log "[${SETUP_STAGE_INDEX}/${SETUP_STAGE_TOTAL}] ${stage_name} started"
  set +e
  ( set -e; "$@" ) 2>&1 | tee "${log_file}"
  exit_code=${PIPESTATUS[0]}
  set -e

  end_epoch="$(date +%s)"
  duration=$((end_epoch - start_epoch))

  if [[ "${exit_code}" -eq 0 ]]; then
    log "[${SETUP_STAGE_INDEX}/${SETUP_STAGE_TOTAL}] ${stage_name} ok (${duration}s)"
    SETUP_STAGE_RESULTS+=("${stage_name}:PASS:${duration}s")
    printf '%s\tPASS\t%s\t%s\n' "${stage_name}" "${duration}" "${log_file}" >> "${SETUP_RUN_DIR}/stages.tsv"
    return 0
  fi

  warn "[${SETUP_STAGE_INDEX}/${SETUP_STAGE_TOTAL}] ${stage_name} failed (${duration}s). See ${log_file}"
  SETUP_STAGE_RESULTS+=("${stage_name}:FAIL:${duration}s")
  printf '%s\tFAIL\t%s\t%s\n' "${stage_name}" "${duration}" "${log_file}" >> "${SETUP_RUN_DIR}/stages.tsv"
  setup_run_summary
  exit "${exit_code}"
}

setup_run_summary() {
  local result_line stage_name stage_result stage_duration

  [[ -n "${SETUP_RUN_DIR}" ]] || return 0
  {
    printf '# Setup Run Summary\n\n'
    printf 'Run directory: `%s`\n\n' "${SETUP_RUN_DIR}"
    printf '| Stage | Result | Duration |\n'
    printf '|---|---:|---:|\n'
    for result_line in "${SETUP_STAGE_RESULTS[@]}"; do
      IFS=':' read -r stage_name stage_result stage_duration <<<"${result_line}"
      printf '| `%s` | %s | %s |\n' "${stage_name}" "${stage_result}" "${stage_duration}"
    done
  } > "${SETUP_RUN_DIR}/summary.md"

  log "Summary: ${SETUP_RUN_DIR}/summary.md"
}

deploy_e2e_cleanup() {
  if [[ "${DEPLOY_E2E_STARTED_TUNNEL:-0}" == "1" ]]; then
    bastion_tunnel stop >/dev/null 2>&1 || true
  fi
}

ensure_deploy_e2e_bastion_access() {
  local kubeconfig_path bastion_port requested_bastion_port candidate_bastion_port

  bastion_port="${ANYSCALE_BASTION_PORT:-${DEFAULT_BASTION_TUNNEL_PORT}}"

  if bastion_tunnel status >/dev/null 2>&1; then
    log "Reusing existing Bastion tunnel"
  else
    requested_bastion_port="${bastion_port}"
    if listener_is_ready "${bastion_port}" && ! port_listeners_are_bastion_tunnels "${bastion_port}"; then
      for ((candidate_bastion_port = bastion_port + 1; candidate_bastion_port <= bastion_port + 20; candidate_bastion_port++)); do
        if ! listener_is_ready "${candidate_bastion_port}"; then
          bastion_port="${candidate_bastion_port}"
          warn "Local port ${requested_bastion_port} is already in use; using Bastion port ${bastion_port} instead."
          break
        fi
      done
    fi

    bastion_tunnel start --port "${bastion_port}"
    DEPLOY_E2E_STARTED_TUNNEL=1
  fi

  kubeconfig_path="$(kubeconfig_bastion --print-path)"
  export_kubeconfig_env "${kubeconfig_path}"
  log "Using Bastion-backed kubeconfig ${KUBECONFIG}"
  kubectl get nodes -o wide
}

remove_local_terraform_state_artifacts() {
  rm -f terraform.tfstate terraform.tfstate.backup .terraform.tfstate.lock.info tfplan *.tfplan
  rm -f terraform.tfstate.*.backup
}

ensure_local_state_matches_target() {
  local desired_resource_group current_resource_group backup_path

  [[ -f terraform.tfstate ]] || return 0

  desired_resource_group="$(resource_group_name)"
  current_resource_group="$(jq -r '.outputs.resource_group_name.value // empty' terraform.tfstate 2>/dev/null || true)"

  [[ -n "${current_resource_group}" ]] || return 0
  [[ "${current_resource_group}" == "${desired_resource_group}" ]] && return 0

  backup_path="$(terraform_state_backup_path "retarget-${current_resource_group}")"
  cp terraform.tfstate "${backup_path}"

  if [[ -f terraform.tfstate.backup ]]; then
    cp terraform.tfstate.backup "${backup_path}.previous"
  fi

  warn "Local Terraform state targets ${current_resource_group}, but the current deployment target is ${desired_resource_group}."
  log "Backed up the previous local Terraform state to ${backup_path}"
  log "Clearing local Terraform state and saved plans before continuing with the new target"
  remove_local_terraform_state_artifacts
}

deploy_e2e_phase1() {
  log "Phase 1: build the Azure foundation and private AKS cluster"
  export TF_VAR_cluster_bootstrap='{"enabled":false}'
  export TF_VAR_anyscale_platform='{"enabled":false}'
  plan
  apply
  outputs
}

deploy_e2e_phase2() {
  log "Phase 2: connect through Bastion and finish the deployment"
  unset TF_VAR_cluster_bootstrap TF_VAR_anyscale_platform
  ensure_deploy_e2e_bastion_access
  export TF_VAR_cluster_bootstrap="{\"kubeconfig_path\":\"${KUBECONFIG}\"}"
  plan
  apply
  outputs
}

require_full_deploy_inputs() {
  load_env
  sync_anyscale_cli_env
  require_env_var ANYSCALE_CLI_TOKEN
  require_env_var ANYSCALE_CLOUD_NAME
  require_anyscale_cli
  require_cmd rsync
}

deploy_prepare_stage() {
  require_full_deploy_inputs
  preflight
}

deploy_reset_stage() {
  load_env
  sync_anyscale_cli_env

  if [[ "${DEPLOY_FROM_SCRATCH}" == true ]]; then
    if [[ "${DEPLOY_FORCE_YES}" == true ]]; then
      nuke --yes
    else
      nuke
    fi
  else
    ensure_local_state_matches_target
  fi
}

deploy_init_validate_stage() {
  tf_init
  validate
}

deploy_foundation_stage() {
  load_env
  sync_anyscale_cli_env

  if aks_cluster_exists_for_target; then
    log "Target AKS cluster $(target_aks_cluster_name) already exists. Skipping phase-1 toggle apply and reconciling phase 2."
    return 0
  fi

  deploy_e2e_phase1
}

deploy_platform_stage() {
  deploy_e2e_phase2
}

deploy_p2s_vpn_stage() {
  generate_p2s_vpn_artifacts
}

deploy_workspaces_stage() {
  ensure_deploy_e2e_bastion_access
  anyscale_workspaces_register
}

deploy_health_stage() {
  health
}

deploy() {
  DEPLOY_FROM_SCRATCH=false
  DEPLOY_FORCE_YES=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from-scratch)
        DEPLOY_FROM_SCRATCH=true
        shift
        ;;
      --yes|-y)
        DEPLOY_FORCE_YES=true
        shift
        ;;
      --help|-h)
        cat <<'USAGE'
Usage:
  ./scripts/setup.sh deploy
  ./scripts/setup.sh deploy --from-scratch --yes

Runs the full private AKS + Anyscale deployment without a token pause.
ANYSCALE_CLI_TOKEN must be present in .env before the run starts.
USAGE
        return 0
        ;;
      *)
        die "Unknown deploy option: $1"
        ;;
    esac
  done

  [[ "${DEPLOY_FROM_SCRATCH}" == false && "${DEPLOY_FORCE_YES}" == true ]] && die "--yes is only valid with --from-scratch."

  DEPLOY_E2E_STARTED_TUNNEL=0
  trap deploy_e2e_cleanup EXIT

  setup_run_init "deploy" 8
  run_stage "prepare" deploy_prepare_stage
  run_stage "reset-or-state" deploy_reset_stage
  run_stage "terraform-init-validate" deploy_init_validate_stage
  run_stage "foundation" deploy_foundation_stage
  run_stage "platform" deploy_platform_stage
  run_stage "vpn-profile" deploy_p2s_vpn_stage
  run_stage "workspaces" deploy_workspaces_stage
  run_stage "health" deploy_health_stage
  setup_run_summary

  log "Deployment complete. Run ./scripts/setup.sh verify --full, then ./scripts/setup.sh workload proof all."
}

verify_static_stage() {
  preflight
  tf_init
  validate
}

verify_live_stage() {
  health
  if [[ "${VERIFY_SKIP_OBSERVABILITY}" == true ]]; then
    validate_focused --skip-observability
  else
    validate_focused
  fi
}

verify() {
  local mode="full"
  VERIFY_SKIP_OBSERVABILITY=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --static)
        mode="static"
        shift
        ;;
      --live)
        mode="live"
        shift
        ;;
      --full)
        mode="full"
        shift
        ;;
      --skip-observability)
        VERIFY_SKIP_OBSERVABILITY=true
        shift
        ;;
      --help|-h)
        cat <<'USAGE'
Usage:
  ./scripts/setup.sh verify --static
  ./scripts/setup.sh verify --live [--skip-observability]
  ./scripts/setup.sh verify --full [--skip-observability]
USAGE
        return 0
        ;;
      *)
        die "Unknown verify option: $1"
        ;;
    esac
  done

  case "${mode}" in
    static)
      setup_run_init "verify-static" 1
      run_stage "static" verify_static_stage
      ;;
    live)
      setup_run_init "verify-live" 1
      run_stage "live" verify_live_stage
      ;;
    full)
      setup_run_init "verify-full" 2
      run_stage "static" verify_static_stage
      run_stage "live" verify_live_stage
      ;;
    *)
      die "Unknown verify mode: ${mode}"
      ;;
  esac

  setup_run_summary
}

###############################################################################
outputs() {
  load_env
  sync_anyscale_cli_env
  terraform output
}

###############################################################################
# Read-only environment status. Kubernetes checks require an active Bastion
# tunnel because the AKS API server is private.
###############################################################################
status() {
  load_env
  sync_anyscale_cli_env

  local resource_group cluster private_fqdn
  resource_group="$(terraform_output_raw resource_group_name)"
  cluster="$(terraform_output_raw aks_cluster_name)"
  private_fqdn="$(terraform_output_raw aks_private_fqdn)"

  [[ -n "${resource_group}" && -n "${cluster}" ]] || die "Terraform outputs are missing. Run ./scripts/setup.sh deploy first."

  log "Terraform deployment"
  printf '  Resource group: %s\n' "${resource_group}"
  printf '  AKS cluster:    %s\n' "${cluster}"
  printf '  Private FQDN:   %s\n' "${private_fqdn}"

  log "Anyscale CLI metadata"
  printf '  Host:               %s\n' "${ANYSCALE_HOST:-$(default_anyscale_host)}"
  printf '  Cloud name:         %s\n' "${ANYSCALE_CLOUD_NAME:-<unset>}"
  printf '  Cloud deployment:   %s\n' "${ANYSCALE_CLOUD_DEPLOYMENT_ID:-<unset>}"

  log "Azure AKS state"
  run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" az aks show \
    --resource-group "${resource_group}" \
    --name "${cluster}" \
    --query '{provisioningState:provisioningState,power:powerState.code,private:apiServerAccessProfile.enablePrivateCluster,vnetIntegration:apiServerAccessProfile.enableVnetIntegration,kubernetesVersion:kubernetesVersion}' \
    --output table \
    --only-show-errors

  log "Node pools"
  run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" az aks nodepool list \
    --resource-group "${resource_group}" \
    --cluster-name "${cluster}" \
    --query '[].{name:name,mode:mode,vmSize:vmSize,count:count,min:minCount,max:maxCount,state:provisioningState}' \
    --output table \
    --only-show-errors

  log "Enterprise DNS path"
  printf '  VNet DNS servers:             %s\n' "$(terraform output -json vnet_dns_servers | jq -r 'join(", ")')"
  printf '  DNS resolver inbound IP:      %s\n' "$(terraform output -raw dns_resolver_inbound_endpoint_ip)"
  printf '  Azure Firewall private IP:    %s\n' "$(terraform output -raw firewall_private_ip)"

  local p2s_vpn_contract p2s_enabled
  p2s_vpn_contract="$(terraform output -json p2s_vpn_contract 2>/dev/null || true)"
  p2s_enabled="$(jq -r '.enabled // false' <<<"${p2s_vpn_contract:-null}" 2>/dev/null || echo "false")"
  if [[ "${p2s_enabled}" == "true" ]]; then
    log "Point-to-Site VPN"
    printf '  VPN gateway:                  %s\n' "$(jq -r '.gateway_name // "<unknown>"' <<<"${p2s_vpn_contract}")"
    printf '  VPN public IP:                %s\n' "$(terraform output -raw vpn_gateway_public_ip 2>/dev/null || echo "<pending>")"
    printf '  P2S client pool:              %s\n' "$(jq -r '.client_address_space | join(", ")' <<<"${p2s_vpn_contract}")"
    printf '  P2S client DNS:               %s\n' "$(jq -r '.client_dns_servers | join(", ")' <<<"${p2s_vpn_contract}")"
    if [[ -f "$(p2s_vpn_ready_ovpn_path)" ]]; then
      printf '  Ready OpenVPN profile:        %s\n' "$(p2s_vpn_ready_ovpn_path)"
      printf '  VPN artifact summary:         %s\n' "$(p2s_vpn_summary_path)"
    fi
  fi

  if kubectl get nodes --request-timeout=15s >/dev/null 2>&1; then
    log "Kubernetes nodes"
    kubectl get nodes -o wide

    log "Helm add-ons"
    helm list -n gpu-resources || true
    helm list -n ingress-nginx || true

    log "Ingress service"
    kubectl get service -n ingress-nginx ingress-nginx-controller -o wide || true

    if [[ -n "${ANYSCALE_CLI_TOKEN:-}" ]]; then
      log "Run ./scripts/setup.sh health for Azure, operator, workspace, and recent log checks."
    fi
  else
    log "kubectl cannot reach the private API server from this shell. Run ./scripts/setup.sh verify --live to refresh Bastion-backed access and retry live checks."
  fi
}

health() {
  local cpu_workspace_name="aks-cpu-workspace"
  local gpu_workspace_name="aks-gpu-workspace"
  local resource_group cluster namespace extension_name cloud_resource_id cli_bin
  local aks_provisioning_state aks_power_state extension_state cloud_state
  local cpu_status_raw cpu_status gpu_status_raw gpu_status
  local cpu_health_wait_log gpu_health_wait_log
  local cpu_head_pod operator_log_matches workspace_log_matches

  load_env
  sync_anyscale_cli_env
  require_cmd az
  require_cmd jq
  require_anyscale_cli
  ensure_deploy_e2e_bastion_access
  require_env_var ANYSCALE_CLI_TOKEN
  require_env_var ANYSCALE_CLOUD_NAME

  resource_group="$(terraform_output_raw resource_group_name)"
  cluster="$(terraform_output_raw aks_cluster_name)"
  extension_name="$(terraform_output_raw anyscale_extension_name)"
  cloud_resource_id="$(terraform_output_raw anyscale_cloud_resource_id)"
  namespace="${TF_VAR_anyscale_operator_namespace}"
  cli_bin="$(anyscale_cli_bin)"

  [[ -n "${resource_group}" && -n "${cluster}" ]] || die "Terraform outputs are missing. Run ./scripts/setup.sh deploy first."
  [[ -n "${extension_name}" ]] || die "Missing anyscale_extension_name Terraform output."
  [[ -n "${cloud_resource_id}" ]] || die "Missing anyscale_cloud_resource_id Terraform output."

  aks_provisioning_state="$(run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" az aks show \
    --resource-group "${resource_group}" \
    --name "${cluster}" \
    --query 'provisioningState' \
    --output tsv \
    --only-show-errors)"
  aks_power_state="$(run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" az aks show \
    --resource-group "${resource_group}" \
    --name "${cluster}" \
    --query 'powerState.code' \
    --output tsv \
    --only-show-errors)"
  [[ "${aks_provisioning_state}" == "Succeeded" ]] || die "AKS cluster ${cluster} provisioningState is ${aks_provisioning_state}, expected Succeeded."
  [[ "${aks_power_state}" == "Running" ]] || die "AKS cluster ${cluster} power state is ${aks_power_state}, expected Running."
  log "Azure AKS cluster ${cluster} is ${aks_provisioning_state}/${aks_power_state}."

  extension_state="$(run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" az k8s-extension show \
    --cluster-type managedClusters \
    --cluster-name "${cluster}" \
    --resource-group "${resource_group}" \
    --name "${extension_name}" \
    --query 'provisioningState' \
    --output tsv \
    --only-show-errors)"
  [[ "${extension_state}" == "Succeeded" ]] || die "Anyscale AKS extension ${extension_name} provisioningState is ${extension_state}, expected Succeeded."
  log "Anyscale AKS extension ${extension_name} provisioningState=${extension_state}."

  cloud_state="$(run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" az resource show \
    --ids "${cloud_resource_id}" \
    --query 'properties.provisioningState' \
    --output tsv \
    --only-show-errors)"
  [[ "${cloud_state}" == "Succeeded" ]] || die "Anyscale cloud resource provisioningState is ${cloud_state}, expected Succeeded."
  log "Anyscale cloud resource provisioningState=${cloud_state}."

  log "Checking Kubernetes rollouts"
  kubectl rollout status deployment/anyscale-operator -n "${namespace}" --timeout=5m >/dev/null
  kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=5m >/dev/null
  log "Anyscale operator and ingress-nginx deployments are Available."

  cpu_status_raw="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
    "${cli_bin}" workspace_v2 status \
      --name "${cpu_workspace_name}" \
      --cloud "${ANYSCALE_CLOUD_NAME}" 2>&1)"
  cpu_status="$(normalize_anyscale_workspace_status "${cpu_status_raw}")"
  [[ -n "${cpu_status}" ]] || cpu_status="UNKNOWN"

  if [[ "${cpu_status}" == "RUNNING" ]]; then
    log "CPU workspace ${cpu_workspace_name} API status=${cpu_status}."
  elif [[ "${cpu_status}" =~ ^(CREATE_FAILED|FAILED|ERROR|TERMINATED)$ ]]; then
    die "CPU workspace ${cpu_workspace_name} is unhealthy with API status ${cpu_status}."
  else
    warn "CPU workspace ${cpu_workspace_name} API status is ${cpu_status}; confirming readiness from the Kubernetes runtime."
  fi
  cpu_health_wait_log="$(harness_state_file "${cpu_workspace_name}.health.wait.log")"
  wait_for_workspace_runtime_stable "${cpu_workspace_name}" "aks-cpu-" "${cpu_health_wait_log}"

  gpu_status_raw="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
    "${cli_bin}" workspace_v2 status \
      --name "${gpu_workspace_name}" \
      --cloud "${ANYSCALE_CLOUD_NAME}" 2>&1)"
  gpu_status="$(normalize_anyscale_workspace_status "${gpu_status_raw}")"
  [[ -n "${gpu_status}" ]] || gpu_status="UNKNOWN"

  case "${gpu_status}" in
    CREATE_FAILED|FAILED|ERROR|TERMINATED)
      die "GPU workspace ${gpu_workspace_name} is unhealthy with API status ${gpu_status}."
      ;;
    RUNNING)
      log "GPU workspace ${gpu_workspace_name} API status=${gpu_status}."
      ;;
    *)
      warn "GPU workspace ${gpu_workspace_name} API status is ${gpu_status}; confirming readiness from the Kubernetes runtime."
      ;;
  esac
  gpu_health_wait_log="$(harness_state_file "${gpu_workspace_name}.health.wait.log")"
  wait_for_workspace_runtime_stable "${gpu_workspace_name}" "aks-gput4-" "${gpu_health_wait_log}"

  operator_log_matches="$(kubectl logs -n "${namespace}" deploy/anyscale-operator -c operator --since=30m 2>&1 \
    | egrep -i 'error|warn|fail|exception|backoff|forbidden' \
    | tail -n 20 || true)"
  if [[ -n "${operator_log_matches}" ]]; then
    warn "Recent Anyscale operator log matches from the last 30m:"
    printf '%s\n' "${operator_log_matches}"
  else
    log "No recent Anyscale operator error/warn matches in the last 30m."
  fi

  cpu_head_pod="$(workspace_head_pod_name "${cpu_workspace_name}")"
  workspace_log_matches="$(kubectl logs -n "${namespace}" "${cpu_head_pod}" -c ray --since=30m 2>&1 \
    | egrep -i 'error|exception|traceback|fail|fatal' \
    | tail -n 20 || true)"
  if [[ -n "${workspace_log_matches}" ]]; then
    warn "Recent CPU workspace ray log matches from the last 30m:"
    printf '%s\n' "${workspace_log_matches}"
  else
    log "No recent CPU workspace ray error matches in the last 30m."
  fi

  log "Anyscale health check completed."
}

###############################################################################
# Open a private AKS API shell through Azure Bastion (az aks bastion preview).
# Docs: https://learn.microsoft.com/azure/bastion/bastion-connect-to-aks-private-cluster
###############################################################################
bastion() {
  local use_admin=false
  if [[ "${1:-}" == "--admin" ]]; then
    use_admin=true
  fi

  local rg cluster bastion_id
  rg="$(terraform output -raw resource_group_name)"
  cluster="$(terraform output -raw aks_cluster_name)"
  bastion_id="$(terraform output -json | jq -r '.aks_bastion_connect_command.value' | grep -oE '/subscriptions/[^ ]+/bastionHosts/[^ ]+')"

  ensure_bastion_extensions

  if [[ "${use_admin}" == true ]]; then
    warn "Opening break-glass admin Bastion shell. Prefer non-admin kubelogin access for normal validation."
    az aks bastion --name "${cluster}" --resource-group "${rg}" --admin --bastion "${bastion_id}" --yes
  else
    log "Opening Entra-backed Bastion shell. Run setup.sh kubeconfig inside the shell if kubectl needs conversion."
    az aks bastion --name "${cluster}" --resource-group "${rg}" --bastion "${bastion_id}" --yes
  fi
}

###############################################################################
# Run a noninteractive Bastion tunnel that agents and scripts can reuse without
# entering the interactive `az aks bastion` subshell wrapper.
###############################################################################
bastion_tunnel() {
  require_cmd az
  require_cmd lsof

  local action="${1:-start}"
  shift || true

  local pidfile portfile logfile pid port rg cluster bastion_name cluster_id launcher_pid listener_pid
  pidfile="$(bastion_tunnel_pidfile)"
  portfile="$(bastion_tunnel_portfile)"
  logfile="$(bastion_tunnel_logfile)"
  port="${DEFAULT_BASTION_TUNNEL_PORT}"

  case "${action}" in
    start)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --port)
            [[ $# -ge 2 ]] || die "--port requires a value."
            port="$2"
            shift 2
            ;;
          --help|-h)
            cat <<'USAGE'
Usage:
  ./scripts/setup.sh bastion-tunnel start [--port 64430]
  ./scripts/setup.sh bastion-tunnel status
  ./scripts/setup.sh bastion-tunnel stop

Starts a reusable Azure Bastion tunnel to the private AKS API server using
`az network bastion tunnel`.
USAGE
            return 0
            ;;
          *)
            die "Unknown bastion-tunnel option: $1"
            ;;
        esac
      done

      pid="$(pid_from_file "${pidfile}")"
      if pid_is_running "${pid}"; then
        port="$(cat "${portfile}" 2>/dev/null || echo "${port}")"
        if ! listener_is_ready "${port}"; then
          warn "Recorded Bastion tunnel pid ${pid} is running but 127.0.0.1:${port} is not listening. Restarting it."
          kill "${pid}" 2>/dev/null || true
          clear_runtime_files "${pidfile}" "${portfile}"
        elif ! port_listeners_are_bastion_tunnels "${port}"; then
          die "Tracked Bastion tunnel port ${port} is in use by another process. Stop it or choose another port with --port."
        else
          listener_pid="$(first_listener_pid "${port}" 2>/dev/null || true)"
          if [[ -n "${listener_pid}" ]]; then
            printf '%s\n' "${listener_pid}" > "${pidfile}"
            pid="${listener_pid}"
          fi
          log "Bastion tunnel already running on 127.0.0.1:${port} (pid ${pid})"
          printf 'log file: %s\n' "${logfile}"
          return 0
        fi
      fi

      if listener_is_ready "${port}"; then
        if ! port_listeners_are_bastion_tunnels "${port}"; then
          die "Local port ${port} is already in use. Pick another port with --port."
        fi

        warn "Removing stale Bastion tunnel listener on 127.0.0.1:${port} before starting a fresh tunnel."
        stop_bastion_listeners_on_port "${port}" || true
        if listener_is_ready "${port}"; then
          die "Local port ${port} is already in use after removing stale Bastion listeners. Pick another port with --port."
        fi
      fi

      rg="$(resolve_aks_context resource_group_name)"
      cluster="$(resolve_aks_context aks_cluster_name)"
      bastion_name="$(resolve_aks_context bastion_name)"
      cluster_id="$(resolve_aks_cluster_id)"
      [[ -n "${rg}" && -n "${cluster}" && -n "${bastion_name}" && -n "${cluster_id}" ]] || die "Missing Terraform outputs required for the Bastion tunnel."

      ensure_bastion_extensions
      : > "${logfile}"

      log "Starting Bastion tunnel to ${cluster} on 127.0.0.1:${port}"
      nohup az network bastion tunnel \
        --resource-group "${rg}" \
        --name "${bastion_name}" \
        --target-resource-id "${cluster_id}" \
        --resource-port 443 \
        --port "${port}" > "${logfile}" 2>&1 &
      launcher_pid="$!"

      printf '%s\n' "${port}" > "${portfile}"

      if ! wait_for_local_listener "${port}" 30; then
        kill "${launcher_pid}" 2>/dev/null || true
        stop_bastion_listeners_on_port "${port}" || true
        clear_runtime_files "${pidfile}" "${portfile}"
        tail -20 "${logfile}" >&2 || true
        die "Bastion tunnel did not open on port ${port}."
      fi

      listener_pid="$(first_listener_pid "${port}" 2>/dev/null || true)"
      [[ -n "${listener_pid}" ]] || die "Bastion tunnel opened on port ${port} but no listener PID was found."
      printf '%s\n' "${listener_pid}" > "${pidfile}"

      log "Bastion tunnel ready on 127.0.0.1:${port} (pid ${listener_pid})"
      printf 'export ANYSCALE_BASTION_PORT=%s\n' "${port}"
      printf 'log file: %s\n' "${logfile}"
      ;;
    status)
      pid="$(pid_from_file "${pidfile}")"
      port="$(cat "${portfile}" 2>/dev/null || true)"
      if [[ -n "${port}" ]] && listener_is_ready "${port}" && port_listeners_are_bastion_tunnels "${port}"; then
        pid="$(first_listener_pid "${port}" 2>/dev/null || true)"
        [[ -n "${pid}" ]] && printf '%s\n' "${pid}" > "${pidfile}"
        printf 'status=running\n'
        printf 'pid=%s\n' "${pid}"
        printf 'port=%s\n' "${port}"
        printf 'log=%s\n' "${logfile}"
        return 0
      fi

      clear_runtime_files "${pidfile}" "${portfile}"
      printf 'status=stopped\n'
      printf 'log=%s\n' "${logfile}"
      return 1
      ;;
    stop)
      local stopped=false
      pid="$(pid_from_file "${pidfile}")"
      port="$(cat "${portfile}" 2>/dev/null || true)"
      if pid_is_running "${pid}"; then
        kill "${pid}" 2>/dev/null || true
        stopped=true
      fi
      if [[ -n "${port}" ]] && stop_bastion_listeners_on_port "${port}"; then
        stopped=true
      fi
      if [[ "${stopped}" == true ]]; then
        log "Stopped Bastion tunnel${port:+ on 127.0.0.1:${port}}"
      else
        warn "No running Bastion tunnel found."
      fi
      clear_runtime_files \
        "${pidfile}" \
        "${portfile}" \
        "$(bastion_kubeconfig_path)" \
        "$(bastion_admin_kubeconfig_path)"
      ;;
    *)
      die "Usage: ./scripts/setup.sh bastion-tunnel {start|status|stop}"
      ;;
  esac
}

###############################################################################
# Fetch a dedicated kubeconfig that targets the local Bastion tunnel rather than
# the cluster private FQDN directly.
###############################################################################
kubeconfig_bastion() {
  require_cmd az
  require_cmd kubectl
  require_cmd kubelogin

  local admin=false print_path=false export_line=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --admin)
        admin=true
        shift
        ;;
      --print-path)
        print_path=true
        shift
        ;;
      --export)
        export_line=true
        shift
        ;;
      --help|-h)
        cat <<'USAGE'
Usage:
  ./scripts/setup.sh kubeconfig-bastion [--admin] [--print-path|--export]

Writes a kubeconfig file pointed at the local Bastion tunnel listener.
Run ./scripts/setup.sh bastion-tunnel start first.
USAGE
        return 0
        ;;
      *)
        die "Unknown kubeconfig-bastion option: $1"
        ;;
    esac
  done

  local pidfile portfile pid port rg cluster kubeconfig_file tmp_file original_server tls_server_name
  pidfile="$(bastion_tunnel_pidfile)"
  portfile="$(bastion_tunnel_portfile)"
  pid="$(pid_from_file "${pidfile}")"

  port="$(cat "${portfile}" 2>/dev/null || true)"
  pid_is_running "${pid}" || die "Bastion tunnel is not running. Start it with ./scripts/setup.sh bastion-tunnel start."
  [[ -n "${port}" ]] || die "Could not determine the Bastion tunnel port."
  listener_is_ready "${port}" || die "Bastion tunnel is not listening on 127.0.0.1:${port}. Restart it with ./scripts/setup.sh bastion-tunnel start."

  rg="$(resolve_aks_context resource_group_name)"
  cluster="$(resolve_aks_context aks_cluster_name)"
  [[ -n "${rg}" && -n "${cluster}" ]] || die "Terraform outputs are missing. Run ./scripts/setup.sh deploy first."

  if [[ "${admin}" == true ]]; then
    kubeconfig_file="$(bastion_admin_kubeconfig_path)"
  else
    kubeconfig_file="$(bastion_kubeconfig_path)"
  fi

  if [[ "${admin}" == true ]]; then
    az aks get-credentials \
      --resource-group "${rg}" \
      --name "${cluster}" \
      --file "${kubeconfig_file}" \
      --overwrite-existing \
      --admin \
      --only-show-errors >/dev/null
  else
    az aks get-credentials \
      --resource-group "${rg}" \
      --name "${cluster}" \
      --file "${kubeconfig_file}" \
      --overwrite-existing \
      --only-show-errors >/dev/null
  fi

  original_server="$(kubectl config view --kubeconfig "${kubeconfig_file}" --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
  tls_server_name="${original_server#https://}"
  tls_server_name="${tls_server_name%%/*}"
  tls_server_name="${tls_server_name%%:*}"

  tmp_file="${kubeconfig_file}.tmp"
  awk -v port="${port}" -v tls_server_name="${tls_server_name}" '
    /^    server: https:\/\// {
      print "    server: https://127.0.0.1:" port
      if (tls_server_name != "") {
        print "    tls-server-name: " tls_server_name
      }
      next
    }
    { print }
  ' "${kubeconfig_file}" > "${tmp_file}"
  mv "${tmp_file}" "${kubeconfig_file}"

  if [[ "${admin}" != true ]]; then
    KUBECONFIG="${kubeconfig_file}" kubelogin convert-kubeconfig -l azurecli >/dev/null
  fi

  kubectl_readyz "${kubeconfig_file}"

  if [[ "${print_path}" == true ]]; then
    printf '%s\n' "${kubeconfig_file}"
    return 0
  fi

  if [[ "${export_line}" == true ]]; then
    printf 'export KUBECONFIG=%q\n' "${kubeconfig_file}"
    printf 'export KUBE_CONFIG_PATH=%q\n' "${kubeconfig_file}"
    return 0
  fi

  log "Bastion kubeconfig ready at ${kubeconfig_file}"
  printf 'export KUBECONFIG=%q\n' "${kubeconfig_file}"
  printf 'export KUBE_CONFIG_PATH=%q\n' "${kubeconfig_file}"
  KUBECONFIG="${kubeconfig_file}" kubectl get nodes -o wide
}

###############################################################################
# Fetch Entra-backed kubeconfig and convert it for kubectl with kubelogin.
# For private clusters, run this from a shell with network path to the API server,
# or inside the shell opened by ./scripts/setup.sh bastion.
###############################################################################
kubeconfig() {
  require_cmd az
  require_cmd kubelogin
  require_cmd kubectl

  local rg cluster current_server
  rg="$(terraform output -raw resource_group_name)"
  cluster="$(terraform output -raw aks_cluster_name)"

  current_server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
  if [[ -n "${KUBECONFIG:-}" && "${current_server}" =~ ^https://(localhost|127\.0\.0\.1):[0-9]+/?$ ]]; then
    log "Using Bastion-provided kubeconfig at ${KUBECONFIG}"
  else
    log "Fetching Entra-backed kubeconfig for ${cluster}"
    az aks get-credentials --resource-group "${rg}" --name "${cluster}" --overwrite-existing --only-show-errors
  fi

  log "Converting kubeconfig for azurecli login with kubelogin"
  kubelogin convert-kubeconfig -l azurecli

  log "Checking kubectl access"
  kubectl get --raw=/readyz >/dev/null
  kubectl auth can-i get nodes >/dev/null
  kubectl get nodes -o wide
}

ensure_kubelogin_kubeconfig() {
  require_cmd kubectl
  require_cmd kubelogin
  use_bastion_kubeconfig_if_present
  kubelogin convert-kubeconfig -l azurecli >/dev/null 2>&1 || true
}

validation_namespace() {
  printf 'anyscale-validation\n'
}

job_progress_state_file() {
  local namespace="$1"
  local job_name="$2"

  harness_state_file "job-progress-${namespace}-${job_name}.state"
}

job_pod_name() {
  local namespace="$1"
  local job_name="$2"

  kubectl get pod --namespace "${namespace}" -l "job-name=${job_name}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

job_event_snapshot() {
  local namespace="$1"
  local pod_name="$2"

  [[ -n "${pod_name}" ]] || return 0

  kubectl get events \
    --namespace "${namespace}" \
    --field-selector "involvedObject.kind=Pod,involvedObject.name=${pod_name}" \
    --sort-by=.lastTimestamp \
    -o custom-columns='REASON:.reason,MESSAGE:.message' \
    --no-headers 2>/dev/null | tail -3 | sed '/^$/d' || true
}

print_job_progress() {
  local namespace="$1"
  local job_name="$2"
  local active succeeded failed pod_name pod_phase node_name state_file event_snapshot status_snapshot
  local scheduler_pending=false autoscaler_triggered=false

  active="$(kubectl get job --namespace "${namespace}" "${job_name}" -o jsonpath='{.status.active}' 2>/dev/null || true)"
  succeeded="$(kubectl get job --namespace "${namespace}" "${job_name}" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)"
  failed="$(kubectl get job --namespace "${namespace}" "${job_name}" -o jsonpath='{.status.failed}' 2>/dev/null || true)"

  pod_name="$(job_pod_name "${namespace}" "${job_name}")"
  pod_phase="-"
  node_name="-"

  if [[ -n "${pod_name}" ]]; then
    pod_phase="$(kubectl get pod --namespace "${namespace}" "${pod_name}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    node_name="$(kubectl get pod --namespace "${namespace}" "${pod_name}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
  fi

  event_snapshot="$(job_event_snapshot "${namespace}" "${pod_name}")"
  [[ "${event_snapshot}" == *"FailedScheduling"* && "${event_snapshot}" == *"Insufficient nvidia.com/gpu"* ]] && scheduler_pending=true
  [[ "${event_snapshot}" == *"TriggeredScaleUp"* ]] && autoscaler_triggered=true

  status_snapshot="${active:-0}|${succeeded:-0}|${failed:-0}|${pod_name:-none}|${pod_phase:-Unknown}|${node_name:-pending}|${event_snapshot}"
  state_file="$(job_progress_state_file "${namespace}" "${job_name}")"
  if [[ -f "${state_file}" ]] && [[ "$(cat "${state_file}")" == "${status_snapshot}" ]]; then
    return 0
  fi
  printf '%s\n' "${status_snapshot}" > "${state_file}"

  log "Waiting on job/${job_name}: active=${active:-0} succeeded=${succeeded:-0} failed=${failed:-0} pod=${pod_name:-none} phase=${pod_phase:-Unknown} node=${node_name:-pending}"

  if [[ -n "${pod_name}" && "${pod_phase}" != "Succeeded" ]]; then
    if [[ "${job_name}" == "anyscale-gpu-smoke" && "${scheduler_pending}" == true ]]; then
      warn "GPU pod is still pending because no node currently advertises free nvidia.com/gpu capacity. This is expected while the GPU pool scales from zero and the NVIDIA device plugin converges."
      if [[ "${autoscaler_triggered}" == true ]]; then
        warn "Cluster autoscaler has already requested the GPU pool scale-up. Waiting for the new GPU node to become Ready and report GPU allocatable capacity."
      fi
    elif [[ -n "${event_snapshot}" ]]; then
      printf '%s\n' "${event_snapshot}"
    fi
  fi
}

print_job_logs_or_status() {
  local namespace="$1"
  local job_name="$2"
  local pod_name exit_code reason

  if kubectl logs --namespace "${namespace}" "job/${job_name}"; then
    return 0
  fi

  pod_name="$(job_pod_name "${namespace}" "${job_name}")"
  if [[ -n "${pod_name}" ]]; then
    exit_code="$(kubectl get pod --namespace "${namespace}" "${pod_name}" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || true)"
    reason="$(kubectl get pod --namespace "${namespace}" "${pod_name}" -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}' 2>/dev/null || true)"

    if [[ "${exit_code}" == "0" ]]; then
      warn "Could not stream logs for completed job/${job_name}; pod ${pod_name} exited 0 (${reason:-Completed})."
      kubectl get pod --namespace "${namespace}" "${pod_name}" -o wide || true
      return 0
    fi

    kubectl describe pod --namespace "${namespace}" "${pod_name}" || true
  fi

  return 1
}

wait_for_job() {
  local namespace="$1"
  local job_name="$2"
  local timeout="${3:-20m}"
  local wait_log wait_pid wait_status progress_state_file

  wait_log="$(mktemp "${TMPDIR:-${ROOT_DIR}}/wait-for-job.${job_name}.XXXXXX")"
  progress_state_file="$(job_progress_state_file "${namespace}" "${job_name}")"
  rm -f "${progress_state_file}"
  kubectl wait --namespace "${namespace}" --for=condition=complete "job/${job_name}" --timeout="${timeout}" >"${wait_log}" 2>&1 &
  wait_pid="$!"

  while kill -0 "${wait_pid}" 2>/dev/null; do
    print_job_progress "${namespace}" "${job_name}" || true
    sleep 15
  done

  if wait "${wait_pid}"; then
    wait_status=0
  else
    wait_status=$?
  fi

  cat "${wait_log}"
  rm -f "${wait_log}"
  rm -f "${progress_state_file}"

  if [[ "${wait_status}" -ne 0 ]]; then
    local pod_name
    pod_name="$(job_pod_name "${namespace}" "${job_name}")"
    kubectl describe job --namespace "${namespace}" "${job_name}" || true
    if [[ -n "${pod_name}" ]]; then
      kubectl describe pod --namespace "${namespace}" "${pod_name}" || true
    fi
    return "${wait_status}"
  fi

  print_job_logs_or_status "${namespace}" "${job_name}"
}

cleanup_validation() {
  local namespace
  namespace="$(validation_namespace)"
  kubectl delete namespace "${namespace}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

prepare_validation_namespace() {
  local namespace
  namespace="$(validation_namespace)"
  kubectl create namespace "${namespace}" --dry-run=client -o yaml | kubectl apply --validate=false -f -
}

control_plane_egress_smoke() {
  require_cmd jq
  require_cluster_kubectl_access
  load_env

  local namespace hosts_json hosts_env
  local hosts=()
  namespace="$(validation_namespace)"
  prepare_validation_namespace

  hosts_json="${TF_VAR_anyscale_fqdns:-[]}"
  while IFS= read -r host; do
    [[ -n "${host}" ]] && hosts+=("${host}")
  done < <(jq -r '(. + ["console.anyscale.com", "console.azure.anyscale.com", "api.anyscale.com"]) | unique[]' <<<"${hosts_json}")

  hosts_env=""
  for host in "${hosts[@]}"; do
    hosts_env+="${host} "
  done
  hosts_env="${hosts_env% }"

  log "Validating cluster egress to Anyscale control-plane endpoints"
  kubectl delete job --namespace "${namespace}" anyscale-control-plane-egress --ignore-not-found >/dev/null 2>&1 || true
  kubectl apply --validate=false -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: anyscale-control-plane-egress
  namespace: ${namespace}
spec:
  backoffLimit: 1
  template:
    spec:
      restartPolicy: Never
      tolerations:
      - key: node.anyscale.com/capacity-type
        operator: Exists
        effect: NoSchedule
      containers:
      - name: control-plane-egress
        image: curlimages/curl:8.11.1
        env:
        - name: HOSTS
          value: "${hosts_env}"
        command: ["/bin/sh", "-c"]
        args:
        - |
          set -eu
          for host in \${HOSTS}; do
            echo "== resolving \${host} =="
            nslookup "\${host}"
            echo "== probing https://\${host}/ =="
            code="\$(curl -k -sS -o /dev/null -w '%{http_code}' --connect-timeout 20 --max-time 60 "https://\${host}/")"
            case "\${code}" in
              2*|3*|4*) echo "https://\${host}/ -> HTTP \${code}" ;;
              *) echo "Unexpected HTTP status \${code} for https://\${host}/" >&2; exit 1 ;;
            esac
          done
          echo CONTROL_PLANE_EGRESS_OK
EOF
  wait_for_job "${namespace}" anyscale-control-plane-egress 15m
}

validate_access() {
  log "Validating kubelogin-backed kubectl access"
  ensure_kubelogin_kubeconfig
  kubectl get --raw=/readyz >/dev/null
  kubectl auth can-i get nodes
  kubectl get nodes -o wide
}

validate_private_dns_and_egress() {
  local namespace storage_account acr_login_server aks_private_fqdn workspace_customer_id region
  namespace="$(validation_namespace)"
  storage_account="$(terraform output -raw storage_account_name)"
  acr_login_server="$(terraform output -raw acr_login_server)"
  aks_private_fqdn="$(terraform output -raw aks_private_fqdn)"
  workspace_customer_id="$(terraform output -raw log_analytics_workspace_customer_id)"
  region="$(terraform output -raw location)"

  log "Validating DNS resolution for Private Link and Anyscale endpoints"
  kubectl delete job --namespace "${namespace}" anyscale-dns-egress --ignore-not-found >/dev/null 2>&1 || true
  kubectl apply --validate=false -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: anyscale-dns-egress
  namespace: ${namespace}
spec:
  backoffLimit: 1
  template:
    spec:
      restartPolicy: Never
      tolerations:
      - key: node.anyscale.com/capacity-type
        operator: Exists
        effect: NoSchedule
      containers:
      - name: dns-egress
        image: curlimages/curl:8.11.1
        command: ["/bin/sh", "-c"]
        args:
        - |
          set -eu
          for host in \
            ${storage_account}.blob.core.windows.net \
            ${storage_account}.dfs.core.windows.net \
            ${acr_login_server} \
            arcmktplaceprod.azurecr.io \
            ${aks_private_fqdn} \
            global.handler.control.monitor.azure.com \
            ${region}.handler.control.monitor.azure.com \
            ${workspace_customer_id}.ods.opinsights.azure.com \
            ${workspace_customer_id}.oms.opinsights.azure.com \
            api.anyscale.com \
            console.azure.anyscale.com \
            console.anyscale.com; do
            echo "== resolving \${host} =="
            nslookup "\${host}"
          done
          for url in \
            https://${storage_account}.blob.core.windows.net/ \
            https://arcmktplaceprod.azurecr.io/v2/ \
            https://global.handler.control.monitor.azure.com/ \
            https://${workspace_customer_id}.ods.opinsights.azure.com/ \
            https://api.anyscale.com/ \
            https://console.azure.anyscale.com/ \
            https://console.anyscale.com/; do
            echo "== probing \${url} =="
            code="\$(curl -k -sS -o /dev/null -w '%{http_code}' --connect-timeout 20 --max-time 60 "\${url}")"
            case "\${code}" in
              2*|3*|4*) echo "\${url} -> HTTP \${code}" ;;
              *) echo "Unexpected HTTP status \${code} for \${url}" >&2; exit 1 ;;
            esac
          done
EOF
  wait_for_job "${namespace}" anyscale-dns-egress 15m
}

validate_workload_identity_storage() {
  require_cmd jq

  local wi namespace service_account storage_account container tenant_id client_id
  wi="$(terraform output -json anyscale_operator_workload_identity)"
  namespace="$(jq -r '.namespace' <<<"${wi}")"
  service_account="$(jq -r '.service_account' <<<"${wi}")"
  storage_account="$(jq -r '.storage.account_name' <<<"${wi}")"
  container="$(jq -r '.storage.container' <<<"${wi}")"
  tenant_id="$(jq -r '.tenant_id' <<<"${wi}")"
  client_id="$(jq -r '.client_id' <<<"${wi}")"

  kubectl get namespace "${namespace}" >/dev/null
  kubectl get serviceaccount --namespace "${namespace}" "${service_account}" >/dev/null

  log "Validating Anyscale operator Workload Identity read/write access to Azure Storage"
  kubectl delete job --namespace "${namespace}" anyscale-wi-storage --ignore-not-found >/dev/null 2>&1 || true
  kubectl apply --validate=false -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: anyscale-wi-storage
  namespace: ${namespace}
  labels:
    azure.workload.identity/use: "true"
spec:
  backoffLimit: 1
  template:
    metadata:
      labels:
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: ${service_account}
      restartPolicy: Never
      tolerations:
      - key: node.anyscale.com/capacity-type
        operator: Exists
        effect: NoSchedule
      containers:
      - name: storage-rw
        image: mcr.microsoft.com/azure-cli:2.74.0
        env:
        - name: AZURE_CLIENT_ID
          value: "${client_id}"
        - name: AZURE_TENANT_ID
          value: "${tenant_id}"
        - name: STORAGE_ACCOUNT
          value: "${storage_account}"
        - name: STORAGE_CONTAINER
          value: "${container}"
        command: ["/bin/bash", "-lc"]
        args:
        - |
          set -euo pipefail
          test -f "\${AZURE_FEDERATED_TOKEN_FILE}"
          az login --service-principal \
            --username "\${AZURE_CLIENT_ID}" \
            --tenant "\${AZURE_TENANT_ID}" \
            --federated-token "\$(cat "\${AZURE_FEDERATED_TOKEN_FILE}")" \
            --allow-no-subscriptions \
            --only-show-errors >/dev/null
          blob_name="workload-identity-smoke-\${HOSTNAME}.txt"
          echo "WORKLOAD_IDENTITY_STORAGE_OK" > /tmp/wi.txt
          az storage blob upload \
            --account-name "\${STORAGE_ACCOUNT}" \
            --container-name "\${STORAGE_CONTAINER}" \
            --name "\${blob_name}" \
            --file /tmp/wi.txt \
            --auth-mode login \
            --overwrite true \
            --only-show-errors >/dev/null
          az storage blob download \
            --account-name "\${STORAGE_ACCOUNT}" \
            --container-name "\${STORAGE_CONTAINER}" \
            --name "\${blob_name}" \
            --file /tmp/wi.out \
            --auth-mode login \
            --only-show-errors >/dev/null
          grep -q WORKLOAD_IDENTITY_STORAGE_OK /tmp/wi.out
          az storage blob delete \
            --account-name "\${STORAGE_ACCOUNT}" \
            --container-name "\${STORAGE_CONTAINER}" \
            --name "\${blob_name}" \
            --auth-mode login \
            --only-show-errors >/dev/null
          echo WORKLOAD_IDENTITY_STORAGE_OK
EOF
  wait_for_job "${namespace}" anyscale-wi-storage 20m
}

validate_internal_ingress() {
  local namespace ingress_ip
  namespace="$(validation_namespace)"

  log "Validating internal ingress-nginx reachability"
  kubectl apply --validate=false -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: anyscale-echo
  namespace: ${namespace}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: anyscale-echo
  template:
    metadata:
      labels:
        app: anyscale-echo
    spec:
      tolerations:
      - key: node.anyscale.com/capacity-type
        operator: Exists
        effect: NoSchedule
      containers:
      - name: echo
        image: registry.k8s.io/e2e-test-images/agnhost:2.45
        args: ["netexec", "--http-port=8080"]
        ports:
        - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: anyscale-echo
  namespace: ${namespace}
spec:
  selector:
    app: anyscale-echo
  ports:
  - name: http
    port: 80
    targetPort: 8080
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: anyscale-echo
  namespace: ${namespace}
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      - path: /echo
        pathType: Prefix
        backend:
          service:
            name: anyscale-echo
            port:
              number: 80
EOF

  kubectl rollout status --namespace "${namespace}" deployment/anyscale-echo --timeout=10m
  ingress_ip="$(kubectl get service --namespace ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
  [[ -n "${ingress_ip}" ]] || die "ingress-nginx internal load balancer IP is not assigned."

  kubectl delete job --namespace "${namespace}" anyscale-ingress-probe --ignore-not-found >/dev/null 2>&1 || true
  kubectl apply --validate=false -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: anyscale-ingress-probe
  namespace: ${namespace}
spec:
  backoffLimit: 1
  template:
    spec:
      restartPolicy: Never
      tolerations:
      - key: node.anyscale.com/capacity-type
        operator: Exists
        effect: NoSchedule
      containers:
      - name: curl
        image: curlimages/curl:8.11.1
        command: ["/bin/sh", "-c"]
        args:
        - |
          set -eu
          curl -fsS --connect-timeout 20 --max-time 60 "http://${ingress_ip}/echo"
          echo INGRESS_OK
EOF
  wait_for_job "${namespace}" anyscale-ingress-probe 10m
}

validate_gpu() {
  local namespace
  namespace="$(validation_namespace)"

  log "Validating GPU node pool, autoscale, NVIDIA plugin, and nvidia-smi"
  log "GPU validation can take several minutes when the T4 pool scales from zero. Progress snapshots will print while the job waits."
  kubectl get daemonset --namespace gpu-resources nvidia-device-plugin >/dev/null
  kubectl delete job --namespace "${namespace}" anyscale-gpu-smoke --ignore-not-found >/dev/null 2>&1 || true
  kubectl apply --validate=false -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: anyscale-gpu-smoke
  namespace: ${namespace}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: kubernetes.azure.com/accelerator
                operator: Exists
      tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
      - key: node.anyscale.com/accelerator-type
        operator: Exists
        effect: NoSchedule
      - key: node.anyscale.com/capacity-type
        operator: Exists
        effect: NoSchedule
      containers:
      - name: nvidia-smi
        image: nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04
        command: ["/bin/bash", "-lc"]
        args: ["nvidia-smi && echo GPU_OK"]
        resources:
          limits:
            nvidia.com/gpu: 1
EOF
  wait_for_job "${namespace}" anyscale-gpu-smoke 45m
}

validate_anyscale_operator_patches() {
  local namespace patches_yaml

  load_env
  namespace="${TF_VAR_anyscale_operator_namespace}"

  require_cluster_kubectl_access

  log "Validating Anyscale operator GPU toleration patches"
  patches_yaml="$(kubectl get configmap patches -n "${namespace}" -o jsonpath='{.data.patches\.yaml}')"
  [[ -n "${patches_yaml}" ]] || die "Anyscale operator patches ConfigMap is empty in namespace ${namespace}."

  grep -q 'key: node.anyscale.com/accelerator-type' <<<"${patches_yaml}" || die "Anyscale operator patches ConfigMap is missing the accelerator-type GPU toleration."
  grep -q 'key: nvidia.com/gpu' <<<"${patches_yaml}" || die "Anyscale operator patches ConfigMap is missing the AKS nvidia.com/gpu toleration."

  log "Anyscale operator patches ConfigMap includes both GPU tolerations."
}

validate_k8s() {
  validate_access
  validate_anyscale_operator_patches
  prepare_validation_namespace
  validate_private_dns_and_egress
  validate_workload_identity_storage
  validate_internal_ingress
  validate_gpu
  log "Functional Kubernetes validation completed."
}

validate_observability() {
  require_cmd az
  require_cmd jq

  local workspace_customer_id container_query diagnostics_query container_json diagnostics_json container_rows diagnostics_rows diagnostic_settings_count
  workspace_customer_id="$(terraform output -raw log_analytics_workspace_customer_id)"
  [[ -n "${workspace_customer_id}" ]] || die "Missing log_analytics_workspace_customer_id output. Run ./scripts/setup.sh deploy first."

  container_query='ContainerLogV2 | where TimeGenerated > ago(2h) | summarize Records=count(), Namespaces=make_set(PodNamespace, 10), Sample=any(LogMessage)'
  diagnostics_query='union isfuzzy=true withsource=TableName AzureDiagnostics, AzureMetrics, StorageBlobLogs, ContainerRegistryLoginEvents, ContainerRegistryRepositoryEvents, MicrosoftAzureBastionAuditLogs | where TimeGenerated > ago(2h) | summarize Records=count() by TableName | order by Records desc'

  log "Querying ContainerLogV2 in Log Analytics"
  container_json="$(az monitor log-analytics query --workspace "${workspace_customer_id}" --analytics-query "${container_query}" --output json --only-show-errors)"
  jq . <<<"${container_json}"
  container_rows="$(jq -r 'def n: tonumber? // 0; if type == "array" then (.[0].Records? | n) else (.tables[0].rows[0][0] | n) end' <<<"${container_json}")"
  [[ "${container_rows}" =~ ^[0-9]+$ && "${container_rows}" -gt 0 ]] || die "ContainerLogV2 has no records yet. Run this again after Azure Monitor ingestion catches up."

  diagnostic_settings_count="$(terraform output -json private_mode_validation \
    | jq -r '[.. | objects | .diagnostic_settings_enabled? // empty | select(. == true)] | length')"
  if [[ "${diagnostic_settings_count}" -gt 0 ]]; then
    log "Querying diagnostic tables in Log Analytics"
    diagnostics_json="$(az monitor log-analytics query --workspace "${workspace_customer_id}" --analytics-query "${diagnostics_query}" --output json --only-show-errors)"
    jq . <<<"${diagnostics_json}"
    diagnostics_rows="$(jq -r 'def n: tonumber? // 0; if type == "array" then ([.[].Records? | n] | add // 0) else ([.tables[0].rows[]?[1] | n] | add // 0) end' <<<"${diagnostics_json}")"
    [[ "${diagnostics_rows}" =~ ^[0-9]+$ && "${diagnostics_rows}" -gt 0 ]] || die "Diagnostic tables have no records yet. Generate traffic and run this again after ingestion catches up."
  else
    log "Terraform-managed diagnostic settings are disabled; skipping diagnostic table query."
  fi

  log "Observability validation completed."
}

validate_focused() {
  local include_observability=true

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-observability)
        include_observability=false
        shift
        ;;
      --help|-h)
        cat <<'USAGE'
Usage:
  ./scripts/setup.sh validate-focused
  ./scripts/setup.sh validate-focused --skip-observability

Runs the post-deploy live validation suite with PASS/FAIL output and per-check
logs under .cache/focused-validation/<timestamp>/.
USAGE
        return 0
        ;;
      *)
        die "Unknown validate-focused option: $1"
        ;;
    esac
  done

  reset_focused_validation_run
  log "Running focused live validation suite"

  local cluster_access_ready=false
  local validation_namespace_ready=false

  if run_focused_validation_check "kubectl-access" "kubelogin kubectl access" validate_access; then
    cluster_access_ready=true
  fi

  if [[ "${cluster_access_ready}" == true ]]; then
    run_focused_validation_check "anyscale-operator-patches" "Anyscale operator GPU toleration patches" validate_anyscale_operator_patches || true
    if run_focused_validation_check "validation-namespace" "validation namespace preparation" prepare_validation_namespace; then
      validation_namespace_ready=true
    fi
  else
    skip_focused_validation_check "anyscale-operator-patches" "Anyscale operator GPU toleration patches" "skipped because kubectl access failed"
    skip_focused_validation_check "validation-namespace" "validation namespace preparation" "skipped because kubectl access failed"
  fi

  if [[ "${validation_namespace_ready}" == true ]]; then
    run_focused_validation_check "private-dns-egress" "private DNS and control-plane egress" validate_private_dns_and_egress || true
    run_focused_validation_check "workload-identity-storage" "workload identity storage access" validate_workload_identity_storage || true
    run_focused_validation_check "internal-ingress" "internal ingress reachability" validate_internal_ingress || true
    run_focused_validation_check "gpu-smoke" "GPU scheduling and nvidia-smi" validate_gpu || true
  else
    skip_focused_validation_check "private-dns-egress" "private DNS and control-plane egress" "skipped because validation namespace setup failed"
    skip_focused_validation_check "workload-identity-storage" "workload identity storage access" "skipped because validation namespace setup failed"
    skip_focused_validation_check "internal-ingress" "internal ingress reachability" "skipped because validation namespace setup failed"
    skip_focused_validation_check "gpu-smoke" "GPU scheduling and nvidia-smi" "skipped because validation namespace setup failed"
  fi

  if [[ "${include_observability}" == true ]]; then
    run_focused_validation_check "observability" "Log Analytics and diagnostics ingestion" validate_observability || true
  else
    skip_focused_validation_check "observability" "Log Analytics and diagnostics ingestion" "skipped by --skip-observability"
  fi

  write_focused_validation_summary
  [[ "${FOCUSED_VALIDATION_FAIL_COUNT}" -eq 0 ]]
}

###############################################################################
write_anyscale_compute_config_file() {
  local file_path="$1"
  local profile="${2:-mixed}"

  case "${profile}" in
    mixed)
      cat > "${file_path}" <<EOF
cloud: ${ANYSCALE_CLOUD_NAME}
head_node:
  required_resources:
    CPU: 4
    memory: 16Gi
  advanced_instance_config:
    spec:
      nodeSelector:
        agentpool: cpu
worker_nodes:
  - name: cpu-workers
    required_resources:
      CPU: 4
      memory: 16Gi
    min_nodes: 1
    max_nodes: 4
    advanced_instance_config:
      spec:
        nodeSelector:
          agentpool: cpu
  - name: gpu-workers
    required_resources:
      CPU: 4
      GPU: 1
      memory: 16Gi
    required_labels:
      ray.io/accelerator-type: T4
    min_nodes: 1
    max_nodes: 2
    advanced_instance_config:
      spec:
        nodeSelector:
          agentpool: gput4
        tolerations:
          - key: nvidia.com/gpu
            operator: Exists
            effect: NoSchedule
          - key: node.anyscale.com/accelerator-type
            operator: Exists
            effect: NoSchedule
          - key: node.anyscale.com/capacity-type
            operator: Exists
            effect: NoSchedule
EOF
      ;;
    cpu)
      cat > "${file_path}" <<EOF
cloud: ${ANYSCALE_CLOUD_NAME}
head_node:
  required_resources:
    CPU: 4
    memory: 16Gi
  advanced_instance_config:
    spec:
      nodeSelector:
        agentpool: cpu
worker_nodes:
  - name: cpu-workers
    required_resources:
      CPU: 4
      memory: 16Gi
    min_nodes: 1
    max_nodes: 1
    advanced_instance_config:
      spec:
        nodeSelector:
          agentpool: cpu
EOF
      ;;
    gpu)
      cat > "${file_path}" <<EOF
cloud: ${ANYSCALE_CLOUD_NAME}
head_node:
  required_resources:
    CPU: 4
    memory: 16Gi
  advanced_instance_config:
    spec:
      nodeSelector:
        agentpool: cpu
worker_nodes:
  - name: gpu-workers
    required_resources:
      CPU: 4
      GPU: 1
      memory: 16Gi
    required_labels:
      ray.io/accelerator-type: T4
    min_nodes: 1
    max_nodes: 1
    advanced_instance_config:
      spec:
        nodeSelector:
          agentpool: gput4
        tolerations:
          - key: nvidia.com/gpu
            operator: Exists
            effect: NoSchedule
          - key: node.anyscale.com/accelerator-type
            operator: Exists
            effect: NoSchedule
          - key: node.anyscale.com/capacity-type
            operator: Exists
            effect: NoSchedule
EOF
      ;;
    *)
      die "Unknown Anyscale compute config profile ${profile}"
      ;;
  esac
}

anyscale_compute_config_worker_min_nodes_signature_from_file() {
  local file_path="$1"

  awk '
    $1 == "-" && $2 == "name:" { name = $3; next }
    $1 == "name:" { name = $2; next }
    $1 == "min_nodes:" && name != "" { print name "=" $2; name = "" }
  ' "${file_path}" | sort
}

anyscale_compute_config_worker_min_nodes_signature_from_output() {
  local raw_output="$1"

  printf '%s\n' "${raw_output}" | awk '
    /^config:/ { in_config = 1; next }
    !in_config { next }
    $1 == "-" && $2 == "name:" { name = $3; next }
    $1 == "name:" { name = $2; next }
    $1 == "min_nodes:" && name != "" { print name "=" $2; name = "" }
  ' | sort
}

anyscale_compute_config_output_matches_profile() {
  local raw_output="$1"
  local profile="$2"

  grep -q 'CPU: 4' <<<"${raw_output}" || return 1
  grep -q 'memory: 16Gi' <<<"${raw_output}" || return 1
  ! grep -Eq 'CPU: 8|memory: 32Gi' <<<"${raw_output}" || return 1

  case "${profile}" in
    mixed)
      grep -q 'GPU: 1' <<<"${raw_output}" || return 1
      grep -q 'node.anyscale.com/capacity-type' <<<"${raw_output}" || return 1
      ;;
    gpu)
      grep -q 'GPU: 1' <<<"${raw_output}" || return 1
      grep -q 'node.anyscale.com/capacity-type' <<<"${raw_output}" || return 1
      ;;
    cpu)
      ! grep -q 'GPU: 1' <<<"${raw_output}" || return 1
      ;;
  esac
}

ensure_anyscale_compute_config() {
  local compute_config_name="$1"
  local cli_bin="$2"
  local config_file="$3"
  local profile="${4:-mixed}"
  local get_output
  local desired_worker_min_nodes current_worker_min_nodes

  write_anyscale_compute_config_file "${config_file}" "${profile}"

  if get_output="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
    "${cli_bin}" compute-config get \
      --name "${compute_config_name}" \
      --cloud-name "${ANYSCALE_CLOUD_NAME}" 2>&1)"; then
    desired_worker_min_nodes="$(anyscale_compute_config_worker_min_nodes_signature_from_file "${config_file}")"
    current_worker_min_nodes="$(anyscale_compute_config_worker_min_nodes_signature_from_output "${get_output}")"
    if grep -q 'required_resources' <<<"${get_output}" \
      && ! grep -Eq 'instance_type:|14CPU-56GB-CPU|8CPU-32GB-1xT4-AKS' <<<"${get_output}" \
      && [[ "${current_worker_min_nodes}" == "${desired_worker_min_nodes}" ]] \
      && anyscale_compute_config_output_matches_profile "${get_output}" "${profile}"; then
      log "Using existing Anyscale declarative compute config ${compute_config_name}"
      return 0
    fi
    log "Refreshing Anyscale compute config ${compute_config_name} to declarative profile ${profile}"
  else
    log "Creating Anyscale declarative compute config ${compute_config_name} (profile ${profile})"
  fi

  run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
    "${cli_bin}" compute-config create \
      --name "${compute_config_name}" \
      --config-file "${config_file}" >/dev/null
}

anyscale_compute_config_version_name() {
  local compute_config_name="$1"
  local cli_bin="$2"
  local get_output

  get_output="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
    "${cli_bin}" compute-config get \
      --name "${compute_config_name}" \
      --cloud-name "${ANYSCALE_CLOUD_NAME}" 2>&1)"

  awk -F': ' '/^name:/ {print $2; exit}' <<<"${get_output}"
}

write_anyscale_workspace_update_file() {
  local workspace_json="$1"
  local file_path="$2"
  local compute_config_name="$3"
  local workspace_name image_uri idle_termination_minutes

  workspace_name="$(jq -r '.name // empty' <<<"${workspace_json}")"
  image_uri="$(jq -r '.config.image_uri // empty' <<<"${workspace_json}")"
  idle_termination_minutes="$(jq -r '.config.idle_termination_minutes // -1' <<<"${workspace_json}")"

  [[ -n "${workspace_name}" ]] || die "Cannot build Anyscale workspace update file without a workspace name."
  [[ -n "${image_uri}" ]] || die "Workspace ${workspace_name} does not expose config.image_uri; cannot build a safe update file."

  {
    printf 'name: %s\n' "${workspace_name}"
    printf 'image_uri: %s\n' "${image_uri}"
    printf 'compute_config: %s\n' "${compute_config_name}"
    printf 'idle_termination_minutes: %s\n' "${idle_termination_minutes}"
    if jq -e '.config.env_vars | type == "object" and length > 0' <<<"${workspace_json}" >/dev/null 2>&1; then
      printf 'env_vars:\n'
      jq -r '.config.env_vars | to_entries[] | "  \(.key): " + (.value | @json)' <<<"${workspace_json}"
    else
      printf 'env_vars: {}\n'
    fi
  } > "${file_path}"
}

normalize_anyscale_workspace_status() {
  local raw_status="$1"

  printf '%s\n' "${raw_status}" \
    | tail -n 1 \
    | sed -E 's/'$'\033''\[[0-9;]*[A-Za-z]//g' \
    | sed -E 's/^.*\)[[:space:]]*//' \
    | tr -d '\r' \
    | awk '{$1=$1; print}'
}

require_positive_integer_arg() {
  local name="$1"
  local value="$2"

  [[ "${value}" =~ ^[1-9][0-9]*$ ]] || die "${name} must be a positive integer."
}

wait_for_anyscale_workspace_running() {
  local workspace_name="$1"
  local cli_bin="$2"
  local wait_log="$3"
  local deadline current_epoch raw_status current_status previous_status=""

  ANYSCALE_WORKSPACE_WAIT_RESULT=""
  : > "${wait_log}"
  deadline=$(( $(date +%s) + SETUP_TIMEOUT_ANYSCALE_WORKSPACE_WAIT_SECONDS ))

  while true; do
    if ! raw_status="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
      "${cli_bin}" workspace_v2 status \
        --name "${workspace_name}" \
        --cloud "${ANYSCALE_CLOUD_NAME}" 2>&1)"; then
      printf '%s\n' "${raw_status}" | tee -a "${wait_log}"
      return 1
    fi

    current_status="$(normalize_anyscale_workspace_status "${raw_status}")"
    printf '%s\n' "${raw_status}" >> "${wait_log}"

    if [[ -z "${current_status}" ]]; then
      current_status="UNKNOWN"
    fi

    if [[ "${current_status}" != "${previous_status}" ]]; then
      log "Workspace ${workspace_name} status: ${current_status}"
      previous_status="${current_status}"
    fi

    case "${current_status}" in
      RUNNING)
        ANYSCALE_WORKSPACE_WAIT_RESULT="${current_status}"
        return 0
        ;;
      TERMINATED|TERMINATING|CREATE_FAILED|FAILED|ERROR)
        ANYSCALE_WORKSPACE_WAIT_RESULT="${current_status}"
        return 1
        ;;
    esac

    if anyscale_workspace_runtime_ready_on_cluster "${workspace_name}"; then
      warn "Workspace ${workspace_name} is still reported as ${current_status} by the Anyscale API, but the Ray head pod is Ready and serving on the cluster. Proceeding with Kubernetes-backed readiness confirmation."
      ANYSCALE_WORKSPACE_WAIT_RESULT="RUNNING (confirmed via Kubernetes head-pod readiness while Anyscale API reported ${current_status})"
      return 0
    fi

    current_epoch=$(date +%s)
    if (( current_epoch >= deadline )); then
      ANYSCALE_WORKSPACE_WAIT_RESULT="Timed out waiting for RUNNING; last observed state=${current_status}"
      return 1
    fi

    sleep 15
  done
}

wait_for_anyscale_workspace_running_attempts() {
  local workspace_name="$1"
  local cli_bin="$2"
  local wait_log="$3"
  local max_attempts="$4"
  local interval_seconds="$5"
  local attempt raw_status current_status previous_status=""

  require_positive_integer_arg "--max-attempts" "${max_attempts}"
  require_positive_integer_arg "--interval-seconds" "${interval_seconds}"

  ANYSCALE_WORKSPACE_WAIT_RESULT=""
  : > "${wait_log}"

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if ! raw_status="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
      "${cli_bin}" workspace_v2 status \
        --name "${workspace_name}" \
        --cloud "${ANYSCALE_CLOUD_NAME}" 2>&1)"; then
      printf 'attempt=%s/%s\n' "${attempt}" "${max_attempts}" >> "${wait_log}"
      printf '%s\n' "${raw_status}" | tee -a "${wait_log}"
      return 1
    fi

    current_status="$(normalize_anyscale_workspace_status "${raw_status}")"
    printf 'attempt=%s/%s\n' "${attempt}" "${max_attempts}" >> "${wait_log}"
    printf '%s\n' "${raw_status}" >> "${wait_log}"

    if [[ -z "${current_status}" ]]; then
      current_status="UNKNOWN"
    fi

    if [[ "${current_status}" != "${previous_status}" ]]; then
      log "Workspace ${workspace_name} status (${attempt}/${max_attempts}): ${current_status}"
      previous_status="${current_status}"
    fi

    case "${current_status}" in
      RUNNING)
        ANYSCALE_WORKSPACE_WAIT_RESULT="${current_status}"
        return 0
        ;;
      TERMINATED|TERMINATING|CREATE_FAILED|FAILED|ERROR)
        ANYSCALE_WORKSPACE_WAIT_RESULT="${current_status}"
        return 1
        ;;
    esac

    if anyscale_workspace_runtime_ready_on_cluster "${workspace_name}"; then
      warn "Workspace ${workspace_name} is still reported as ${current_status} by the Anyscale API, but the Ray head pod is Ready and serving on the cluster. Proceeding with Kubernetes-backed readiness confirmation."
      ANYSCALE_WORKSPACE_WAIT_RESULT="RUNNING (confirmed via Kubernetes head-pod readiness while Anyscale API reported ${current_status})"
      return 0
    fi

    if (( attempt < max_attempts )); then
      sleep "${interval_seconds}"
    fi
  done

  ANYSCALE_WORKSPACE_WAIT_RESULT="Timed out waiting for RUNNING after ${max_attempts} attempts; last observed state=${current_status}"
  return 1
}

anyscale_workspace_runtime_ready_on_cluster() {
  local workspace_name="$1"
  local namespace head_pod_name pod_phase pod_ready

  namespace="${TF_VAR_anyscale_operator_namespace}"
  head_pod_name="$(kubectl get pods -n "${namespace}" \
    -l "app.kubernetes.io/name=${workspace_name},ray-node-type=head" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

  [[ -n "${head_pod_name}" ]] || return 1

  pod_phase="$(kubectl get pod -n "${namespace}" "${head_pod_name}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  pod_ready="$(kubectl get pod -n "${namespace}" "${head_pod_name}" \
    -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || true)"

  [[ "${pod_phase}" == "Running" && "${pod_ready}" == "True" ]] || return 1

  run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_WORKSPACE_COMMAND_SECONDS}" \
    kubectl exec -n "${namespace}" -c ray "${head_pod_name}" -- \
    bash -lc 'ray status >/dev/null 2>&1'
}

wait_for_anyscale_workspace_terminated_attempts() {
  local workspace_name="$1"
  local cli_bin="$2"
  local wait_log="$3"
  local max_attempts="$4"
  local interval_seconds="$5"
  local attempt raw_status current_status previous_status=""

  require_positive_integer_arg "--max-attempts" "${max_attempts}"
  require_positive_integer_arg "--interval-seconds" "${interval_seconds}"

  ANYSCALE_WORKSPACE_WAIT_RESULT=""
  : > "${wait_log}"

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if ! raw_status="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
      "${cli_bin}" workspace_v2 status \
        --name "${workspace_name}" \
        --cloud "${ANYSCALE_CLOUD_NAME}" 2>&1)"; then
      printf 'attempt=%s/%s\n' "${attempt}" "${max_attempts}" >> "${wait_log}"
      printf '%s\n' "${raw_status}" | tee -a "${wait_log}"
      return 1
    fi

    current_status="$(normalize_anyscale_workspace_status "${raw_status}")"
    printf 'attempt=%s/%s\n' "${attempt}" "${max_attempts}" >> "${wait_log}"
    printf '%s\n' "${raw_status}" >> "${wait_log}"

    if [[ -z "${current_status}" ]]; then
      current_status="UNKNOWN"
    fi

    if [[ "${current_status}" != "${previous_status}" ]]; then
      log "Workspace ${workspace_name} status (${attempt}/${max_attempts}): ${current_status}"
      previous_status="${current_status}"
    fi

    if [[ "${current_status}" == "TERMINATED" ]]; then
      ANYSCALE_WORKSPACE_WAIT_RESULT="${current_status}"
      return 0
    fi

    if (( attempt < max_attempts )); then
      sleep "${interval_seconds}"
    fi
  done

  ANYSCALE_WORKSPACE_WAIT_RESULT="Timed out waiting for TERMINATED after ${max_attempts} attempts; last observed state=${current_status}"
  return 1
}

workspace_head_pod_name() {
  local workspace_name="$1"
  local namespace head_pod_name

  namespace="${TF_VAR_anyscale_operator_namespace}"
  head_pod_name="$(kubectl get pods -n "${namespace}" \
    -l "app.kubernetes.io/name=${workspace_name},ray-node-type=head" \
    -o json 2>/dev/null \
    | jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | select(.status.phase == "Running") | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | sort_by(.metadata.creationTimestamp) | last | .metadata.name // empty' || true)"

  [[ -n "${head_pod_name}" ]] || die "Could not find a Ray head pod for workspace ${workspace_name} in namespace ${namespace}."
  printf '%s\n' "${head_pod_name}"
}

wait_for_workspace_runtime_stable() {
  local workspace_name="$1"
  local worker_node_prefix="$2"
  local wait_log="$3"
  local namespace deadline current_epoch snapshot_json terminating_count head_name worker_line stable_count=0 previous_summary=""

  namespace="${TF_VAR_anyscale_operator_namespace}"
  deadline=$(( $(date +%s) + SETUP_TIMEOUT_ANYSCALE_WORKSPACE_WAIT_SECONDS ))
  : > "${wait_log}.runtime-stable"

  while true; do
    snapshot_json="$(kubectl get pods -n "${namespace}" \
      -l "app.kubernetes.io/name=${workspace_name}" \
      -o json 2>/dev/null || true)"
    terminating_count="$(jq -r '[.items[] | select(.metadata.deletionTimestamp != null)] | length' <<<"${snapshot_json}")"
    head_name="$(jq -r '[.items[] | select(.metadata.labels["ray-node-type"] == "head") | select(.metadata.deletionTimestamp == null) | select(.status.phase == "Running") | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | sort_by(.metadata.creationTimestamp) | last | .metadata.name // empty' <<<"${snapshot_json}")"
    worker_line="$(jq -r --arg prefix "${worker_node_prefix}" '[.items[] | select(.metadata.labels["ray-node-type"] == "worker") | select(.metadata.deletionTimestamp == null) | select(.status.phase == "Running") | select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) | select(.spec.nodeName | startswith($prefix))] | sort_by(.metadata.creationTimestamp) | last | if . == null then "" else [.metadata.name, .spec.nodeName, .status.podIP] | @tsv end' <<<"${snapshot_json}")"

    printf 'terminating=%s head=%s worker=%s\n' "${terminating_count}" "${head_name}" "${worker_line}" >> "${wait_log}.runtime-stable"

    if [[ "${terminating_count}" == "0" && -n "${head_name}" && -n "${worker_line}" ]] \
      && anyscale_workspace_runtime_ready_on_cluster "${workspace_name}"; then
      stable_count=$((stable_count + 1))
      if (( stable_count >= 2 )); then
        log "Workspace ${workspace_name} runtime is stable with worker on ${worker_node_prefix}*."
        return 0
      fi
    else
      stable_count=0
    fi

    summary="terminating=${terminating_count} head=${head_name:-none} worker=${worker_line:-none} stable=${stable_count}/2"
    if [[ "${summary}" != "${previous_summary}" ]]; then
      log "Waiting for workspace ${workspace_name} runtime stability: ${summary}"
      previous_summary="${summary}"
    fi

    current_epoch=$(date +%s)
    if (( current_epoch >= deadline )); then
      die "Workspace ${workspace_name} runtime did not become stable. See ${wait_log}.runtime-stable."
    fi

    sleep 15
  done
}

workspace_exec_head_bash() {
  local workspace_name="$1"
  local script="$2"

  workspace_exec_head_bash_with_timeout "${workspace_name}" "${script}" "${SETUP_TIMEOUT_ANYSCALE_WORKSPACE_COMMAND_SECONDS}"
}

workspace_exec_head_bash_with_timeout() {
  local workspace_name="$1"
  local script="$2"
  local timeout_seconds="$3"
  local namespace head_pod_name

  require_positive_integer_arg "--command-timeout-seconds" "${timeout_seconds}"

  namespace="${TF_VAR_anyscale_operator_namespace}"
  head_pod_name="$(workspace_head_pod_name "${workspace_name}")"

  run_with_timeout "${timeout_seconds}" \
    kubectl exec -n "${namespace}" -c ray "${head_pod_name}" -- bash -lc "${script}"
}

workspace_cpu_probe_command() {
  cat <<'EOF'
python - <<'PY'
import ray

ray.init(address="auto")

@ray.remote(num_cpus=1)
def cpu_probe():
    return "CPU_WORKSPACE_OK"

print(ray.get(cpu_probe.remote()))
PY
EOF
}

run_workspace_cpu_probe_with_timeout() {
  local workspace_name="$1"
  local timeout_seconds="$2"
  local cpu_ray_command

  cpu_ray_command="$(workspace_cpu_probe_command)"
  workspace_exec_head_bash_with_timeout "${workspace_name}" "${cpu_ray_command}" "${timeout_seconds}"
}

run_workspace_cpu_probe_with_retries() {
  local workspace_name="$1"
  local timeout_seconds="$2"
  local cpu_ray_log="$3"
  local max_attempts="${4:-4}"
  local cli_bin="${5:-}"
  local wait_log="${6:-}"
  local probe_attempt probe_exit

  require_positive_integer_arg "cpu-probe-max-attempts" "${max_attempts}"

  for ((probe_attempt=1; probe_attempt<=max_attempts; probe_attempt++)); do
    log "Ray num_cpus=1 probe attempt ${probe_attempt}/${max_attempts} on ${workspace_name}"
    probe_exit=0
    run_workspace_cpu_probe_with_timeout "${workspace_name}" "${timeout_seconds}" 2>&1 | tee "${cpu_ray_log}" || probe_exit=$?
    if [[ "${probe_exit}" -eq 0 ]] && grep -q 'CPU_WORKSPACE_OK' "${cpu_ray_log}"; then
      return 0
    fi
    if [[ "${probe_attempt}" -eq "${max_attempts}" ]]; then
      return 1
    fi
    log "CPU probe attempt ${probe_attempt} failed (exit=${probe_exit}); waiting 30s for workspace readiness to settle and retrying"
    sleep 30
    if [[ -n "${cli_bin}" && -n "${wait_log}" ]]; then
      wait_for_anyscale_workspace_running_attempts "${workspace_name}" "${cli_bin}" "${wait_log}" 10 30 || true
    fi
  done
}

###############################################################################
anyscale_workspaces_register() {
  local cpu_workspace_name="aks-cpu-workspace"
  local gpu_workspace_name="aks-gpu-workspace"
  local cpu_compute_config_name="aks-cpu"
  local gpu_compute_config_name="aks-gpu"
  local cli_bin namespace
  local cpu_compute_config_file gpu_compute_config_file
  local cpu_create_log cpu_start_log cpu_wait_log cpu_validate_log
  local gpu_create_log gpu_start_log gpu_wait_log gpu_validate_log

  load_env
  sync_anyscale_cli_env
  require_anyscale_cli
  require_cmd jq
  require_cluster_kubectl_access
  require_env_var ANYSCALE_CLI_TOKEN
  require_env_var ANYSCALE_CLOUD_NAME
  require_env_var ANYSCALE_CLOUD_DEPLOYMENT_ID

  cli_bin="$(anyscale_cli_bin)"
  namespace="${TF_VAR_anyscale_operator_namespace}"
  mkdir -p "${CACHE_DIR}"

  cpu_compute_config_file="${CACHE_DIR}/anyscale-compute.${cpu_compute_config_name}.yaml"
  gpu_compute_config_file="${CACHE_DIR}/anyscale-compute.${gpu_compute_config_name}.yaml"
  cpu_create_log="${CACHE_DIR}/${cpu_workspace_name}.create.log"
  cpu_start_log="${CACHE_DIR}/${cpu_workspace_name}.start.log"
  cpu_wait_log="${CACHE_DIR}/${cpu_workspace_name}.wait.log"
  cpu_validate_log="${CACHE_DIR}/${cpu_workspace_name}.validate.log"
  gpu_create_log="${CACHE_DIR}/${gpu_workspace_name}.create.log"
  gpu_start_log="${CACHE_DIR}/${gpu_workspace_name}.start.log"
  gpu_wait_log="${CACHE_DIR}/${gpu_workspace_name}.wait.log"
  gpu_validate_log="${CACHE_DIR}/${gpu_workspace_name}.validate.log"

  ensure_registered_workspace() {
    local workspace_name="$1"
    local compute_config_name="$2"
    local create_log="$3"
    local workspace_json workspace_id workspace_state current_compute_config target_compute_config
    local create_output create_status update_output terminate_output workspace_update_file update_log terminate_log terminate_wait_log

    create_status=0
    if run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
      "${cli_bin}" workspace_v2 status \
        --name "${workspace_name}" \
        --cloud "${ANYSCALE_CLOUD_NAME}" >/dev/null 2>&1; then
      log "Workspace ${workspace_name} already exists"
      workspace_json="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
        "${cli_bin}" workspace_v2 get \
          --name "${workspace_name}" \
          --cloud "${ANYSCALE_CLOUD_NAME}" \
          --json 2>&1)"
      workspace_id="$(jq -r '.id // empty' <<<"${workspace_json}")"
      workspace_state="$(jq -r '.state // empty' <<<"${workspace_json}")"
      current_compute_config="$(jq -r '.config.compute_config // empty' <<<"${workspace_json}")"
      target_compute_config="$(anyscale_compute_config_version_name "${compute_config_name}" "${cli_bin}")"

      if [[ -n "${workspace_id}" && -n "${target_compute_config}" && "${current_compute_config}" != "${target_compute_config}" ]]; then
        update_log="${CACHE_DIR}/${workspace_name}.update-compute-config.log"
        terminate_log="${CACHE_DIR}/${workspace_name}.terminate-for-update.log"
        terminate_wait_log="${CACHE_DIR}/${workspace_name}.terminate-for-update.wait.log"
        workspace_update_file="${CACHE_DIR}/${workspace_name}.update-compute-config.yaml"

        if [[ "${workspace_state}" != "TERMINATED" ]]; then
          log "Terminating workspace ${workspace_name} before compute-config update"
          if ! terminate_output="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
            "${cli_bin}" workspace_v2 terminate \
              --name "${workspace_name}" \
              --cloud "${ANYSCALE_CLOUD_NAME}" 2>&1)"; then
            printf '%s\n' "${terminate_output}" | tee "${terminate_log}"
            if ! grep -Eiq 'already.*terminated|currently in state: TERMINATED' <<<"${terminate_output}"; then
              die "Workspace ${workspace_name} could not be terminated for compute-config update. See ${terminate_log}."
            fi
          else
            printf '%s\n' "${terminate_output}" | tee "${terminate_log}"
          fi
          if ! wait_for_anyscale_workspace_terminated_attempts "${workspace_name}" "${cli_bin}" "${terminate_wait_log}" 30 20; then
            printf '%s\n' "${ANYSCALE_WORKSPACE_WAIT_RESULT}" | tee -a "${terminate_wait_log}"
            die "${workspace_name} did not reach TERMINATED before compute-config update. See ${terminate_wait_log}."
          fi
        fi

        write_anyscale_workspace_update_file "${workspace_json}" "${workspace_update_file}" "${compute_config_name}"
        if ! update_output="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
          "${cli_bin}" workspace_v2 update "${workspace_id}" \
            -f "${workspace_update_file}" \
            --compute-config "${compute_config_name}" 2>&1)"; then
          printf '%s\n' "${update_output}" | tee "${update_log}"
          die "Workspace ${workspace_name} compute-config update failed. See ${update_log}."
        fi
        printf '%s\n' "${update_output}" | tee "${update_log}"
      fi
      return 0
    fi

    log "Creating workspace ${workspace_name} with compute config ${compute_config_name}"
    if ! create_output="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
      "${cli_bin}" workspace_v2 create \
        --name "${workspace_name}" \
        --compute-config "${compute_config_name}" \
        --cloud "${ANYSCALE_CLOUD_NAME}" 2>&1)"; then
      create_status=$?
    fi
    printf '%s\n' "${create_output}" | tee "${create_log}"
    if [[ "${create_status}" -ne 0 ]] && ! grep -q 'Workspace created successfully id:' <<<"${create_output}"; then
      die "Workspace ${workspace_name} creation failed. See ${create_log}."
    fi
  }

  start_workspace_for_validation() {
    local workspace_name="$1"
    local start_log="$2"
    local start_output

    if ! start_output="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
      "${cli_bin}" workspace_v2 start \
        --name "${workspace_name}" \
        --cloud "${ANYSCALE_CLOUD_NAME}" 2>&1)"; then
      printf '%s\n' "${start_output}" | tee "${start_log}"
      if ! grep -Eiq 'already.*running|currently in state: STARTING|currently in state: RUNNING' <<<"${start_output}"; then
        die "Workspace ${workspace_name} start failed. See ${start_log}."
      fi
    else
      printf '%s\n' "${start_output}" | tee "${start_log}"
    fi
  }

  wait_for_workspace_running_or_die() {
    local workspace_name="$1"
    local wait_log="$2"

    if ! wait_for_anyscale_workspace_running "${workspace_name}" "${cli_bin}" "${wait_log}"; then
      printf '%s\n' "${ANYSCALE_WORKSPACE_WAIT_RESULT}" | tee -a "${wait_log}"
      die "Workspace ${workspace_name} did not reach RUNNING. See ${wait_log}."
    fi
    printf '%s\n' "${ANYSCALE_WORKSPACE_WAIT_RESULT}" | tee -a "${wait_log}"
  }

  validate_workspace_warm_capacity() {
    local workspace_name="$1"
    local worker_node_prefix="$2"
    local validate_log="$3"
    local deadline current_epoch head_pod head_node worker_line

    head_pod="$(workspace_head_pod_name "${workspace_name}")"
    head_node="$(kubectl get pod -n "${namespace}" "${head_pod}" -o jsonpath='{.spec.nodeName}')"
    deadline=$(( $(date +%s) + SETUP_TIMEOUT_ANYSCALE_WORKSPACE_WAIT_SECONDS ))

    while true; do
      worker_line="$(kubectl get pods -n "${namespace}" \
        -l "app.kubernetes.io/name=${workspace_name},ray-node-type=worker" \
        -o wide --no-headers 2>/dev/null \
        | awk -v prefix="${worker_node_prefix}" '$3 == "Running" && $7 ~ "^"prefix {print; exit}')"
      if [[ -n "${worker_line}" ]]; then
        {
          printf 'workspace=%s\n' "${workspace_name}"
          printf 'head_pod=%s\n' "${head_pod}"
          printf 'head_node=%s\n' "${head_node}"
          printf 'worker=%s\n' "${worker_line}"
          kubectl get pods -n "${namespace}" -l "app.kubernetes.io/name=${workspace_name}" -o wide
        } 2>&1 | tee "${validate_log}"
        return 0
      fi

      current_epoch="$(date +%s)"
      if (( current_epoch >= deadline )); then
        {
          printf 'workspace=%s\n' "${workspace_name}"
          printf 'head_pod=%s\n' "${head_pod}"
          printf 'head_node=%s\n' "${head_node}"
          printf 'missing_worker_prefix=%s\n' "${worker_node_prefix}"
          kubectl get pods -n "${namespace}" -l "app.kubernetes.io/name=${workspace_name}" -o wide
        } 2>&1 | tee "${validate_log}"
        die "Workspace ${workspace_name} did not keep a warm worker on ${worker_node_prefix}*. See ${validate_log}."
      fi

      sleep 15
    done
  }

  validate_anyscale_operator_patches
  ensure_anyscale_compute_config "${cpu_compute_config_name}" "${cli_bin}" "${cpu_compute_config_file}" "cpu"
  ensure_anyscale_compute_config "${gpu_compute_config_name}" "${cli_bin}" "${gpu_compute_config_file}" "gpu"

  ensure_registered_workspace "${cpu_workspace_name}" "${cpu_compute_config_name}" "${cpu_create_log}"
  ensure_registered_workspace "${gpu_workspace_name}" "${gpu_compute_config_name}" "${gpu_create_log}"

  start_workspace_for_validation "${cpu_workspace_name}" "${cpu_start_log}"
  start_workspace_for_validation "${gpu_workspace_name}" "${gpu_start_log}"

  wait_for_workspace_running_or_die "${cpu_workspace_name}" "${cpu_wait_log}"
  wait_for_workspace_running_or_die "${gpu_workspace_name}" "${gpu_wait_log}"

  validate_workspace_warm_capacity "${cpu_workspace_name}" "aks-cpu-" "${cpu_validate_log}"
  validate_workspace_warm_capacity "${gpu_workspace_name}" "aks-gput4-" "${gpu_validate_log}"

  log "CPU workspace ${cpu_workspace_name} and GPU workspace ${gpu_workspace_name} are registered, running, and warm on the expected node pools."
}

###############################################################################
workload_require_inputs() {
  load_env
  sync_anyscale_cli_env
  require_anyscale_cli
  require_cmd jq
  require_cmd rsync
  require_env_var ANYSCALE_CLI_TOKEN
  require_env_var ANYSCALE_CLOUD_NAME
}

workload_require_workspace_proof_inputs() {
  workload_require_inputs
  [[ -f "${ROOT_DIR}/workloads/proofs/cpu_ray_proof.py" ]] || die "Missing workloads/proofs/cpu_ray_proof.py"
  [[ -f "${ROOT_DIR}/workloads/proofs/gpu_ray_proof.py" ]] || die "Missing workloads/proofs/gpu_ray_proof.py"
}

workload_require_pipeline_inputs() {
  workload_require_inputs
  require_cmd curl
  require_cmd lsof
  [[ -f "${ROOT_DIR}/workloads/proofs/build_train_serve_common.py" ]] || die "Missing workloads/proofs/build_train_serve_common.py"
  [[ -f "${ROOT_DIR}/workloads/proofs/anyscale_build_cpu_job_proof.py" ]] || die "Missing workloads/proofs/anyscale_build_cpu_job_proof.py"
  [[ -f "${ROOT_DIR}/workloads/proofs/anyscale_train_gpu_job_proof.py" ]] || die "Missing workloads/proofs/anyscale_train_gpu_job_proof.py"
  [[ -f "${ROOT_DIR}/workloads/proofs/anyscale_serve_gpu_proof.py" ]] || die "Missing workloads/proofs/anyscale_serve_gpu_proof.py"
}

workload_prepare_stage() {
  workload_require_inputs
  ensure_deploy_e2e_bastion_access
}

workload_workspace_name_for_compute_config() {
  local compute_config_name="$1"

  case "${compute_config_name}" in
    "${WORKLOAD_CPU_COMPUTE_CONFIG_NAME}")
      printf '%s\n' "${WORKLOAD_CPU_WORKSPACE_NAME}"
      ;;
    "${WORKLOAD_GPU_COMPUTE_CONFIG_NAME}")
      printf '%s\n' "${WORKLOAD_GPU_WORKSPACE_NAME}"
      ;;
    *)
      die "No workload workspace is mapped to compute config ${compute_config_name}."
      ;;
  esac
}

workload_worker_node_prefix_for_compute_config() {
  local compute_config_name="$1"

  case "${compute_config_name}" in
    "${WORKLOAD_CPU_COMPUTE_CONFIG_NAME}")
      printf '%s\n' 'aks-cpu-'
      ;;
    "${WORKLOAD_GPU_COMPUTE_CONFIG_NAME}")
      printf '%s\n' 'aks-gput4-'
      ;;
    *)
      die "No worker-node prefix is mapped to compute config ${compute_config_name}."
      ;;
  esac
}

prepare_workload_submission_dir() {
  local workspace_name="$1"
  local worker_node_prefix="$2"
  local remote_dir="$3"
  local cli_bin proof_dir wait_log namespace head_pod

  ensure_deploy_e2e_bastion_access

  cli_bin="$(anyscale_cli_bin)"
  proof_dir="${ROOT_DIR}/workloads/proofs"
  wait_log="${SETUP_RUN_DIR}/${workspace_name}.wait.log"
  namespace="${TF_VAR_anyscale_operator_namespace}"

  ensure_workload_workspace_running "${workspace_name}" "${cli_bin}" "${wait_log}"
  wait_for_workspace_runtime_stable "${workspace_name}" "${worker_node_prefix}" "${wait_log}"

  head_pod="$(workspace_head_pod_name "${workspace_name}")"

  log "Copying workload proof scripts to ${workspace_name} head pod ${head_pod}"
  run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_WORKSPACE_COMMAND_SECONDS}" \
    kubectl exec -n "${namespace}" -c ray "${head_pod}" -- \
      bash -lc "mkdir -p '${remote_dir}'"
  run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_WORKSPACE_COMMAND_SECONDS}" \
    kubectl cp -n "${namespace}" -c ray \
      "${proof_dir}/." \
      "${head_pod}:${remote_dir}/"

  WORKLOAD_LAST_HEAD_POD="${head_pod}"
}

workload_workspace_id() {
  local cli_bin="$1"
  local workspace_name="$2"

  run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
    "${cli_bin}" workspace_v2 get \
      --name "${workspace_name}" \
      --cloud "${ANYSCALE_CLOUD_NAME}" \
      --json \
    | jq -r '.id // empty'
}

ensure_workload_workspace_running() {
  local workspace_name="$1"
  local cli_bin="$2"
  local wait_log="$3"
  local status_output workspace_status start_output

  if status_output="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
    "${cli_bin}" workspace_v2 status \
      --name "${workspace_name}" \
      --cloud "${ANYSCALE_CLOUD_NAME}" 2>&1)"; then
    workspace_status="$(normalize_anyscale_workspace_status "${status_output}")"
    [[ -n "${workspace_status}" ]] || workspace_status="UNKNOWN"
    printf '%s\n' "${status_output}" > "${wait_log}.status"

    case "${workspace_status}" in
      RUNNING)
        log "Workspace ${workspace_name} is already RUNNING; skipping start to avoid churn."
        printf '%s\n' "${workspace_status}" | tee "${wait_log}.start"
        printf '%s\n' "${workspace_status}" | tee -a "${wait_log}"
        return 0
        ;;
      STARTING)
        log "Workspace ${workspace_name} is already STARTING; waiting for it to become RUNNING."
        printf '%s\n' "${workspace_status}" | tee "${wait_log}.start"
        ;;
      CREATE_FAILED|FAILED|ERROR)
        die "Workspace ${workspace_name} is unhealthy with API status ${workspace_status}."
        ;;
      TERMINATED|TERMINATING|UNKNOWN)
        ;;
    esac
  else
    printf '%s\n' "${status_output}" > "${wait_log}.status"
  fi

  log "Starting or reusing workspace ${workspace_name}"
  if ! start_output="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
    "${cli_bin}" workspace_v2 start \
      --name "${workspace_name}" \
      --cloud "${ANYSCALE_CLOUD_NAME}" 2>&1)"; then
    printf '%s\n' "${start_output}" | tee "${wait_log}.start"
    if ! grep -Eiq 'already.*running|currently in state: STARTING|currently in state: RUNNING' <<<"${start_output}"; then
      die "Workspace ${workspace_name} could not be started. See ${wait_log}.start."
    fi
  else
    printf '%s\n' "${start_output}" | tee "${wait_log}.start"
  fi

  if ! wait_for_anyscale_workspace_running "${workspace_name}" "${cli_bin}" "${wait_log}"; then
    printf '%s\n' "${ANYSCALE_WORKSPACE_WAIT_RESULT}" | tee -a "${wait_log}"
    die "Workspace ${workspace_name} did not reach RUNNING. See ${wait_log}."
  fi
  printf '%s\n' "${ANYSCALE_WORKSPACE_WAIT_RESULT}" | tee -a "${wait_log}"
}

release_workload_workspace_if_running() {
  local workspace_name="$1"
  local cli_bin="$2"
  local wait_log="$3"
  local status_output workspace_status terminate_output

  if ! status_output="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
    "${cli_bin}" workspace_v2 status \
      --name "${workspace_name}" \
      --cloud "${ANYSCALE_CLOUD_NAME}" 2>&1)"; then
    if grep -Eiq 'not found|does not exist' <<<"${status_output}"; then
      log "Workspace ${workspace_name} does not exist; nothing to release."
      return 0
    fi
    printf '%s\n' "${status_output}" | tee "${wait_log}.release-status"
    die "Could not determine whether workspace ${workspace_name} is running. See ${wait_log}.release-status."
  fi

  workspace_status="$(normalize_anyscale_workspace_status "${status_output}")"
  [[ -n "${workspace_status}" ]] || workspace_status="UNKNOWN"
  printf '%s\n' "${status_output}" > "${wait_log}.release-status"

  case "${workspace_status}" in
    TERMINATED)
      log "Workspace ${workspace_name} is already TERMINATED; nothing to release."
      return 0
      ;;
    TERMINATING)
      log "Workspace ${workspace_name} is already TERMINATING; waiting for it to finish releasing GPU capacity."
      ;;
    RUNNING|STARTING|PENDING|UPDATING|RESTARTING|RESUMING|STOPPING|UNKNOWN)
      log "Terminating workspace ${workspace_name} to release compute for GPU proof jobs and services."
      if ! terminate_output="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
        "${cli_bin}" workspace_v2 terminate \
          --name "${workspace_name}" \
          --cloud "${ANYSCALE_CLOUD_NAME}" 2>&1)"; then
        printf '%s\n' "${terminate_output}" | tee "${wait_log}.release-terminate"
        if ! grep -Eiq 'already.*terminated|currently in state: TERMINATED|currently in state: TERMINATING' <<<"${terminate_output}"; then
          die "Workspace ${workspace_name} could not be terminated to release GPU capacity. See ${wait_log}.release-terminate."
        fi
      else
        printf '%s\n' "${terminate_output}" | tee "${wait_log}.release-terminate"
      fi
      ;;
    *)
      die "Workspace ${workspace_name} is in unsupported state ${workspace_status} for release handling."
      ;;
  esac

  if ! wait_for_anyscale_workspace_terminated_attempts "${workspace_name}" "${cli_bin}" "${wait_log}.release-wait" 30 20; then
    printf '%s\n' "${ANYSCALE_WORKSPACE_WAIT_RESULT}" | tee -a "${wait_log}.release-wait"
    die "Workspace ${workspace_name} did not reach TERMINATED while releasing GPU capacity. See ${wait_log}.release-wait."
  fi

  printf '%s\n' "${ANYSCALE_WORKSPACE_WAIT_RESULT}" | tee -a "${wait_log}.release-wait"
}

wait_for_workload_workspace_command_ready() {
  local workspace_name="$1"
  local cli_bin="$2"
  local wait_log="$3"
  local deadline current_epoch probe_output previous_message=""

  deadline=$(( $(date +%s) + SETUP_TIMEOUT_ANYSCALE_WORKSPACE_WAIT_SECONDS ))

  while true; do
    if probe_output="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
      "${cli_bin}" workspace_v2 run_command \
        --name "${workspace_name}" \
        --cloud "${ANYSCALE_CLOUD_NAME}" \
        "true" 2>&1)"; then
      printf '%s\n' "${probe_output}" >> "${wait_log}.command-ready"
      log "Workspace ${workspace_name} command channel is ready."
      return 0
    fi

    printf '%s\n' "${probe_output}" >> "${wait_log}.command-ready"
    if [[ "${probe_output}" != "${previous_message}" ]]; then
      warn "Workspace ${workspace_name} command channel is not ready yet; waiting before push/run_command."
      previous_message="${probe_output}"
    fi

    current_epoch=$(date +%s)
    if (( current_epoch >= deadline )); then
      die "Workspace ${workspace_name} command channel did not become ready. See ${wait_log}.command-ready."
    fi

    sleep 15
  done
}

workload_remote_command() {
  local script_name="$1"

  cat <<EOF
set -eu
proof_file=\$(find "\$HOME" -maxdepth 4 -type f -name "${script_name}" -print -quit)
if [ -z "\${proof_file}" ]; then
  echo "Proof script ${script_name} was not found under \$HOME"
  exit 1
fi
cd "\$(dirname "\${proof_file}")"
python "\$(basename "\${proof_file}")"
EOF
}

collect_workload_diagnostics() {
  local workspace_name="$1"
  local cli_bin="$2"
  local diagnostics_dir="$3"
  local workspace_id namespace

  mkdir -p "${diagnostics_dir}"
  namespace="${TF_VAR_anyscale_operator_namespace}"
  workspace_id="$(workload_workspace_id "${cli_bin}" "${workspace_name}" 2>/dev/null || true)"

  if [[ -n "${workspace_id}" ]]; then
    run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
      "${cli_bin}" logs workspace \
        --id "${workspace_id}" \
        --tail 200 \
      > "${diagnostics_dir}/anyscale-workspace.tail.log" 2>&1 || true

    run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
      "${cli_bin}" logs workspace \
        --id "${workspace_id}" \
        --download \
        --download-dir "${diagnostics_dir}/anyscale-workspace-logs" \
      > "${diagnostics_dir}/anyscale-workspace-download.log" 2>&1 || true
  fi

  kubectl get pods -n "${namespace}" \
    -l "app.kubernetes.io/name=${workspace_name}" \
    -o wide > "${diagnostics_dir}/pods.txt" 2>&1 || true
  kubectl describe pods -n "${namespace}" \
    -l "app.kubernetes.io/name=${workspace_name}" \
    > "${diagnostics_dir}/pods.describe.txt" 2>&1 || true
  kubectl logs -n "${namespace}" \
    -l "app.kubernetes.io/name=anyscale-operator" \
    --tail=200 > "${diagnostics_dir}/anyscale-operator.log" 2>&1 || true
  kubectl logs -n "${namespace}" \
    -l "app.kubernetes.io/name=${workspace_name}" \
    --all-containers=true \
    --tail=200 > "${diagnostics_dir}/workspace-containers.log" 2>&1 || true
  kubectl get events -n "${namespace}" \
    --sort-by=.lastTimestamp > "${diagnostics_dir}/events.txt" 2>&1 || true
}

run_workspace_proof() {
  local workspace_name="$1"
  local script_name="$2"
  local success_marker="$3"
  local worker_node_prefix="$4"
  local cli_bin proof_dir output_log diagnostics_dir wait_log namespace head_pod remote_dir proof_exit

  workload_require_workspace_proof_inputs
  ensure_deploy_e2e_bastion_access

  cli_bin="$(anyscale_cli_bin)"
  proof_dir="${ROOT_DIR}/workloads/proofs"
  output_log="${SETUP_RUN_DIR}/${workspace_name}.${script_name}.out.log"
  diagnostics_dir="${SETUP_RUN_DIR}/diagnostics/${workspace_name}"
  wait_log="${SETUP_RUN_DIR}/${workspace_name}.wait.log"
  namespace="${TF_VAR_anyscale_operator_namespace}"

  ensure_workload_workspace_running "${workspace_name}" "${cli_bin}" "${wait_log}"
  wait_for_workspace_runtime_stable "${workspace_name}" "${worker_node_prefix}" "${wait_log}"

  head_pod="$(workspace_head_pod_name "${workspace_name}")"
  remote_dir="/tmp/anyscale-proof-${script_name%.py}"

  log "Copying workload proof scripts to ${workspace_name} head pod ${head_pod}"
  run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_WORKSPACE_COMMAND_SECONDS}" \
    kubectl exec -n "${namespace}" -c ray "${head_pod}" -- \
      bash -lc "mkdir -p '${remote_dir}'"
  run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_WORKSPACE_COMMAND_SECONDS}" \
    kubectl cp -n "${namespace}" -c ray \
      "${proof_dir}/." \
      "${head_pod}:${remote_dir}/"

  log "Running ${script_name} inside ${workspace_name} via Bastion-backed Kubernetes exec"
  proof_exit=0
  set +e
  run_with_timeout "${WORKLOAD_COMMAND_TIMEOUT_SECONDS}" \
    kubectl exec -n "${namespace}" -c ray "${head_pod}" -- \
      bash -lc "cd '${remote_dir}' && python '${script_name}'" 2>&1 | tee "${output_log}"
  proof_exit=${PIPESTATUS[0]}
  set -e

  collect_workload_diagnostics "${workspace_name}" "${cli_bin}" "${diagnostics_dir}"

  [[ "${proof_exit}" -eq 0 ]] || die "${script_name} failed on ${workspace_name}. See ${output_log} and ${diagnostics_dir}."
  grep -q "${success_marker}" "${output_log}" || die "${script_name} did not print ${success_marker}. See ${output_log}."
  log "${workspace_name} printed ${success_marker}. Diagnostics: ${diagnostics_dir}"
}

extract_prefixed_value_from_log() {
  local prefix="$1"
  local log_file="$2"

  awk -v prefix="${prefix}" '
    index($0, prefix) == 1 { value = substr($0, length(prefix) + 1) }
    END {
      if (value != "") {
        print value
        exit 0
      }
      exit 1
    }
  ' "${log_file}"
}

run_anyscale_job_proof() {
  local job_name="$1"
  local compute_config_name="$2"
  local script_name="$3"
  local success_marker="$4"
  shift 4

  local cli_bin jobs_dir output_log status_log workspace_name worker_node_prefix
  local remote_dir namespace head_pod env_file remote_env_path remote_command job_command job_exit
  local -a job_cmd auth_env_specs

  workload_require_pipeline_inputs

  cli_bin="$(anyscale_cli_bin)"
  jobs_dir="${SETUP_RUN_DIR}/jobs"
  output_log="${jobs_dir}/${job_name}.out.log"
  status_log="${jobs_dir}/${job_name}.status.json"
  workspace_name="${WORKLOAD_CPU_WORKSPACE_NAME}"
  worker_node_prefix='aks-cpu-'
  remote_dir="/tmp/anyscale-proof-${job_name}"
  namespace="${TF_VAR_anyscale_operator_namespace}"

  mkdir -p "${jobs_dir}"

  prepare_workload_submission_dir "${workspace_name}" "${worker_node_prefix}" "${remote_dir}"
  head_pod="${WORKLOAD_LAST_HEAD_POD}"

  auth_env_specs=(
    "ANYSCALE_HOST=${ANYSCALE_HOST}"
    "ANYSCALE_CLI_TOKEN=${ANYSCALE_CLI_TOKEN}"
    "ANYSCALE_CLOUD_NAME=${ANYSCALE_CLOUD_NAME}"
  )
  env_file="${jobs_dir}/${job_name}.remote.env.sh"
  remote_env_path="${remote_dir}/.anyscale-proof.env"
  write_export_env_script "${env_file}" "${auth_env_specs[@]}"
  run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_WORKSPACE_COMMAND_SECONDS}" \
    kubectl cp -n "${namespace}" -c ray \
      "${env_file}" \
      "${head_pod}:${remote_env_path}"

  job_cmd=(
    anyscale job submit
      --name "${job_name}"
      --wait
      --compute-config "${compute_config_name}"
      --working-dir "${remote_dir}"
      --cloud "${ANYSCALE_CLOUD_NAME}"
  )

  while [[ $# -gt 0 ]]; do
    job_cmd+=(--env "$1")
    shift
  done

  job_cmd+=(-- python "${script_name}")
  job_command="$(shell_join "${job_cmd[@]}")"
  remote_command="$(cat <<EOF
set -euo pipefail
source $(shell_join "${remote_env_path}")
cd $(shell_join "${remote_dir}")
${job_command}
EOF
)"

  log "Submitting Anyscale job proof ${job_name} on compute config ${compute_config_name} from ${workspace_name} head pod ${head_pod}"
  job_exit=0
  set +e
  run_with_timeout "${WORKLOAD_COMMAND_TIMEOUT_SECONDS}" \
    kubectl exec -n "${namespace}" -c ray "${head_pod}" -- \
      bash -lc "${remote_command}" 2>&1 | tee "${output_log}"
  job_exit=${PIPESTATUS[0]}
  set -e

  run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
    "${cli_bin}" job status \
      --name "${job_name}" \
      --cloud "${ANYSCALE_CLOUD_NAME}" \
      --json \
      --verbose \
      --include-archived \
    > "${status_log}" 2>&1 || true

  WORKLOAD_LAST_JOB_OUTPUT_LOG="${output_log}"
  WORKLOAD_LAST_JOB_STATUS_LOG="${status_log}"

  [[ "${job_exit}" -eq 0 ]] || die "Job proof ${job_name} failed. See ${output_log} and ${status_log}."
  grep -q "${success_marker}" "${output_log}" || die "Job proof ${job_name} did not print ${success_marker}. See ${output_log}."
  log "Job ${job_name} printed ${success_marker}. Status: ${status_log}"
}

extract_anyscale_service_url() {
  local status_file="$1"
  local service_url

  service_url="$(jq -r '.. | strings | select(test("^https?://"))' "${status_file}" | grep -E 'serve-session-|session-' | head -n1 || true)"
  if [[ -z "${service_url}" ]]; then
    service_url="$(jq -r '.. | strings | select(test("^https?://"))' "${status_file}" | head -n1 || true)"
  fi

  [[ -n "${service_url}" ]] || return 1
  printf '%s\n' "${service_url}"
}

wait_for_anyscale_service_ready() {
  local cli_bin="$1"
  local service_name="$2"
  local cloud_name="$3"
  local timeout_seconds="$4"
  local wait_log="$5"
  local status_log="$6"
  local start_epoch current_epoch service_state primary_version_state tmp_status_log

  start_epoch="$(date +%s)"
  : > "${wait_log}"

  while true; do
    tmp_status_log="${status_log}.tmp"
    if run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
      "${cli_bin}" service status \
        --name "${service_name}" \
        --cloud "${cloud_name}" \
        --json \
        --verbose \
      > "${tmp_status_log}" 2>&1; then
      mv "${tmp_status_log}" "${status_log}"
      service_state="$(jq -r '.state // ""' "${status_log}")"
      primary_version_state="$(jq -r '.primary_version.state // ""' "${status_log}")"
      printf 'service_state=%s primary_version_state=%s\n' "${service_state}" "${primary_version_state}" | tee -a "${wait_log}"
      if [[ "${service_state}" == "RUNNING" || "${primary_version_state}" == "RUNNING" ]]; then
        return 0
      fi
    else
      if [[ -f "${tmp_status_log}" ]]; then
        cat "${tmp_status_log}" >> "${wait_log}"
        mv "${tmp_status_log}" "${status_log}"
      fi
    fi

    current_epoch="$(date +%s)"
    if (( current_epoch - start_epoch >= timeout_seconds )); then
      die "Service ${service_name} did not reach a ready state within ${timeout_seconds}s. See ${wait_log} and ${status_log}."
    fi

    sleep 10
  done
}

wait_for_anyscale_service_terminated() {
  local cli_bin="$1"
  local service_name="$2"
  local cloud_name="$3"
  local timeout_seconds="$4"
  local wait_log="$5"
  local status_log="$6"
  local start_epoch current_epoch service_state tmp_status_log

  start_epoch="$(date +%s)"
  : > "${wait_log}"

  while true; do
    tmp_status_log="${status_log}.tmp"
    if run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
      "${cli_bin}" service status \
        --name "${service_name}" \
        --cloud "${cloud_name}" \
        --json \
        --verbose \
      > "${tmp_status_log}" 2>&1; then
      mv "${tmp_status_log}" "${status_log}"
      service_state="$(jq -r '.state // ""' "${status_log}")"
      printf 'service_state=%s\n' "${service_state}" | tee -a "${wait_log}"
      case "${service_state}" in
        TERMINATED|SYSTEM_FAILURE)
          return 0
          ;;
      esac
    else
      if [[ -f "${tmp_status_log}" ]]; then
        cat "${tmp_status_log}" >> "${wait_log}"
        mv "${tmp_status_log}" "${status_log}"
      fi
      if grep -Eiq 'not found|does not exist|404' "${status_log}" 2>/dev/null; then
        return 0
      fi
    fi

    current_epoch="$(date +%s)"
    if (( current_epoch - start_epoch >= timeout_seconds )); then
      die "Service ${service_name} did not terminate within ${timeout_seconds}s. See ${wait_log} and ${status_log}."
    fi

    sleep 10
  done
}

terminate_anyscale_service_if_present() {
  local cli_bin="$1"
  local service_name="$2"
  local cloud_name="$3"
  local status_log="$4"
  local terminate_log="$5"
  local service_id service_state output

  : > "${terminate_log}"

  if ! run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
    "${cli_bin}" service status \
      --name "${service_name}" \
      --cloud "${cloud_name}" \
      --json \
      --verbose \
    > "${status_log}" 2>&1; then
    return 0
  fi

  service_id="$(jq -r '.id // ""' "${status_log}")"
  service_state="$(jq -r '.state // ""' "${status_log}")"
  [[ -n "${service_id}" ]] || return 0

  case "${service_state}" in
    TERMINATED|SYSTEM_FAILURE)
      log "Found existing service ${service_name} in state ${service_state}; reusing the name for a fresh proof deploy."
      return 0
      ;;
  esac

  log "Terminating existing service ${service_name} (${service_id}) in state ${service_state} before proof deploy"
  if output="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
    "${cli_bin}" service terminate --service-id "${service_id}" 2>&1)"; then
    printf '%s\n' "${output}" >> "${terminate_log}"
  else
    printf '%s\n' "${output}" >> "${terminate_log}"
    if ! grep -Eiq 'already.*terminated|currently in state: TERMINATED|currently in state: TERMINATING' <<<"${output}"; then
      die "Failed to terminate existing service ${service_name}. See ${terminate_log}."
    fi
  fi

  wait_for_anyscale_service_terminated \
    "${cli_bin}" \
    "${service_name}" \
    "${cloud_name}" \
    "${WORKLOAD_COMMAND_TIMEOUT_SECONDS}" \
    "${terminate_log}" \
    "${status_log}"
}

service_url_host() {
  local service_url="$1"
  local host

  host="${service_url#https://}"
  host="${host#http://}"
  printf '%s\n' "${host%%/*}"
}

service_url_path() {
  local service_url="$1"
  local path

  path="${service_url#https://}"
  path="${path#http://}"
  if [[ "${path}" == */* ]]; then
    printf '/%s\n' "${path#*/}"
  else
    printf '/\n'
  fi
}

curl_anyscale_service_via_head_pod() {
  local method="$1"
  local service_name="$2"
  local service_url="$3"
  local request_body="$4"
  local response_file="$5"
  local stderr_file="$6"
  local tunnel_log="$7"
  local namespace service_path pod_list pod curl_exit request_body_b64

  namespace="${TF_VAR_anyscale_operator_namespace:-anyscale-operator}"
  service_path="$(service_url_path "${service_url}")"
  [[ -n "${service_path}" ]] || service_path='/'

  : > "${tunnel_log}"
  pod_list="$(kubectl get pods \
    -n "${namespace}" \
    -l "app.kubernetes.io/name=${service_name},ray-node-type=head" \
    --field-selector=status.phase=Running \
    --sort-by=.metadata.creationTimestamp \
    -o name 2>> "${tunnel_log}" | sed 's#pod/##')"
  [[ -n "${pod_list}" ]] || return 1

  request_body_b64="$(printf '%s' "${request_body}" | base64 | tr -d '\n')"

  while IFS= read -r pod; do
    [[ -n "${pod}" ]] || continue
    printf 'Trying service head pod %s\n' "${pod}" >> "${tunnel_log}"

    curl_exit=0
    set +e
    if [[ "${method}" == "GET" ]]; then
      kubectl exec -n "${namespace}" -c ray "${pod}" -- \
        curl -sfS "http://127.0.0.1:8000${service_path}" \
        > "${response_file}" 2>> "${stderr_file}"
      curl_exit=$?
    else
      kubectl exec -n "${namespace}" -c ray "${pod}" -- sh -lc \
        "printf %s \"${request_body_b64}\" | base64 -d >/tmp/anyscale-service-proof-request.json && curl -sfS -H \"Content-Type: application/json\" --data-binary @/tmp/anyscale-service-proof-request.json \"http://127.0.0.1:8000${service_path}\"" \
        > "${response_file}" 2>> "${stderr_file}"
      curl_exit=$?
    fi
    set -e

    if [[ "${curl_exit}" -eq 0 ]]; then
      printf 'Service head pod request succeeded via %s\n' "${pod}" >> "${tunnel_log}"
      return 0
    fi

    printf 'Service head pod request via %s failed with exit code %s\n' "${pod}" "${curl_exit}" >> "${tunnel_log}"
  done <<< "${pod_list}"

  return 1
}

curl_anyscale_service_endpoint() {
  local method="$1"
  local service_name="$2"
  local service_url="$3"
  local request_body="$4"
  local response_file="$5"
  local stderr_file="$6"
  local tunnel_log="$7"
  local query_auth_token="$8"
  local curl_exit
  local -a auth_header=()

  if [[ -n "${query_auth_token}" ]]; then
    auth_header=(-H "Authorization: Bearer ${query_auth_token}")
  fi

  curl_exit=0
  set +e
  if [[ "${method}" == "GET" ]]; then
    curl -fSs "${auth_header[@]}" "${service_url}" -o "${response_file}" 2> "${stderr_file}"
    curl_exit=$?
  else
    curl -fSs \
      -X "${method}" \
      "${auth_header[@]}" \
      -H 'Content-Type: application/json' \
      --data "${request_body}" \
      "${service_url}" \
      -o "${response_file}" 2> "${stderr_file}"
    curl_exit=$?
  fi
  set -e

  if [[ "${curl_exit}" -eq 0 ]]; then
    return 0
  fi

  warn "Direct request to ${service_url} failed; retrying from a service head pod inside the AKS cluster."
  curl_anyscale_service_via_head_pod "${method}" "${service_name}" "${service_url}" "${request_body}" "${response_file}" "${stderr_file}" "${tunnel_log}"
}

run_anyscale_service_proof() {
  local service_name="$1"
  local compute_config_name="$2"
  local import_path="$3"
  local success_marker="$4"
  local model_json="$5"
  local cli_bin services_dir cleanup_log deploy_log wait_log status_log service_url_file
  local health_log positive_log negative_log stderr_log tunnel_log service_url
  local service_auth_token
  local positive_payload negative_payload positive_expected negative_expected deploy_exit
  local workspace_name worker_node_prefix remote_dir namespace head_pod env_file remote_env_path
  local deploy_command remote_command
  local -a auth_env_specs

  workload_require_pipeline_inputs

  cli_bin="$(anyscale_cli_bin)"
  services_dir="${SETUP_RUN_DIR}/services"
  cleanup_log="${services_dir}/${service_name}.cleanup.log"
  deploy_log="${services_dir}/${service_name}.deploy.log"
  wait_log="${services_dir}/${service_name}.wait.log"
  status_log="${services_dir}/${service_name}.status.json"
  service_url_file="${services_dir}/${service_name}.url.txt"
  health_log="${services_dir}/${service_name}.health.json"
  positive_log="${services_dir}/${service_name}.predict-positive.json"
  negative_log="${services_dir}/${service_name}.predict-negative.json"
  stderr_log="${services_dir}/${service_name}.curl.stderr.log"
  tunnel_log="${services_dir}/${service_name}.tunnel.log"

  mkdir -p "${services_dir}"

  terminate_anyscale_service_if_present \
    "${cli_bin}" \
    "${service_name}" \
    "${ANYSCALE_CLOUD_NAME}" \
    "${status_log}" \
    "${cleanup_log}"

  positive_payload="$(printf '%s' "${model_json}" | jq -c '.probes.positive | {x1, x2}')"
  negative_payload="$(printf '%s' "${model_json}" | jq -c '.probes.negative | {x1, x2}')"
  positive_expected="$(printf '%s' "${model_json}" | jq -r '.probes.positive.expected_label')"
  negative_expected="$(printf '%s' "${model_json}" | jq -r '.probes.negative.expected_label')"

  workspace_name="${WORKLOAD_CPU_WORKSPACE_NAME}"
  worker_node_prefix='aks-cpu-'
  remote_dir="/tmp/anyscale-proof-${service_name}"
  namespace="${TF_VAR_anyscale_operator_namespace}"

  prepare_workload_submission_dir "${workspace_name}" "${worker_node_prefix}" "${remote_dir}"
  head_pod="${WORKLOAD_LAST_HEAD_POD}"

  auth_env_specs=(
    "ANYSCALE_HOST=${ANYSCALE_HOST}"
    "ANYSCALE_CLI_TOKEN=${ANYSCALE_CLI_TOKEN}"
    "ANYSCALE_CLOUD_NAME=${ANYSCALE_CLOUD_NAME}"
  )
  env_file="${services_dir}/${service_name}.remote.env.sh"
  remote_env_path="${remote_dir}/.anyscale-proof.env"
  write_export_env_script "${env_file}" "${auth_env_specs[@]}"
  run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_WORKSPACE_COMMAND_SECONDS}" \
    kubectl cp -n "${namespace}" -c ray \
      "${env_file}" \
      "${head_pod}:${remote_env_path}"

  deploy_command="$(shell_join \
    anyscale service deploy \
      --name "${service_name}" \
      --compute-config "${compute_config_name}" \
      --working-dir "${remote_dir}" \
      --cloud "${ANYSCALE_CLOUD_NAME}" \
      --env 'ANYSCALE_PROOF_USE_GPU=1' \
      --env "GPU_TRAIN_MODEL_JSON=${model_json}" \
      "${import_path}")"
  remote_command="$(cat <<EOF
set -euo pipefail
source $(shell_join "${remote_env_path}")
cd $(shell_join "${remote_dir}")
${deploy_command}
EOF
)"

  log "Deploying Anyscale service proof ${service_name} on compute config ${compute_config_name} from ${workspace_name} head pod ${head_pod}"
  deploy_exit=0
  set +e
  run_with_timeout "${WORKLOAD_COMMAND_TIMEOUT_SECONDS}" \
    kubectl exec -n "${namespace}" -c ray "${head_pod}" -- \
      bash -lc "${remote_command}" 2>&1 | tee "${deploy_log}"
  deploy_exit=${PIPESTATUS[0]}
  set -e
  [[ "${deploy_exit}" -eq 0 ]] || die "Service proof ${service_name} deploy failed. See ${deploy_log}."

  wait_for_anyscale_service_ready \
    "${cli_bin}" \
    "${service_name}" \
    "${ANYSCALE_CLOUD_NAME}" \
    "${WORKLOAD_COMMAND_TIMEOUT_SECONDS}" \
    "${wait_log}" \
    "${status_log}"

  service_url="$(extract_anyscale_service_url "${status_log}")" || die "Could not find a service URL in ${status_log}."
  service_auth_token="$(jq -r '.query_auth_token // ""' "${status_log}")"
  printf '%s\n' "${service_url}" > "${service_url_file}"

  curl_anyscale_service_endpoint GET "${service_name}" "${service_url}" '' "${health_log}" "${stderr_log}" "${tunnel_log}" "${service_auth_token}"
  jq -e --arg marker "${success_marker}" '.marker == $marker and (.metrics.accuracy // 0) >= 0.99' "${health_log}" >/dev/null \
    || die "Service proof ${service_name} health response was unexpected. See ${health_log}."

  curl_anyscale_service_endpoint POST "${service_name}" "${service_url}" "${positive_payload}" "${positive_log}" "${stderr_log}" "${tunnel_log}" "${service_auth_token}"
  jq -e --arg marker "${success_marker}" --argjson expected "${positive_expected}" '.marker == $marker and .label == $expected' "${positive_log}" >/dev/null \
    || die "Service proof ${service_name} positive prediction was unexpected. See ${positive_log}."

  curl_anyscale_service_endpoint POST "${service_name}" "${service_url}" "${negative_payload}" "${negative_log}" "${stderr_log}" "${tunnel_log}" "${service_auth_token}"
  jq -e --arg marker "${success_marker}" --argjson expected "${negative_expected}" '.marker == $marker and .label == $expected' "${negative_log}" >/dev/null \
    || die "Service proof ${service_name} negative prediction was unexpected. See ${negative_log}."

  WORKLOAD_LAST_SERVICE_STATUS_LOG="${status_log}"
  log "Service ${service_name} printed ${success_marker}. URL: ${service_url}. Diagnostics: ${services_dir}"
}

workload_cpu_stage() {
  run_workspace_proof "${WORKLOAD_CPU_WORKSPACE_NAME}" "cpu_ray_proof.py" "CPU_RAY_PROOF_OK" "aks-cpu-"
}

workload_gpu_stage() {
  run_workspace_proof "${WORKLOAD_GPU_WORKSPACE_NAME}" "gpu_ray_proof.py" "GPU_RAY_PROOF_OK" "aks-gput4-"
}

workload_build_manifest_file() {
  printf '%s\n' "${SETUP_RUN_DIR}/jobs/${WORKLOAD_BUILD_JOB_NAME}.manifest.json"
}

workload_train_model_file() {
  printf '%s\n' "${SETUP_RUN_DIR}/jobs/${WORKLOAD_TRAIN_JOB_NAME}.model.json"
}

workload_name_with_run_suffix() {
  local base_name="$1"
  local run_suffix

  run_suffix="$(basename "${SETUP_RUN_DIR}")"
  run_suffix="${run_suffix%%-*}"
  run_suffix="${run_suffix//[!0-9]/}"

  printf '%s-%s\n' "${base_name}" "${run_suffix}"
}

workload_build_stage() {
  local manifest_file

  run_anyscale_job_proof \
    "${WORKLOAD_BUILD_JOB_NAME}" \
    "${WORKLOAD_CPU_COMPUTE_CONFIG_NAME}" \
    "anyscale_build_cpu_job_proof.py" \
    "CPU_BUILD_JOB_PROOF_OK"

  manifest_file="$(workload_build_manifest_file)"
  WORKLOAD_BUILD_MANIFEST_JSON="$(extract_prefixed_value_from_log 'CPU_BUILD_MANIFEST_JSON=' "${WORKLOAD_LAST_JOB_OUTPUT_LOG}")" \
    || die "Build job proof did not emit CPU_BUILD_MANIFEST_JSON=. See ${WORKLOAD_LAST_JOB_OUTPUT_LOG}."
  printf '%s\n' "${WORKLOAD_BUILD_MANIFEST_JSON}" > "${manifest_file}"
}

workload_train_stage() {
  local manifest_file model_file

  workload_require_pipeline_inputs

  manifest_file="$(workload_build_manifest_file)"
  if [[ -z "${WORKLOAD_BUILD_MANIFEST_JSON:-}" && -f "${manifest_file}" ]]; then
    WORKLOAD_BUILD_MANIFEST_JSON="$(tr -d '\n' < "${manifest_file}")"
  fi
  [[ -n "${WORKLOAD_BUILD_MANIFEST_JSON:-}" ]] || die "Build manifest is missing; run the build proof stage before the train proof stage."

  log "Keeping workspace ${WORKLOAD_GPU_WORKSPACE_NAME} running; GPU job and service proofs will rely on AKS autoscaling for additional capacity."

  run_anyscale_job_proof \
    "${WORKLOAD_TRAIN_JOB_NAME}" \
    "${WORKLOAD_GPU_COMPUTE_CONFIG_NAME}" \
    "anyscale_train_gpu_job_proof.py" \
    "GPU_TRAIN_JOB_PROOF_OK" \
    'ANYSCALE_PROOF_USE_GPU=1' \
    'RAY_TRAIN_V2_ENABLED=0' \
    "CPU_BUILD_MANIFEST_JSON=${WORKLOAD_BUILD_MANIFEST_JSON}"

  model_file="$(workload_train_model_file)"
  WORKLOAD_TRAIN_MODEL_JSON="$(extract_prefixed_value_from_log 'GPU_TRAIN_MODEL_JSON=' "${WORKLOAD_LAST_JOB_OUTPUT_LOG}")" \
    || die "Train job proof did not emit GPU_TRAIN_MODEL_JSON=. See ${WORKLOAD_LAST_JOB_OUTPUT_LOG}."
  printf '%s\n' "${WORKLOAD_TRAIN_MODEL_JSON}" > "${model_file}"
}

workload_service_stage() {
  local model_file

  model_file="$(workload_train_model_file)"
  if [[ -z "${WORKLOAD_TRAIN_MODEL_JSON:-}" && -f "${model_file}" ]]; then
    WORKLOAD_TRAIN_MODEL_JSON="$(tr -d '\n' < "${model_file}")"
  fi
  [[ -n "${WORKLOAD_TRAIN_MODEL_JSON:-}" ]] || die "Train model payload is missing; run the train proof stage before the service proof stage."

  run_anyscale_service_proof \
    "${WORKLOAD_SERVICE_NAME}" \
    "${WORKLOAD_GPU_COMPUTE_CONFIG_NAME}" \
    'anyscale_serve_gpu_proof:app' \
    "GPU_SERVE_SERVICE_PROOF_OK" \
    "${WORKLOAD_TRAIN_MODEL_JSON}"
}

workload() {
  local subcommand="${1:-}"
  local target="${2:-}"
  WORKLOAD_CPU_WORKSPACE_NAME="aks-cpu-workspace"
  WORKLOAD_GPU_WORKSPACE_NAME="aks-gpu-workspace"
  WORKLOAD_CPU_COMPUTE_CONFIG_NAME="aks-cpu"
  WORKLOAD_GPU_COMPUTE_CONFIG_NAME="aks-gpu"
  WORKLOAD_BUILD_JOB_BASENAME="aks-cpu-build-proof"
  WORKLOAD_TRAIN_JOB_BASENAME="aks-gpu-train-proof"
  WORKLOAD_SERVICE_BASENAME="aks-gpu-serve-proof"
  WORKLOAD_BUILD_JOB_NAME="${WORKLOAD_BUILD_JOB_BASENAME}"
  WORKLOAD_TRAIN_JOB_NAME="${WORKLOAD_TRAIN_JOB_BASENAME}"
  WORKLOAD_SERVICE_NAME="${WORKLOAD_SERVICE_BASENAME}"
  WORKLOAD_COMMAND_TIMEOUT_SECONDS="${ANYSCALE_WORKSPACE_PROOF_COMMAND_TIMEOUT_SECONDS:-900}"
  WORKLOAD_BUILD_MANIFEST_JSON=""
  WORKLOAD_TRAIN_MODEL_JSON=""

  if [[ "${subcommand}" == "--help" || "${subcommand}" == "-h" || -z "${subcommand}" ]]; then
    cat <<'USAGE'
Usage:
  ./scripts/setup.sh workload proof cpu
  ./scripts/setup.sh workload proof gpu
  ./scripts/setup.sh workload proof pipeline
  ./scripts/setup.sh workload proof all

Runs deterministic Ray workload proofs in the durable Anyscale workspaces plus
a lightweight build/train/serve pipeline that uses the Anyscale job and service
APIs across the CPU and GPU compute pools.
USAGE
    return 0
  fi

  [[ "${subcommand}" == "proof" ]] || die "Usage: ./scripts/setup.sh workload proof {cpu|gpu|pipeline|all}"
  [[ -n "${target}" ]] || die "Usage: ./scripts/setup.sh workload proof {cpu|gpu|pipeline|all}"
  shift 2

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cpu-workspace-name)
        [[ $# -ge 2 ]] || die "Missing value for --cpu-workspace-name"
        WORKLOAD_CPU_WORKSPACE_NAME="$2"
        shift 2
        ;;
      --gpu-workspace-name)
        [[ $# -ge 2 ]] || die "Missing value for --gpu-workspace-name"
        WORKLOAD_GPU_WORKSPACE_NAME="$2"
        shift 2
        ;;
      --command-timeout-seconds)
        [[ $# -ge 2 ]] || die "Missing value for --command-timeout-seconds"
        require_positive_integer_arg "--command-timeout-seconds" "$2"
        WORKLOAD_COMMAND_TIMEOUT_SECONDS="$2"
        shift 2
        ;;
      --help|-h)
        cat <<'USAGE'
Usage:
  ./scripts/setup.sh workload proof {cpu|gpu|pipeline|all} [--command-timeout-seconds N]

Options:
  --cpu-workspace-name NAME     Default: aks-cpu-workspace
  --gpu-workspace-name NAME     Default: aks-gpu-workspace
  --command-timeout-seconds N   Default: 900
USAGE
        return 0
        ;;
      *)
        die "Unknown workload proof option: $1"
        ;;
    esac
  done

  case "${target}" in
    cpu)
      setup_run_init "workload-cpu" 2
      run_stage "prepare" workload_prepare_stage
      run_stage "cpu-proof" workload_cpu_stage
      ;;
    gpu)
      setup_run_init "workload-gpu" 2
      run_stage "prepare" workload_prepare_stage
      run_stage "gpu-proof" workload_gpu_stage
      ;;
    pipeline)
      setup_run_init "workload-pipeline" 4
      WORKLOAD_BUILD_JOB_NAME="$(workload_name_with_run_suffix "${WORKLOAD_BUILD_JOB_BASENAME}")"
      WORKLOAD_TRAIN_JOB_NAME="$(workload_name_with_run_suffix "${WORKLOAD_TRAIN_JOB_BASENAME}")"
      WORKLOAD_SERVICE_NAME="$(workload_name_with_run_suffix "${WORKLOAD_SERVICE_BASENAME}")"
      run_stage "prepare" workload_prepare_stage
      run_stage "build-job-proof" workload_build_stage
      run_stage "train-job-proof" workload_train_stage
      run_stage "serve-service-proof" workload_service_stage
      ;;
    all)
      setup_run_init "workload-all" 6
      WORKLOAD_BUILD_JOB_NAME="$(workload_name_with_run_suffix "${WORKLOAD_BUILD_JOB_BASENAME}")"
      WORKLOAD_TRAIN_JOB_NAME="$(workload_name_with_run_suffix "${WORKLOAD_TRAIN_JOB_BASENAME}")"
      WORKLOAD_SERVICE_NAME="$(workload_name_with_run_suffix "${WORKLOAD_SERVICE_BASENAME}")"
      run_stage "prepare" workload_prepare_stage
      run_stage "cpu-proof" workload_cpu_stage
      run_stage "gpu-proof" workload_gpu_stage
      run_stage "build-job-proof" workload_build_stage
      run_stage "train-job-proof" workload_train_stage
      run_stage "serve-service-proof" workload_service_stage
      ;;
    *)
      die "Unknown workload proof target: ${target}"
      ;;
  esac

  setup_run_summary
}

###############################################################################
post() {
  log "Use ./scripts/setup.sh deploy to reconcile Terraform, Bastion-backed bootstrap, Anyscale platform registration, and durable CPU/GPU workspaces."
  log "Use ./scripts/setup.sh verify --full for static and live validation."
  log "Use ./scripts/setup.sh workload proof all for deterministic CPU/GPU workspace proofs plus the Anyscale CPU-build/GPU-train/GPU-serve pipeline."
  log "Use ./scripts/setup.sh teardown for Terraform-backed teardown, or ./scripts/setup.sh teardown --force --yes for explicit resource-group deletion."
}

functional_test() {
  validate_k8s
}

###############################################################################
destroy() {
  local cluster_bootstrap_json destroy_postcheck_error="" remaining_state remaining_state_file resource_group terraform_exit_code

  render_tfvars
  resource_group="$(resource_group_name)"
  warn "Destroying ALL resources in the workspace."
  read -r -p "Type the project name to confirm destroy: " confirm
  [[ "${confirm}" == "${TF_VAR_project}" ]] || die "Cancelled."

  force_teardown_drain_anyscale_cloud
  ensure_deploy_e2e_bastion_access

  cluster_bootstrap_json="${TF_VAR_cluster_bootstrap:-{}}"
  if ! jq -e . >/dev/null 2>&1 <<<"${cluster_bootstrap_json}"; then
    cluster_bootstrap_json="{}"
  fi
  export TF_VAR_cluster_bootstrap
  TF_VAR_cluster_bootstrap="$(jq -cn \
    --argjson cluster_bootstrap "${cluster_bootstrap_json}" \
    --arg kubeconfig_path "${KUBECONFIG}" \
    '$cluster_bootstrap + {kubeconfig_path: $kubeconfig_path}')"

  terraform_exit_code=0
  set +e
  run_with_timeout "${SETUP_TIMEOUT_TERRAFORM_DESTROY_SECONDS}" \
    terraform destroy -auto-approve -var="cluster_bootstrap=${TF_VAR_cluster_bootstrap}"
  terraform_exit_code=$?
  set -e

  if (( terraform_exit_code != 0 )); then
    destroy_postcheck_error="Terraform destroy failed with exit code ${terraform_exit_code}."
  fi

  remaining_state_file="${SETUP_RUN_DIR}/terraform-state-after-destroy.txt"
  if remaining_state="$(terraform state list 2>/dev/null)" && [[ -n "${remaining_state}" ]]; then
    printf '%s\n' "${remaining_state}" > "${remaining_state_file}"
    if [[ -n "${destroy_postcheck_error}" ]]; then
      destroy_postcheck_error="${destroy_postcheck_error} Terraform state still contains resources. See ${remaining_state_file}."
    else
      destroy_postcheck_error="Terraform destroy returned, but state still contains resources. See ${remaining_state_file}."
    fi
  elif (( terraform_exit_code == 0 )); then
    log "Waiting for ${resource_group} deletion to complete"
    wait_for_resource_group_deletion "${resource_group}"
  fi

  bastion_tunnel stop >/dev/null 2>&1 || true
  clear_anyscale_cloud_deployment_id

  [[ -z "${destroy_postcheck_error}" ]] || die "${destroy_postcheck_error}"
}

force_teardown_drain_anyscale_cloud() {
  load_env
  sync_anyscale_cli_env

  anyscale_platform_enabled || {
    log "Anyscale platform is disabled; skipping cloud drain before force teardown."
    return 0
  }

  require_cmd az
  require_cmd jq

  local cloud_arm_id subscription_id
  cloud_arm_id="${ANYSCALE_CLOUD_ARM_ID:-$(default_anyscale_cloud_arm_id)}"
  subscription_id="${AZURE_SUBSCRIPTION_ID:-${TF_VAR_azure_subscription_id}}"

  export ANYSCALE_CLOUD_ARM_ID="${cloud_arm_id}"
  export AZURE_SUBSCRIPTION_ID="${subscription_id}"

  if [[ ! -x "${ANYSCALE_CLOUD_TEARDOWN_SCRIPT}" ]]; then
    die "Missing executable Anyscale cloud teardown helper."
  fi

  az account set --subscription "${subscription_id}" --only-show-errors
  if ! az resource show --ids "${cloud_arm_id}" --only-show-errors >/dev/null 2>&1; then
    log "Anyscale cloud resource ${cloud_arm_id} is already absent; skipping cloud drain."
    return 0
  fi

  require_env_var ANYSCALE_CLI_TOKEN

  log "Draining Anyscale cloud before Azure teardown: ${ANYSCALE_CLOUD_NAME}"
  SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS="${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
    SETUP_TIMEOUT_AZURE_COMMAND_SECONDS="${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" \
    run_with_timeout 2400 \
      "${ANYSCALE_CLOUD_TEARDOWN_SCRIPT}" \
      --timeout-seconds 1800 \
      --poll-interval-seconds 20
}

wait_for_resource_group_deletion() {
  local resource_group="$1"
  local max_attempts="${2:-180}"
  local attempt=1
  local remaining_count=""
  local remaining_names=""

  while (( attempt <= max_attempts )); do
    if [[ "$(az group exists --name "${resource_group}" --output tsv --only-show-errors 2>/dev/null || printf 'true')" == "false" ]]; then
      return 0
    fi

    if (( attempt == 1 || attempt % 6 == 0 )); then
      remaining_count="$(az resource list \
        --resource-group "${resource_group}" \
        --query 'length(@)' \
        --output tsv \
        --only-show-errors 2>/dev/null || true)"

      if [[ -n "${remaining_count}" && "${remaining_count}" != "0" ]]; then
        remaining_names="$(az resource list \
          --resource-group "${resource_group}" \
          --query '[0:5].name' \
          --output tsv \
          --only-show-errors 2>/dev/null | paste -sd ', ' - || true)"
        log "Still waiting for ${resource_group} deletion (${remaining_count} resources remain${remaining_names:+: ${remaining_names}})"
      else
        log "Still waiting for ${resource_group} deletion"
      fi
    fi

    sleep 10
    ((attempt++))
  done

  die "Timed out waiting for resource group ${resource_group} to delete. Check Azure activity logs and retry."
}

###############################################################################
# Delete the Azure resource group directly and remove local Terraform state.
# This is intentionally stronger than terraform destroy and is useful for
# rebuilding after failed private AKS/bootstrap experiments.
###############################################################################
nuke() {
  local force=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y)
        force=true
        shift
        ;;
      --help|-h)
        cat <<'USAGE'
Usage:
  ./scripts/setup.sh nuke
  ./scripts/setup.sh nuke --yes

Deletes the configured resource group with Azure CLI, waits until it is gone,
then removes local Terraform state and saved plan files. It keeps .env and the
committed .terraform.lock.hcl intact.
USAGE
        return 0
        ;;
      *) die "Unknown nuke option: $1" ;;
    esac
  done

  load_env
  require_cmd az

  local resource_group
  resource_group="$(resource_group_name)"

  if [[ "${force}" != true ]]; then
    warn "This will delete Azure resource group ${resource_group} and remove local Terraform state."
    read -r -p "Type the project name to confirm nuke: " confirm
    [[ "${confirm}" == "${TF_VAR_project}" ]] || die "Cancelled."
  fi

  bastion_tunnel stop >/dev/null 2>&1 || true

  az account set --subscription "${TF_VAR_azure_subscription_id}" --only-show-errors
  if az group show --name "${resource_group}" --only-show-errors >/dev/null 2>&1; then
    warn "Deleting resource group ${resource_group}"
    az group delete --name "${resource_group}" --yes --no-wait --only-show-errors
    log "Waiting for ${resource_group} deletion to complete"
    wait_for_resource_group_deletion "${resource_group}"
  else
    log "Resource group ${resource_group} is already absent."
  fi

  log "Removing local Terraform state and saved plans"
  remove_local_terraform_state_artifacts
  clear_anyscale_cloud_deployment_id
  log "Nuke completed. Run ./scripts/setup.sh init before the next plan/apply if providers are not initialized."
}

teardown() {
  local force=false
  local yes=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force)
        force=true
        shift
        ;;
      --yes|-y)
        yes=true
        shift
        ;;
      --help|-h)
        cat <<'USAGE'
Usage:
  ./scripts/setup.sh teardown
  ./scripts/setup.sh teardown --force --yes

Default teardown uses Terraform destroy, including the Anyscale cloud teardown
hook. --force deletes the Azure resource group directly and purges local
Terraform state artifacts.
USAGE
        return 0
        ;;
      *)
        die "Unknown teardown option: $1"
        ;;
    esac
  done

  if [[ "${force}" == true ]]; then
    setup_run_init "teardown-force" 2
    run_stage "drain-anyscale-cloud" force_teardown_drain_anyscale_cloud
    if [[ "${yes}" == true ]]; then
      run_stage "force-delete-resource-group" nuke --yes
    else
      run_stage "force-delete-resource-group" nuke
    fi
    setup_run_summary
    return 0
  fi

  [[ "${yes}" == true ]] && die "--yes is only valid with --force."
  setup_run_init "teardown" 1
  run_stage "terraform-destroy" destroy
  setup_run_summary
}

IDEMPOTENCY_RUN_DIR=""
IDEMPOTENCY_LOG_DIR=""
IDEMPOTENCY_SUMMARY_TSV=""
IDEMPOTENCY_SUMMARY_MD=""
IDEMPOTENCY_SUMMARY_JSON=""

idempotency_write_summaries() {
  {
    printf '# Idempotency Validation Summary\n\n'
    printf 'Run directory: `%s`\n\n' "${IDEMPOTENCY_RUN_DIR}"
    printf '| Stage | Result | Duration | Log |\n'
    printf '|---|---:|---:|---|\n'
    tail -n +2 "${IDEMPOTENCY_SUMMARY_TSV}" | while IFS=$'\t' read -r stage_name stage_result duration_seconds log_file; do
      printf '| `%s` | %s | %ss | `%s` |\n' "${stage_name}" "${stage_result}" "${duration_seconds}" "${log_file}"
    done
  } > "${IDEMPOTENCY_SUMMARY_MD}"

  {
    printf '{\n'
    printf '  "run_dir": %s,\n' "$(printf '%s' "${IDEMPOTENCY_RUN_DIR}" | jq -R .)"
    printf '  "stages": [\n'
    local first_stage=true
    while IFS=$'\t' read -r stage_name stage_result duration_seconds log_file; do
      if [[ "${stage_name}" == "stage" ]]; then
        continue
      fi
      if [[ "${first_stage}" == true ]]; then
        first_stage=false
      else
        printf ',\n'
      fi
      printf '    {"stage": %s, "result": %s, "duration_seconds": %s, "log": %s}' \
        "$(printf '%s' "${stage_name}" | jq -R .)" \
        "$(printf '%s' "${stage_result}" | jq -R .)" \
        "${duration_seconds}" \
        "$(printf '%s' "${log_file}" | jq -R .)"
    done < "${IDEMPOTENCY_SUMMARY_TSV}"
    printf '\n  ]\n'
    printf '}\n'
  } > "${IDEMPOTENCY_SUMMARY_JSON}"
}

idempotency_run_stage() {
  local stage_name="$1"
  shift

  local log_file start_epoch end_epoch duration_seconds exit_code
  log_file="${IDEMPOTENCY_LOG_DIR}/${stage_name}.log"
  start_epoch="$(date +%s)"
  printf '[idempotency] %s started\n' "${stage_name}"

  set +e
  ( set -e; "$@" ) 2>&1 | tee "${log_file}"
  exit_code=${PIPESTATUS[0]}
  set -e

  end_epoch="$(date +%s)"
  duration_seconds=$((end_epoch - start_epoch))

  if [[ "${exit_code}" -eq 0 ]]; then
    printf '[idempotency] %s ok (%ss)\n' "${stage_name}" "${duration_seconds}"
    printf '%s\tPASS\t%s\t%s\n' "${stage_name}" "${duration_seconds}" "${log_file}" >> "${IDEMPOTENCY_SUMMARY_TSV}"
    return 0
  fi

  printf '[idempotency] %s failed (%ss). See %s\n' "${stage_name}" "${duration_seconds}" "${log_file}" >&2
  printf '%s\tFAIL\t%s\t%s\n' "${stage_name}" "${duration_seconds}" "${log_file}" >> "${IDEMPOTENCY_SUMMARY_TSV}"
  idempotency_write_summaries
  return "${exit_code}"
}

idempotency_terraform_noop_plan() {
  local cluster_bootstrap_json kubeconfig_path plan_exit

  kubeconfig_path="${ROOT_DIR}/.cache/aks-anyscale-sample-harness/kubeconfig.bastion"
  if [[ ! -f "${kubeconfig_path}" ]]; then
    printf 'Missing Bastion-backed kubeconfig at %s. Run deploy before the no-op plan.\n' "${kubeconfig_path}" >&2
    return 1
  fi
  if ! KUBECONFIG="${kubeconfig_path}" kubectl --request-timeout=15s get --raw=/readyz >/dev/null 2>&1; then
    printf 'Bastion-backed kubeconfig at %s is not currently usable. Run deploy or verify --live to refresh it.\n' "${kubeconfig_path}" >&2
    return 1
  fi
  export KUBECONFIG="${kubeconfig_path}"
  export KUBE_CONFIG_PATH="${kubeconfig_path}"

  cluster_bootstrap_json="${TF_VAR_cluster_bootstrap:-{}}"
  if ! jq -e . >/dev/null 2>&1 <<<"${cluster_bootstrap_json}"; then
    cluster_bootstrap_json="{}"
  fi
  export TF_VAR_cluster_bootstrap
  TF_VAR_cluster_bootstrap="$(jq -cn \
    --argjson cluster_bootstrap "${cluster_bootstrap_json}" \
    --arg kubeconfig_path "${kubeconfig_path}" \
    '$cluster_bootstrap + {kubeconfig_path: $kubeconfig_path}')"

  pushd "${TERRAFORM_DIR}" >/dev/null
  set +e
  terraform plan \
    -input=false \
    -detailed-exitcode \
    -var="cluster_bootstrap=${TF_VAR_cluster_bootstrap}" \
    -out="${IDEMPOTENCY_RUN_DIR}/idempotency.tfplan"
  plan_exit=$?
  set -e
  popd >/dev/null

  case "${plan_exit}" in
    0)
      return 0
      ;;
    2)
      printf 'Terraform reported a non-idempotent plan (detailed-exitcode=2).\n' >&2
      return 2
      ;;
    *)
      return "${plan_exit}"
      ;;
  esac
}

idempotency() {
  local include_teardown=false
  local include_force_teardown=false
  local destructive_ack=false
  local skip_workload=false
  local setup_script="${ROOT_DIR}/scripts/setup.sh"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --include-teardown)
        include_teardown=true
        shift
        ;;
      --include-force-teardown)
        include_force_teardown=true
        shift
        ;;
      --i-understand-this-deletes-azure-resources)
        destructive_ack=true
        shift
        ;;
      --skip-workload)
        skip_workload=true
        shift
        ;;
      --help|-h)
        cat <<'USAGE'
Usage:
  ./scripts/setup.sh idempotency
  ./scripts/setup.sh idempotency --skip-workload
  ./scripts/setup.sh idempotency --include-teardown
  ./scripts/setup.sh idempotency --include-force-teardown --i-understand-this-deletes-azure-resources

Default mode is non-destructive: deploy twice, verify twice, workload proof all
twice, then assert that Terraform has a no-op plan.
USAGE
        return 0
        ;;
      *)
        die "Unknown idempotency option: $1"
        ;;
    esac
  done

  if [[ "${include_teardown}" == true && "${include_force_teardown}" == true ]]; then
    die "Use either --include-teardown or --include-force-teardown, not both."
  fi

  if [[ "${include_force_teardown}" == true && "${destructive_ack}" != true ]]; then
    die "Force teardown requires --i-understand-this-deletes-azure-resources."
  fi

  require_cmd jq
  require_cmd kubectl

  IDEMPOTENCY_RUN_DIR="${ROOT_DIR}/.cache/idempotency-validation/$(date -u +%Y%m%dT%H%M%SZ)"
  IDEMPOTENCY_LOG_DIR="${IDEMPOTENCY_RUN_DIR}/logs"
  IDEMPOTENCY_SUMMARY_TSV="${IDEMPOTENCY_RUN_DIR}/summary.tsv"
  IDEMPOTENCY_SUMMARY_MD="${IDEMPOTENCY_RUN_DIR}/summary.md"
  IDEMPOTENCY_SUMMARY_JSON="${IDEMPOTENCY_RUN_DIR}/summary.json"

  mkdir -p "${IDEMPOTENCY_LOG_DIR}"
  printf 'stage\tresult\tduration_seconds\tlog\n' > "${IDEMPOTENCY_SUMMARY_TSV}"

  idempotency_run_stage "deploy-first" "${setup_script}" deploy
  idempotency_run_stage "verify-first" "${setup_script}" verify --full
  if [[ "${skip_workload}" != true ]]; then
    idempotency_run_stage "workload-first" "${setup_script}" workload proof all
  fi

  idempotency_run_stage "deploy-second" "${setup_script}" deploy
  idempotency_run_stage "verify-second" "${setup_script}" verify --full
  if [[ "${skip_workload}" != true ]]; then
    idempotency_run_stage "workload-second" "${setup_script}" workload proof all
  fi

  idempotency_run_stage "terraform-noop-plan" idempotency_terraform_noop_plan

  if [[ "${include_teardown}" == true ]]; then
    idempotency_run_stage "teardown" "${setup_script}" teardown
  elif [[ "${include_force_teardown}" == true ]]; then
    idempotency_run_stage "teardown-force" "${setup_script}" teardown --force --yes
  fi

  idempotency_write_summaries
  printf '[idempotency] summary: %s\n' "${IDEMPOTENCY_SUMMARY_MD}"
}

###############################################################################
cmd="${1:-}"
case "${cmd}" in
  ""|--help|-h)
    cat <<'USAGE'
Usage: ./scripts/setup.sh {deploy|verify|workload|idempotency|teardown}

Commands:
  deploy [--from-scratch --yes]
  verify [--static|--live|--full] [--skip-observability]
  workload proof {cpu|gpu|all}
  idempotency [--skip-workload] [--include-teardown|--include-force-teardown --i-understand-this-deletes-azure-resources]
  teardown [--force] [--yes]
USAGE
    ;;
  deploy) shift; deploy "$@" ;;
  verify) shift; verify "$@" ;;
  workload) shift; workload "$@" ;;
  idempotency) shift; idempotency "$@" ;;
  teardown) shift; teardown "$@" ;;
  *) die "Usage: $0 {deploy|verify|workload|idempotency|teardown}" ;;
esac
