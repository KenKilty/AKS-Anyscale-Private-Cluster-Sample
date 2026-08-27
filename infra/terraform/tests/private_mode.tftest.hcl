###############################################################################
# Plan-only validation test for the private AKS security posture.
#
# Run with:
#   terraform test -filter=tests/private_mode.tftest.hcl
###############################################################################

variables {
  project             = "tftest"
  environment         = "ci"
  azure_location      = "westus2"
  region_short        = "wus2"
  enable_browser_host = false

  vnet_address_space = ["10.50.0.0/16"]
  subnet_cidrs = {
    firewall          = "10.50.0.0/26"
    bastion           = "10.50.0.128/26"
    aks_apiserver     = "10.50.1.0/28"
    dns_resolver_in   = "10.50.1.16/28"
    dns_resolver_out  = "10.50.1.32/28"
    private_endpoints = "10.50.2.0/24"
    jump_host         = "10.50.3.0/27"
    browser_jump_host = "10.50.3.32/27"
    aks_nodes         = "10.50.4.0/22"
  }

  dns_forwarding_rules = {}

  anyscale_jump_host_fqdns = []

  anyscale_fqdns = [
    "console.anyscale.com",
    "console.azure.anyscale.com",
    "api.azure.anyscale.com",
    "*.anyscale-cloud.dev",
    "*.azure.anyscale-cloud.dev",
    "*.az1.westus2.admin.azure.anyscale.com",
    "anyscaleazwestus2prod.blob.core.windows.net",
    "anyscaleazwestus2prod.dfs.core.windows.net",
    "api.anyscale.com",
    "anyscale-public.s3.us-west-2.amazonaws.com",
    "anyscale.com",
    "learn.microsoft.com",
  ]

  container_registry_fqdns = [
    "mcr.microsoft.com",
    "*.data.mcr.microsoft.com",
    "ghcr.io",
    "*.ghcr.io",
    "pkg-containers.githubusercontent.com",
    "*.docker.io",
    "registry-1.docker.io",
    "auth.docker.io",
    "production.cloudflare.docker.com",
    "production.cloudfront.docker.com",
    "quay.io",
    "*.quay.io",
    "registry.k8s.io",
    "k8s.gcr.io",
    "gcr.io",
    "*.gcr.io",
    "*.pkg.dev",
    "us-docker.pkg.dev",
    "europe-docker.pkg.dev",
    "asia-docker.pkg.dev",
    "nvcr.io",
    "*.nvcr.io",
    "authn.nvidia.com",
    "arcmktplaceprod.azurecr.io",
    "*.data.azurecr.io",
    "prod-registry-k8s-io-us-west-1.s3.dualstack.us-west-1.amazonaws.com",
  ]

  system_vm_size                       = "Standard_D2s_v5"
  cpu_vm_size                          = "Standard_D16s_v5"
  linux_jump_host_vm_size              = "Standard_D2s_v5"
  linux_jump_host_admin_username       = "azureoperator"
  linux_jump_host_admin_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKbBsj5ktF3GEfYJ5G5O2CP658q5S7Lf4K3b4BVVij7F terraform-test"
  gpu_pool_configs = {
    T4 = {
      name         = "gput4"
      vm_size      = "Standard_NC16as_T4_v3"
      product_name = "NVIDIA-T4"
      gpu_count    = "1"
      min_count    = 1
      max_count    = 2
    }
  }

  kubernetes_version               = "1.34.6"
  service_cidr                     = "10.100.0.0/16"
  dns_service_ip                   = "10.100.0.10"
  anyscale_operator_namespace      = "anyscale-operator"
  anyscale_operator_serviceaccount = "anyscale-operator"
  anyscale_platform = {
    enabled = false
  }
  storage_cors_rule = {
    allowed_headers    = ["*"]
    allowed_methods    = ["GET", "POST", "PUT", "HEAD", "DELETE"]
    allowed_origins    = ["https://*.anyscale.com"]
    expose_headers     = ["Accept-Ranges", "Content-Range", "Content-Length"]
    max_age_in_seconds = 0
  }

  log_analytics_retention_days                  = 30
  terraform_managed_diagnostic_settings_enabled = true
  tags = {
    Project     = "tftest"
    Environment = "ci"
    ManagedBy   = "terraform"
    Owner       = "terraform-test"
  }
}

run "private_aks_and_egress_contract" {
  command = plan

  assert {
    condition     = output.private_mode_validation.aks.private_cluster_enabled == true
    error_message = "AKS private_cluster_enabled must be true."
  }

  assert {
    condition     = output.private_mode_validation.aks.private_cluster_public_fqdn_enabled == false
    error_message = "AKS private_cluster_public_fqdn_enabled must be false."
  }

  assert {
    condition     = output.private_mode_validation.aks.api_server_vnet_integration_enabled == true
    error_message = "AKS API Server VNet Integration must be enabled."
  }

  assert {
    condition     = output.private_mode_validation.aks.outbound_type == "userDefinedRouting"
    error_message = "AKS outbound type must be userDefinedRouting."
  }

  assert {
    condition     = output.private_mode_validation.aks.sku_tier == "Standard" && contains(output.private_mode_validation.aks.availability_zones, "1") && contains(output.private_mode_validation.aks.availability_zones, "2") && contains(output.private_mode_validation.aks.availability_zones, "3") && output.private_mode_validation.aks.system_node_pool_min_count >= 3 && output.private_mode_validation.aks.system_node_pool_max_count >= output.private_mode_validation.aks.system_node_pool_min_count
    error_message = "AKS must use the Standard tier with a zone-spread system pool sized for enterprise HA."
  }

  assert {
    condition     = length(output.private_mode_validation.aks.gpu_pool_availability_zones["T4"]) == 0
    error_message = "The westus2 T4 GPU pool must not inherit system availability zones because Standard_NC16as_T4_v3 is non-zonal in this region."
  }

  assert {
    condition     = output.private_mode_validation.aks.oidc_issuer_enabled == true && output.private_mode_validation.aks.workload_identity_enabled == true
    error_message = "AKS OIDC issuer and Workload Identity must both be enabled."
  }

  assert {
    condition     = output.private_mode_validation.aks.azure_rbac_enabled == true && output.private_mode_validation.aks.local_account_disabled == true
    error_message = "AKS must use managed Entra/Azure RBAC and disable local accounts by default."
  }

  assert {
    condition     = output.private_mode_validation.aks.defender_enabled == true
    error_message = "AKS Microsoft Defender for Containers must be enabled."
  }

  assert {
    condition     = output.private_mode_validation.aks.key_vault_secrets_provider_enabled == true
    error_message = "AKS Key Vault Secrets Provider must be enabled."
  }

  assert {
    condition     = output.private_mode_validation.aks.automatic_upgrade_channel == "patch"
    error_message = "AKS automatic upgrade channel must default to patch for security patch hygiene."
  }

  assert {
    condition     = output.private_mode_validation.aks.node_os_upgrade_channel == "SecurityPatch"
    error_message = "AKS node OS upgrade channel must default to SecurityPatch."
  }

  assert {
    condition     = output.private_mode_validation.routing.address_prefix == "0.0.0.0/0" && output.private_mode_validation.routing.next_hop_type == "VirtualAppliance"
    error_message = "AKS node subnet default route must point to a virtual appliance."
  }


  assert {
    condition     = output.private_mode_validation.firewall.firewall_sku_tier == "Standard" && output.private_mode_validation.firewall.firewall_policy_sku == "Standard"
    error_message = "Azure Firewall and Firewall Policy must use Standard SKU."
  }

  assert {
    condition     = output.private_mode_validation.firewall.dns_proxy_enabled == true && length(output.private_mode_validation.firewall.dns_servers) == 0
    error_message = "Azure Firewall DNS proxy must use default Azure DNS upstream so AKS bootstrap can resolve public and VNet-linked private zones."
  }

  assert {
    condition     = output.private_mode_validation.dns_resolver.inbound_endpoint_ip == "10.50.1.20"
    error_message = "DNS Private Resolver must use the expected stable inbound endpoint IP."
  }

  assert {
    condition     = output.private_mode_validation.dns_resolver.forwarding_rule_count == 0 && contains(keys(output.private_mode_validation.dns_resolver.forwarding_ruleset_vnets), "workload")
    error_message = "DNS forwarding ruleset must be linked to the workload VNet and support zero or more enterprise forwarding rules."
  }

  assert {
    condition     = output.private_mode_validation.firewall.aks_fqdn_tag == "AzureKubernetesService"
    error_message = "Firewall egress rules must include the AzureKubernetesService FQDN tag."
  }

  assert {
    condition     = contains(output.private_mode_validation.firewall.aks_network_ports, "TCP:9000") && contains(output.private_mode_validation.firewall.aks_network_ports, "UDP:1194")
    error_message = "Firewall egress rules must include AKS TCP 9000 and UDP 1194 network rules."
  }

  assert {
    condition     = contains(output.private_mode_validation.firewall.anyscale_fqdns, "api.anyscale.com") && contains(output.private_mode_validation.firewall.anyscale_fqdns, "api.azure.anyscale.com") && contains(output.private_mode_validation.firewall.anyscale_fqdns, "console.anyscale.com") && contains(output.private_mode_validation.firewall.anyscale_fqdns, "console.azure.anyscale.com") && contains(output.private_mode_validation.firewall.anyscale_fqdns, "*.anyscale-cloud.dev") && contains(output.private_mode_validation.firewall.anyscale_fqdns, "*.azure.anyscale-cloud.dev") && contains(output.private_mode_validation.firewall.anyscale_fqdns, "*.az1.westus2.admin.azure.anyscale.com") && contains(output.private_mode_validation.firewall.anyscale_fqdns, "anyscaleazwestus2prod.blob.core.windows.net") && contains(output.private_mode_validation.firewall.anyscale_fqdns, "anyscaleazwestus2prod.dfs.core.windows.net") && contains(output.private_mode_validation.firewall.anyscale_fqdns, "learn.microsoft.com")
    error_message = "Firewall egress rules must include required Anyscale API, console, cloud-domain, admin-zone, Anyscale-managed Azure Storage, and Microsoft Learn FQDNs for the operator, workspace runtime, and public preview documentation access."
  }

  assert {
    condition     = contains(output.private_mode_validation.firewall.container_registry_fqdns, "registry.k8s.io") && contains(output.private_mode_validation.firewall.container_registry_fqdns, "prod-registry-k8s-io-us-west-1.s3.dualstack.us-west-1.amazonaws.com") && contains(output.private_mode_validation.firewall.container_registry_fqdns, "nvcr.io") && contains(output.private_mode_validation.firewall.container_registry_fqdns, "arcmktplaceprod.azurecr.io") && contains(output.private_mode_validation.firewall.container_registry_fqdns, "*.data.azurecr.io")
    error_message = "Firewall egress rules must include Kubernetes image registry, NVIDIA registry, the Anyscale marketplace ACR, and required backing hosts."
  }

  assert {
    condition     = contains(output.private_mode_validation.firewall.azure_identity_fqdns, "login.microsoftonline.com") && contains(output.private_mode_validation.firewall.azure_identity_fqdns, "sts.windows.net") && contains(output.private_mode_validation.firewall.azure_identity_fqdns, "management.azure.com")
    error_message = "Firewall egress rules must include Microsoft identity and ARM endpoints for AKS Workload Identity token exchange and Azure SDK/CLI auth."
  }

  assert {
    condition     = length(output.private_mode_validation.firewall.browser_jump_host_cidrs) == 0
    error_message = "Azure Portal firewall egress must be omitted when the Windows browser jump host is disabled."
  }

  assert {
    condition     = contains(output.private_mode_validation.firewall.azure_portal_fqdns, "portal.azure.com") && contains(output.private_mode_validation.firewall.azure_portal_fqdns, "*.portal.azure.com") && contains(output.private_mode_validation.firewall.azure_portal_fqdns, "login.microsoftonline.com") && contains(output.private_mode_validation.firewall.azure_portal_fqdns, "*.msauth.net") && contains(output.private_mode_validation.firewall.azure_portal_fqdns, "management.azure.com")
    error_message = "Firewall egress rules must include the documented Azure Portal authentication and framework FQDNs for the Windows browser jump-host subnet."
  }

  assert {
    condition     = contains(output.private_mode_validation.firewall.azure_monitor_fqdns, "global.handler.control.monitor.azure.com") && contains(output.private_mode_validation.firewall.azure_monitor_fqdns, "*.ods.opinsights.azure.com") && contains(output.private_mode_validation.firewall.azure_monitor_fqdns, "*.ingest.monitor.azure.com") && contains(output.private_mode_validation.firewall.azure_monitor_fqdns, "*.monitoring.azure.com")
    error_message = "Firewall egress rules must include Azure Monitor Agent, Log Analytics ingestion, DCE ingestion, and metrics endpoints."
  }

  assert {
    condition     = output.private_mode_validation.acr.sku == "Premium" && output.private_mode_validation.acr.public_network_access_enabled == false && output.private_mode_validation.acr.admin_enabled == false && output.private_mode_validation.acr.zone_redundancy_enabled == true
    error_message = "ACR must be Premium, private-only, admin disabled, and zone redundant."
  }

  assert {
    condition     = output.private_mode_validation.storage.public_network_access_enabled == false && output.private_mode_validation.storage.default_network_action == "Deny"
    error_message = "Storage account public network access must be disabled and default network action must be Deny."
  }

  assert {
    condition     = output.private_mode_validation.storage.account_replication_type == "ZRS"
    error_message = "Storage account must use ZRS for zone-resilient enterprise posture in supported regions."
  }

  assert {
    condition     = output.private_mode_validation.keyvault.public_network_access_enabled == false && output.private_mode_validation.keyvault.network_default_action == "Deny" && length(output.private_mode_validation.keyvault.network_ip_rules) == 0 && output.private_mode_validation.keyvault.private_endpoint_auto_approved
    error_message = "Key Vault must default to private-endpoint-only access with a default-deny firewall and automatic private endpoint approval."
  }

  assert {
    condition     = output.private_mode_validation.observability.ampls_enabled == true && output.private_mode_validation.observability.ampls_ingestion_access_mode == "PrivateOnly" && output.private_mode_validation.observability.ampls_query_access_mode == "Open" && output.private_mode_validation.observability.internet_ingestion_enabled == false && output.private_mode_validation.observability.internet_query_enabled == true
    error_message = "Observability must create AMPLS with private ingestion, public proof queries enabled, and workspace public ingestion disabled."
  }

  assert {
    condition     = contains(keys(output.private_mode_validation.observability.ampls_private_dns_zone_ids), "monitor") && contains(keys(output.private_mode_validation.observability.ampls_private_dns_zone_ids), "oms") && contains(keys(output.private_mode_validation.observability.ampls_private_dns_zone_ids), "ods") && contains(keys(output.private_mode_validation.observability.ampls_private_dns_zone_ids), "agentsvc") && contains(keys(output.private_mode_validation.observability.ampls_private_dns_zone_ids), "blob")
    error_message = "AMPLS private endpoint must attach the five documented private DNS zones."
  }

  assert {
    condition     = output.private_mode_validation.container_insights.container_log_v2_enabled == true && contains(output.private_mode_validation.container_insights.streams, "Microsoft-ContainerLogV2") && output.private_mode_validation.container_insights.ampls_enabled == true && output.private_mode_validation.container_insights.config_dce_public_network_access == false && output.private_mode_validation.container_insights.publisher_role_definition_name == "Monitoring Metrics Publisher"
    error_message = "Container Insights must explicitly enable ContainerLogV2, use a private configuration DCE with AMPLS, and authorize the AKS managed identity to publish at cluster scope."
  }

  assert {
    condition     = output.private_mode_validation.aks.diagnostic_settings_enabled == true && output.private_mode_validation.firewall.diagnostic_settings_enabled == true && output.private_mode_validation.storage.diagnostic_settings_enabled == true && output.private_mode_validation.acr.diagnostic_settings_enabled == true && output.private_mode_validation.bastion.diagnostic_settings_enabled == true
    error_message = "Terraform-managed diagnostics must be enabled for AKS, Firewall, Storage, ACR, and Bastion."
  }

  assert {
    condition     = output.anyscale_operator_identity_contract.mode == "create" && output.anyscale_operator_identity_contract.created_by_terraform == true && output.anyscale_operator_identity_contract.managed_by_terraform == true && output.anyscale_operator_identity_contract.role_definition_name == "Storage Blob Data Contributor"
    error_message = "Default Anyscale operator identity path must create the UAMI and manage Storage Blob Data Contributor at container scope."
  }

  assert {
    condition     = output.private_mode_validation.storage.https_traffic_only_enabled == true && output.private_mode_validation.storage.min_tls_version == "TLS1_2" && output.private_mode_validation.storage.allow_nested_items_to_be_public == false && output.private_mode_validation.storage.shared_access_key_enabled == false && output.private_mode_validation.storage.default_to_oauth_authentication == true
    error_message = "Storage account must require HTTPS/TLS1.2, block public nested items, keep shared keys disabled, and default to OAuth."
  }

  assert {
    condition     = contains(output.private_mode_validation.storage.cors_allowed_origins, "https://*.anyscale.com") && contains(output.private_mode_validation.storage.cors_allowed_methods, "GET") && contains(output.private_mode_validation.storage.cors_allowed_methods, "DELETE")
    error_message = "Storage account CORS must allow the Anyscale web UI log/object access pattern."
  }

  assert {
    condition     = contains(output.private_mode_validation.workload_identity.audience, "api://AzureADTokenExchange") && output.private_mode_validation.workload_identity.subject == "system:serviceaccount:anyscale-operator:anyscale-operator"
    error_message = "The Anyscale operator federated identity credential must target the expected service account and Azure AD token exchange audience."
  }

  assert {
    condition     = output.anyscale_operator_workload_identity.namespace == "anyscale-operator" && output.anyscale_operator_workload_identity.service_account == "anyscale-operator" && output.anyscale_operator_workload_identity.federated_subject == output.private_mode_validation.workload_identity.subject && output.anyscale_operator_workload_identity.pod_labels["azure.workload.identity/use"] == "true" && contains(keys(output.anyscale_operator_workload_identity.service_account_annotations), "azure.workload.identity/tenant-id")
    error_message = "Anyscale operator Workload Identity install values must match the federated credential and include required AKS Workload Identity metadata."
  }

  assert {
    condition     = output.private_mode_validation.bastion.sku == "Standard" && output.private_mode_validation.bastion.tunneling_enabled == true
    error_message = "Azure Bastion must be Standard with tunneling enabled for az aks bastion."
  }

  assert {
    condition     = output.private_mode_validation.kubelogin_access.azure_rbac_enabled == true && contains(output.private_mode_validation.kubelogin_access.role_assignments, "Azure Kubernetes Service RBAC Cluster Admin")
    error_message = "The deploying principal must receive Entra-backed AKS RBAC access for kubelogin validation."
  }
}

run "browser_host_password_picker_rbac_contract" {
  command = plan

  variables {
    enable_browser_host                      = true
    windows_browser_jump_host_admin_password = "Tftest-NotReal-Passw0rd!"
    key_vault_public_network_access_enabled  = true
    key_vault_public_access_cidrs_csv        = "203.0.113.10/32, 198.51.100.0/24"
    browser_host_admin_password_secret_reader_principal_ids = {
      operator = "00000000-0000-0000-0000-000000000001"
    }
  }

  assert {
    condition     = azurerm_role_assignment.browser_host_admin_password_reader["operator"].role_definition_name == "Key Vault Secrets User"
    error_message = "The picker principal must be able to read the selected secret value."
  }

  assert {
    condition     = azapi_resource_action.browser_host_admin_password[0].method == "PUT" && azapi_resource_action.browser_host_admin_password[0].when == "apply"
    error_message = "The browser-host fallback password must be created through ARM without an unsupported remote DELETE action."
  }

  assert {
    condition     = length(output.private_mode_validation.firewall.browser_jump_host_cidrs) == 1 && contains(output.private_mode_validation.firewall.browser_jump_host_cidrs, "10.50.3.32/27")
    error_message = "Azure Portal firewall egress must be scoped only to the enabled Windows browser jump-host subnet."
  }

  assert {
    condition     = contains(output.private_mode_validation.firewall.azure_portal_fqdns, "portal.azure.com") && contains(output.private_mode_validation.firewall.azure_portal_fqdns, "*.portal.azure.com") && contains(output.private_mode_validation.firewall.azure_portal_fqdns, "login.microsoftonline.com") && contains(output.private_mode_validation.firewall.azure_portal_fqdns, "*.msauth.net") && contains(output.private_mode_validation.firewall.azure_portal_fqdns, "management.azure.com")
    error_message = "The enabled Windows browser host must receive the documented Azure Portal authentication and framework FQDNs."
  }

  assert {
    condition     = contains(output.private_mode_validation.firewall.azure_portal_protocols, "HTTP:80") && contains(output.private_mode_validation.firewall.azure_portal_protocols, "HTTPS:443")
    error_message = "The enabled Windows browser host must allow the documented Azure Portal HTTP and HTTPS ports."
  }

  assert {
    condition     = azurerm_role_assignment.browser_host_admin_password_metadata_reader["operator"].role_definition_name == "Key Vault Reader"
    error_message = "The picker principal must be able to list vault and secret metadata."
  }

  assert {
    condition = (
      output.browser_jump_host_admin_username == output.browser_host_admin_username &&
      keys(output.browser_jump_host_admin_password_secret) == keys(output.browser_host_admin_password_secret) &&
      output.browser_jump_host_admin_password_secret.enabled == output.browser_host_admin_password_secret.enabled &&
      output.browser_jump_host_admin_password_secret.secret_name == output.browser_host_admin_password_secret.secret_name &&
      output.browser_jump_host_admin_password_secret.reader_principal_count == output.browser_host_admin_password_secret.reader_principal_count &&
      output.browser_jump_host_admin_password_secret.password_generated == output.browser_host_admin_password_secret.password_generated
    )
    error_message = "Canonical browser jump-host outputs must remain equivalent to their compatibility aliases for all plan-known fields."
  }

  assert {
    condition     = output.private_mode_validation.keyvault.public_network_access_enabled && output.private_mode_validation.keyvault.network_default_action == "Deny" && output.private_mode_validation.keyvault.network_ip_rules == toset(["203.0.113.10/32", "198.51.100.0/24"])
    error_message = "Optional Key Vault access must remain default-deny and parse the configured IPv4 CIDR CSV."
  }

  assert {
    condition     = output.private_mode_validation.keyvault.private_endpoint_auto_approved
    error_message = "Optional client access must not disable automatic approval of the Key Vault private endpoint."
  }

}

run "browser_host_password_picker_rejects_malformed_cidr" {
  command = plan

  variables {
    key_vault_public_network_access_enabled = true
    key_vault_public_access_cidrs_csv       = "203.0.113.0/33"
  }

  expect_failures = [var.key_vault_public_access_cidrs_csv]
}

run "browser_host_password_picker_rejects_ipv6_client" {
  command = plan

  variables {
    key_vault_public_network_access_enabled = true
    key_vault_public_access_cidrs_csv       = "2001:db8::1/128"
  }

  expect_failures = [var.key_vault_public_access_cidrs_csv]
}

run "browser_host_password_picker_rejects_rule_when_disabled" {
  command = plan

  variables {
    key_vault_public_network_access_enabled = false
    key_vault_public_access_cidrs_csv       = "203.0.113.10/32"
  }

  expect_failures = [var.key_vault_public_access_cidrs_csv]
}
