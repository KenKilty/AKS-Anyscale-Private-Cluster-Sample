###############################################################################
# Azure Key Vault — RBAC-authorized with a private endpoint. Public access is
# optional and remains default-deny behind explicit client IP rules. Holds the
# Notation signing certificate used to sign custom container images (consumed
# by `notation` + the azure-kv plugin) and read by AKS Image Integrity (Ratify).
# Docs:
# - https://learn.microsoft.com/azure/key-vault/general/private-link-service
# - https://learn.microsoft.com/azure/container-registry/container-registry-tutorial-sign-build-push
###############################################################################
resource "azurerm_key_vault" "this" {
  name                          = var.name
  resource_group_name           = var.resource_group_name
  location                      = var.location
  tenant_id                     = var.tenant_id
  sku_name                      = "standard"
  rbac_authorization_enabled    = true
  public_network_access_enabled = var.public_network_access_enabled
  purge_protection_enabled      = var.purge_protection_enabled
  soft_delete_retention_days    = var.soft_delete_retention_days
  tags                          = var.tags

  # Default-deny firewall. AzureServices bypass lets trusted Azure platform
  # services reach the vault; explicit IPv4 CIDRs let authorized clients use the
  # public data-plane endpoint. The private endpoint keeps working regardless of
  # these rules.
  network_acls {
    bypass         = "AzureServices"
    default_action = "Deny"
    ip_rules       = var.public_network_access_ip_rules
  }
}

resource "azurerm_private_endpoint" "this" {
  name                = "pep-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.pe_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-${var.name}"
    private_connection_resource_id = azurerm_key_vault.this.id
    is_manual_connection           = false
    subresource_names              = ["vault"]
  }

  private_dns_zone_group {
    name                 = "pdz-kv"
    private_dns_zone_ids = [var.pe_dns_zone_id]
  }
}
