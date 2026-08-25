# Clean Up

## Purpose

Drain Anyscale platform resources, destroy the Azure lab, verify that no
Terraform-managed resources remain, and retain teardown evidence for audit.

## Prerequisites

- Complete browser, workload, image, and Private Link validation before cleanup.
- Use current Azure CLI and Anyscale CLI authentication.
- Ensure no other Terraform operation holds the state lock.
- Confirm the configured project, subscription, and resource group before
  proceeding.

## Procedure

Run every cleanup and validation command from the workstation repository.

> **Warning:** Teardown permanently deletes the lab resource group and every
> resource in it. Run `az account show` first and stop if it identifies a
> different subscription than the one you deployed.

### Standard teardown

```bash
./scripts/anyscale-aks.sh module 3 teardown
```

Type the exact `TF_VAR_project` value at this prompt:

```text
Type the project name to confirm teardown:
```

Any other value cancels the operation. The staged teardown:

1. Drains active Anyscale platform workspaces, services, jobs, and cloud
   resources.
2. Runs `terraform destroy -auto-approve` with retries for recognized transient
   Azure operation conflicts.
3. Fails if Terraform state still contains resources.
4. Stops the Bastion tunnel, clears the cached cloud deployment identifier, and
   waits for resource-group deletion.
5. Writes teardown evidence under the current harness run directory.

Private Link, the Windows browser jump host, private DNS, private ACR, Key Vault,
AKS, firewall, Bastion, and both jump host paths are removed by the same
Terraform destroy.

### Non-interactive confirmation

Use the exact project value from `.env` to bypass only the interactive prompt:

```bash
set -a
source .env
set +a
./scripts/anyscale-aks.sh teardown --confirm-project "${TF_VAR_project}"
```

The command exits if the supplied value does not equal `TF_VAR_project`. `--yes`
is not valid for standard teardown. The end-to-end flow supplies
`--confirm-project` when it performs a requested teardown.

### Force reset

Use force reset only when standard Terraform teardown cannot complete and the
configured resource group is dedicated to this lab:

```bash
./scripts/anyscale-aks.sh teardown --force --yes
```

This path still drains the Anyscale platform first. It then deletes the Azure
resource group directly, waits for deletion, and removes local Terraform state
and saved plan files. It keeps `.env` and the committed Terraform dependency
lock file.

> **Warning:** `--force --yes` is destructive and bypasses the project-name
> prompt. Recheck the active subscription and the derived resource-group name
> before you run it.

## Expected Duration

Allow at least 10 to 15 minutes. Active Anyscale platform resources, Azure
Firewall deallocation, Key Vault deletion, and cross-tenant Private Endpoint
deletion can extend the run. The resource-group wait reports progress roughly
once per minute.

> **Note:** Do not interrupt a destroy that is still reporting progress. An
> interrupted destroy can leave orphaned resources that you must remove
> manually.

## Validation

Confirm Terraform state is empty:

```bash
terraform -chdir=infra/terraform state list
```

Confirm the resource group is absent:

```bash
set -a
source .env
set +a
resource_group="rg-${TF_VAR_project}-${TF_VAR_environment}-${TF_VAR_region_short}"
az group exists --name "${resource_group}"
```

Expected result:

```output
false
```

Each standard teardown writes `teardown-evidence.json` under:

```text
.cache/aks-anyscale-sample-harness/runs/<run>/
```

The evidence records the command, UTC timestamp, Terraform exit code, remaining
state count, and resource-group existence result. A teardown is complete only
when state is empty and the resource group no longer exists.

## Local Artifacts

Harness logs, rendered temporary files, proof output, and teardown evidence are
stored under `.cache/aks-anyscale-sample-harness/`. Remove that directory only
after retaining any required audit evidence.

Standard teardown preserves `.env` and the Terraform dependency lock file. Force
reset removes local Terraform state and saved plan files after resource-group
deletion.

## Troubleshooting

- **Anyscale platform drain fails:** inspect active workspaces, services, jobs,
  and nested cloud resources, terminate the blocker, and rerun standard
  teardown.
- **Terraform reports an operation in progress:** allow the built-in retries to
  complete. If the run exits, inspect the stage log and retry standard teardown.
- **Terraform destroy exits with resources in state:** use the recorded
  `terraform-state-after-destroy.txt` to identify the remaining resource, resolve
  it, and rerun. Use force reset only for the dedicated lab resource group.
- **Private Endpoint deletion times out:** inspect Azure activity logs. Retry
  standard teardown if Azure is still processing the deletion.
- **Anyscale-side scope lock blocks Private Link deletion:** retries and direct
  resource-group deletion cannot remove a lock in the provider subscription;
  contact Anyscale Support.
- **Kubernetes resource deletion times out:** keep Bastion available until the
  Kubernetes bootstrap resources are gone. Do not manually delete Bastion first.
- **Resource group still exists after state is empty:** inspect the resource
  group activity log and remaining resources, then rerun the deletion wait or
  use the reviewed force-reset path.
- **State lock exists:** confirm no Terraform process is active before resolving
  the lock. Do not remove an active lock.

## Next Step

Retain the required evidence and return to the [README](../../README.md) for
deployment and operations reference.
