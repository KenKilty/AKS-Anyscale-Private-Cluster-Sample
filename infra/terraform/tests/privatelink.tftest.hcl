###############################################################################
# Plan-only tests for the optional Anyscale control plane Private Link, the
# operator/local control-plane URL split, and the image-integrity toggle.
#
# command = plan only: these do not call Azure. Per terraform.instructions.md,
# private-endpoint SUBNET placement is an apply-time property and is asserted in
# apply tests, not here. These prove the composition, the firewall FQDN
# filtering, variable validation, the URL split, and the image-integrity guards.
###############################################################################

variables {
  project        = "tftest"
  environment    = "ci"
  azure_location = "westus2"
  region_short   = "wus2"

  vnet_address_space = ["10.50.0.0/16"]
  subnet_cidrs = {
    firewall          = "10.50.0.0/26"
    bastion           = "10.50.0.128/26"
    aks_apiserver     = "10.50.1.0/28"
    dns_resolver_in   = "10.50.1.16/28"
    dns_resolver_out  = "10.50.1.32/28"
    private_endpoints = "10.50.2.0/24"
    jump_host         = "10.50.3.0/27"
    browser_jump_host = "10.50.3.32/27"
    aks_nodes         = "10.50.4.0/22"
  }

  dns_forwarding_rules = {}

  anyscale_fqdns = [
    "console.anyscale.com",
    "console.azure.anyscale.com",
    "api.azure.anyscale.com",
    "*.anyscale-cloud.dev",
    "*.azure.anyscale-cloud.dev",
    "*.az1.westus2.admin.azure.anyscale.com",
    "anyscaleazwestus2prod.blob.core.windows.net",
    "anyscaleazwestus2prod.dfs.core.windows.net",
    "api.anyscale.com",
    "anyscale-public.s3.us-west-2.amazonaws.com",
    "anyscale.com",
    "learn.microsoft.com",
  ]

  anyscale_jump_host_fqdns = [
    "console.azure.anyscale.com",
    "api.azure.anyscale.com",
    "*.azure.anyscale-cloud.dev",
    "anyscaleazwestus2prod.blob.core.windows.net",
  ]

  enable_browser_host = false

  container_registry_fqdns = [
    "mcr.microsoft.com",
    "*.data.mcr.microsoft.com",
    "ghcr.io",
    "*.ghcr.io",
    "pkg-containers.githubusercontent.com",
    "*.docker.io",
    "registry-1.docker.io",
    "auth.docker.io",
    "production.cloudflare.docker.com",
    "production.cloudfront.docker.com",
    "quay.io",
    "*.quay.io",
    "registry.k8s.io",
    "k8s.gcr.io",
    "gcr.io",
    "*.gcr.io",
    "*.pkg.dev",
    "us-docker.pkg.dev",
    "europe-docker.pkg.dev",
    "asia-docker.pkg.dev",
    "nvcr.io",
    "*.nvcr.io",
    "authn.nvidia.com",
    "arcmktplaceprod.azurecr.io",
    "*.data.azurecr.io",
    "prod-registry-k8s-io-us-west-1.s3.dualstack.us-west-1.amazonaws.com",
  ]

  system_vm_size                       = "Standard_D2s_v5"
  cpu_vm_size                          = "Standard_D16s_v5"
  linux_jump_host_vm_size              = "Standard_D2s_v5"
  linux_jump_host_admin_username       = "azureoperator"
  linux_jump_host_admin_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKbBsj5ktF3GEfYJ5G5O2CP658q5S7Lf4K3b4BVVij7F terraform-test"
  gpu_pool_configs = {
    T4 = {
      name         = "gput4"
      vm_size      = "Standard_NC16as_T4_v3"
      product_name = "NVIDIA-T4"
      gpu_count    = "1"
      min_count    = 1
      max_count    = 2
    }
  }

  kubernetes_version               = "1.34.6"
  service_cidr                     = "10.100.0.0/16"
  dns_service_ip                   = "10.100.0.10"
  anyscale_operator_namespace      = "anyscale-operator"
  anyscale_operator_serviceaccount = "anyscale-operator"
  anyscale_platform = {
    enabled = false
  }
  storage_cors_rule = {
    allowed_headers    = ["*"]
    allowed_methods    = ["GET", "POST", "PUT", "HEAD", "DELETE"]
    allowed_origins    = ["https://*.anyscale.com"]
    expose_headers     = ["Accept-Ranges", "Content-Range", "Content-Length"]
    max_age_in_seconds = 0
  }

  log_analytics_retention_days                  = 30
  terraform_managed_diagnostic_settings_enabled = true
  tags = {
    Project     = "tftest"
    Environment = "ci"
    ManagedBy   = "terraform"
    Owner       = "terraform-test"
  }
}

# Default (Private Link off): no endpoint, no private DNS, no records, and the
# firewall keeps the full Anyscale allow-list (nothing superseded).
run "privatelink_disabled_by_default" {
  command = plan

  assert {
    condition     = output.anyscale_privatelink.enabled == false
    error_message = "Private Link must be disabled by default."
  }

  assert {
    condition     = output.anyscale_privatelink.endpoint_id == null && output.anyscale_privatelink.private_ip == null && output.anyscale_privatelink.dns_zone == null
    error_message = "Disabled Private Link must not expose an endpoint, private IP, or zone."
  }

  assert {
    condition     = length(output.anyscale_privatelink.record_fqdns) == 0 && length(output.anyscale_privatelink.superseded_firewall_fqdns) == 0
    error_message = "Disabled Private Link must create no records and supersede no firewall FQDNs."
  }
}

# Enabled: endpoint/zone/records planned, wildcard + apex record FQDNs derived,
# and ONLY private-zone FQDNs removed from the firewall lists.
run "privatelink_enabled_plans_endpoint_and_filters_firewall" {
  command = plan

  variables {
    enable_privatelink                 = true
    anyscale_privatelink_service_alias = "sample.00000000-0000-0000-0000-000000000000.westus2.azure.privatelinkservice"
    anyscale_private_dns_zone_name     = "azure.anyscale-cloud.dev"
    anyscale_privatelink_record_names  = ["*", "@"]
  }

  assert {
    condition     = output.anyscale_privatelink.enabled == true && output.anyscale_privatelink.dns_zone == "azure.anyscale-cloud.dev"
    error_message = "Enabled Private Link must report enabled and the configured zone."
  }

  assert {
    condition     = contains(output.anyscale_privatelink.record_fqdns, "*.azure.anyscale-cloud.dev") && contains(output.anyscale_privatelink.record_fqdns, "azure.anyscale-cloud.dev")
    error_message = "Record FQDNs must include the wildcard and the apex (@) forms."
  }

  # Private-zone FQDNs are superseded (dropped from the firewall list).
  assert {
    condition     = contains(output.anyscale_privatelink.superseded_firewall_fqdns, "*.azure.anyscale-cloud.dev")
    error_message = "The private-zone wildcard must be superseded when Private Link is enabled."
  }

  # Public console, API, the generic parent domain, and Anyscale storage stay on
  # the firewall path -- only names under the private zone are removed.
  assert {
    condition     = !contains(output.anyscale_privatelink.superseded_firewall_fqdns, "console.azure.anyscale.com") && !contains(output.anyscale_privatelink.superseded_firewall_fqdns, "api.azure.anyscale.com") && !contains(output.anyscale_privatelink.superseded_firewall_fqdns, "*.anyscale-cloud.dev") && !contains(output.anyscale_privatelink.superseded_firewall_fqdns, "anyscaleazwestus2prod.blob.core.windows.net")
    error_message = "Only private-zone FQDNs may be superseded; public console/API/storage and the generic parent domain must remain."
  }
}

# Enabling without a service alias fails validation.
run "privatelink_requires_alias" {
  command = plan

  variables {
    enable_privatelink                 = true
    anyscale_privatelink_service_alias = ""
    anyscale_privatelink_record_names  = ["*"]
  }

  expect_failures = [
    var.anyscale_privatelink_service_alias,
  ]
}

# Enabling without record names fails validation.
run "privatelink_requires_record_names" {
  command = plan

  variables {
    enable_privatelink                 = true
    anyscale_privatelink_service_alias = "sample.00000000-0000-0000-0000-000000000000.westus2.azure.privatelinkservice"
    anyscale_privatelink_record_names  = []
  }

  expect_failures = [
    var.anyscale_privatelink_record_names,
  ]
}

# Operator control-plane URL is distinct from the public console/CLI host.
run "operator_control_plane_url_split" {
  command = plan

  variables {
    anyscale_platform = {
      enabled                    = true
      operator_control_plane_url = "https://cld-00000000000000000000000000.azure.anyscale-cloud.dev"
    }
  }

  assert {
    condition     = output.anyscale_platform_contract.operator_control_plane_url == "https://cld-00000000000000000000000000.azure.anyscale-cloud.dev"
    error_message = "The operator control plane URL must use the configured private host."
  }

  assert {
    condition     = output.anyscale_platform_contract.control_plane_url == "https://console.azure.anyscale.com"
    error_message = "The local CLI/teardown control plane URL must stay the public console host."
  }
}

# Without an operator override, the operator falls back to the public host.
run "operator_control_plane_url_defaults_to_public" {
  command = plan

  variables {
    anyscale_platform = {
      enabled = true
    }
  }

  assert {
    condition     = output.anyscale_platform_contract.operator_control_plane_url == output.anyscale_platform_contract.control_plane_url
    error_message = "With no override, the operator URL must fall back to the public control plane URL."
  }
}

# A non-URL operator control-plane host fails validation.
run "operator_control_plane_url_must_be_url" {
  command = plan

  variables {
    anyscale_platform = {
      enabled                    = true
      operator_control_plane_url = "not-a-url"
    }
  }

  expect_failures = [
    var.anyscale_platform,
  ]
}

# Image integrity disabled: the Ratify workload identity is not created, so the
# root ratify_client_id output is null (proxy for all its resources/RBAC being
# guarded off).
run "image_integrity_disabled_guards_resources" {
  command = plan

  variables {
    enable_image_integrity = false
  }

  assert {
    condition     = output.ratify_client_id == null
    error_message = "Disabling image integrity must produce a null Ratify client ID (no UAMI, no policy, no Ratify RBAC)."
  }
}
