output "enabled" {
  description = "Whether the Image Integrity resources were created."
  value       = var.enabled
}

output "ratify_client_id" {
  description = "Client ID of the Ratify workload identity (null when disabled)."
  value       = one(azurerm_user_assigned_identity.ratify[*].client_id)
}

output "ratify_principal_id" {
  description = "Principal (object) ID of the Ratify workload identity (null when disabled)."
  value       = one(azurerm_user_assigned_identity.ratify[*].principal_id)
}

output "policy_assignment_id" {
  description = "ID of the Image Integrity policy assignment (null when disabled)."
  value       = one(azurerm_resource_group_policy_assignment.image_integrity[*].id)
}
