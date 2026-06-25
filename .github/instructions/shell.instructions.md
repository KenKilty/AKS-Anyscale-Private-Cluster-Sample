---
applyTo: "scripts/**/*.sh"
---

# Shell conventions (loaded for scripts/**/*.sh)

The harness is `scripts/anyscale-aks.sh` (dispatcher) → `scripts/setup.sh` (core) +
`scripts/modules/module-{1,2,3}-*.sh` + `scripts/lib/*.sh`.

## Style
- Every script starts `set -euo pipefail`. Keep it.
- Quote expansions (`"$var"`); prefer `$()` over backticks; `[[ ]]` over `[ ]`.
- Long-running or network operations go through `run_with_timeout`
  (`scripts/lib/timeout.sh`); exit code **124** means timeout. Honor the
  `SETUP_TIMEOUT_*` knobs rather than hard-coding waits.
- Stages emit logs under `.cache/aks-anyscale-sample-harness/runs/<run-id>/`; keep
  that artifact shape (`summary.md`, `stages.tsv`, `logs/XX-*.log`).
- Two execution modes: `workstation` (default, Bastion tunnel on port 64430+) and
  `jump-host` (in-VNet, `az login --identity`). Don't break either path.

## Safety
- Never weaken safety prompts or add `--yes`/`--no-verify` on the user's behalf.
- Mutating commands (`deploy`, `apply`, `e2e`, `teardown`, `nuke`, Anyscale
  job/service submit) run only on explicit user instruction.
- Never print tokens, keys, subscription/tenant ids, or bearer values. Prefer cached
  Anyscale OAuth (`anyscale login`) over `ANYSCALE_CLI_TOKEN`.
- Treat external dependencies (Podman, kubelogin, helm, jq, uv) as checked, not
  installed, by the harness — detect and report what's missing.

## Validation gate
Run `bash -n` on every edited script before declaring done (or the
**quality: gate (fast)** task). Use a `shellcheck` pass when available, but `bash -n`
is the required floor.
