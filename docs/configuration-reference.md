# Configuration Reference

This document is the current-state configuration reference for the private
Anyscale on AKS sample. Operator steps are in the [README](../README.md), and
maintainer commands are in [Maintainer Workflows](maintainer-workflows.md).

## Architecture Invariants

- The Anyscale platform control plane is managed outside the customer
  subscription. The private data plane runs on customer-owned AKS, storage,
  ACR, identities, and networking.
- AKS, Blob/DFS storage, ACR, Key Vault, Azure Monitor ingestion, workspace
  endpoints, and service endpoints use private networking.
- AKS API access is private. Workstation access uses Azure Bastion; in-VNet
  operations use the Linux jump host. The optional Windows browser jump host
  provides browser access to private workspace and service hostnames.
- AKS and jump-host default routes use Azure Firewall. Anyscale control-plane,
  Microsoft identity, monitoring, registry, and tool-bootstrap traffic is
  permitted through explicit firewall egress rules.
- The AKS cluster uses Azure CNI, Azure network policy, Standard Load Balancer,
  `userDefinedRouting`, OIDC, Workload Identity, Entra-backed Kubernetes RBAC,
  and a private API-server integration subnet.
- Workspace and service traffic enters through an internal AKS Application
  Routing Gateway API implementation with
  `gatewayClassName: approuting-istio`.
- AKS pulls from private ACR with kubelet identity `AcrPull`. The Anyscale
  operator identity uses workload identity and Azure RBAC; registry passwords
  are not part of the cluster contract.
- Terraform runs from the operator workstation. The Linux jump host owns
  private post-configuration, image build and push, and proof submission that
  requires private storage DNS.
- Ray cluster authentication is owned by the Anyscale platform. Ray token
  authentication (`RAY_AUTH_MODE=token`) targets self-managed Ray such as
  `ray start`, `ray up`, and KubeRay; this sample runs no self-managed Ray, so
  the variable is intentionally unset. Browser access to a workspace or Ray
  dashboard goes through the Anyscale `cluster_auth` relay. The direct
  `head open` dashboard fallback bypasses that relay, and its boundary is the
  private AKS API, Entra-backed Kubernetes RBAC, and a localhost-only
  port-forward rather than a Ray-layer token.

Reference architecture sources:

- [Anyscale on Azure architecture](https://learn.microsoft.com/azure/anyscale-on-azure/architecture)
- [Anyscale on Azure networking](https://learn.microsoft.com/azure/anyscale-on-azure/networking)
- [Anyscale on Azure identity and access](https://learn.microsoft.com/azure/anyscale-on-azure/identity-access)
- [AKS private clusters](https://learn.microsoft.com/azure/aks/private-clusters)
- [AKS outbound traffic through Azure Firewall](https://learn.microsoft.com/azure/aks/limit-egress-traffic)
- [Ray token authentication](https://docs.ray.io/en/latest/ray-security/token-auth.html)

## Input Contract

The ignored repo-root `.env` is the only deployment input file. Copy
`.env-template` to `.env`, then set every declared `TF_VAR_*` key. The quality
gate compares variable names in `.env-template`, `.env`, and
`infra/terraform/variables.tf`; root variables intentionally have no Terraform
defaults.

- `ARM_*` selects Azure provider authentication.
- `TF_VAR_azure_subscription_id` and `TF_VAR_azure_tenant_id` select the target
  subscription and tenant. Keep them aligned with `ARM_*` unless the auth and
  target contexts are intentionally different.
- Every root Terraform variable is represented by a `TF_VAR_*` entry.
- Harness-only values such as `ANYSCALE_HOST`, `ANYSCALE_CLOUD_NAME`,
  `ANYSCALE_CLOUD_DEPLOYMENT_ID`, and custom-image settings are not Terraform
  inputs.
- Lists, maps, objects, booleans, numbers, and `null` values use Terraform JSON
  syntax inside shell strings.
- Secrets stay in `.env` or an approved credential store. Terraform state,
  `.tfvars` files, generated results, and `.cache/` artifacts are not source
  inputs.

The local Anyscale CLI normally uses cached OAuth after:

```bash
ANYSCALE_HOST=https://console.azure.anyscale.com .venv/bin/anyscale login
```

`ANYSCALE_CLI_TOKEN` is reserved for non-interactive protected settings and
remote execution where the local OAuth cache is unavailable.

## Resource Naming

`infra/terraform/locals.tf` owns names. The standard suffix is
`${project}-${environment}-${region_short}`; alphanumeric-only resources use
`${project}${environment}${region_short}`. `global_name_suffix` adds up to six
lowercase alphanumeric characters to globally unique names.

| Resource | Pattern |
| --- | --- |
| Resource group | `rg-${project}-${environment}-${region_short}` |
| VNet | `vnet-${project}-${environment}-${region_short}` |
| AKS | `aks-${project}-${environment}-${region_short}` |
| Linux jump host | `vm-jump-${project}-${environment}-${region_short}` |
| Windows browser jump host | `vmbrw${project}${environment}${region_short}`, truncated to 15 characters |
| Storage account | `st${project}${environment}${region_short}${global_name_suffix}`, truncated to 24 characters |
| ACR | `cr${project}${environment}${region_short}${global_name_suffix}`, truncated to 50 characters |
| Key Vault | `kv-${project}-${environment}-${region_short}` plus the optional suffix, truncated to 24 characters |

Use the canonical Terraform outputs `browser_jump_host_enabled`,
`browser_jump_host_vm_id`, `browser_jump_host_vm_name`,
`browser_jump_host_private_ip`, `browser_jump_host_admin_username`, and
`browser_jump_host_admin_password_secret`.

## Terraform and Provider Contract

- Terraform version: `>= 1.9.0`.
- AzureRM provider: `~> 5.2`, locked at `5.2.0`.
- AzAPI provider: `~> 2.12`, locked at `2.12.0`.
- Random provider: `~> 3.6`.
- Child modules declare provider requirements and inherit root provider
  configurations.
- AKS uses `node_provisioning_profile { mode = "Manual" }` and
  `api_server_access_profile.virtual_network_integration_enabled = true`.
- GPU pools set `gpu_driver = "Install"` explicitly.
- Federated identity credentials use `user_assigned_identity_id`.
- The Anyscale extension uses
  `azurerm_kubernetes_cluster_extension`. When `extension_version` is set,
  `release_train` is `null`; otherwise the configured release train is used.
- AKS Application Routing Gateway API is enabled by
  `azapi_update_resource` against
  `Microsoft.ContainerService/managedClusters@2026-03-02-preview`. Create and
  update timeouts are one hour because the managed-cluster reconciliation is
  long-running.
- The Anyscale cloud and default cloud resource use the ARM API version set by
  `TF_VAR_anyscale_platform_arm_api_version`, currently `2026-08-01-preview`.
  `.env` is the source of truth: `anyscale.tf` interpolates it into the platform
  ARM template and passes it to the teardown hook. Bumping it also requires
  updating the pinned assertion in `infra/terraform/tests/plan.tftest.hcl` and
  the fallback default in `scripts/lib/anyscale-cloud-teardown.sh`. Confirm a
  candidate version is offered by the provider first:
  `az provider show --namespace Anyscale.Platform --query "resourceTypes[?resourceType=='clouds'].apiVersions | [0]" -o tsv`.

## Deployment Profiles and Optional Features

The harness has two execution profiles:

| Profile | Contract |
| --- | --- |
| `workstation` | Runs Terraform, Azure checks, and Bastion-backed private AKS access from the operator workstation. |
| `jump-host` | Runs module 3, proof, and custom-image operations inside the VNet with direct private DNS and AKS access. Terraform does not run here. |

Anyscale compute configurations use `cpu` and `gpu` profiles. Heads run on the
CPU pool. GPU workers select `agentpool: gput4`, request `GPU: 1`, and tolerate
the GPU, accelerator-type, and capacity-type taints. A `mixed` renderer exists
for a combined CPU/GPU compute configuration; the durable workspace flow uses
the separate `cpu` and `gpu` profiles.

| Feature | Input | Current contract |
| --- | --- | --- |
| Windows browser jump host | `enable_browser_host` | Creates the VM, subnet rules, login RBAC, and optional Key Vault password fallback. |
| Anyscale control-plane Private Link | `enable_privatelink` | Creates a manual cross-tenant private endpoint, private DNS zone, VNet link, and records. |
| Image integrity | `enable_image_integrity` | Creates Ratify identity/RBAC and Azure Policy resources. |
| Service HTTPS listener | `bootstrap_k8s.gateway_service_https_enabled` | Adds the service listener only when the service TLS secret is available. |
| GPU capacity | `gpu_pool_configs` | A map of AKS pool names, SKUs, labels, counts, and optional zones; an empty map is CPU-only. |
| AMPLS | `ampls_enabled` | Creates Azure Monitor Private Link Scope and its private endpoint/DNS integration. |
| Terraform diagnostics | `terraform_managed_diagnostic_settings_enabled` | Creates diagnostic settings unless another owner supplies them. |
| Storage diagnostics | `storage_diagnostic_settings_enabled` | Controls storage diagnostics independently. |
| Platform resources | `anyscale_platform.enabled` | Controls the Anyscale cloud, cloud resource, AKS extension, and platform role assignments. |

## Network and Firewall Egress

The VNet contains dedicated subnets for Azure Firewall, Azure Bastion, AKS API
server integration, DNS Private Resolver inbound and outbound endpoints,
private endpoints, AKS nodes, the Linux jump host, and the Windows browser jump
host. The workload VNet uses Azure Firewall DNS proxy. A UDR sends default
traffic from AKS and both jump-host subnets to the firewall.

The `.env-template` firewall lists are the maintained starting point:

- `anyscale_fqdns`: `console.anyscale.com`,
  `console.azure.anyscale.com`, `api.azure.anyscale.com`,
  `*.anyscale-cloud.dev`, `*.azure.anyscale-cloud.dev`,
  `*.az1.westus2.admin.azure.anyscale.com`,
  `anyscaleazwestus2prod.blob.core.windows.net`,
  `anyscaleazwestus2prod.dfs.core.windows.net`, `api.anyscale.com`,
  `anyscale-public.s3.us-west-2.amazonaws.com`, `anyscale.com`, and
  `learn.microsoft.com`.
- `anyscale_jump_host_fqdns`: empty. The firewall module falls back to
  `anyscale_fqdns`; set a non-empty list to narrow Linux jump-host Anyscale
  destinations independently.
- `azure_identity_fqdns`: `login.microsoftonline.com`,
  `*.login.microsoftonline.com`, `sts.windows.net`, and
  `management.azure.com`.
- `azure_portal_fqdns`: `login.microsoft.com`,
  `login.microsoftonline.com`, `login.live.com`,
  `*.aadcdn.msftauth.net`, `*.aadcdn.msftauthimages.net`,
  `*.aadcdn.msauthimages.net`, `*.logincdn.msftauth.net`, `*.msauth.net`,
  `*.aadcdn.microsoftonline-p.com`, `*.microsoftonline-p.com`,
  `portal.azure.com`, `*.portal.azure.com`, `*.hosting.portal.azure.net`,
  `*.hosting-ms.portal.azure.net`, `*.reactblade.portal.azure.net`,
  `management.azure.com`, `*.ext.azure.com`, `*.graph.windows.net`,
  `*.graph.microsoft.com`, and `hosting.partners.azure.net`.
- `azure_monitor_fqdns`: `global.handler.control.monitor.azure.com`,
  `*.handler.control.monitor.azure.com`,
  `global.prod.microsoftmetrics.com`, `*.monitoring.azure.com`,
  `*.ods.opinsights.azure.com`, `*.oms.opinsights.azure.com`,
  `*.agentsvc.azure-automation.net`, `*.ingest.monitor.azure.com`, and
  `*.monitor.azure.com`.
- `container_registry_fqdns`: `mcr.microsoft.com`,
  `*.data.mcr.microsoft.com`, `ghcr.io`, `*.ghcr.io`,
  `pkg-containers.githubusercontent.com`, `*.docker.io`,
  `registry-1.docker.io`, `auth.docker.io`,
  `production.cloudflare.docker.com`, `production.cloudfront.docker.com`,
  `quay.io`, `*.quay.io`, `registry.k8s.io`, `k8s.gcr.io`, `gcr.io`,
  `*.gcr.io`, `*.pkg.dev`, `us-docker.pkg.dev`,
  `europe-docker.pkg.dev`, `asia-docker.pkg.dev`, `nvcr.io`, `*.nvcr.io`,
  `authn.nvidia.com`, `arcmktplaceprod.azurecr.io`, `*.data.azurecr.io`,
  `prod-registry-k8s-io-us-west-1.s3.dualstack.us-west-1.amazonaws.com`,
  `prod-registry-k8s-io-us-east-1.s3.dualstack.us-east-1.amazonaws.com`,
  `prod-registry-k8s-io-us-east-2.s3.dualstack.us-east-2.amazonaws.com`,
  `prod-registry-k8s-io-eu-west-1.s3.dualstack.eu-west-1.amazonaws.com`,
  `prod-registry-k8s-io-ap-northeast-1.s3.dualstack.ap-northeast-1.amazonaws.com`,
  and
  `prod-registry-k8s-io-ap-southeast-1.s3.dualstack.ap-southeast-1.amazonaws.com`.
- `tool_bootstrap_fqdns`: `packages.microsoft.com`, `aka.ms`,
  `azurecliprod.blob.core.windows.net`, `azcliprod.blob.core.windows.net`,
  `azcliextensionsync.blob.core.windows.net`, `azure.archive.ubuntu.com`,
  `security.ubuntu.com`, `apt.releases.hashicorp.com`, `dl.k8s.io`,
  `cdn.dl.k8s.io`, `get.helm.sh`, `astral.sh`, `releases.astral.sh`,
  `pypi.org`, `files.pythonhosted.org`, `github.com`, `api.github.com`,
  `*.githubusercontent.com`, and `nvidia.github.io`.

When Private Link is enabled, names under
`anyscale_private_dns_zone_name` are removed from both effective Anyscale
firewall lists. If the filtered Linux jump-host list is empty, it falls back to
the filtered AKS list. Public console/OAuth, Microsoft identity, registry, and
other required destinations continue through firewall egress.

Compare the Anyscale list with
[Anyscale networking requirements](https://docs.anyscale.com/networking/overview#important-domains)
and the AKS lists against
[AKS required outbound traffic](https://learn.microsoft.com/azure/aks/outbound-rules-control-egress)
before deploying a long-lived environment.

## AKS and Node Pools

- The system pool is autoscaled, zonal, and restricted to critical add-ons.
- The CPU pool is an autoscaled user pool with `min_count = 0` and
  `max_count = 4`.
- Each `gpu_pool_configs` entry creates an autoscaled user pool with explicit
  SKU, labels, taints, zones, `min_count`, and `max_count`.
- `system_vm_size`, `cpu_vm_size`, `gpu_pool_configs`,
  `system_node_pool_min_count`, `system_node_pool_max_count`,
  `availability_zones`, `kubernetes_version`, `aks_sku_tier`, and the upgrade
  channels are the supported sizing and lifecycle inputs.
- `local_account_disabled`, `defender_enabled`,
  `key_vault_secrets_provider_enabled`, and `azure_policy_enabled` control the
  AKS security add-ons.
- `local.gateway_internal_lb_ip` pins the internal Gateway address to
  `cidrhost(subnet_cidrs.aks_nodes, 1019)`. The Gateway service annotation and
  extension hostname must use this same value.

## Identities and RBAC

- AKS uses a user-assigned control-plane identity with Network Contributor on
  the node and API-server subnets and Private DNS Zone Contributor on the AKS
  private DNS zone.
- The kubelet identity receives `AcrPull` on the private ACR.
- `anyscale_operator_identity.mode` is `create`, `existing-managed-rbac`, or
  `existing-external-rbac`. The first two modes manage Storage Blob Data
  Contributor on the storage container; external RBAC mode validates the
  supplied identity contract without creating that assignment.
- The Anyscale operator service account is federated to the operator identity
  through the AKS OIDC issuer.
- `aks_cluster_admin_principal_ids` and `aks_cluster_user_principal_ids` own
  explicit AKS access. `assign_current_principal_cluster_access` controls access
  for the Terraform principal.
- `acr_push_principal_ids` grants image publishers `AcrPush`.
- `anyscale_platform_default_admin_assignment` and
  `anyscale_platform_role_assignments` own Anyscale platform built-in role
  assignments at subscription, resource-group, cloud, or custom scope.
- `anyscale_platform_admin_role_assignments` adds assignments at the Anyscale
  cloud ARM resource scope and is `{}` in the template. The Anyscale Platform
  Administrator role is effective only at subscription scope during public
  preview, so configure that role through `anyscale_platform_role_assignments`.
- The Linux jump-host managed identity can receive the configured subscription
  or custom-scope roles through `assign_jump_host_subscription_contributor` and
  `jump_host_rbac_scope`.
- Windows browser jump-host login and Key Vault secret-reader access use their
  dedicated principal maps.

## Anyscale Platform, Gateway, and TLS

`infra/terraform/anyscale.tf` owns the Azure-native Anyscale cloud, default
cloud resource, AKS marketplace extension, platform RBAC, ACR build
configuration, and ordered teardown hook. The extension is configured with the
operator namespace/service account, control-plane URL, workload identity, and
Gateway settings.

The bootstrap layer creates:

- the `anyscale-operator` service account with Helm adoption and workload
  identity metadata;
- the NVIDIA device plugin in the GPU resources namespace;
- an internal `anyscale-gateway` using `approuting-istio`;
- private wildcard DNS records for `*.i.azure.anyscaleuserdata.com` and
  `*.s.azure.anyscaleuserdata.com` at the pinned Gateway IP.

The primary TLS secret is available after cloud/operator setup. The service TLS
secret is available after a service is deployed. Cloud deployment IDs are
normalized from underscores to hyphens in Kubernetes secret names. Health
checks validate the extension configuration, Gateway status, listener and
route state, certificate secrets, and private endpoint reachability.

## Private Link

`enable_privatelink` requires an Anyscale-provided
`anyscale_privatelink_service_alias`, the confirmed
`anyscale_private_dns_zone_name`, and one or more
`anyscale_privatelink_record_names`. The template uses a wildcard record so the
cloud, Grafana, and registry hostnames resolve to the endpoint.

The connection is manual and cross-tenant. A successful Terraform apply can
leave it pending. Verify the Azure connection state, then run:

```bash
./scripts/anyscale-aks.sh privatelink-proof --hostname <cloud-specific-fqdn>
```

The proof resolves the hostname from the Windows browser jump host and compares
it with the Terraform private endpoint IP. Private Link carries Anyscale
control-plane traffic only; public OAuth and required Azure traffic still use
firewall egress.

## Observability

The observability module owns Log Analytics, Container Insights, Azure Monitor
Private Link Scope, its private endpoint and DNS zones, a data collection rule,
associations, and diagnostic settings. The template selects private ingestion,
public management queries, `ContainerLogV2`, Kubernetes events, pod inventory,
and a one-minute collection interval.

Use `container_insights_namespace_filtering_mode` and
`container_insights_namespaces` to reduce collection scope. Disable Terraform
diagnostic settings when Azure Policy or another control plane owns the same
resources and categories.

## Custom Image and Image Integrity

The custom image packages `onnxruntime==1.22.0` into the configured Anyscale Ray
base image. Podman builds `linux/amd64` on the Linux jump host and pushes to the
private ACR. The image URI and Ray version are passed explicitly when updating
workspaces and submitting jobs or services. The private ACR path does not use
`az acr build`. `ANYSCALE_STANDARD_IMAGE_URI` selects the image restored to CPU
workspaces when custom-image mode is disabled.

The SBOM path uses Syft and ORAS. The signing path uses Notation with the Azure
Key Vault plugin. Image integrity uses Ratify identity/RBAC, trust-policy
manifests under `workloads/image-integrity/`, and Azure Policy audit results.
Proof marker definitions are centralized in [Proof Markers](proof-markers.md).

## Modification Points

| Area | Owning files | Inputs or contract | Checks |
| --- | --- | --- | --- |
| Root inputs and validation | `.env-template`, `infra/terraform/variables.tf`, `scripts/quality-gate.sh` | Every root variable has one `TF_VAR_*` entry; no root defaults | `./scripts/anyscale-aks.sh self-test quality` |
| Naming | `infra/terraform/locals.tf` | `project`, `environment`, `region_short`, `global_name_suffix` | `terraform -chdir=infra/terraform test -test-directory=tests` |
| Network and subnets | `infra/terraform/main.tf`, `modules/network`, `modules/routing`, `modules/dns`, `modules/dns_resolver` | VNet, subnet CIDRs, forwarding rules | Terraform contract tests and `verify --live` |
| Firewall egress | `infra/terraform/main.tf`, `privatelink.tf`, `modules/firewall` | FQDN lists, jump-host fallback, Private Link filtering | `self-test terraform`, `verify --live` |
| AKS cluster | `infra/terraform/modules/aks` | Kubernetes version, SKU, zones, security and upgrade inputs | Terraform contract tests and `verify --live` |
| Node pools and compute | `modules/aks`, `scripts/setup.sh` | VM sizes, counts, `gpu_pool_configs`, compute profiles | `proof cpu`, `proof gpu`, `proof pipeline` |
| Linux jump host | `modules/jump_host`, `scripts/bootstrap-jump-host.sh`, `scripts/modules/module-2-jump-host.sh` | VM size, SSH key, managed-identity scope | `module 2 doctor`, `module 2 verify` |
| Windows browser jump host | `modules/browser_jump_host`, `scripts/setup.sh` | `enable_browser_host`, login and secret-reader maps | `module 2 browser verify`, `browser ready` |
| Storage and ACR | `modules/storage`, `modules/acr`, `main.tf` | replication, CORS, zone redundancy, RBAC | `verify --live`, custom-image preflight |
| Operator identity | `modules/identity`, `modules/aks` | identity mode and storage RBAC ownership | identity contract tests and `verify --live` |
| Anyscale platform | `.env-template`, `anyscale.tf`, platform ARM template, `scripts/lib/anyscale-cloud-teardown.sh`, `infra/terraform/tests/plan.tftest.hcl` | platform object, ARM API version (pinned in the contract test), extension settings, role maps | platform contract tests and `verify --live` |
| Gateway and TLS | `modules/cluster_bootstrap`, `modules/aks`, `scripts/bootstrap-k8s.sh`, `scripts/setup.sh` | `bootstrap_k8s`, pinned Gateway IP, extension networking settings | `verify --live`, service proof |
| Private Link | `privatelink.tf`, `outputs.tf`, `scripts/privatelink-dns-proof.sh` | enable flag, service alias, zone, records, operator URL | `self-test terraform`, `privatelink-proof` |
| Observability | `modules/observability`, `main.tf` | AMPLS, DCR, retention, filtering, diagnostic ownership | `verify --full` |
| Custom image and SBOM | `workloads/custom-image`, `workloads/proofs`, `scripts/setup.sh` | custom-image harness values, requirement, image URI, Ray version | custom-image preflight, prepare, proof, SBOM proof |
| Image integrity | `modules/image_integrity`, `workloads/image-integrity`, `scripts/setup.sh` | enable flag, certificate name, Key Vault controls | image-integrity preflight, apply, verify |
| Results and evidence | `scripts/anyscale-aks.sh`, `docs/proof-markers.md` | generated root report and stable proof markers | inspect root `RESULTS.md` and `.cache` logs |

## Operational Constraints

- Deploy, apply, end-to-end, teardown, and Anyscale mutation commands change
  live resources. Run them only with explicit authorization.
- `--from-scratch --yes`, force teardown, resource-group deletion, and
  Terraform destroy are destructive.
- Drain services, jobs, workspaces, and sessions before deleting the Anyscale
  cloud, AKS extension, cluster, or resource group.
- Keep Azure Bastion available until Kubernetes and Helm resources that use the
  Bastion-backed kubeconfig are destroyed.
- Job and service working-directory uploads require private Blob/DFS DNS from
  the submitter. Run those proofs on the Linux jump host or use the supported
  in-pod non-interactive path.
- Private service URLs can be unreachable from the workstation while in-cluster
  and in-VNet probes succeed. Interpret reachability from the correct network
  boundary.
- Do not print or commit tokens, keys, IDs, aliases, passwords, image digests,
  Terraform state, generated root results, or `.cache` evidence.
- Keep generated evidence under `.cache/aks-anyscale-sample-harness/`.
