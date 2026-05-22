output "gateway_id" {
  value = one(azurerm_virtual_network_gateway.this[*].id)
}

output "gateway_name" {
  value = one(azurerm_virtual_network_gateway.this[*].name)
}

output "public_ip_address" {
  value = one(azurerm_public_ip.this[*].ip_address)
}

output "contract" {
  description = "Known VPN settings used by root terraform tests and post-apply client generation flow."
  value = {
    enabled                   = var.enabled
    gateway_id                = one(azurerm_virtual_network_gateway.this[*].id)
    gateway_name              = one(azurerm_virtual_network_gateway.this[*].name)
    gateway_subnet_id         = var.subnet_id
    public_ip_address         = one(azurerm_public_ip.this[*].ip_address)
    public_ip_sku             = one(azurerm_public_ip.this[*].sku)
    public_ip_allocation      = one(azurerm_public_ip.this[*].allocation_method)
    sku                       = var.sku
    vpn_client_protocols      = var.enabled ? ["OpenVPN"] : []
    vpn_auth_types            = var.enabled ? ["Certificate"] : []
    client_address_space      = var.client_address_space
    client_dns_servers        = var.client_dns_servers
    trusted_root_certificates = [for cert in var.trusted_root_certificates : cert.name]
  }
}