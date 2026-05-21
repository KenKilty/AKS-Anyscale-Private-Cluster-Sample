###############################################################################
# Resource Group
###############################################################################
resource "azurerm_resource_group" "this" {
  name     = local.names.resource_group
  location = var.azure_location
  tags     = var.tags
}

###############################################################################
# Network — VNet + all subnets (Phase 1)
###############################################################################
module "network" {
  source = "./modules/network"

  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = var.tags

  vnet_name          = local.names.vnet
  vnet_address_space = var.vnet_address_space

  subnet_cidrs = var.subnet_cidrs
  subnet_names = {
    aks_nodes         = local.names.subnet_aks_nodes
    aks_apiserver     = local.names.subnet_aks_apiserver
    dns_resolver_in   = local.names.subnet_dns_resolver_in
    dns_resolver_out  = local.names.subnet_dns_resolver_out
    private_endpoints = local.names.subnet_private_endpoints
    firewall          = local.names.subnet_firewall
    bastion           = local.names.subnet_bastion
  }

  nsg_aks_nodes_name = local.names.nsg_aks_nodes
  nsg_pe_name        = local.names.nsg_pe
}

###############################################################################
# Private DNS zones (for private endpoints) (Phase 1)
###############################################################################
module "dns" {
  source = "./modules/dns"

  resource_group_name = azurerm_resource_group.this.name
  zones               = local.private_dns_zones
  vnet_links = {
    workload = module.network.vnet_id
  }
  tags = var.tags
}

###############################################################################
# Azure DNS Private Resolver — enterprise DNS path for Private Link + hybrid DNS
###############################################################################
module "dns_resolver" {
  source = "./modules/dns_resolver"

  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = var.tags

  resolver_name           = local.names.dns_resolver
  inbound_endpoint_name   = local.names.dns_resolver_in
  outbound_endpoint_name  = local.names.dns_resolver_out
  forwarding_ruleset_name = local.names.dns_forwarding_rs

  virtual_network_id  = module.network.vnet_id
  inbound_subnet_id   = module.network.subnet_ids.dns_resolver_in
  outbound_subnet_id  = module.network.subnet_ids.dns_resolver_out
  inbound_endpoint_ip = cidrhost(var.subnet_cidrs.dns_resolver_in, 4)

  forwarding_rules = var.dns_forwarding_rules
  forwarding_ruleset_vnet_links = {
    workload = module.network.vnet_id
  }
}

###############################################################################
# Observability — Log Analytics workspace (Phase 1)
###############################################################################
module "observability" {
  source = "./modules/observability"

  resource_group_name         = azurerm_resource_group.this.name
  location                    = azurerm_resource_group.this.location
  log_analytics_name          = local.names.log_analytics
  ampls_name                  = local.names.ampls
  ampls_private_endpoint_name = local.names.pep_ampls
  retention_in_days           = var.log_analytics_retention_days
  internet_ingestion_enabled  = var.log_analytics_internet_ingestion_enabled
  internet_query_enabled      = var.log_analytics_internet_query_enabled
  ampls_enabled               = var.ampls_enabled
  ampls_ingestion_access_mode = var.ampls_ingestion_access_mode
  ampls_query_access_mode     = var.ampls_query_access_mode
  private_endpoint_subnet_id  = module.network.subnet_ids.private_endpoints
  ampls_private_dns_zone_ids = {
    monitor  = module.dns.zone_ids["monitor"]
    oms      = module.dns.zone_ids["oms"]
    ods      = module.dns.zone_ids["ods"]
    agentsvc = module.dns.zone_ids["agentsvc"]
    blob     = module.dns.zone_ids["blob"]
  }
  tags = var.tags
}

###############################################################################
# Storage — public access disabled, AAD-only, private endpoints (blob, dfs) (Phase 1)
###############################################################################
module "storage" {
  source = "./modules/storage"

  resource_group_name  = azurerm_resource_group.this.name
  location             = azurerm_resource_group.this.location
  storage_account_name = local.names.storage_account
  subscription_id      = var.azure_subscription_id
  tenant_id            = var.azure_tenant_id
  container_name       = "${var.project}-${var.environment}-blob"
  replication_type     = var.storage_replication_type
  cors_rule            = var.storage_cors_rule

  pe_subnet_id = module.network.subnet_ids.private_endpoints
  pe_dns_zone_ids = {
    blob = module.dns.zone_ids["blob"]
    dfs  = module.dns.zone_ids["dfs"]
  }

  log_analytics_workspace_id  = module.observability.log_analytics_workspace_id
  diagnostic_settings_enabled = var.storage_diagnostic_settings_enabled != null ? var.storage_diagnostic_settings_enabled : var.terraform_managed_diagnostic_settings_enabled
  tags                        = var.tags
}

###############################################################################
# Identity — User-assigned MI for Anyscale operator (Phase 1)
# Federated credential is wired in Phase 2 once the AKS OIDC issuer URL exists.
###############################################################################
module "identity" {
  source = "./modules/identity"

  resource_group_name   = azurerm_resource_group.this.name
  location              = azurerm_resource_group.this.location
  name                  = local.names.user_assigned_id
  operator_identity     = var.anyscale_operator_identity
  storage_data_scope_id = module.storage.container_id
  tags                  = var.tags
}

###############################################################################
# Azure Firewall — egress lockdown for AKS (Phase 1)
# Docs: https://learn.microsoft.com/azure/aks/limit-egress-traffic
#       https://learn.microsoft.com/azure/aks/outbound-rules-control-egress
###############################################################################
module "firewall" {
  source = "./modules/firewall"

  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = var.tags

  pip_name             = local.names.pip_firewall
  firewall_name        = local.names.firewall
  firewall_policy_name = local.names.firewall_policy
  rcg_name             = local.names.firewall_rcg

  firewall_subnet_id = module.network.subnet_ids.firewall

  aks_nodes_cidr           = var.subnet_cidrs.aks_nodes
  anyscale_fqdns           = var.anyscale_fqdns
  azure_identity_fqdns     = var.azure_identity_fqdns
  azure_monitor_fqdns      = var.azure_monitor_fqdns
  container_registry_fqdns = var.container_registry_fqdns
  dns_proxy_enabled        = true
  dns_servers              = []

  log_analytics_workspace_id  = module.observability.log_analytics_workspace_id
  diagnostic_settings_enabled = var.terraform_managed_diagnostic_settings_enabled
}

resource "azurerm_virtual_network_dns_servers" "workload" {
  virtual_network_id = module.network.vnet_id
  dns_servers        = [module.firewall.firewall_private_ip]
}

###############################################################################
# Routing — UDR with default route -> Azure Firewall private IP (Phase 2)
# Required by AKS outboundType=userDefinedRouting.
###############################################################################
module "routing" {
  source = "./modules/routing"

  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = var.tags

  route_table_name    = local.names.route_table_aks
  firewall_private_ip = module.firewall.firewall_private_ip

  subnet_ids_to_associate = {
    aks_nodes = module.network.subnet_ids.aks_nodes
  }

  depends_on = [azurerm_virtual_network_dns_servers.workload]
}

###############################################################################
# Azure Container Registry (Premium) + private endpoint (Phase 2)
###############################################################################
module "acr" {
  source = "./modules/acr"

  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = var.tags

  name           = local.names.acr
  pe_subnet_id   = module.network.subnet_ids.private_endpoints
  pe_dns_zone_id = module.dns.zone_ids["acr"]

  zone_redundancy_enabled     = var.acr_zone_redundancy_enabled
  log_analytics_workspace_id  = module.observability.log_analytics_workspace_id
  diagnostic_settings_enabled = var.terraform_managed_diagnostic_settings_enabled
}

###############################################################################
# Azure Bastion (Standard, native client tunneling) (Phase 2)
###############################################################################
module "bastion" {
  source = "./modules/bastion"

  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = var.tags

  bastion_name = local.names.bastion
  pip_name     = local.names.pip_bastion
  subnet_id    = module.network.subnet_ids.bastion

  log_analytics_workspace_id  = module.observability.log_analytics_workspace_id
  diagnostic_settings_enabled = var.terraform_managed_diagnostic_settings_enabled
}

###############################################################################
# Private AKS cluster (Phase 2)
# - Private cluster + API Server VNet integration
# - outboundType = userDefinedRouting (egress via Azure Firewall)
# - Workload identity + federated cred for the Anyscale operator UAMI
# - Container Insights via OMS agent (msi auth)
###############################################################################
module "aks" {
  source = "./modules/aks"

  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = var.tags

  cluster_name = local.names.aks
  dns_prefix   = local.names.aks_dns_prefix

  azure_tenant_id    = var.azure_tenant_id
  kubernetes_version = var.kubernetes_version
  service_cidr       = var.service_cidr
  dns_service_ip     = var.dns_service_ip

  nodes_subnet_id     = module.network.subnet_ids.aks_nodes
  apiserver_subnet_id = module.network.subnet_ids.aks_apiserver
  private_dns_zone_id = module.dns.zone_ids["aks"]

  system_vm_size             = var.system_vm_size
  availability_zones         = var.availability_zones
  sku_tier                   = var.aks_sku_tier
  system_node_pool_min_count = var.system_node_pool_min_count
  system_node_pool_max_count = var.system_node_pool_max_count
  cpu_vm_size                = var.cpu_vm_size
  gpu_pool_configs           = var.gpu_pool_configs

  log_analytics_workspace_id                  = module.observability.log_analytics_workspace_id
  container_insights_v2_enabled               = var.container_insights_v2_enabled
  container_insights_streams                  = var.container_insights_streams
  container_insights_data_collection_interval = var.container_insights_data_collection_interval
  container_insights_namespace_filtering_mode = var.container_insights_namespace_filtering_mode
  container_insights_namespaces               = var.container_insights_namespaces
  ampls_enabled                               = var.ampls_enabled
  ampls_scope_name                            = module.observability.ampls_scope_name
  ampls_resource_group_name                   = azurerm_resource_group.this.name
  diagnostic_settings_enabled                 = var.terraform_managed_diagnostic_settings_enabled
  anyscale_operator_identity_id               = module.identity.id
  anyscale_operator_namespace                 = var.anyscale_operator_namespace
  anyscale_operator_serviceaccount            = var.anyscale_operator_serviceaccount
  acr_id                                      = module.acr.acr_id

  # The cluster needs the UDR in place AND the firewall egress allow-list
  # (rule collection group) created before nodes come up — outboundType
  # = userDefinedRouting otherwise blocks all bootstrap traffic.
  depends_on = [module.routing, module.firewall, azurerm_virtual_network_dns_servers.workload]
}

###############################################################################
# Kubernetes bootstrap — operator service account + baseline Helm add-ons
# Requires a Bastion-backed kubeconfig generated locally for the private AKS
# API endpoint before terraform apply.
###############################################################################
module "cluster_bootstrap" {
  source = "./modules/cluster_bootstrap"

  providers = {
    kubernetes = kubernetes.bootstrap
    helm       = helm.bootstrap
  }

  enabled                            = var.cluster_bootstrap.enabled
  operator_namespace                 = var.anyscale_operator_namespace
  operator_service_account_name      = var.anyscale_operator_serviceaccount
  workload_identity_client_id        = module.identity.client_id
  workload_identity_tenant_id        = var.azure_tenant_id
  extension_release_name             = local.anyscale_platform_extension_name
  gpu_resources_namespace            = var.cluster_bootstrap.gpu_resources_namespace
  nvidia_device_plugin_release_name  = var.cluster_bootstrap.nvidia_device_plugin_release_name
  nvidia_device_plugin_chart_version = var.cluster_bootstrap.nvidia_device_plugin_chart_version
  ingress_namespace                  = var.cluster_bootstrap.ingress_namespace
  ingress_release_name               = var.cluster_bootstrap.ingress_release_name
  ingress_chart_version              = var.cluster_bootstrap.ingress_chart_version

  depends_on = [module.aks, module.bastion]
}
