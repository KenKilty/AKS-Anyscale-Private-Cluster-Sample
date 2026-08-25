variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "tags" {
  type = map(string)
}

variable "name" {
  type = string
  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9-]{1,22}[a-zA-Z0-9]$", var.name))
    error_message = "Key Vault name must be 3-24 chars, start with a letter, end alphanumeric, and contain only letters, digits, and hyphens."
  }
}

variable "tenant_id" {
  type = string
}

variable "pe_subnet_id" {
  type = string
}

variable "pe_dns_zone_id" {
  type = string
}

variable "public_network_access_enabled" {
  description = "Optionally allow configured IPv4 CIDRs to reach the vault public endpoint through network_acls. Secure default false keeps the vault reachable through the private endpoint only."
  type        = bool
  default     = false
}

variable "public_network_access_ip_rules" {
  description = "IPv4 CIDRs allowed through the vault firewall when public_network_access_enabled is true. Secure default empty."
  type        = set(string)
  default     = []

  validation {
    condition = (
      !var.public_network_access_enabled && length(var.public_network_access_ip_rules) == 0
      ) || (
      var.public_network_access_enabled &&
      length(var.public_network_access_ip_rules) > 0 &&
      alltrue([
        for rule in var.public_network_access_ip_rules :
        can(cidrhost(rule, 0)) && can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$", rule))
      ])
    )
    error_message = "public_network_access_ip_rules must be empty when public access is disabled, or contain valid IPv4 CIDRs when enabled."
  }
}

variable "purge_protection_enabled" {
  description = "Enable purge protection. Recommended true for production; defaults false to keep the sample easy to tear down."
  type        = bool
  default     = false
}

variable "soft_delete_retention_days" {
  type    = number
  default = 7
}
