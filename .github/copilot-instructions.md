# Project Instructions

This repository is an Azure private AKS reference architecture for Anyscale on Azure. Keep changes aligned with the official Microsoft Learn Anyscale on Azure docs, the AKS docs, Azure Container Registry docs, and Anyscale docs.

> **Governance, the agent team, and non-negotiable rules live in
> [`../AGENTS.md`](../AGENTS.md)** — read it first and do not duplicate it here.
> This file holds the **domain knowledge, environment specifics, and the
> validation/quality gate**. Path-scoped rules live in
> [`instructions/`](instructions/) (Terraform, shell, proofs, code-quality).

## Anyscale On Azure Auth

- Do not assume `ANYSCALE_CLI_TOKEN` is required for every Anyscale CLI operation.
- Microsoft Learn's Anyscale on Azure quickstart verifies CLI access by setting `ANYSCALE_HOST=https://console.azure.anyscale.com` and running `anyscale login`, which uses browser/OAuth against Microsoft Entra-backed Anyscale sign-in.
- The local Anyscale CLI can use cached OAuth credentials. Prefer this for local `anyscale` commands such as `cloud list`, `compute-config`, `workspace_v2`, `job submit`, and `service deploy` when run from the operator workstation.
- `ANYSCALE_CLI_TOKEN` is still valid for non-interactive protected settings, Terraform extension configuration, and remote commands running inside workspace pods where local OAuth cache is not present.
- Before adding a hard token requirement, prove the specific command cannot run with `anyscale login`/cached OAuth.
- Do not print tokens, API keys, or bearer values in logs or summaries.

## Current Local Auth Reality

- Azure CLI auth is expected to use the cached Azure CLI account unless `.env` deliberately selects another provider auth mode.
- Local Anyscale CLI auth may be cached outside the repo; do not delete or overwrite it.
- If Anyscale CLI reports `Credentials not found`, the correct interactive recovery is `ANYSCALE_HOST=https://console.azure.anyscale.com .venv/bin/anyscale login`, not fabricating `ANYSCALE_CLI_TOKEN`.

## Custom Image Scenario

- The custom image proof uses `onnxruntime==1.22.0` as the representative dependency.
- The standard-image failure is intentional and should be the only expected failure. It proves runtime package download/install is blocked in the private AKS data plane.
- The success path must use a custom image built locally with Podman, pushed to the private ACR, applied to durable workspaces, and passed explicitly to Anyscale jobs/services through `--image-uri` and `--ray-version` when needed.
- Do not install or configure Podman inside the harness. Treat Podman like other dependencies: check for it and tell the user what is missing.
- For Apple Silicon, the Podman machine is native arm64 and AMD64 images are built with `podman build --platform linux/amd64`.

## Private ACR And Builds

- The sample ACR is private-only with public network access disabled.
- Do not make raw `az acr build` the default path. Microsoft documents that `az acr build` fails with public network access disabled unless dedicated ACR Tasks networking or service-tag allow rules are configured.
- Baseline local build path is Podman run from the in-VNet Linux jump host, which can reach the ACR private endpoint through private DNS.
- Keep ACR pulls Azure-native: AKS kubelet identity gets `AcrPull`; Anyscale operator image-build support uses `acrResourceId`, `AcrPush`, and `Container Registry Tasks Contributor` when that path is validated.

## Results And Evidence

- `RESULTS.md` should be easy to read and should include proof excerpts from logs, not only PASS/FAIL claims.
- Include evidence lines such as proof markers, Anyscale job `SUCCEEDED` state, service `RUNNING` state, and log lines showing `*_PROOF_OK` markers.
- Keep local run artifacts under `.cache/` and avoid committing generated `RESULTS.md` unless explicitly requested.

## Validation Expectations

- After shell or proof changes, run `bash -n` on touched shell scripts and `python3 -m py_compile` on proof scripts.
- Run `terraform -chdir=infra/terraform fmt -check -recursive` after Terraform changes.
- For live work, prefer `./scripts/anyscale-aks.sh e2e --custom-image --teardown` once `.env`, Azure CLI auth, Anyscale OAuth, and Terraform init are available.

<!-- mermaid-ai-skills:start -->
## Mermaid Diagrams

When the user asks to create, edit, or visualize a diagram, follow the
instructions in `.github/instructions/mermaid.instructions.md`.
<!-- mermaid-ai-skills:end -->
