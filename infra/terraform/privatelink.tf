###############################################################################
# Azure Private Link to the Anyscale control plane (optional, default-off).
#
# Moves control-plane traffic off the public-internet egress path. Without this,
# nodes reach the cloud-specific Anyscale hostname
# (cld-<cloud-resource-id>.azure.anyscale-cloud.dev) outbound through Azure
# Firewall application rules (see modules/firewall). With it, the hostnames
# under the private DNS zone resolve to a private endpoint inside the VNet and
# never leave it.
#
# Three things to know before enabling:
#
#   * This does NOT remove the need for egress. Private Link carries control
#     plane traffic only. Nodes still reach Microsoft Entra for workload identity
#     tokens (no Private Link exists for Entra), MCR for system images, the AKS
#     binary mirror, and Azure Resource Manager through the firewall.
#
#   * The private DNS zone is authoritative for its whole domain inside this
#     VNet. Once linked, no other name in that domain resolves publicly from
#     inside the VNet. That is why the record list defaults to a wildcard rather
#     than an enumeration of hostnames. The PUBLIC browser/OAuth console host
#     console.azure.anyscale.com is a different domain and is unaffected.
#
#   * The connection is cross-tenant and manual. `terraform apply` SUCCEEDS with
#     the endpoint in Pending, so a green apply is not evidence the path works.
#     Verify with a DNS lookup from inside the VNet afterwards, then approval and
#     a TLS probe once Anyscale approves the connection.
###############################################################################

locals {
  privatelink_enabled = var.enable_privatelink

  # FQDNs that resolve to the endpoint, for the output in outputs.tf.
  # "*" produces the wildcard record *.<zone>; "@" is the apex.
  privatelink_record_fqdns = local.privatelink_enabled ? [
    for name in var.anyscale_privatelink_record_names :
    name == "@" ? var.anyscale_private_dns_zone_name : "${name}.${var.anyscale_private_dns_zone_name}"
  ] : []

  # Once the private zone is authoritative for the Anyscale cloud domain inside
  # the VNet, the firewall's outbound FQDN rules for that domain can never match:
  # the private endpoint IP is in-VNet, so the 0.0.0.0/0 route to the firewall
  # does not apply. Drop them so the allow-list keeps describing the real egress
  # surface rather than carrying an inert wildcard.
  #
  # Everything else stays: the public console/OAuth host, the API hosts, and
  # Anyscale's storage account all still egress through the firewall.
  privatelink_superseded_fqdn_suffixes = local.privatelink_enabled ? [
    var.anyscale_private_dns_zone_name,
  ] : []

  firewall_anyscale_fqdns = [
    for fqdn in var.anyscale_fqdns : fqdn
    if length([
      for suffix in local.privatelink_superseded_fqdn_suffixes : suffix
      if fqdn == suffix || endswith(fqdn, ".${suffix}")
    ]) == 0
  ]

  # Same filter for the jump-host list: Private Link is VNet-wide, so the jump
  # host reaches the Anyscale cloud domain over the endpoint too. The jump host
  # keeps the public console, API, login, and artifact destinations.
  firewall_anyscale_jump_host_fqdns = [
    for fqdn in var.anyscale_jump_host_fqdns : fqdn
    if length([
      for suffix in local.privatelink_superseded_fqdn_suffixes : suffix
      if fqdn == suffix || endswith(fqdn, ".${suffix}")
    ]) == 0
  ]

  # FQDNs the firewall no longer needs because Private Link supersedes them.
  # Exposed through the outputs.tf anyscale_privatelink output.
  privatelink_superseded_firewall_fqdns = [
    for fqdn in var.anyscale_fqdns : fqdn
    if !contains(local.firewall_anyscale_fqdns, fqdn)
  ]
}

###############################################################################
# Private endpoint against the Anyscale Private Link Service.
#
# `is_manual_connection = true` because this is a cross-tenant connection:
# Anyscale owns the service and must approve the request. The endpoint stays
# Pending -- and DNS records point at an IP that does not yet carry traffic --
# until they do.
###############################################################################
resource "azurerm_private_endpoint" "anyscale_control_plane" {
  count = local.privatelink_enabled ? 1 : 0

  name                = "pep-anyscale-cp-${local.suffix}"
  resource_group_name = local.resource_group_name
  location            = local.resource_group_location
  subnet_id           = local.net_subnet_ids.private_endpoints
  tags                = var.tags

  private_service_connection {
    name                              = "psc-anyscale-cp-${local.suffix}"
    private_connection_resource_alias = var.anyscale_privatelink_service_alias
    is_manual_connection              = true
    request_message                   = "Anyscale private AKS sample ${local.suffix}"
  }

  timeouts {
    delete = "15m"
  }
}

###############################################################################
# Private DNS zone linked to this VNet.
#
# Deliberately not part of module.dns / local.private_dns_zones: those zones are
# created unconditionally, and this one must follow enable_privatelink.
#
# No private_dns_zone_group on the endpoint above either -- that only works for
# Azure first-party resources whose zone layout the platform knows. For a
# third-party Private Link Service the records are ours to manage.
###############################################################################
resource "azurerm_private_dns_zone" "anyscale_control_plane" {
  count = local.privatelink_enabled ? 1 : 0

  name                = var.anyscale_private_dns_zone_name
  resource_group_name = local.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "anyscale_control_plane" {
  count = local.privatelink_enabled ? 1 : 0

  name                 = "link-anyscale-cp-${local.suffix}"
  private_dns_zone_id  = azurerm_private_dns_zone.anyscale_control_plane[0].id
  virtual_network_id   = local.net_vnet_id
  registration_enabled = false
  tags                 = var.tags
}

# Point the Anyscale hostnames at the private endpoint's NIC address.
resource "azurerm_private_dns_a_record" "anyscale_control_plane" {
  for_each = toset(local.privatelink_enabled ? var.anyscale_privatelink_record_names : [])

  name                = each.value
  private_dns_zone_id = azurerm_private_dns_zone.anyscale_control_plane[0].id
  ttl                 = 60
  records             = [azurerm_private_endpoint.anyscale_control_plane[0].private_service_connection[0].private_ip_address]
  tags                = var.tags
}
