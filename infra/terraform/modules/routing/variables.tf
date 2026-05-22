variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "tags" {
  type = map(string)
}

variable "route_table_name" {
  type = string
}

variable "firewall_private_ip" {
  description = "Azure Firewall private IP — UDR next hop for all egress (0.0.0.0/0)."
  type        = string
}

variable "subnet_ids_to_associate" {
  description = "Map of subnet logical name -> subnet ID to associate with this route table."
  type        = map(string)
}

variable "p2s_client_address_prefixes" {
  description = "Optional P2S client address prefixes that should route back to the virtual network gateway."
  type        = list(string)
  default     = []
}
