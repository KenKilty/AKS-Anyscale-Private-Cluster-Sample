###############################################################################
# Naming locals — CAF abbreviations
# https://learn.microsoft.com/azure/cloud-adoption-framework/ready/azure-best-practices/resource-abbreviations
###############################################################################
locals {
  suffix     = "${var.project}-${var.environment}-${var.region_short}"
  suffix_alt = "${var.project}${var.environment}${var.region_short}" # for alphanumeric-only resources

  names = {
    resource_group           = "rg-${local.suffix}"
    vnet                     = "vnet-${local.suffix}"
    subnet_aks_nodes         = "snet-aks-nodes-${local.suffix}"
    subnet_aks_apiserver     = "snet-aks-apiserver-${local.suffix}"
    subnet_private_endpoints = "snet-pe-${local.suffix}"
    subnet_dns_resolver_in   = "snet-dnspr-in-${local.suffix}"
    subnet_dns_resolver_out  = "snet-dnspr-out-${local.suffix}"
    # Azure-required fixed names:
    subnet_firewall = "AzureFirewallSubnet"
    subnet_bastion  = "AzureBastionSubnet"
    subnet_gateway  = "GatewaySubnet"

    nsg_aks_nodes     = "nsg-aks-nodes-${local.suffix}"
    nsg_pe            = "nsg-pe-${local.suffix}"
    route_table_aks   = "rt-aks-${local.suffix}"
    pip_firewall      = "pip-afw-${local.suffix}"
    pip_bastion       = "pip-bas-${local.suffix}"
    pip_vpn_gateway   = "pip-vpngw-${local.suffix}"
    firewall          = "afw-${local.suffix}"
    firewall_policy   = "afwp-${local.suffix}"
    firewall_rcg      = "afwp-rcg-${local.suffix}"
    dns_resolver      = "dnspr-${local.suffix}"
    dns_resolver_in   = "in-dnspr-${local.suffix}"
    dns_resolver_out  = "out-dnspr-${local.suffix}"
    dns_forwarding_rs = "dnsfwdrs-${local.suffix}"
    bastion           = "bas-${local.suffix}"
    vpn_gateway       = "vpngw-${local.suffix}"
    aks               = "aks-${local.suffix}"
    aks_dns_prefix    = "aks-${local.suffix}"
    log_analytics     = "log-${local.suffix}"
    ampls             = "ampls-${local.suffix}"
    pep_ampls         = "pep-ampls-${local.suffix}"
    user_assigned_id  = "id-anyscale-operator-${local.suffix}"

    # alphanumeric-only (≤ 24 / ≤ 50 chars). Truncate defensively.
    storage_account = substr("st${local.suffix_alt}", 0, 24)
    acr             = substr("cr${local.suffix_alt}", 0, 50)
  }

  # Private DNS zones used by private endpoints
  private_dns_zones = {
    blob     = "privatelink.blob.core.windows.net"
    dfs      = "privatelink.dfs.core.windows.net"
    acr      = "privatelink.azurecr.io"
    aks      = "privatelink.${var.azure_location}.azmk8s.io"
    monitor  = "privatelink.monitor.azure.com"
    oms      = "privatelink.oms.opinsights.azure.com"
    ods      = "privatelink.ods.opinsights.azure.com"
    agentsvc = "privatelink.agentsvc.azure-automation.net"
  }

  anyscale_operator_identity_mode                = var.anyscale_operator_identity.mode
  anyscale_operator_identity_created_by_tf       = local.anyscale_operator_identity_mode == "create"
  anyscale_operator_storage_rbac_managed_by_tf   = coalesce(var.anyscale_operator_identity.manage_storage_rbac, local.anyscale_operator_identity_mode != "existing-external-rbac")
  anyscale_operator_storage_role_definition_name = "Storage Blob Data Contributor"
  cluster_bootstrap_kubeconfig_path              = try(var.cluster_bootstrap.kubeconfig_path, null)
}
