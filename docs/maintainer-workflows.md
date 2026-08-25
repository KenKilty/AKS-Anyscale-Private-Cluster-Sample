# Maintainer Workflows

This is the maintainer workflow for the private Anyscale on AKS sample. The
[README](../README.md) and [guided modules](modules/intro.md) are the operator
entry points.

## Maintainer Setup

Create the local environment and install the Anyscale CLI:

```bash
cp .env-template .env
uv venv .venv
UV_CACHE_DIR="$PWD/.cache/uv-cache" \
  uv pip install --python .venv/bin/python anyscale
az login
ANYSCALE_HOST=https://console.azure.anyscale.com .venv/bin/anyscale login
./scripts/anyscale-aks.sh doctor
```

The harness supports macOS and Linux workstations and the provisioned Linux
jump host. It checks dependencies but does not install the workstation
toolchain.

## Dependencies

| Tool | Purpose |
| --- | --- |
| Git | Source and pre-commit workflows |
| Azure CLI | Authentication, Azure resource checks, AKS, and Bastion |
| Terraform `>= 1.9.0` | Infrastructure, validation, and contract tests |
| `kubectl`, `kubelogin`, Helm | Private AKS access and bootstrap |
| `jq`, `curl`, `rsync`, `lsof` | Harness data processing, probes, transfer, and tunnel checks |
| Python `3.9+`, `uv`, Anyscale CLI | Helpers, proofs, and Anyscale operations |
| pre-commit | Commit and push checks |
| ShellCheck, shfmt | Shell checks |
| Ruff, pyright | Python checks |
| TFLint | Terraform lint |
| markdownlint-cli2, yamllint, hadolint | Documentation and configuration checks |
| Trivy | IaC, vulnerability, and secret scans |
| Podman | Custom image build and push on the Linux jump host |
| Syft, ORAS, Notation, `notation-azure-kv` | SBOM and image signing on the Linux jump host |
| diagrams.net/draw.io CLI | Diagram export |
| Firefox | Isolated private workspace browser profile |

Install sources are reported by:

```bash
./scripts/anyscale-aks.sh doctor
```

## Pre-commit and Quality Gate

Install the configured hooks once per checkout:

```bash
pre-commit install --install-hooks
```

Run selected-file checks and the push gate directly:

```bash
pre-commit run --all-files
pre-commit run --all-files --hook-stage pre-push
pre-commit run --all-files --hook-stage manual
```

The commit stage runs agent metadata validation, shell syntax/lint/format,
Terraform formatting, Python compile/Ruff, Markdown/YAML/Dockerfile lint, and
Trivy configuration/secret checks. The push and manual stages run the full
quality gate, Terraform contract tests, and the full agent validator.

The canonical gate is the direct script `scripts/quality-gate.sh`; the
dispatcher exposes the same command:

```bash
./scripts/anyscale-aks.sh self-test quality
```

It checks the `.env`/`TF_VAR_*` contract, tracked-artifact hygiene, Terraform
format/validate/TFLint, shell syntax/ShellCheck/shfmt, Python
compile/Ruff/pyright, Markdown/YAML/Dockerfile lint, and Trivy
configuration/vulnerability/secret scans.

## Terraform Tests

Run non-billable plan-contract tests through the dispatcher:

```bash
./scripts/anyscale-aks.sh self-test terraform
```

The command loads Azure provider context from `.env`, isolates the contract-test
inputs, and runs `infra/terraform/tests/*.tftest.hcl`. It does not run the
billable apply test under `infra/terraform/tests/e2e/`.

Run the apply test only with explicit authorization to create Azure resources:

```bash
terraform -chdir=infra/terraform test \
  -test-directory=tests/e2e -verbose
```

Useful read-only inspection:

```bash
terraform -chdir=infra/terraform output
terraform -chdir=infra/terraform fmt -check -recursive
```

## Deploy Stage Reference

The current dispatcher command is:

```bash
./scripts/anyscale-aks.sh deploy
```

| Stage | Responsibility |
| --- | --- |
| `prepare` | Load `.env`, export `TF_VAR_*`, check tools and inputs, and validate Azure authentication. |
| `reset-or-state` | Reconcile state or perform an explicitly authorized from-scratch reset. |
| `terraform-init-validate` | Initialize Terraform, check formatting, and validate configuration. |
| `foundation` | Apply networking, firewall egress, DNS, Bastion, AKS, private dependencies, identities, and observability. |
| `bootstrap-a` | Establish private AKS access and apply namespaces, service account, and cluster prerequisites. |
| `platform` | Apply Anyscale platform resources, extension, RBAC, and Gateway configuration. |
| `bootstrap-b` | Reconcile the internal Gateway, TLS resources, and remaining Kubernetes bootstrap. |
| `workspaces` | Reconcile CPU/GPU compute configurations and durable workspaces. |
| `health` | Run live platform, AKS, Gateway, workspace, and observability checks. |

Run static or live verification with existing dispatcher commands:

```bash
./scripts/anyscale-aks.sh verify --static
./scripts/anyscale-aks.sh verify --live
./scripts/anyscale-aks.sh verify --full
```

## Proof Execution Locations

CPU and GPU Ray proofs execute from the workstation through the Bastion-backed
kubeconfig into durable workspace pods:

```bash
./scripts/anyscale-aks.sh proof cpu
./scripts/anyscale-aks.sh proof gpu
```

Job, service, and custom-image proofs upload a working directory to private
Blob/DFS storage. Run them from the in-VNet Linux jump host, where private DNS
and storage endpoints are reachable:

```bash
ANYSCALE_HOST=https://console.azure.anyscale.com .venv/bin/anyscale login
./scripts/anyscale-aks.sh module 3 proof pipeline
./scripts/anyscale-aks.sh proof all
```

`ANYSCALE_CLI_TOKEN` is a non-interactive fallback for a remote execution path
without the local OAuth cache. Proof marker names and interpretation are in
[Proof Markers](proof-markers.md).

## Custom Image Workflow

Run the private ACR workflow on the Linux jump host. Podman builds
`linux/amd64`, pushes through the ACR private endpoint, and the harness applies
the image URI and Ray version explicitly.

```bash
./scripts/anyscale-aks.sh custom-image prove-failure
./scripts/anyscale-aks.sh custom-image preflight
./scripts/anyscale-aks.sh custom-image prepare
./scripts/anyscale-aks.sh custom-image sign
./scripts/anyscale-aks.sh custom-image verify
./scripts/anyscale-aks.sh custom-image sbom
./scripts/anyscale-aks.sh custom-image sbom-proof
./scripts/anyscale-aks.sh custom-image apply
./scripts/anyscale-aks.sh custom-image proof
```

The image source is `workloads/custom-image/`. Do not use `az acr build` for
this private-only ACR path. Podman is an operator dependency; the harness does
not install or configure it.

## MCP Configuration

`.vscode/mcp.json` runs
`docker.io/hashicorp/terraform-mcp-server:1.2.0` with Podman and enables only
the public `registry` toolset. It exposes provider and module documentation;
it has no HCP Terraform credentials or workspace mutation tools.

```bash
podman machine start
podman pull docker.io/hashicorp/terraform-mcp-server:1.2.0
```

Start or restart the `terraform` server from **MCP: List Servers** in VS Code.
Do not add tokens or Terraform Enterprise addresses to the tracked config.

## Idempotency

Run the reconciliation check with:

```bash
./scripts/anyscale-aks.sh self-test idempotency
```

It runs deploy, verify, and proofs twice, then requires a Terraform no-op plan.
Cleanup is opt-in:

```bash
./scripts/anyscale-aks.sh self-test idempotency --include-teardown
./scripts/anyscale-aks.sh self-test idempotency \
  --include-force-teardown \
  --i-understand-this-deletes-azure-resources
```

> **Warning:** Both teardown flags delete real Azure resources. Run them only
> against a dedicated test subscription.

## Diagram Export

`docs/architecture-overview.drawio` is the editable overview source. Export its
checked-in SVG with the dispatcher:

```bash
./scripts/anyscale-aks.sh diagrams export
```

The additional diagram sources and PNG exports live under `docs/diagrams/`.

## Generated Artifacts

| Path | Contents | Source-control contract |
| --- | --- | --- |
| `.cache/aks-anyscale-sample-harness/kubeconfig.bastion` | Bastion-backed kubeconfig | Local only |
| `.cache/aks-anyscale-sample-harness/runs/<timestamp>-<command>/` | `summary.md`, `stages.tsv`, stage logs, and diagnostics | Local only |
| `.cache/` | Tool caches, temporary configs, proof payloads, and scan data | Local only |
| Root `RESULTS.md` | Current generated end-to-end summary and selected evidence lines | Local generated file |
| `docs/proof-markers.md` | Stable proof marker reference | Tracked documentation |
| `docs/architecture-overview.svg` | Exported architecture rendering | Tracked generated asset |

Do not commit credentials, Terraform state, `.env`, generated root results, or
run evidence. The generated root report points to the exact `.cache` summary and
logs that support each status.
