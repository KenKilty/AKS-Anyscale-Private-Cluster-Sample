#!/usr/bin/env bash
# Idempotent in-cluster Kubernetes bootstrap for the Anyscale private AKS setup.
# Runs on the Linux jump host from inside the VNet after the AKS cluster exists.
#
# Usage: ./scripts/bootstrap-k8s.sh phase-a | phase-b
#
# phase-a  operator namespace, ServiceAccount, gpu-resources namespace,
#          NVIDIA device plugin, and Anyscale Gateway (no TLS secret names).
# phase-b  re-run Anyscale Gateway helm upgrade with TLS secret names
#          derived from CLOUD_DEPLOYMENT_ID.
#
# Required env vars (set by orchestrator via invoke_jump_host_bootstrap):
#   AKS_CLUSTER_NAME, AKS_RG
#   OPERATOR_NAMESPACE, OPERATOR_SA_NAME
#   WORKLOAD_IDENTITY_CLIENT_ID, WORKLOAD_IDENTITY_TENANT_ID
#   EXTENSION_RELEASE_NAME
#   GPU_RESOURCES_NAMESPACE
#   NVIDIA_RELEASE_NAME, NVIDIA_CHART_VERSION
#   GATEWAY_RELEASE_NAME, GATEWAY_NAME, GATEWAY_CLASS_NAME, GATEWAY_SERVICE_NAME
#   GATEWAY_PRIVATE_IP
#   CLOUD_DEPLOYMENT_ID        (phase-b only)
#   GATEWAY_SERVICE_HTTPS_ENABLED  (optional; default false)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

LOG_INFO_PREFIX="bootstrap-k8s"
LOG_WARN_PREFIX="bootstrap-k8s"
LOG_ERROR_PREFIX="bootstrap-k8s"
# shellcheck source=./lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"

###############################################################################
# Helpers
###############################################################################

require_var() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "Required env var ${name} is not set."
}

setup_kubeconfig() {
  log "Acquiring kubeconfig for ${AKS_CLUSTER_NAME} in ${AKS_RG} ..."
  local kubeconfig_file
  kubeconfig_file="${ROOT_DIR}/.cache/kubeconfig.bootstrap-k8s"
  mkdir -p "${ROOT_DIR}/.cache"

  az aks get-credentials \
    --resource-group "${AKS_RG}" \
    --name "${AKS_CLUSTER_NAME}" \
    --file "${kubeconfig_file}" \
    --overwrite-existing \
    --only-show-errors >/dev/null

  kubelogin convert-kubeconfig -l azurecli --kubeconfig "${kubeconfig_file}" >/dev/null
  export KUBECONFIG="${kubeconfig_file}"
  log "Kubeconfig ready (${KUBECONFIG})"
}

# Build and deploy the Anyscale Gateway helm release.
# Args: cloud_deployment_id (empty string for phase-a)
gateway_upgrade() {
  local cloud_deployment_id="$1"
  local gateway_values_file
  gateway_values_file="$(mktemp)"

  local deployment_slug="" primary_tls="" service_tls=""
  if [[ -n "${cloud_deployment_id}" ]]; then
    deployment_slug="${cloud_deployment_id//_/-}"
    primary_tls="anyscale-${deployment_slug}-certificate"
    if [[ "${GATEWAY_SERVICE_HTTPS_ENABLED:-false}" == "true" ]]; then
      service_tls="anyscale-svc-${deployment_slug}-certificate"
    fi
  fi

  {
    printf 'gateway:\n'
    printf '  name: "%s"\n' "${GATEWAY_NAME}"
    printf '  className: "%s"\n' "${GATEWAY_CLASS_NAME}"
    [[ -n "${primary_tls}" ]] && printf '  primaryTlsSecretName: "%s"\n' "${primary_tls}"
    [[ -n "${service_tls}" ]] && printf '  serviceTlsSecretName: "%s"\n' "${service_tls}"
    printf '  sessionHostname: "*.i.azure.anyscaleuserdata.com"\n'
    printf '  serviceHostname: "*.s.azure.anyscaleuserdata.com"\n'
    printf '  annotations:\n'
    printf '    service.beta.kubernetes.io/azure-load-balancer-internal: "true"\n'
    printf '    service.beta.kubernetes.io/azure-load-balancer-ipv4: "%s"\n' "${GATEWAY_PRIVATE_IP}"
    printf '    gateway.istio.io/name-override: "%s"\n' "${GATEWAY_SERVICE_NAME}"
    printf '  allowedRoutes:\n'
    printf '    namespaces:\n'
    printf '      from: Same\n'
  } > "${gateway_values_file}"

  log "helm upgrade --install ${GATEWAY_RELEASE_NAME} (cloud_deployment_id=${cloud_deployment_id:-<empty>}) ..."
  helm upgrade --install "${GATEWAY_RELEASE_NAME}" \
    "${ROOT_DIR}/infra/terraform/modules/cluster_bootstrap/charts/anyscale-gateway" \
    --namespace "${OPERATOR_NAMESPACE}" \
    --values "${gateway_values_file}" \
    --wait

  rm -f "${gateway_values_file}"
  log "Gateway helm release ${GATEWAY_RELEASE_NAME} installed/upgraded."
}

###############################################################################
# phase-a: namespaces, ServiceAccount, NVIDIA, Gateway (no TLS)
###############################################################################

phase_a() {
  require_var AKS_CLUSTER_NAME
  require_var AKS_RG
  require_var OPERATOR_NAMESPACE
  require_var OPERATOR_SA_NAME
  require_var WORKLOAD_IDENTITY_CLIENT_ID
  require_var WORKLOAD_IDENTITY_TENANT_ID
  require_var EXTENSION_RELEASE_NAME
  require_var GPU_RESOURCES_NAMESPACE
  require_var NVIDIA_RELEASE_NAME
  require_var NVIDIA_CHART_VERSION
  require_var GATEWAY_RELEASE_NAME
  require_var GATEWAY_NAME
  require_var GATEWAY_CLASS_NAME
  require_var GATEWAY_SERVICE_NAME
  require_var GATEWAY_PRIVATE_IP

  setup_kubeconfig

  # 1. Operator namespace (idempotent via dry-run/apply)
  log "Applying operator namespace ${OPERATOR_NAMESPACE} ..."
  kubectl create namespace "${OPERATOR_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

  # 2. Operator ServiceAccount with exact workload-identity labels + annotations
  log "Applying ServiceAccount ${OPERATOR_SA_NAME} ..."
  kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${OPERATOR_SA_NAME}
  namespace: ${OPERATOR_NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: "Helm"
    azure.workload.identity/use: "true"
  annotations:
    meta.helm.sh/release-name: "${EXTENSION_RELEASE_NAME}"
    meta.helm.sh/release-namespace: "${OPERATOR_NAMESPACE}"
    azure.workload.identity/client-id: "${WORKLOAD_IDENTITY_CLIENT_ID}"
    azure.workload.identity/tenant-id: "${WORKLOAD_IDENTITY_TENANT_ID}"
EOF

  # 3. GPU resources namespace (idempotent)
  log "Applying GPU resources namespace ${GPU_RESOURCES_NAMESPACE} ..."
  kubectl create namespace "${GPU_RESOURCES_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

  # 4. NVIDIA device plugin
  log "Installing NVIDIA device plugin ${NVIDIA_CHART_VERSION} into ${GPU_RESOURCES_NAMESPACE} ..."
  helm repo add nvdp https://nvidia.github.io/k8s-device-plugin --force-update >/dev/null
  helm repo update nvdp >/dev/null

  local nvidia_values_file
  nvidia_values_file="$(mktemp)"
  cat > "${nvidia_values_file}" <<'NVVALS'
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
NVVALS

  helm upgrade --install "${NVIDIA_RELEASE_NAME}" nvdp/nvidia-device-plugin \
    --version "${NVIDIA_CHART_VERSION}" \
    --namespace "${GPU_RESOURCES_NAMESPACE}" \
    --values "${nvidia_values_file}" \
    --wait
  rm -f "${nvidia_values_file}"
  log "NVIDIA device plugin installed."

  # 5. Anyscale Gateway (phase-a: cloud_deployment_id empty → no TLS listener entries)
  gateway_upgrade ""
}

###############################################################################
# phase-b: re-apply Gateway with TLS secret names from CLOUD_DEPLOYMENT_ID
###############################################################################

phase_b() {
  require_var AKS_CLUSTER_NAME
  require_var AKS_RG
  require_var OPERATOR_NAMESPACE
  require_var GATEWAY_RELEASE_NAME
  require_var GATEWAY_NAME
  require_var GATEWAY_CLASS_NAME
  require_var GATEWAY_SERVICE_NAME
  require_var GATEWAY_PRIVATE_IP
  require_var CLOUD_DEPLOYMENT_ID

  setup_kubeconfig
  # TLS secret names are derived in gateway_upgrade() from CLOUD_DEPLOYMENT_ID:
  #   primaryTlsSecretName = "anyscale-${cloud_deployment_id//_/-}-certificate"
  #   serviceTlsSecretName = "anyscale-svc-${cloud_deployment_id//_/-}-certificate"
  gateway_upgrade "${CLOUD_DEPLOYMENT_ID}"
}

###############################################################################
# Dispatch
###############################################################################

case "${1:-}" in
  phase-a)
    log "Starting phase-a ..."
    phase_a
    log "phase-a complete."
    ;;
  phase-b)
    log "Starting phase-b ..."
    phase_b
    log "phase-b complete."
    ;;
  --help | -h)
    cat <<'USAGE'
Usage: ./scripts/bootstrap-k8s.sh phase-a | phase-b

Idempotent Kubernetes bootstrap run on the Linux jump host.
The orchestrator (scripts/setup.sh invoke_jump_host_bootstrap) syncs this
script to the jump box and invokes it via Bastion-tunnelled SSH.
USAGE
    ;;
  *)
    die "Usage: ./scripts/bootstrap-k8s.sh phase-a | phase-b"
    ;;
esac
