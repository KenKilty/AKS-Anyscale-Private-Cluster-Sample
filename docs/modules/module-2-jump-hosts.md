# Module 2: Prepare the Jump Hosts

## Purpose

Prepare the Linux jump host to run private data plane operations from inside the
VNet. The host uses its managed identity for Azure access and contains Azure
CLI, `kubectl`, `kubelogin`, Helm, `jq`, Podman, and the Anyscale CLI in the
repository-local `.venv`.

Terraform always runs on the workstation. It is not installed or run on the
Linux jump host. The optional Windows browser jump host is used only for
interactive browser access through Bastion.

## Prerequisites

- Module 1 apply completed and the following command passes on the workstation:

  ```bash
  ./scripts/anyscale-aks.sh module 1 verify
  ```

- The workstation has Azure CLI, `rsync`, and the private key identified by
  `SSH_PRIVATE_KEY_PATH`.
- The Linux jump host is reachable through:

  ```bash
  ./scripts/anyscale-aks.sh module 1 connect
  ```

- `.env` exists on the workstation. The sync procedure copies it to the Linux
  jump host; it is never read from Git.
- Module 1 applied the firewall egress lists needed by the bootstrap. If your
  organization changed those lists, confirm that `TF_VAR_tool_bootstrap_fqdns`
  still permits the package and installer destinations in `.env-template`.

## Configuration

No new Terraform decisions are required for this module. The workstation uses
`SSH_PRIVATE_KEY_PATH` to synchronize through Bastion. `module 2 sync` writes
`ANYSCALE_EXECUTION_MODE=jump-host` only to the jump-host copy of `.env`.

> **Warning:** Do not set the workstation copy of `.env` to jump-host mode.
> Terraform must keep running on the workstation.

Use cached OAuth for the Anyscale CLI. `ANYSCALE_CLI_TOKEN` is only for an
approved non-interactive flow and must never be committed or printed.

The canonical repository path on the Linux jump host is
`/opt/anyscale-aks-sample`.

### Sync and Optional Clone

`module 2 sync` is the default transfer path. It copies the workstation working
tree, including uncommitted changes, and the ignored `.env` through a Bastion
tunnel. It excludes `.git`, `.terraform`, `.cache`, `.venv`, and Terraform state.

When `ANYSCALE_AKS_REPO_URL` is set and the canonical repository path does not
exist, `scripts/bootstrap-jump-host.sh` can clone that URL. A clone contains only
committed content and never contains `.env`. The `.env` file must still be
delivered separately; the supported `module 2 sync` command delivers it and
also synchronizes the working tree.

> **Note:** `.env` is never stored in Git. `module 2 sync` is the only supported
> way to deliver it to the Linux jump host.

## Procedure

### Workstation

1. Synchronize the repository and `.env`:

   ```bash
   ./scripts/anyscale-aks.sh module 2 sync
   ```

2. Open a Bastion SSH session:

   ```bash
   ./scripts/anyscale-aks.sh module 1 connect
   ```

### Linux Jump Host

3. Change to the synchronized repository and run the bootstrap:

   ```bash
   cd /opt/anyscale-aks-sample
   ./scripts/anyscale-aks.sh module 2 bootstrap
   ```

   The idempotent bootstrap installs `git`, `curl`, `jq`, `rsync`, `lsof`, Azure
   CLI, `kubectl`, `kubelogin`, Helm, Python through `uv`, Podman, Notation, the
   `notation-azure-kv` plugin, Syft, ORAS, and the Anyscale CLI at
   `.venv/bin/anyscale`.

  On a new deployment, Azure can take several minutes to make the Module 1
  jump-host role assignments visible to its managed identity. The bootstrap
  retries managed-identity login for up to 10 minutes before failing.

   > **Note:** The bootstrap refuses to run on the workstation. Run it only from
   > the Linux jump host. Because it is idempotent, you can safely rerun it.

4. Authenticate the Anyscale CLI on the Linux jump host:

   ```bash
   ANYSCALE_HOST=https://console.azure.anyscale.com \
     .venv/bin/anyscale login --no-browser
   ```

   Open the URL printed by the CLI in a workstation browser and complete the
   sign-in. The credentials are cached on the Linux jump host.

   > **Warning:** Never copy an Anyscale token into the repository, `.env`, or
   > any log. Cached OAuth is the supported path.

5. Run readiness checks on the Linux jump host:

   ```bash
   ./scripts/anyscale-aks.sh module 2 doctor
   ```

   Required tools, `.env`, managed-identity Azure authentication, Anyscale CLI
   authentication, and Podman must be ready.

   > **Note:** `custom-image local ACR build/push readiness` can report
   > `not-ready` here. That is expected, because Module 3 has not created the
   > ACR yet. Module 4 checks it again.

6. Run Linux jump host validation:

   ```bash
   ./scripts/anyscale-aks.sh module 2 verify
   ```

   > **Stop:** Continue only when `module 2 verify` reports that every readiness
   > check passed.

7. Exit the SSH session before running Module 3 deployment commands:

   ```bash
   exit
   ```

### Workstation Browser Check

When the Windows browser jump host is enabled, validate its infrastructure from
the workstation, where the Terraform outputs are available:

```bash
./scripts/anyscale-aks.sh module 2 browser verify
```

## Validation

`module 2 verify` must run from `/opt/anyscale-aks-sample` on the Linux jump
host. It requires these checks to pass:

- `az account show` with the managed identity
- `kubectl version --client`
- `kubelogin --version`
- `helm version`
- `podman version`
- `.venv/bin/anyscale --help`
- Repository present at `/opt/anyscale-aks-sample`
- `.env` contains `ANYSCALE_EXECUTION_MODE=jump-host`

The validation does not require workstation access to private DNS. Private
endpoints resolve from the Linux jump host inside the VNet.

## Adapt the Lab

Use `.env` to change identity scope or firewall destinations. For toolchain,
sync, and implementation changes, see the
[Configuration Reference](../configuration-reference.md#modification-points)
and [Maintainer Workflows](../maintainer-workflows.md).

## Troubleshooting

- If `module 2 sync` is run on the Linux jump host, return to the workstation.
  The command requires workstation Terraform outputs and opens a Bastion tunnel.
- If sync cannot find the SSH key, correct `SSH_PRIVATE_KEY_PATH` on the
  workstation.
- If bootstrap cannot download a tool, check Azure Firewall logs and the
  relevant FQDN list in `.env`, then rerun the idempotent bootstrap.
- If `az login --identity` or `az account show` fails, confirm the system-assigned
  managed identity and its configured role scope from Module 1.
- If Anyscale authentication is unavailable, run
  `ANYSCALE_HOST=https://console.azure.anyscale.com .venv/bin/anyscale login`
  on the Linux jump host. Use a token only when the specific non-interactive
  operation requires one.
- If verification reports the wrong execution mode, rerun `module 2 sync` from
  the workstation.
- If verification reports a missing tool, rerun `module 2 bootstrap` on the
  Linux jump host.

## Next Step

Return to the workstation and continue to
[Module 3: Deploy and Prove the Lab Workload](module-3-lab-workload.md).
