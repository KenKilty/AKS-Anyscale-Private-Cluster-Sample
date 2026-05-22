###############################################################################
# Azure VPN Gateway (P2S certificate auth, OpenVPN)
# Docs:
# - https://learn.microsoft.com/azure/vpn-gateway/point-to-site-certificate-gateway
# - https://learn.microsoft.com/azure/vpn-gateway/point-to-site-about
###############################################################################
locals {
  public_ip_zones = endswith(upper(var.sku), "AZ") ? ["1", "2", "3"] : null
}

resource "azurerm_public_ip" "this" {
  count = var.enabled ? 1 : 0

  name                = var.pip_name
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = local.public_ip_zones
  tags                = var.tags
}

resource "azurerm_virtual_network_gateway" "this" {
  count = var.enabled ? 1 : 0

  name                = var.gateway_name
  resource_group_name = var.resource_group_name
  location            = var.location

  type     = "Vpn"
  vpn_type = "RouteBased"
  sku      = var.sku

  active_active = false
  bgp_enabled   = false
  tags          = var.tags

  ip_configuration {
    name                          = "ipconfig"
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.this[0].id
    subnet_id                     = var.subnet_id
  }

  vpn_client_configuration {
    address_space        = var.client_address_space
    vpn_auth_types       = ["Certificate"]
    vpn_client_protocols = ["OpenVPN"]

    dynamic "root_certificate" {
      for_each = var.trusted_root_certificates
      content {
        name             = root_certificate.value.name
        public_cert_data = root_certificate.value.public_cert_data
      }
    }
  }

  lifecycle {
    precondition {
      condition     = var.subnet_id != null
      error_message = "P2S VPN requires a GatewaySubnet ID. Set subnet_cidrs.gateway when enable_p2s_vpn is true."
    }

    precondition {
      condition     = length(var.trusted_root_certificates) > 0
      error_message = "P2S VPN requires at least one trusted root certificate for certificate authentication."
    }
  }
}