###############################################################################
# Required Azure context
###############################################################################
variable "azure_subscription_id" {
  description = "Target Azure subscription ID."
  type        = string
}

variable "azure_tenant_id" {
  description = "Microsoft Entra (Azure AD) tenant ID."
  type        = string
}

###############################################################################
# Naming (CAF: https://learn.microsoft.com/azure/cloud-adoption-framework/ready/azure-best-practices/resource-abbreviations)
###############################################################################
variable "project" {
  description = "Short project / workload token (lowercase, no hyphens)."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9]{2,12}$", var.project))
    error_message = "project must be 2-12 lowercase alphanumeric characters."
  }
}

variable "environment" {
  description = "Environment short token (e.g. dev, test, prod)."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9]{2,6}$", var.environment))
    error_message = "environment must be 2-6 lowercase alphanumeric characters."
  }
}

variable "azure_location" {
  description = "Azure region (e.g. westus3)."
  type        = string
}

variable "region_short" {
  description = "Short region code used in resource names (e.g. wus3, wus2, eus2)."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9]{2,6}$", var.region_short))
    error_message = "region_short must be 2-6 lowercase alphanumeric characters."
  }
}

###############################################################################
# Networking
###############################################################################
variable "vnet_address_space" {
  description = "VNet CIDR list."
  type        = list(string)

  validation {
    condition     = length(var.vnet_address_space) > 0 && alltrue([for cidr in var.vnet_address_space : can(cidrhost(cidr, 0))])
    error_message = "vnet_address_space must contain at least one valid CIDR block."
  }
}

variable "subnet_cidrs" {
  description = <<-EOT
    Subnet CIDRs. AzureFirewallSubnet must be at least /26, AzureBastionSubnet must be at least /26,
    AKS API server delegated subnet must be at least /28 (Microsoft.ContainerService/managedClusters delegation).
  EOT
  type = object({
    firewall          = string
    bastion           = string
    aks_apiserver     = string
    dns_resolver_in   = string
    dns_resolver_out  = string
    private_endpoints = string
    aks_nodes         = string
  })

  validation {
    condition     = alltrue([for cidr in values(var.subnet_cidrs) : can(cidrhost(cidr, 0))])
    error_message = "All subnet_cidrs values must be valid CIDR blocks."
  }

  validation {
    condition     = tonumber(split("/", var.subnet_cidrs.firewall)[1]) <= 26 && tonumber(split("/", var.subnet_cidrs.bastion)[1]) <= 26 && tonumber(split("/", var.subnet_cidrs.aks_apiserver)[1]) <= 28 && tonumber(split("/", var.subnet_cidrs.dns_resolver_in)[1]) <= 28 && tonumber(split("/", var.subnet_cidrs.dns_resolver_out)[1]) <= 28
    error_message = "Firewall and Bastion subnets must be /26 or larger; AKS API server and DNS Private Resolver subnets must be /28 or larger."
  }
}

variable "dns_forwarding_rules" {
  description = <<-EOT
    Optional Azure DNS Private Resolver forwarding rules. Use this for enterprise/on-prem zones that AKS workloads must resolve.
    Map keys become Terraform rule names; domain_name should be a fully qualified DNS suffix ending in a dot, for example corp.contoso.com.
  EOT
  type = map(object({
    domain_name = string
    target_dns_servers = list(object({
      ip_address = string
      port       = number
    }))
  }))

  validation {
    condition     = alltrue([for rule in values(var.dns_forwarding_rules) : can(regex("^([A-Za-z0-9_-]+\\.)+$", rule.domain_name)) && length(rule.target_dns_servers) > 0])
    error_message = "Each dns_forwarding_rules domain_name must end in a dot and include at least one target DNS server."
  }

  validation {
    condition     = alltrue(flatten([for rule in values(var.dns_forwarding_rules) : [for server in rule.target_dns_servers : can(cidrhost("${server.ip_address}/32", 0)) && server.port > 0 && server.port <= 65535]]))
    error_message = "Each DNS forwarding target must use a valid IP address and TCP/UDP port."
  }
}

###############################################################################
# Anyscale FQDN allowlist (Azure Firewall application rules)
# Source: https://docs.anyscale.com/networking/overview#important-domains
# NOTE: Set these with TF_VAR_anyscale_fqdns in .env. Verify the starter list
# against the canonical Anyscale docs before using a long-lived environment.
###############################################################################
variable "anyscale_fqdns" {
  description = "List of FQDNs Anyscale operator/workloads need outbound (HTTPS:443)."
  type        = list(string)

  validation {
    condition     = length(var.anyscale_fqdns) > 0 && alltrue([for fqdn in var.anyscale_fqdns : can(regex("^(\\*\\.)?([A-Za-z0-9-]+\\.)+[A-Za-z]{2,}$", fqdn))])
    error_message = "anyscale_fqdns must contain valid FQDNs, optionally prefixed with *."
  }
}

variable "container_registry_fqdns" {
  description = "Public container registries permitted egress (in addition to private ACR via Private Link)."
  type        = list(string)

  validation {
    condition     = length(var.container_registry_fqdns) > 0 && alltrue([for fqdn in var.container_registry_fqdns : can(regex("^(\\*\\.)?([A-Za-z0-9-]+\\.)+[A-Za-z]{2,}$", fqdn))])
    error_message = "container_registry_fqdns must contain valid FQDNs, optionally prefixed with *."
  }
}

variable "azure_identity_fqdns" {
  description = "Microsoft identity and ARM endpoints permitted for AKS Workload Identity token exchange and Azure SDK/CLI data-plane auth flows."
  type        = list(string)
  default = [
    "login.microsoftonline.com",
    "*.login.microsoftonline.com",
    "sts.windows.net",
    "management.azure.com",
  ]

  validation {
    condition     = length(var.azure_identity_fqdns) > 0 && alltrue([for fqdn in var.azure_identity_fqdns : can(regex("^(\\*\\.)?([A-Za-z0-9-]+\\.)+[A-Za-z]{2,}$", fqdn))])
    error_message = "azure_identity_fqdns must contain valid FQDNs, optionally prefixed with *."
  }
}

variable "azure_monitor_fqdns" {
  description = "Azure Monitor, Log Analytics, and Azure Monitor Agent endpoints permitted for diagnostics and Container Insights when public egress fallback is required. AMPLS private endpoints are created separately."
  type        = list(string)
  default = [
    "global.handler.control.monitor.azure.com",
    "*.handler.control.monitor.azure.com",
    "global.prod.microsoftmetrics.com",
    "*.monitoring.azure.com",
    "*.ods.opinsights.azure.com",
    "*.oms.opinsights.azure.com",
    "*.agentsvc.azure-automation.net",
    "*.ingest.monitor.azure.com",
    "*.monitor.azure.com",
  ]

  validation {
    condition     = length(var.azure_monitor_fqdns) > 0 && alltrue([for fqdn in var.azure_monitor_fqdns : can(regex("^(\\*\\.)?([A-Za-z0-9-]+\\.)+[A-Za-z]{2,}$", fqdn))])
    error_message = "azure_monitor_fqdns must contain valid FQDNs, optionally prefixed with *."
  }
}

###############################################################################
# Compute / GPU
###############################################################################
variable "system_vm_size" {
  description = "VM size for the AKS system node pool."
  type        = string
}

variable "availability_zones" {
  description = "Availability zones used by zone-capable enterprise resources, including the AKS system/CPU pools and Premium ACR. GPU pools can override this per pool when a GPU SKU is non-zonal in the selected region."
  type        = list(string)
  default     = ["1", "2", "3"]

  validation {
    condition     = alltrue([for zone in var.availability_zones : can(regex("^[1-9][0-9]*$", zone))])
    error_message = "availability_zones must contain Azure zone numbers as strings, for example [\"1\", \"2\", \"3\"]."
  }
}

variable "aks_sku_tier" {
  description = "AKS control-plane SKU tier. Standard is recommended for production private clusters."
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Free", "Standard", "Premium"], var.aks_sku_tier)
    error_message = "aks_sku_tier must be one of Free, Standard, or Premium."
  }
}

variable "system_node_pool_min_count" {
  description = "Minimum nodes in the AKS system node pool. Use at least 3 with availability zones for enterprise HA."
  type        = number
  default     = 3

  validation {
    condition     = var.system_node_pool_min_count >= 1
    error_message = "system_node_pool_min_count must be at least 1."
  }
}

variable "system_node_pool_max_count" {
  description = "Maximum nodes in the AKS system node pool autoscaler."
  type        = number
  default     = 6

  validation {
    condition     = var.system_node_pool_max_count >= var.system_node_pool_min_count
    error_message = "system_node_pool_max_count must be greater than or equal to system_node_pool_min_count."
  }
}

variable "cpu_vm_size" {
  description = "VM size for the AKS user CPU node pool."
  type        = string
}

variable "gpu_pool_configs" {
  description = <<-EOT
    GPU node pool config(s). Map key is logical label (e.g. "T4").
    The sample .env is sized for a 32 vCPU NCASv3_T4 family quota in westus3 (max 2 nodes).
    Set availability_zones per pool only when the selected GPU SKU supports zones in the selected region.
    Use an empty map only for CPU-only or quota-safe validation scenarios.
  EOT
  type = map(object({
    name               = string
    vm_size            = string
    product_name       = string
    gpu_count          = string
    min_count          = number
    max_count          = number
    availability_zones = optional(list(string), [])
  }))

  validation {
    condition     = alltrue([for pool in values(var.gpu_pool_configs) : pool.min_count >= 1 && pool.max_count >= pool.min_count && can(regex("^[a-z][a-z0-9]{0,11}$", pool.name))])
    error_message = "Each configured GPU pool must have a valid AKS pool name, min_count >= 1, and max_count >= min_count."
  }

  validation {
    condition     = alltrue(flatten([for pool in values(var.gpu_pool_configs) : [for zone in pool.availability_zones : can(regex("^[1-9][0-9]*$", zone))]]))
    error_message = "GPU pool availability_zones must contain Azure zone numbers as strings when set. Leave empty for GPU SKUs that do not support zones in the selected region."
  }
}

variable "kubernetes_version" {
  description = "Kubernetes version. Pin an exact patch version for reproducible AKS node bootstrap behavior; null uses the regional default."
  type        = string
  nullable    = true

  validation {
    condition     = var.kubernetes_version == null || can(regex("^[0-9]+\\.[0-9]+(\\.[0-9]+)?$", var.kubernetes_version))
    error_message = "kubernetes_version must be null or a version string like 1.34.6."
  }
}

variable "service_cidr" {
  description = "Kubernetes service CIDR. Must not overlap node subnet."
  type        = string

  validation {
    condition     = can(cidrhost(var.service_cidr, 0))
    error_message = "service_cidr must be a valid CIDR block."
  }
}

variable "dns_service_ip" {
  description = "Kubernetes DNS service IP. Must be inside service_cidr."
  type        = string

  validation {
    condition     = can(cidrhost("${var.dns_service_ip}/32", 0))
    error_message = "dns_service_ip must be a valid IP address. It must also be inside service_cidr."
  }
}

variable "anyscale_operator_namespace" {
  description = "Kubernetes namespace where the Anyscale operator service account lives."
  type        = string
}

variable "anyscale_cli_token" {
  description = "Anyscale CLI token for the operator (global.auth.anyscaleCliToken). Stored as an AKS extension protected setting (encrypted at rest, not visible in az k8s-extension show). Leave null to install the extension without the secret; the operator will surface auth handshake failures until the token is provided."
  type        = string
  default     = null
  sensitive   = true
}

variable "anyscale_operator_serviceaccount" {
  description = "Kubernetes service account name for the Anyscale operator."
  type        = string
}

variable "anyscale_operator_identity" {
  description = <<-EOT
    Anyscale operator managed identity contract.

    Modes:
    - create: Terraform creates the user-assigned managed identity and assigns Storage Blob Data Contributor on the default storage container.
    - existing-managed-rbac: Terraform uses an existing user-assigned managed identity and assigns Storage Blob Data Contributor on the default storage container.
    - existing-external-rbac: Terraform uses an existing user-assigned managed identity and only outputs the expected Storage Blob Data Contributor scope for external RBAC validation.

    Existing identity modes require id, client_id, and principal_id from the user-assigned managed identity.
  EOT
  type = object({
    mode                = optional(string, "create")
    id                  = optional(string)
    client_id           = optional(string)
    principal_id        = optional(string)
    name                = optional(string)
    manage_storage_rbac = optional(bool)
  })
  default = {
    mode = "create"
  }
  validation {
    condition     = contains(["create", "existing-managed-rbac", "existing-external-rbac"], var.anyscale_operator_identity.mode)
    error_message = "anyscale_operator_identity.mode must be one of: create, existing-managed-rbac, existing-external-rbac."
  }

  validation {
    condition = var.anyscale_operator_identity.mode == "create" || (
      try(var.anyscale_operator_identity.id != null && var.anyscale_operator_identity.id != "", false) &&
      try(var.anyscale_operator_identity.client_id != null && var.anyscale_operator_identity.client_id != "", false) &&
      try(var.anyscale_operator_identity.principal_id != null && var.anyscale_operator_identity.principal_id != "", false)
    )
    error_message = "Existing Anyscale operator identity modes require id, client_id, and principal_id."
  }

  validation {
    condition = (
      var.anyscale_operator_identity.mode == "create" ? try(var.anyscale_operator_identity.manage_storage_rbac == null || var.anyscale_operator_identity.manage_storage_rbac == true, true) :
      var.anyscale_operator_identity.mode == "existing-managed-rbac" ? try(var.anyscale_operator_identity.manage_storage_rbac == null || var.anyscale_operator_identity.manage_storage_rbac == true, true) :
      var.anyscale_operator_identity.mode == "existing-external-rbac" ? try(var.anyscale_operator_identity.manage_storage_rbac == null || var.anyscale_operator_identity.manage_storage_rbac == false, true) : false
    )
    error_message = "anyscale_operator_identity.manage_storage_rbac must be true for create/existing-managed-rbac and false for existing-external-rbac when set."
  }
}

variable "anyscale_platform" {
  description = <<-EOT
    Terraform-managed Anyscale-on-Azure deployment settings.

    When enabled, Terraform keeps the Azure-native Anyscale cloud resources on
    the portal-exported AzAPI/ARM path, but manages the AKS marketplace
    extension natively with azurerm, wired to the existing AKS cluster,
    storage account, ACR, and operator UAMI.

    teardown is the established Azure cloud teardown hook. It terminates the
    current cloud's jobs, services, workspaces, and backing cluster sessions,
    then deletes the Anyscale cloud before Terraform tears down the AKS
    extension and cluster. destroy_workaround remains accepted as a legacy
    alias for compatibility.
  EOT

  type = object({
    enabled                          = optional(bool, true)
    cloud_name                       = optional(string)
    extension_resource_name          = optional(string, "anyscaleoperator")
    control_plane_url                = optional(string, "https://console.azure.anyscale.com")
    auth_audience                    = optional(string, "api://086bc555-6989-4362-ba30-fded273e432b/.default")
    extension_configuration_settings = optional(map(string), {})
    plan_name                        = optional(string, "anyscale-operator")
    plan_publisher                   = optional(string, "anyscale1750870039553")
    plan_product                     = optional(string, "anyscale-operator-aks")
    release_train                    = optional(string, "stable")
    tags_by_resource                 = optional(map(map(string)), {})
    teardown = optional(object({
      enabled                               = optional(bool, true)
      runtime_termination_timeout_seconds   = optional(number)
      workspace_termination_timeout_seconds = optional(number)
      poll_interval_seconds                 = optional(number, 20)
    }), {})
    destroy_workaround = optional(object({
      enabled                               = optional(bool, true)
      runtime_termination_timeout_seconds   = optional(number)
      workspace_termination_timeout_seconds = optional(number)
      poll_interval_seconds                 = optional(number, 20)
    }), {})
  })

  default = {}

  validation {
    condition     = var.anyscale_platform.cloud_name == null || can(regex("^[A-Za-z0-9._-]+$", var.anyscale_platform.cloud_name))
    error_message = "anyscale_platform.cloud_name may contain only letters, numbers, dots, underscores, and hyphens."
  }

  validation {
    condition     = can(regex("^[A-Za-z0-9-]+$", var.anyscale_platform.extension_resource_name))
    error_message = "anyscale_platform.extension_resource_name may contain only letters, numbers, and hyphens."
  }

  validation {
    condition = (
      try(var.anyscale_platform.teardown.runtime_termination_timeout_seconds, null) == null ||
      try(var.anyscale_platform.teardown.workspace_termination_timeout_seconds, null) == null ||
      try(var.anyscale_platform.teardown.runtime_termination_timeout_seconds, null) == try(var.anyscale_platform.teardown.workspace_termination_timeout_seconds, null)
    )
    error_message = "anyscale_platform.teardown.runtime_termination_timeout_seconds and workspace_termination_timeout_seconds must match when both are set."
  }

  validation {
    condition     = coalesce(try(var.anyscale_platform.teardown.runtime_termination_timeout_seconds, null), try(var.anyscale_platform.teardown.workspace_termination_timeout_seconds, null), try(var.anyscale_platform.destroy_workaround.runtime_termination_timeout_seconds, null), try(var.anyscale_platform.destroy_workaround.workspace_termination_timeout_seconds, null), 900) >= 60
    error_message = "anyscale_platform.teardown.runtime_termination_timeout_seconds must be at least 60 seconds. workspace_termination_timeout_seconds and destroy_workaround remain supported as legacy aliases."
  }

  validation {
    condition     = coalesce(try(var.anyscale_platform.teardown.poll_interval_seconds, null), try(var.anyscale_platform.destroy_workaround.poll_interval_seconds, null), 20) >= 5
    error_message = "anyscale_platform.teardown.poll_interval_seconds must be at least 5 seconds. destroy_workaround remains supported as a legacy alias."
  }
}

variable "cluster_bootstrap" {
  description = <<-EOT
    Terraform-managed Kubernetes bootstrap layer for the private AKS cluster.

    This stack uses a Bastion-backed local kubeconfig for the Kubernetes and
    Helm providers. Set kubeconfig_path to a kubeconfig generated by
    ./scripts/setup.sh kubeconfig-bastion before running terraform apply.
  EOT

  type = object({
    enabled                            = optional(bool, true)
    kubeconfig_path                    = optional(string)
    gpu_resources_namespace            = optional(string, "gpu-resources")
    nvidia_device_plugin_release_name  = optional(string, "nvidia-device-plugin")
    nvidia_device_plugin_chart_version = optional(string, "0.17.1")
    ingress_namespace                  = optional(string, "ingress-nginx")
    ingress_release_name               = optional(string, "ingress-nginx")
    ingress_chart_version              = optional(string, "4.12.1")
  })

  default = {}

  validation {
    condition     = try(var.cluster_bootstrap.kubeconfig_path == null || trim(var.cluster_bootstrap.kubeconfig_path) != "", true)
    error_message = "cluster_bootstrap.kubeconfig_path must be null or a non-empty path."
  }

  validation {
    condition = alltrue([
      can(regex("^[A-Za-z0-9.-]+$", var.cluster_bootstrap.gpu_resources_namespace)),
      can(regex("^[A-Za-z0-9.-]+$", var.cluster_bootstrap.nvidia_device_plugin_release_name)),
      can(regex("^[A-Za-z0-9.-]+$", var.cluster_bootstrap.ingress_namespace)),
      can(regex("^[A-Za-z0-9.-]+$", var.cluster_bootstrap.ingress_release_name)),
    ])
    error_message = "cluster_bootstrap namespaces and release names may contain only letters, numbers, dots, and hyphens."
  }

  validation {
    condition = alltrue([
      can(regex("^[0-9A-Za-z][0-9A-Za-z.+-]*$", var.cluster_bootstrap.nvidia_device_plugin_chart_version)),
      can(regex("^[0-9A-Za-z][0-9A-Za-z.+-]*$", var.cluster_bootstrap.ingress_chart_version)),
    ])
    error_message = "cluster_bootstrap chart versions must be explicit non-empty version strings."
  }
}

variable "storage_cors_rule" {
  description = "Blob CORS rule used by the Anyscale web UI for logs and object access workflows."
  type = object({
    allowed_headers    = list(string)
    allowed_methods    = list(string)
    allowed_origins    = list(string)
    expose_headers     = list(string)
    max_age_in_seconds = number
  })

  validation {
    condition     = length(var.storage_cors_rule.allowed_origins) > 0 && alltrue([for origin in var.storage_cors_rule.allowed_origins : can(regex("^https://", origin))]) && var.storage_cors_rule.max_age_in_seconds >= 0
    error_message = "storage_cors_rule must include HTTPS origins and a non-negative max_age_in_seconds."
  }
}

variable "storage_replication_type" {
  description = "Storage account replication type. ZRS is the default enterprise posture in zone-capable regions."
  type        = string
  default     = "ZRS"

  validation {
    condition     = contains(["LRS", "GRS", "RAGRS", "ZRS", "GZRS", "RAGZRS"], var.storage_replication_type)
    error_message = "storage_replication_type must be one of LRS, GRS, RAGRS, ZRS, GZRS, or RAGZRS."
  }
}

variable "acr_zone_redundancy_enabled" {
  description = "Whether the Premium ACR uses zone redundancy in zone-capable regions."
  type        = bool
  default     = true
}

###############################################################################
# Observability
###############################################################################
variable "log_analytics_retention_days" {
  description = "Log Analytics workspace retention (days)."
  type        = number

  validation {
    condition     = var.log_analytics_retention_days >= 30 && var.log_analytics_retention_days <= 730
    error_message = "log_analytics_retention_days must be between 30 and 730."
  }
}

variable "log_analytics_internet_ingestion_enabled" {
  description = "Whether the Log Analytics workspace accepts public ingestion. Set false when AMPLS private ingestion is enabled."
  type        = bool
  default     = false
}

variable "log_analytics_internet_query_enabled" {
  description = "Whether the Log Analytics workspace accepts public query traffic. Kept true by default so management workstations can run proof queries while cluster ingestion is private."
  type        = bool
  default     = true
}

variable "ampls_enabled" {
  description = "Whether to create Azure Monitor Private Link Scope, private endpoint, private DNS zone group, and scoped services for Container Insights/Log Analytics."
  type        = bool
  default     = true
}

variable "ampls_ingestion_access_mode" {
  description = "AMPLS ingestion access mode. PrivateOnly forces ingestion through connected private networks."
  type        = string
  default     = "PrivateOnly"

  validation {
    condition     = contains(["Open", "PrivateOnly"], var.ampls_ingestion_access_mode)
    error_message = "ampls_ingestion_access_mode must be Open or PrivateOnly."
  }
}

variable "ampls_query_access_mode" {
  description = "AMPLS query access mode. Open allows proof queries from public management workstations; PrivateOnly restricts queries to connected private networks."
  type        = string
  default     = "Open"

  validation {
    condition     = contains(["Open", "PrivateOnly"], var.ampls_query_access_mode)
    error_message = "ampls_query_access_mode must be Open or PrivateOnly."
  }
}

variable "container_insights_v2_enabled" {
  description = "Whether the Container Insights DCR sends stdout/stderr logs to ContainerLogV2."
  type        = bool
  default     = true
}

variable "container_insights_streams" {
  description = "Container Insights DCR streams. The default collects ContainerLogV2, Kubernetes events, and pod inventory without enabling Managed Prometheus/Grafana."
  type        = list(string)
  default     = ["Microsoft-ContainerLogV2", "Microsoft-KubeEvents", "Microsoft-KubePodInventory"]

  validation {
    condition     = length(var.container_insights_streams) > 0 && alltrue([for stream in var.container_insights_streams : can(regex("^Microsoft-[A-Za-z0-9-]+$", stream))])
    error_message = "container_insights_streams must contain Microsoft-* stream names."
  }
}

variable "container_insights_data_collection_interval" {
  description = "Container Insights data collection interval."
  type        = string
  default     = "1m"

  validation {
    condition     = can(regex("^([1-9]|[12][0-9]|30)m$", var.container_insights_data_collection_interval))
    error_message = "container_insights_data_collection_interval must be 1m through 30m."
  }
}

variable "container_insights_namespace_filtering_mode" {
  description = "Container Insights namespace filtering mode. Off collects all namespaces."
  type        = string
  default     = "Off"

  validation {
    condition     = contains(["Off", "Include", "Exclude"], var.container_insights_namespace_filtering_mode)
    error_message = "container_insights_namespace_filtering_mode must be Off, Include, or Exclude."
  }
}

variable "container_insights_namespaces" {
  description = "Namespaces used when Container Insights namespace filtering mode is Include or Exclude."
  type        = list(string)
  default     = []
}

variable "terraform_managed_diagnostic_settings_enabled" {
  description = "Whether Terraform creates Azure Monitor diagnostic settings for AKS, Firewall, ACR, Storage, and Bastion. Leave false when Azure Policy deploys diagnostics to avoid category/data-sink conflicts."
  type        = bool
  default     = true
}

variable "storage_diagnostic_settings_enabled" {
  description = "Whether Terraform creates Azure Monitor diagnostic settings for the storage account and blob service. When null, inherits terraform_managed_diagnostic_settings_enabled."
  type        = bool
  default     = null
}

###############################################################################
# Tags
###############################################################################
variable "tags" {
  description = "Tags applied to all taggable resources."
  type        = map(string)
}
