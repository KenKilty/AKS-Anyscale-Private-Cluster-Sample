locals {
  anyscale_platform_enabled                  = var.anyscale_platform.enabled
  anyscale_platform_cloud_name               = coalesce(var.anyscale_platform.cloud_name, local.suffix)
  anyscale_platform_cloud_control_plane_name = "/subscriptions/${var.azure_subscription_id}/resourcegroups/${azurerm_resource_group.this.name}/providers/anyscale.platform/clouds/${local.anyscale_platform_cloud_name}"
  anyscale_platform_cloud_arm_id             = "${azurerm_resource_group.this.id}/providers/Anyscale.Platform/clouds/${local.anyscale_platform_cloud_name}"
  anyscale_platform_extension_name           = var.anyscale_platform.extension_resource_name
  anyscale_platform_extension_release_train  = contains(["stable", "preview"], lower(var.anyscale_platform.release_train)) ? title(lower(var.anyscale_platform.release_train)) : var.anyscale_platform.release_train
  anyscale_platform_destroy_workaround_enabled = coalesce(
    try(var.anyscale_platform.teardown.enabled, null),
    try(var.anyscale_platform.destroy_workaround.enabled, null),
    true,
  )
  anyscale_platform_destroy_workaround_runtime_timeout_seconds = coalesce(
    try(var.anyscale_platform.teardown.runtime_termination_timeout_seconds, null),
    try(var.anyscale_platform.teardown.workspace_termination_timeout_seconds, null),
    try(var.anyscale_platform.destroy_workaround.runtime_termination_timeout_seconds, null),
    try(var.anyscale_platform.destroy_workaround.workspace_termination_timeout_seconds, null),
    900,
  )
  anyscale_platform_destroy_workaround_poll_interval_seconds = coalesce(
    try(var.anyscale_platform.teardown.poll_interval_seconds, null),
    try(var.anyscale_platform.destroy_workaround.poll_interval_seconds, null),
    20,
  )
  anyscale_platform_destroy_workaround_runtime_objects = [
    "jobs",
    "services",
    "workspaces",
    "cluster_sessions",
  ]
  anyscale_platform_lifecycle_create_order = [
    "aks_cluster_and_bootstrap",
    "anyscale_cloud",
    "anyscale_extension",
  ]
  anyscale_platform_lifecycle_destroy_order = [
    "drain_jobs_services_workspaces_and_cluster_sessions",
    "delete_anyscale_cloud",
    "delete_anyscale_extension",
    "delete_aks_cluster",
  ]
  anyscale_platform_extension_dynamic_configuration_keys = [
    "global.cloudDeploymentId",
    "global.controlPlaneURL",
    "global.auth.iamIdentity",
    "global.auth.audience",
    "workloads.serviceAccount.name",
  ]
  anyscale_platform_extension_configuration_defaults = {
    "workloads.accelerator.tolerations.default[0].key"      = "node.anyscale.com/accelerator-type"
    "workloads.accelerator.tolerations.default[0].value"    = "GPU"
    "workloads.accelerator.tolerations.default[0].effect"   = "NoSchedule"
    "workloads.accelerator.tolerations.default[1].key"      = "nvidia.com/gpu"
    "workloads.accelerator.tolerations.default[1].operator" = "Exists"
    "workloads.accelerator.tolerations.default[1].effect"   = "NoSchedule"
    "workloads.instanceTypes.enableDefaults"                = "true"
  }
  anyscale_platform_extension_configuration_settings = merge(
    local.anyscale_platform_extension_configuration_defaults,
    var.anyscale_platform.extension_configuration_settings,
  )
  anyscale_platform_deployments = {
    top_level    = "dep-anyscale-${local.suffix}"
    blob         = "dep-anyblob-${local.suffix}"
    fic          = "dep-anyfic-${local.suffix}"
    storage_rbac = "dep-anystoragerbac-${local.suffix}"
    acr_rbac     = "dep-anyacrrbac-${local.suffix}"
  }
}


# The Anyscale portal still exports the cloud resource path as an ARM template.
# Keep that contract intact with AzAPI, but manage the AKS marketplace
# extension natively with azurerm to shrink the generic AzAPI surface.
resource "azapi_resource" "anyscale_platform" {
  count = local.anyscale_platform_enabled ? 1 : 0

  type                      = "Microsoft.Resources/deployments@2022-09-01"
  name                      = local.anyscale_platform_deployments.top_level
  parent_id                 = azurerm_resource_group.this.id
  schema_validation_enabled = false
  response_export_values = {
    cloud_deployment_id = "properties.outputs.cloudResourceId.value"
    provisioning_state  = "properties.provisioningState"
  }
  body = {
    properties = {
      mode     = "Incremental"
      template = jsondecode(file("${path.module}/templates/anyscale-platform-cloud.template.json"))
      parameters = {
        location = {
          value = azurerm_resource_group.this.location
        }
        cloudName = {
          value = local.anyscale_platform_cloud_name
        }
        storageAccountName = {
          value = module.storage.storage_account_name
        }
        storageMode = {
          value = "existing"
        }
        storageAccountResourceId = {
          value = module.storage.storage_account_id
        }
        storageContainerName = {
          value = module.storage.container_name
        }
        workloadIdentityName = {
          value = module.identity.name
        }
        identityMode = {
          value = "existing"
        }
        identityResourceId = {
          value = module.identity.id
        }
        tagsByResource = {
          value = var.anyscale_platform.tags_by_resource
        }
        acrMode = {
          value = "existing"
        }
        acrName = {
          value = module.acr.acr_name
        }
        acrResourceId = {
          value = module.acr.acr_id
        }
        aksKubeletPrincipalId = {
          value = module.aks.kubelet_identity_object_id
        }
        manageAksKubeletAcrPullRoleAssignment = {
          value = false
        }
        storageBlobServiceDeploymentName = {
          value = local.anyscale_platform_deployments.blob
        }
        federatedIdentityDeploymentName = {
          value = local.anyscale_platform_deployments.fic
        }
        storageRoleAssignmentDeploymentName = {
          value = local.anyscale_platform_deployments.storage_rbac
        }
        acrRoleAssignmentsDeploymentName = {
          value = local.anyscale_platform_deployments.acr_rbac
        }
      }
    }
  }

  lifecycle {
    precondition {
      condition     = var.cluster_bootstrap.enabled
      error_message = "Anyscale platform deployment requires cluster_bootstrap.enabled=true so Terraform pre-creates the operator service account and baseline Helm bootstrap layer before the native AKS marketplace extension runs."
    }
  }

  depends_on = [
    module.aks,
    module.cluster_bootstrap,
    module.storage,
    module.identity,
    module.acr,
  ]
}

resource "azurerm_kubernetes_cluster_extension" "anyscale_operator" {
  count = local.anyscale_platform_enabled ? 1 : 0

  name              = local.anyscale_platform_extension_name
  cluster_id        = module.aks.cluster_id
  extension_type    = "Anyscale.AKS.Operator"
  release_train     = local.anyscale_platform_extension_release_train
  release_namespace = var.anyscale_operator_namespace

  plan {
    name      = var.anyscale_platform.plan_name
    publisher = var.anyscale_platform.plan_publisher
    product   = var.anyscale_platform.plan_product
  }

  configuration_settings = merge(
    {
      "global.cloudDeploymentId"      = azapi_resource.anyscale_platform[0].output.cloud_deployment_id
      "global.controlPlaneURL"        = var.anyscale_platform.control_plane_url
      "global.auth.iamIdentity"       = module.identity.client_id
      "global.auth.audience"          = var.anyscale_platform.auth_audience
      "workloads.serviceAccount.name" = var.anyscale_operator_serviceaccount
    },
    local.anyscale_platform_extension_configuration_settings,
  )

  configuration_protected_settings = var.anyscale_cli_token == null ? {} : {
    "global.auth.anyscaleCliToken" = var.anyscale_cli_token
  }

  # Keep the cloud-to-extension edge explicit even though
  # global.cloudDeploymentId already creates an implicit dependency. The
  # teardown hook handles the non-inverse delete requirement by deleting the
  # cloud before Terraform tears down the extension and AKS cluster.
  depends_on = [
    azapi_resource.anyscale_platform,
    module.cluster_bootstrap,
  ]
}

# Azure cloud teardown hook: while the cloud, extension, AKS backing
# resources, and private-link dependencies still exist, drain Anyscale jobs,
# services, workspaces, and cluster sessions, then delete the cloud before
# Terraform proceeds to extension, AKS, private endpoint, DNS, and network
# teardown.
resource "terraform_data" "anyscale_platform_destroy_workaround" {
  count = local.anyscale_platform_enabled && local.anyscale_platform_destroy_workaround_enabled ? 1 : 0

  input = {
    repo_root             = abspath("${path.root}/../..")
    anyscale_host         = var.anyscale_platform.control_plane_url
    anyscale_cli_token    = var.anyscale_cli_token
    anyscale_cloud_name   = local.anyscale_platform_cloud_control_plane_name
    anyscale_cloud_arm_id = local.anyscale_platform_cloud_arm_id
    azure_subscription_id = var.azure_subscription_id
    timeout_seconds       = local.anyscale_platform_destroy_workaround_runtime_timeout_seconds
    poll_interval_seconds = local.anyscale_platform_destroy_workaround_poll_interval_seconds
  }

  provisioner "local-exec" {
    when        = destroy
    working_dir = self.input.repo_root
    command     = "./scripts/lib/anyscale-cloud-teardown.sh --timeout-seconds ${self.input.timeout_seconds} --poll-interval-seconds ${self.input.poll_interval_seconds}"

    environment = {
      ANYSCALE_HOST         = self.input.anyscale_host
      ANYSCALE_CLI_TOKEN    = self.input.anyscale_cli_token
      ANYSCALE_CLOUD_NAME   = self.input.anyscale_cloud_name
      ANYSCALE_CLOUD_ARM_ID = self.input.anyscale_cloud_arm_id
      AZURE_SUBSCRIPTION_ID = self.input.azure_subscription_id
    }
  }

  depends_on = [
    azapi_resource.anyscale_platform,
    azurerm_kubernetes_cluster_extension.anyscale_operator,
    module.acr,
    module.aks,
    module.bastion,
    module.cluster_bootstrap,
    module.dns,
    module.dns_resolver,
    module.firewall,
    module.identity,
    module.network,
    module.observability,
    module.routing,
    module.storage,
  ]
}
