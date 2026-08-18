variable "enabled" {
  type        = bool
  default     = true
  description = "Create the AKS Image Integrity (Ratify + Azure Policy) resources when true. Disable for deployments that do not run the image-signing demo, or when the deploying principal lacks Microsoft.Authorization/policyAssignments/write."
}

variable "resource_group_name" {
  type = string
}

variable "resource_group_id" {
  type = string
}

variable "location" {
  type = string
}

variable "name_suffix" {
  type = string
}

variable "oidc_issuer_url" {
  description = "AKS OIDC issuer URL used for the Ratify workload identity federated credential."
  type        = string
}

variable "tags" {
  type = map(string)
}
