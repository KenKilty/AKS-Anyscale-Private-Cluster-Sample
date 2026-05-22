variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "tags" {
  type = map(string)
}

variable "vnet_name" { type = string }
variable "vnet_address_space" { type = list(string) }

variable "subnet_cidrs" {
  type = object({
    firewall          = string
    bastion           = string
    aks_apiserver     = string
    dns_resolver_in   = string
    dns_resolver_out  = string
    private_endpoints = string
    aks_nodes         = string
    gateway           = optional(string)
  })
}

variable "subnet_names" {
  type = object({
    aks_nodes         = string
    aks_apiserver     = string
    dns_resolver_in   = string
    dns_resolver_out  = string
    private_endpoints = string
    firewall          = string
    bastion           = string
    gateway           = string
  })
}

variable "nsg_aks_nodes_name" { type = string }
variable "nsg_pe_name" { type = string }
