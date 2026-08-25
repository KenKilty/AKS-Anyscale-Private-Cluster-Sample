# Browser Access to Private Anyscale URLs

## Purpose

Provide browser access to private Anyscale platform workspace, dashboard, VS
Code, and service URLs without changing their hostnames.

Terraform and its state remain on the operator workstation. The Linux jump host
runs private Azure CLI, `kubectl`, Helm, Podman, and Anyscale CLI operations.
The Windows browser jump host is the preferred interactive browser path. Private
`*.azure.anyscaleuserdata.com` names require VNet DNS and routing to the internal
Gateway and do not resolve from a normal workstation network.

## Prerequisites

- Azure Bastion and the Linux jump host are deployed.
- Module 3 is deployed before validating private Anyscale platform URLs.
- Set `TF_VAR_enable_browser_host=true` to deploy the Windows browser jump host.
- Configure at least one Entra principal for VM login.
- Preserve the reviewed `TF_VAR_azure_portal_fqdns` firewall egress list for the
  Windows browser jump host subnet.

## Configuration

### Naming

| Prefix | Use |
| --- | --- |
| `browser_jump_host_*` | Canonical Terraform outputs, including VM identity, name, private IP, username, and fallback-secret metadata |
| `windows_browser_jump_host_*` | OS-specific VM input identifiers for size, administrator username, and administrator password |
| `browser_host_*` | Feature and RBAC input identifiers |

The primary settings are `TF_VAR_enable_browser_host`,
`TF_VAR_windows_browser_jump_host_vm_size`,
`TF_VAR_windows_browser_jump_host_admin_username`,
`TF_VAR_browser_host_vm_user_login_principal_ids`, and
`TF_VAR_browser_host_vm_admin_login_principal_ids`.

## Procedure

### Preferred Entra browser path

From the workstation repository, deploy and verify the Windows browser jump
host:

```bash
./scripts/anyscale-aks.sh module 1 apply --enable-browser-host
./scripts/anyscale-aks.sh module 1 browser verify
```

The verification confirms that the VM has no public IP, the
`AADLoginForWindows` extension succeeded, and a VM login role assignment exists.

After Module 3 is deployed, start the interactive validation:

```bash
./scripts/anyscale-aks.sh module 3 browser validate
```

In Azure portal, connect to the Windows browser jump host through Bastion RDP,
sign in with Entra ID, open `https://console.azure.anyscale.com`, and launch a
workspace or service URL. The public console uses firewall egress; private
workspace and service traffic resolves and routes inside the VNet.

### Key Vault fallback

Use the local administrator only when Entra login is unavailable. Terraform
stores the fallback password in Key Vault when the Windows browser jump host is
enabled. The password is sensitive and is never included in Terraform outputs;
`browser_jump_host_admin_password_secret` contains metadata only.

From `/opt/anyscale-aks-sample` on the Linux jump host, retrieve the secret from
the private-only Key Vault:

```bash
set -a
source .env
set +a
resource_group="rg-${TF_VAR_project}-${TF_VAR_environment}-${TF_VAR_region_short}"
vault_name="$(az keyvault list --resource-group "${resource_group}" --query '[0].name' -o tsv)"
az keyvault secret show \
  --vault-name "${vault_name}" \
  --name browser-vm-admin-password \
  --query value -o tsv
```

The caller needs `Key Vault Secrets User` and private network access. Use the
`browser_jump_host_admin_username` output with the retrieved value in Bastion
RDP.

> **Warning:** This command prints a password to the terminal. Do not save it in
> shell history, logs, screenshots, or source files.

The Azure portal Key Vault password picker accesses the vault from the
workstation path. To use it, set
`TF_VAR_key_vault_public_network_access_enabled=true`, restrict
`TF_VAR_key_vault_public_access_cidrs_csv` to reviewed public IPv4 CIDRs, and add
the operator to
`TF_VAR_browser_host_admin_password_secret_reader_principal_ids`. Terraform
grants `Key Vault Reader` and `Key Vault Secrets User` at vault scope. Leave
public network access disabled when this picker is not required.

### SOCKS developer path

This is an optional developer alternative to the Windows browser jump host. Use
a dedicated browser profile with SOCKS5 over Bastion SSH to the Linux jump host
and enable remote DNS in that profile. Scope the proxy to the dedicated profile
so normal workstation browsing is unaffected.

### Linux desktop demo path

This is an optional demonstration path. Run a browser in a desktop session on
the Linux jump host. Do not use it for Windows-specific login validation.

### Private Link DNS proof

When `TF_VAR_enable_privatelink=true`, the public login console remains public:

```text
console.azure.anyscale.com
```

The cloud-specific control-plane hostname is the Private Link target:

```text
cld-<cloud-resource-id>.azure.anyscale-cloud.dev
```

From the workstation repository, load `.env` and run the DNS proof through the
Windows browser jump host:

```bash
set -a
source .env
set +a
./scripts/anyscale-aks.sh privatelink-proof --hostname "cld-${ANYSCALE_CLOUD_DEPLOYMENT_ID}.${TF_VAR_anyscale_private_dns_zone_name}"
```

> **Stop:** If `ANYSCALE_CLOUD_DEPLOYMENT_ID` is empty, do not run the proof.
> Module 3 populates it after the Anyscale cloud resource is created.

Expected proof marker:

```output
PRIVATELINK_DNS_PROOF_OK hostname=cld-<...>.azure.anyscale-cloud.dev private_ip=10.50.2.7
```

This proves only that the live DNS answer equals the Terraform-reported private
endpoint IP. Private endpoint approval and a successful TLS connection are
separate validations.

## Validation

- `module 1 browser verify` reports no public IP, a successful
  `AADLoginForWindows` extension, and at least one VM login assignment.
- Azure portal loads in the Windows browser jump host through firewall egress.
- Private Anyscale platform URLs retain their original hostnames and valid TLS.
- Private workspace and service hostnames resolve to the internal VNet path.
- The optional Private Link DNS command emits `PRIVATELINK_DNS_PROOF_OK`.
- For non-interactive checks, run:

  ```bash
  ./scripts/anyscale-aks.sh e2e \
    --mode jump-host \
    --custom-image \
    --include-browser-precheck
  ```

  This checks infrastructure prerequisites only; it does not perform RDP or
  browser sign-in.

## Adapt the Lab

Before changing the browser path, decide whether the Windows host is required,
which reviewed Entra users or groups need login, and whether the private Key
Vault fallback is sufficient. Keep the fallback password out of `.env` unless a
specific recovery procedure requires an operator-supplied value.

Use [Configuration Reference: Modification Points](../configuration-reference.md#modification-points)
for the inputs and owning Terraform components. Use
[Maintainer Workflows](../maintainer-workflows.md) for validation and quality
checks after a design change.

## Guardrails

- Use the Windows browser jump host only for interactive browser access.
- Keep Terraform and its state on the operator workstation. Run Podman and
  private Anyscale CLI operations on the Linux jump host.
- Do not rewrite private hostnames to localhost; hostname rewriting breaks TLS
  validation.
- Do not add public IP addresses to either jump host.
- Keep firewall egress scoped to the required browser, identity, Azure portal,
  and Anyscale platform endpoints.
- A portal page loading successfully is not proof that an Anyscale hostname used
  Private Link.
- If a jump host existed before default outbound access was disabled, stop and
  deallocate it once, then start it to clear the Azure portal warning.

## Troubleshooting

- **Entra RDP login fails:** verify the `AADLoginForWindows` extension and the
  VM User Login or VM Administrator Login assignment.
- **Azure portal does not load:** review Windows browser jump host firewall
  egress and DNS; do not add broad internet access.
- **Private hostname does not resolve:** confirm Module 3 Gateway and private DNS
  resources exist and test from inside the VNet.
- **Key Vault picker is denied:** compare the observed client source address with
  the reviewed CIDR list. Do not allow-list the Key Vault server address.
- **Private Link DNS passes but HTTPS fails:** check cross-tenant endpoint
  approval and TLS separately.
- **SOCKS profile resolves publicly:** enable remote DNS for the proxy and keep
  the configuration in the dedicated browser profile.

## Teardown

Complete browser and Private Link validation before teardown. Then follow
[Clean Up](cleanup.md). The Windows browser jump host, Private Link resources,
DNS records, and firewall rules are removed with the lab resource group.

## Next Step

Return to [Module 3](module-3-lab-workload.md) or proceed to
[Clean Up](cleanup.md).
