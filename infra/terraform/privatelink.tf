###############################################################################
# Azure Private Link to the Anyscale control plane.
#
# Moves control-plane traffic off the public-internet egress path. Without this,
# nodes reach `*.azure.anyscale-cloud.dev` outbound through Azure Firewall
# application rules (see modules/firewall, collection "anyscale", priority 400).
# With it, the hostnames resolve to a private endpoint inside the VNet and never
# leave it.
#
# Ported from
# terraform-kubernetes-anyscale-foundation-modules/examples/azure/aks-private-cluster/privatelink.tf
# to keep both repositories on one contract and one runbook.
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
#     than an enumeration of hostnames.
#
#   * The connection is cross-tenant and manual. `terraform apply` SUCCEEDS with
#     the endpoint in Pending, so a green apply is not evidence the path works.
#     Verify with a DNS lookup from inside the cluster afterwards.
###############################################################################

locals {
  privatelink_enabled = var.enable_privatelink

  # FQDNs that resolve to the endpoint, for the output below.
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
  # Everything else in anyscale_fqdns (console/api hosts, Anyscale's storage
  # account, the S3 asset bucket) still egresses through the firewall and stays.
  #
  # The generic parent domain `*.anyscale-cloud.dev` is KEPT only because it is
  # not under the Azure-specific zone -- not because anything needs it. Its sole
  # reference in this repo is scripts/setup.sh:5590, which resolves the generic
  # host to harvest IPs; every connection then uses the azure host as SNI
  # (setup.sh:5610) and CoreDNS only ever aliases the azure host (setup.sh:5632).
  # Application rules govern HTTPS connections, not DNS lookups -- those go to the
  # firewall DNS proxy on 53 -- so the entry is not what makes that resolution
  # work either. Anyscale's own required-egress list
  # (docs/Implementation-Notes.md:107-111) is entirely azure-prefixed.
  #
  # It is therefore a safe candidate for removal from var.anyscale_fqdns. Left in
  # place because the operator is a closed binary and this repo cannot prove no
  # other consumer exists.
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
  # host reaches the Anyscale cloud domain over the endpoint too.
  firewall_anyscale_jump_host_fqdns = [
    for fqdn in var.anyscale_jump_host_fqdns : fqdn
    if length([
      for suffix in local.privatelink_superseded_fqdn_suffixes : suffix
      if fqdn == suffix || endswith(fqdn, ".${suffix}")
    ]) == 0
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

  name                  = "link-anyscale-cp-${local.suffix}"
  resource_group_name   = local.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.anyscale_control_plane[0].name
  virtual_network_id    = local.net_vnet_id
  registration_enabled  = false
  tags                  = var.tags
}

# Point the Anyscale hostnames at the private endpoint's NIC address.
resource "azurerm_private_dns_a_record" "anyscale_control_plane" {
  for_each = toset(local.privatelink_enabled ? var.anyscale_privatelink_record_names : [])

  name                = each.value
  zone_name           = azurerm_private_dns_zone.anyscale_control_plane[0].name
  resource_group_name = local.resource_group_name
  ttl                 = 60
  records             = [azurerm_private_endpoint.anyscale_control_plane[0].private_service_connection[0].private_ip_address]
  tags                = var.tags
}

###############################################################################
# Outputs
###############################################################################
output "anyscale_privatelink" {
  description = <<-EOT
    Anyscale control plane Private Link state, DNS records, and the firewall
    FQDNs it supersedes.

    The cross-tenant approval status is deliberately absent: azurerm does not
    export it on azurerm_private_endpoint, and Terraform would report a stale
    value if it did. Check it against Azure directly:

      az network private-endpoint-connection list --id <endpoint_id> -o table
  EOT
  value = {
    enabled      = local.privatelink_enabled
    endpoint_id  = try(azurerm_private_endpoint.anyscale_control_plane[0].id, null)
    private_ip   = try(azurerm_private_endpoint.anyscale_control_plane[0].private_service_connection[0].private_ip_address, null)
    dns_zone     = local.privatelink_enabled ? var.anyscale_private_dns_zone_name : null
    record_fqdns = local.privatelink_record_fqdns

    superseded_firewall_fqdns = [
      for fqdn in var.anyscale_fqdns : fqdn
      if !contains(local.firewall_anyscale_fqdns, fqdn)
    ]
  }
}
