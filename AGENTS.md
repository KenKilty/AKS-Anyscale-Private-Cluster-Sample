# Agent instructions

This project is the **Anyscale Private AKS Reference Architecture on Azure** — a
Terraform + bash harness that builds, proves, and tears down a private Anyscale on
AKS environment (private AKS, private storage/ACR, Azure Firewall egress, Bastion +
in-VNet jump hosts, Azure-native Anyscale platform resources).

This file is loaded on **every** request and is the single source of truth for
**governance, the agent team, and the non-negotiable rules**. Build/validate
commands and environment specifics live in
[`.github/copilot-instructions.md`](.github/copilot-instructions.md) and are **not**
duplicated here.

## Environment bootstrap

- Supported on macOS and Linux operator workstations, and on the in-VNet Ubuntu
  Linux jump host (`scripts/bootstrap-jump-host.sh`).
- Local setup: copy `.env-template` to `.env`, `az login`, create the repo venv
  (`uv venv .venv`), install the Anyscale CLI into `.venv`.
- There is **no** package-manager bootstrap to run for the harness itself; the
  toolchain (Terraform, Azure CLI, kubectl/kubelogin, Helm, jq, Podman, Python/uv)
  is checked by `./scripts/anyscale-aks.sh doctor`.

## Custom agents — these 5 do the work

1. **`anyscale-aks-planner`** (read-only) — turns one unit of work into an ordered
   plan + acceptance checklist. Never edits.
2. **`anyscale-aks-implementer`** (scoped write) — the smallest change that meets
   the acceptance criteria, then runs the quality gate.
3. **`anyscale-aks-reviewer`** (read-only, independent) — verifies acceptance,
   rules, and security; re-runs the gate; cannot edit, so it can never
   fix-and-re-bless its own review.
4. **`anyscale-aks-infra`** (high-privilege domain) — Terraform / Azure / AKS /
   networking / firewall changes. Widest blast radius; **never auto-selected**
   (`disable-model-invocation: true`).
5. **`anyscale-aks-workloads`** (domain) — bash harness, Python proofs, and the
   docs/RESULTS evidence surface.

Per-task flow: **planner → implementer (or a specialist) → reviewer**. When the
*plan* (not the code) is wrong, route back to the planner.

### Running in the Copilot CLI (handoffs do not apply)

The agents are `target: vscode`, so handoffs are realized only in VS Code Agent
Mode. In the Copilot CLI (or any programmatic dispatch) the chain is
**operator-driven**: run the planner, dispatch the implementer/specialist as a
separate task, then dispatch the reviewer as a **separate** invocation. Never let
one agent both make and bless a change. The high-privilege `anyscale-aks-infra`
agent is reached only by explicit named dispatch.

## Communication style

- Fewest words that carry the meaning. No preamble, no recap of what you just did,
  no restating the request back.
- No praise, no superlatives, no "you're absolutely right". Report the cold result,
  including the parts that failed or you didn't verify.
- Disagree when the evidence says so. A wrong instruction gets pushed back on, not
  implemented politely.
- Never claim something works without a real run log or a passing check.

## Git / commits

Never `git commit` or `git push` unless the user explicitly says so. Read-only git
(status, diff, log) is fine.

When explicitly asked to commit:

- Subject: imperative mood, capitalized, no trailing period, ≤50 chars (72 hard
  limit). It must complete "If applied, this commit will ___".
- Blank line, then a body wrapped at 72 chars explaining **what and why**, not how
  — the diff already shows the how.

## Bugs: reproduce before you fix

When the task says something is broken, do not patch on the first plausible theory.

1. Reproduce it and capture the failing output (log line, `bash -n` error, failing
   proof marker, `terraform validate` error).
2. Then make the fix.
3. Re-run the same reproduction and show it passing.

Two log excerpts (before and after) are the deliverable. Live proofs need an actual
run — see the operational-safety rules before running anything mutating.

## Public interfaces — renaming one is a breaking change

These are contracts other things depend on. Changing or removing one needs explicit
user approval, even when the change looks cosmetic:

- `./scripts/anyscale-aks.sh` subcommands and flags.
- `.env-template` variable names and the `TF_VAR_*` they map to.
- Terraform module input/output names and resource addresses (renames force
  replacement or state moves).
- Proof markers (`*_PROOF_OK`) and the run-artifact shape under `.cache/`.

Adding is cheap; renaming and removing are not.

## Operational safety (this repo deploys real Azure infrastructure)

- Local, reversible edits (files, `terraform fmt`, `bash -n`, `py_compile`) are
  free. **Never** run `deploy`, `apply`, `e2e`, `teardown`, `nuke`, `az group
  delete`, or any Anyscale mutating command without explicit user instruction.
- Treat `--force`/`nuke` teardown and `terraform apply/destroy` as destructive:
  confirm first. Do not bypass safety prompts (`--yes`) on the user's behalf.
- Never delete or overwrite cached Anyscale/Azure CLI credentials.

## Paths & portability — no machine-specific config

Use repo-relative paths or `${workspaceFolder}` / `$HOME` / `$PWD` / `$TMPDIR`.
No personal checkout paths in committed files.

## Secrets — never committed, never printed

No tokens, subscription/tenant/object ids, ACR/storage keys, bearer values, or
SSH private keys in committed files, logs, or summaries. The repo-root `.env` is
git-ignored, holds the real deployment values, and is exported as `TF_VAR_*` at
deploy time (the harness no longer renders a `terraform.auto.tfvars.json`); keep
it that way. When recovering Anyscale auth, use `anyscale login` (cached OAuth), never a
fabricated `ANYSCALE_CLI_TOKEN`.

## User-facing language — no internal jargon

Anything an end user reads (README, module docs, `RESULTS.md`, console output)
must be plain. No internal work-package ids or pipeline jargon. The reviewer
enforces this.

## MCP servers

None are required by the harness. If an Azure/AKS MCP server is wired into
`.vscode/mcp.json`, grant it **read-only and per-role** (the `anyscale-aks-infra`
specialist only), pinned to the specific tools used. Secrets never go in
`mcp.json`.

> **Model tiering.** The `anyscale-aks-implementer` write-side role runs on the
> strongest available model (`Claude Opus 4.8`). The other roles (planner,
> reviewer, workloads, and the high-privilege infra specialist) run
> `Claude Sonnet 4.6` with escalation to `Claude Opus 4.8`. Adjust the `model:`
> strings in `.github/agents/*.agent.md` to the models available in your Copilot
> picker. `model` is either a single model name (string) or a prioritized array
> that the agent tries in order — VS Code (`target: vscode`) honors the array as
> the escalation mechanism.
