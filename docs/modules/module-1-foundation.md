# Module 1: Foundation

## Purpose

Create the Azure foundation used by the private AKS deployment: the resource
group, VNet and subnets, Azure Firewall and route tables, DNS Private Resolver,
private DNS zones, Azure Bastion, and a private Linux jump host with a
system-assigned managed identity. The optional Windows browser jump host is a
private Entra-enabled desktop for browser access through Bastion.

Terraform runs from the workstation and keeps its state in `infra/terraform`.
Neither jump host has a public IP.

## Prerequisites

- Complete the account, subscription, provider-registration, permission, and
  workstation checks in the [lab introduction](intro.md). Use a dedicated test
  subscription or resource group because later modules create billable resources.
- The Azure CLI `ssh` extension is installed:

  ```bash
  az extension add -n ssh
  ```

- `.env` exists at the repository root and contains the required deployment
  inputs from `.env-template`.
- An SSH key pair exists on the workstation. Generate one when needed:

  ```bash
  ssh-keygen -t ed25519 -C "anyscale-aks-operator"
  ```

  Set `TF_VAR_linux_jump_host_admin_ssh_public_key` to the full contents of the
  generated `.pub` file. Set `SSH_PRIVATE_KEY_PATH` to its matching private key.
- The target region has quota for the selected Linux jump host VM size and, when
  enabled, the Windows browser jump host VM size.
- For the Windows browser jump host, identify the Entra user or group object IDs
  that receive `Virtual Machine User Login` or `Virtual Machine Administrator
  Login`. If the Azure portal must retrieve the generated local administrator
  password from Key Vault, also identify the principals that receive `Key Vault
  Reader` and `Key Vault Secrets User`.

> **Warning:** Never place the SSH private key, or any other secret, in `.env`.
> `.env` holds only the path to the private key.

## Configuration

Copy `.env-template` to the ignored repository-root `.env`. Make these decisions
before the first plan; keep the other supplied defaults for a first run.

| Decision | Inputs | First-run guidance |
| --- | --- | --- |
| Azure target | `ARM_*`, `TF_VAR_azure_subscription_id`, `TF_VAR_azure_tenant_id` | Keep authentication and target IDs aligned. Confirm the selected subscription with `az account show`. |
| Naming and region | `TF_VAR_project`, `TF_VAR_environment`, `TF_VAR_azure_location`, `TF_VAR_region_short`, `TF_VAR_tags` | Use short lowercase names and a region where the configured VM families are available. |
| Network ranges | `TF_VAR_vnet_address_space`, `TF_VAR_subnet_cidrs`, `TF_VAR_service_cidr` | Keep the template ranges unless they overlap a network you must connect to. Changing them requires subnet-capacity review. |
| Linux access | `TF_VAR_linux_jump_host_admin_ssh_public_key`, `SSH_PRIVATE_KEY_PATH` | Use the public/private key pair prepared above. |
| Jump-host authorization | `TF_VAR_assign_jump_host_subscription_contributor`, `TF_VAR_jump_host_rbac_scope` | The template grants the Linux jump-host identity both `Contributor` and `Role Based Access Control Administrator` at the configured scope. This is broad. Use a dedicated test subscription, or have an administrator replace it with reviewed scoped roles. |
| Windows browser access | `TF_VAR_enable_browser_host` and `TF_VAR_browser_host_vm_*_principal_ids` | Leave disabled unless you need interactive access to private browser URLs. If enabled, supply at least one Entra login principal. |
| Control-plane Private Link | `TF_VAR_enable_privatelink` and the `TF_VAR_anyscale_privatelink_*` inputs | Leave disabled for the core lab. Enabling it requires an alias and DNS zone from Anyscale plus manual endpoint approval. |

The harness exports `TF_VAR_*` directly and does not write a tfvars file. Do not
commit secrets or use a second `-var-file` input source. The complete input and
hardening reference is [Configuration Reference](../configuration-reference.md).

### Isolate a Second Lab Deployment

Terraform uses the local state in `infra/terraform`. If this checkout already
contains state for another resource group, select a dedicated Terraform
workspace before changing the naming inputs in `.env`:

```bash
terraform -chdir=infra/terraform workspace new <workspace-name>
export TF_WORKSPACE=<workspace-name>
terraform -chdir=infra/terraform workspace show
```

Keep `TF_WORKSPACE` exported in every workstation terminal used for this lab.
The final command must print the new workspace name before you run `module 1
plan`. An empty workspace prevents the new plan from updating or replacing
resources tracked by the existing state.

> **Warning:** The template default grants the Linux jump-host identity
> `Contributor` and `Role Based Access Control Administrator` at the configured
> scope. That is deliberately broad so the lab workflow succeeds. Use a
> dedicated test subscription, or have an administrator replace it with reviewed
> scoped roles before deploying anywhere shared.

## Procedure

Run all commands in this section from the workstation.

1. Check the configured jump-host VM sizes:

   ```bash
   ./scripts/anyscale-aks.sh module 1 sizes
   ```

   When `.env` specifies a VM size, the command verifies that exact size. When
   the value is empty, it checks `Standard_D4s_v5`, `Standard_D4as_v5`,
   `Standard_D2s_v5`, and `Standard_D2as_v5` in order. It records the selection
   in `.cache/aks-anyscale-sample-harness/admin/vm-size-selection.json` and
   exports the Linux size and, when enabled, the Windows size for the Terraform
   run.

   > **Stop:** If the command reports a restriction or an unavailable SKU,
   > choose an available size or request quota before continuing.

2. Review the Terraform plan:

   ```bash
   ./scripts/anyscale-aks.sh module 1 plan
   ```

   Include the Windows browser jump host in the plan when required:

   ```bash
   ./scripts/anyscale-aks.sh module 1 plan --enable-browser-host
   ```

   The command validates `.env`, initializes Terraform when needed, and prints
   the proposed foundation resources. Confirm the subscription, resource-group
   name, CIDRs, firewall, Bastion, jump hosts, role assignments, and absence of
   public VM IP addresses.

  A new isolated deployment should end with no changes or destroys:

  ```output
  Plan: <count> to add, 0 to change, 0 to destroy.
  ```

  The count varies with optional features. Public IP resources for Azure
  Firewall and Bastion are expected; public IPs attached to either jump-host
  network interface are not.

   > **Stop:** Do not apply if the plan contains an unexpected replacement,
   > public endpoint, scope, or region.

3. Apply the reviewed plan:

   ```bash
   ./scripts/anyscale-aks.sh module 1 apply
   ```

   To create the Windows browser jump host:

   ```bash
   ./scripts/anyscale-aks.sh module 1 apply --enable-browser-host
   ```

   The apply is interactive. Use `--yes` only when the exact reviewed plan is
   intentionally approved for non-interactive application.

   > **Note:** Azure Firewall, Bastion, private DNS, and VM provisioning can
   > take several minutes. Do not interrupt Terraform while Azure operations are
   > progressing. Continue only after Terraform reports `Apply complete`.

4. Open a Bastion SSH session to the Linux jump host when access is required:

   ```bash
   ./scripts/anyscale-aks.sh module 1 connect
   ```

5. Print the Azure portal Bastion RDP path for the Windows browser jump host:

   ```bash
   ./scripts/anyscale-aks.sh module 1 browser connect
   ```

## Validation

Run the foundation checks from the workstation:

```bash
./scripts/anyscale-aks.sh module 1 verify
```

The command verifies that the Linux jump host exists in Terraform outputs, has
no public IP, and has an Azure Bastion access path. Private workload DNS targets
are available only after Module 3 deploys the workload resources.

When the Windows browser jump host is enabled, run:

```bash
./scripts/anyscale-aks.sh module 1 browser verify
```

The browser check requires the VM to have no public IP, the
`AADLoginForWindows` extension state to be `Succeeded`, and at least one
`Virtual Machine User Login` or `Virtual Machine Administrator Login` role
assignment.

## Adapt the Lab

For supported inputs and implementation ownership, use the
[Configuration Reference](../configuration-reference.md#modification-points).
Students should change `.env` inputs, review a new plan, and rerun this module;
source changes belong in the maintainer workflow.

## Troubleshooting

- If `module 1 sizes` reports quota or availability failure, inspect the
  candidates with the `az vm list-skus` or `az vm list-usage` command printed by
  the harness. Request quota or set an available VM size in `.env`.
- If Bastion SSH fails, confirm the apply completed, the matching private key is
  at `SSH_PRIVATE_KEY_PATH`, and the Azure CLI `ssh` extension is installed. A
  public IP on the Linux jump host is not expected.
- If browser verification reports no login role assignment, populate
  `TF_VAR_browser_host_vm_user_login_principal_ids` or
  `TF_VAR_browser_host_vm_admin_login_principal_ids` and apply again.
- If Terraform reports `Extra characters after expression` for either browser
  login principal input, confirm the corresponding `.env` value is a JSON
  object such as `'{}'`, without an extra layer of quotes.
- If the portal cannot retrieve the Windows browser jump host password from Key
  Vault, check
  `TF_VAR_browser_host_admin_password_secret_reader_principal_ids` and the Key
  Vault network-access inputs.
- If the Private Link endpoint remains `Pending`, request approval from
  Anyscale. Reapplying Terraform does not approve a cross-tenant connection.
- If Terraform is not initialized, rerun `module 1 plan`; the harness initializes
  `infra/terraform` when required.

## Next Step

Keep the foundation running. Continue to
[Module 2: Prepare the Jump Hosts](module-2-jump-hosts.md). The foundation is
removed only through the documented [Clean Up](cleanup.md) procedure.
