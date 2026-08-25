# Module 3: Deploy and Prove the Lab Workload

## Purpose

Deploy the private AKS cluster, private ACR, storage, observability resources,
Anyscale platform resources, CPU and GPU compute configurations, and durable CPU
and GPU workspaces. Validate Azure resource state, in-cluster components,
workspace state, and deterministic workload proof markers.

Terraform runs from the workstation and uses local state in `infra/terraform`.
The deployment invokes `kubectl` and Helm on the Linux jump host through
Bastion for private data plane bootstrap. Terraform never runs on the Linux
jump host.

## Prerequisites

- Module 1 is applied and Module 2 validation passes.
- The workstation can authenticate to Azure and reach `management.azure.com`.
- The Linux jump host is synchronized, bootstrapped, and reachable through
  Bastion.
- Anyscale CLI authentication is available. For interactive OAuth:

  ```bash
  ANYSCALE_HOST=https://console.azure.anyscale.com .venv/bin/anyscale login
  ```

- Any enabled Anyscale control-plane Private Link endpoint is approved, and its
  private DNS and operator control-plane URL are configured.
- The target subscription has quota for the configured system and CPU VM sizes.
  The default GPU pool uses `Standard_NC16as_T4_v3`; verify that SKU in the
  target region and request the corresponding NC-family vCPU quota before
  deployment. For a CPU-only lab, set `TF_VAR_gpu_pool_configs='{}'` in `.env`.

## Configuration

For a first run, keep the hardening, storage, registry, observability, operator,
and Gateway values supplied by `.env-template`. Decide only:

| Decision | Input | Guidance |
| --- | --- | --- |
| CPU or CPU+GPU | `TF_VAR_gpu_pool_configs` | Keep the T4 map only when the region has SKU availability and quota; use `{}` for CPU-only. |
| Platform access | `TF_VAR_anyscale_platform_default_admin_assignment`, `TF_VAR_anyscale_platform_role_assignments` | The template grants the deploying principal the platform administrator role at subscription scope. Add only reviewed Entra object IDs. |
| Image Integrity | `TF_VAR_enable_image_integrity` | Keep enabled only when you plan to complete Module 5 and can create policy assignments. Modules 1-4 do not require it. |
| Control-plane Private Link | `TF_VAR_enable_privatelink`, `TF_VAR_anyscale_privatelink_service_alias`, `TF_VAR_anyscale_platform` | Optional. Anyscale must provide the service alias and approve the Azure private endpoint. Use the two-pass procedure below. |

Leave `ANYSCALE_CLOUD_NAME` and `ANYSCALE_CLOUD_DEPLOYMENT_ID` empty before the
first deployment. The harness derives the cloud name and writes both values to
the ignored `.env` after Azure creates the Anyscale cloud resource.

See [Configuration Reference](../configuration-reference.md) before changing
AKS versions, upgrade channels, security controls, node pools, storage,
firewall egress, or observability.

## Procedure

Unless a step explicitly says Linux jump host, launch commands from the
workstation.

### Deploy from the Workstation

> **Stop:** On first deployment, the harness can prompt you to review and accept
> the Anyscale AKS Operator Marketplace terms. Do not continue if you are not
> authorized to accept subscription-scoped terms; ask a subscription
> administrator to accept them.

```bash
./scripts/anyscale-aks.sh module 3 deploy
```

Expect the command to validate inputs, apply Azure infrastructure, bootstrap
private AKS access through the Linux jump host, register the Anyscale platform,
create workspaces, and run health checks. Maintainers can find the nine-stage
breakdown in [Maintainer Workflows](../maintainer-workflows.md#deploy-stage-reference).

> **Note:** Azure provisioning commonly takes tens of minutes. Follow the stage
> log path printed by the harness and do not interrupt an active Terraform or
> Azure operation.

If Private Link is enabled, make the first deploy with
`operator_control_plane_url = null` in `TF_VAR_anyscale_platform`. This creates
the private endpoint while the operator continues to use the public control
plane URL. After the endpoint appears as pending:

1. Ask Anyscale to approve the cross-tenant private endpoint.
2. Wait until Azure reports the connection as approved.
3. Set `operator_control_plane_url` to
  `https://cld-${ANYSCALE_CLOUD_DEPLOYMENT_ID}.${TF_VAR_anyscale_private_dns_zone_name}`.
4. Rerun `./scripts/anyscale-aks.sh module 3 deploy` from the workstation.
5. Run the [Private Link DNS proof](browser-access.md#private-link-dns-proof),
   test HTTPS from inside the VNet, and continue only when both checks pass.

> **Warning:** Do not set the private operator URL before Anyscale approves the
> endpoint. The in-cluster operator cannot reach an unapproved endpoint.

### Verify from the Workstation

```bash
./scripts/anyscale-aks.sh module 3 verify --full
```

This runs static Terraform checks and live infrastructure and readiness checks.
Private cluster checks are delegated through the Linux jump host.

### Run Private Proofs on the Linux Jump Host

The complete proof pipeline uploads Anyscale working directories to private
storage and accesses private data plane endpoints. Run it from the synchronized
repository on the Linux jump host.

> **Note:** If the workstation files or `.env` changed after Module 2, rerun
> `module 2 sync` on the workstation first. Reconnect to the Linux jump host and
> repeat the Module 2 Anyscale login step if its cached credentials are
> unavailable.

```bash
cd /opt/anyscale-aks-sample
./scripts/anyscale-aks.sh module 3 proof all
```

The CPU and GPU Ray checks execute in their durable workspaces. The build and
train proofs execute as Anyscale jobs, and the Serve proof executes as an
Anyscale service. GPU stages can wait for node-pool scaling, image pulls, and
NVIDIA device-plugin readiness.

### Validate in the Windows Browser Jump Host

Launch the browser instructions and infrastructure precheck from the
workstation:

```bash
./scripts/anyscale-aks.sh module 3 browser validate
```

Connect to the Windows browser jump host through Azure portal Bastion RDP, open
`https://console.azure.anyscale.com`, and launch a workspace or service. Confirm
that workspace, Ray dashboard, VS Code, and service URLs resolve privately with
valid TLS. Browser validation is interactive and is not part of the unattended
run. See [Browser Access](browser-access.md).

## Validation

The deployment is valid when:

- All nine deploy stages complete successfully.
- AKS, the Anyscale AKS extension, and the Anyscale cloud resource report
  `Succeeded`.
- The Anyscale operator, Istio control plane, and Anyscale gateway report
  available or running state.
- The CPU and, when configured, GPU durable workspaces report `RUNNING`.
- `module 3 verify --full` passes.
- The private proof run emits these proof markers:

  - `CPU_RAY_PROOF_OK`
  - `CPU_BUILD_JOB_PROOF_OK`

  With a GPU pool configured, the run also emits:

  - `GPU_RAY_PROOF_OK`
  - `GPU_TRAIN_JOB_PROOF_OK`
  - `GPU_SERVE_SERVICE_PROOF_OK`

The canonical proof marker list and evidence format are in
[Proof Markers](../proof-markers.md).

## Adapt the Lab

Change supported deployment inputs in `.env`, review a new Terraform plan, and
rerun verification. Source ownership and required checks are listed under
[Configuration Reference: Modification Points](../configuration-reference.md#modification-points).

## Troubleshooting

- If `bootstrap-a` or `bootstrap-b` fails, verify Module 2 on the Linux jump
  host, confirm `kubectl` and Helm are installed, and confirm the managed
  identity is present in the configured AKS admin principal map.
- If Terraform init, validation, plan, or apply fails, troubleshoot from the
  workstation. Confirm Azure CLI authentication and access to
  `management.azure.com`; do not move Terraform to the Linux jump host.
- If a proof upload fails from the workstation, run `module 3 proof all` from
  `/opt/anyscale-aks-sample` on the Linux jump host. Private Blob and DFS
  endpoints resolve and route inside the VNet.
- If the Anyscale operator cannot reach its control plane with Private Link,
  confirm endpoint approval, private DNS resolution, and
  `anyscale_platform.operator_control_plane_url` in
  `TF_VAR_anyscale_platform`.
- If GPU proofs remain in startup, inspect GPU node-pool scaling, image pulls,
  and NVIDIA device-plugin readiness. Treat the proof marker, not an
  intermediate `STARTING` state, as completion.
- If browser URLs fail, run the Windows browser jump host verification and
  follow the DNS and TLS checks in [Browser Access](browser-access.md).

### Unattended Run and Teardown

Launch the unattended workflow from the workstation:

```bash
./scripts/anyscale-aks.sh e2e --mode jump-host --custom-image --teardown
```

Include the non-interactive Windows browser jump host prerequisite checks with:

```bash
./scripts/anyscale-aks.sh e2e --mode jump-host --custom-image --include-browser-precheck
```

The browser precheck does not perform portal RDP or interactive browser
validation. Run `module 3 browser validate` before teardown when that evidence
is required.

To remove the workload separately, launch this command from the workstation:

```bash
./scripts/anyscale-aks.sh module 3 teardown
```

> **Warning:** Both `--teardown` and `module 3 teardown` delete real Azure and
> Anyscale resources. Review the [Clean Up](cleanup.md) procedure and confirm
> the intended scope before continuing.

## Next Step

Continue to
[Module 4: Custom Images for a Private Data Plane](module-4-custom-image.md).
When the lab is no longer required, follow [Clean Up](cleanup.md); teardown
removes real Azure resources.
