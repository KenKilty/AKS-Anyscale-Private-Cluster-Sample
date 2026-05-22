output "resource_group_name" {
  description = "Name of the resource group."
  value       = azurerm_resource_group.this.name
}

output "location" {
  description = "Azure region of the deployment."
  value       = azurerm_resource_group.this.location
}

output "vnet_id" {
  description = "ID of the workload VNet."
  value       = module.network.vnet_id
}

output "subnet_ids" {
  description = "Map of subnet IDs created by the network module."
  value       = module.network.subnet_ids
}

output "firewall_private_ip" {
  description = "Azure Firewall private IP — UDR next-hop for AKS."
  value       = module.firewall.firewall_private_ip
}

output "dns_resolver_inbound_endpoint_ip" {
  description = "Azure DNS Private Resolver inbound endpoint IP for hybrid DNS clients and conditional forwarding patterns."
  value       = module.dns_resolver.inbound_endpoint_ip
}

output "dns_resolver_forwarding_ruleset_id" {
  description = "Azure DNS Private Resolver forwarding ruleset ID."
  value       = module.dns_resolver.forwarding_ruleset_id
}

output "vnet_dns_servers" {
  description = "Custom DNS servers configured on the workload VNet."
  value       = azurerm_virtual_network_dns_servers.workload.dns_servers
}

output "p2s_vpn_contract" {
  description = "Plan-time contract for the optional Point-to-Site VPN path."
  value       = module.vpn.contract
}

output "vpn_gateway_name" {
  description = "Name of the Azure VPN Gateway when P2S is enabled."
  value       = module.vpn.gateway_name
}

output "vpn_gateway_public_ip" {
  description = "Public IP address of the Azure VPN Gateway when P2S is enabled."
  value       = module.vpn.public_ip_address
}

output "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID (full ARM id)."
  value       = module.observability.log_analytics_workspace_id
}

output "log_analytics_workspace_customer_id" {
  description = "Log Analytics workspace customer ID used by Azure CLI query commands."
  value       = module.observability.log_analytics_workspace_customer_id
}

output "storage_account_name" {
  description = "Storage account name."
  value       = module.storage.storage_account_name
}

output "anyscale_operator_identity_client_id" {
  description = "Client ID of the Anyscale operator user-assigned managed identity."
  value       = module.identity.client_id
}

output "anyscale_operator_identity_id" {
  description = "Resource ID of the Anyscale operator user-assigned managed identity."
  value       = module.identity.id
}

output "anyscale_operator_identity_principal_id" {
  description = "Principal ID of the Anyscale operator user-assigned managed identity."
  value       = module.identity.principal_id
}

###############################################################################
# Phase 2 outputs
###############################################################################
output "aks_cluster_name" {
  description = "Name of the AKS cluster."
  value       = module.aks.cluster_name
}

output "aks_private_fqdn" {
  description = "Private FQDN of the AKS API server."
  value       = module.aks.private_fqdn
}

output "aks_oidc_issuer_url" {
  description = "OIDC issuer URL of the AKS cluster (for additional federated credentials)."
  value       = module.aks.oidc_issuer_url
}

output "acr_login_server" {
  description = "ACR login server (privatelink)."
  value       = module.acr.login_server
}

output "bastion_name" {
  description = "Azure Bastion host name."
  value       = module.bastion.bastion_name
}

output "anyscale_cloud_name" {
  description = "Terraform-managed Anyscale cloud name when the AzAPI deployment path is enabled."
  value       = local.anyscale_platform_enabled ? local.anyscale_platform_cloud_name : null
}

output "anyscale_cloud_id" {
  description = "Resource ID of the Terraform-managed Anyscale cloud."
  value       = local.anyscale_platform_enabled ? "${azurerm_resource_group.this.id}/providers/Anyscale.Platform/clouds/${local.anyscale_platform_cloud_name}" : null
}

output "anyscale_cloud_resource_id" {
  description = "Resource ID of the Terraform-managed default Anyscale cloud resource."
  value       = local.anyscale_platform_enabled ? "${azurerm_resource_group.this.id}/providers/Anyscale.Platform/clouds/${local.anyscale_platform_cloud_name}/cloudResources/default" : null
}

output "anyscale_extension_resource_id" {
  description = "Resource ID of the Terraform-managed AKS Anyscale extension."
  value       = local.anyscale_platform_enabled ? azurerm_kubernetes_cluster_extension.anyscale_operator[0].id : null
}

output "anyscale_extension_name" {
  description = "Name of the Terraform-managed AKS Anyscale extension."
  value       = local.anyscale_platform_enabled ? azurerm_kubernetes_cluster_extension.anyscale_operator[0].name : null
}

output "anyscale_platform_contract" {
  description = "Plan-time lifecycle contract for the Terraform-managed Anyscale cloud, AKS marketplace extension, and Azure cloud teardown hook."
  value = {
    enabled                          = local.anyscale_platform_enabled
    cloud_name                       = local.anyscale_platform_cloud_name
    cloud_management_mode            = "azapi_arm_template"
    extension_management_mode        = "azurerm_kubernetes_cluster_extension"
    extension_type                   = "Anyscale.AKS.Operator"
    extension_resource_name          = local.anyscale_platform_extension_name
    extension_release_namespace      = var.anyscale_operator_namespace
    extension_service_account_name   = var.anyscale_operator_serviceaccount
    extension_release_train          = local.anyscale_platform_extension_release_train
    dynamic_configuration_keys       = local.anyscale_platform_extension_dynamic_configuration_keys
    extension_configuration_settings = local.anyscale_platform_extension_configuration_settings
    lifecycle = {
      create_order  = local.anyscale_platform_lifecycle_create_order
      destroy_order = local.anyscale_platform_lifecycle_destroy_order
    }
    teardown = {
      enabled                               = local.anyscale_platform_destroy_workaround_enabled
      mode                                  = "terraform_data_local_exec"
      runtime_objects                       = local.anyscale_platform_destroy_workaround_runtime_objects
      cloud_delete_stage                    = "before_extension_and_aks_destroy"
      runtime_termination_timeout_seconds   = local.anyscale_platform_destroy_workaround_runtime_timeout_seconds
      workspace_termination_timeout_seconds = local.anyscale_platform_destroy_workaround_runtime_timeout_seconds
      poll_interval_seconds                 = local.anyscale_platform_destroy_workaround_poll_interval_seconds
    }
  }
}

output "cluster_bootstrap_contract" {
  description = "Plan-time contract for the Terraform-managed Kubernetes bootstrap layer that prepares the private AKS cluster for Anyscale and validation workloads."
  value = merge(module.cluster_bootstrap.contract, {
    access_mode = "bastion-kubeconfig"
  })
}

###############################################################################
# Convenience commands
###############################################################################
output "aks_get_credentials_command" {
  description = "Run this to fetch Entra-backed kubeconfig, then run kubelogin convert-kubeconfig -l azurecli."
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.this.name} --name ${module.aks.cluster_name} --overwrite-existing && kubelogin convert-kubeconfig -l azurecli"
}

output "aks_bastion_connect_command" {
  description = "Open a Bastion tunnel to the private AKS API server using Entra-backed kubelogin access (preview)."
  value       = "az aks bastion --name ${module.aks.cluster_name} --resource-group ${azurerm_resource_group.this.name} --bastion ${module.bastion.bastion_id}"
}

output "aks_bastion_admin_connect_command" {
  description = "Fallback admin Bastion tunnel command for break-glass validation. Prefer aks_bastion_connect_command."
  value       = "az aks bastion --name ${module.aks.cluster_name} --resource-group ${azurerm_resource_group.this.name} --admin --bastion ${module.bastion.bastion_id}"
}

output "private_mode_validation" {
  description = "Private AKS and locked-down egress invariants consumed by terraform tests."
  value = {
    aks                = module.aks.private_mode
    workload_identity  = module.aks.workload_identity
    routing            = module.routing.egress_route
    vpn                = module.vpn.contract
    firewall           = module.firewall.egress_validation
    dns_resolver       = module.dns_resolver.private_dns_resolver_validation
    vnet_dns_servers   = azurerm_virtual_network_dns_servers.workload.dns_servers
    acr                = module.acr.private_mode
    storage            = module.storage.private_mode
    observability      = module.observability.private_link_validation
    container_insights = module.aks.container_insights
    identity           = module.identity.storage_access
    bastion            = module.bastion.private_aks_access
    kubelogin_access   = module.aks.kubelogin_access
    cluster_bootstrap  = module.cluster_bootstrap.contract
  }
}

output "anyscale_operator_identity_contract" {
  description = "Plan-time identity mode contract for the Anyscale operator user-assigned managed identity."
  value = {
    mode                      = local.anyscale_operator_identity_mode
    created_by_terraform      = local.anyscale_operator_identity_created_by_tf
    managed_by_terraform      = local.anyscale_operator_storage_rbac_managed_by_tf
    role_definition_name      = local.anyscale_operator_storage_role_definition_name
    expected_storage_scope_id = module.storage.container_id
    existing_identity = local.anyscale_operator_identity_created_by_tf ? null : {
      id           = var.anyscale_operator_identity.id
      client_id    = var.anyscale_operator_identity.client_id
      principal_id = var.anyscale_operator_identity.principal_id
      name         = var.anyscale_operator_identity.name
    }
  }
}

output "anyscale_operator_workload_identity" {
  description = "Kubernetes Workload Identity values for the Anyscale operator service account and storage data-plane access."
  value = {
    namespace         = var.anyscale_operator_namespace
    service_account   = var.anyscale_operator_serviceaccount
    tenant_id         = var.azure_tenant_id
    client_id         = module.identity.client_id
    principal_id      = module.identity.principal_id
    identity_id       = module.identity.id
    federated_subject = module.aks.workload_identity.subject
    service_account_annotations = {
      "azure.workload.identity/client-id" = module.identity.client_id
      "azure.workload.identity/tenant-id" = var.azure_tenant_id
    }
    pod_labels = {
      "azure.workload.identity/use" = "true"
    }
    storage = {
      account_name  = module.storage.storage_account_name
      container_id  = module.storage.container_id
      container     = module.storage.container_name
      blob_endpoint = module.storage.blob_endpoint
      dfs_endpoint  = module.storage.dfs_endpoint
      rbac          = module.identity.storage_access
    }
  }
}
