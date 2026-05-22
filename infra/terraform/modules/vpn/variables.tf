variable "enabled" {
  description = "Whether this module creates the Azure VPN Gateway resources."
  type        = bool
  default     = false
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "tags" {
  type = map(string)
}

variable "gateway_name" {
  type = string
}

variable "pip_name" {
  type = string
}

variable "subnet_id" {
  description = "ID of the GatewaySubnet used by the Azure VPN Gateway."
  type        = string
  default     = null
}

variable "sku" {
  description = "Azure VPN Gateway SKU."
  type        = string
}

variable "client_address_space" {
  description = "Address pools assigned to P2S clients."
  type        = list(string)
}

variable "trusted_root_certificates" {
  description = "Trusted root certificates for certificate-auth P2S VPN. Public cert data only."
  type = list(object({
    name             = string
    public_cert_data = string
  }))
}

variable "client_dns_servers" {
  description = "DNS servers intended for VPN client profile generation or post-processing."
  type        = list(string)
  default     = []
}