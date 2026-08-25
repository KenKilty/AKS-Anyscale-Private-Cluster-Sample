---
applyTo: "scripts/**/*.sh"
---

# Shell conventions (loaded for scripts/**/*.sh)

The harness is `scripts/anyscale-aks.sh` (dispatcher) → `scripts/setup.sh` (core) +
`scripts/modules/module-{1..5}-*.sh` + `scripts/lib/*.sh`.

## Layout

- **Entry points** (`scripts/*.sh`, `scripts/modules/*.sh`, plus
  `scripts/lib/anyscale-cloud-teardown.sh`, which Terraform invokes by path) are
  executable and set `set -euo pipefail`.
  - Multi-command entry points expose help text and end with `main "$@"`.
  - Single-purpose scripts (git hooks, one-shot proofs, offline tests) may run
    linearly and end with an explicit `exit`. They still carry the header block.
- **Sourced libraries** (the rest of `scripts/lib/*.sh`) are not executable,
  define functions only, and must **not** set shell options at file scope —
  those leak into the caller. A scoped `set +e` / `set -e` pair inside one
  function is fine when you need an exit code.
- Derive paths with `"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"`; never
  assume the caller's working directory.
- Keep the layering: `anyscale-aks.sh` → `setup.sh`/`modules/**` → `lib/**`.

## Header block

Every script starts with the same block, kept short and factual:

```bash
#!/usr/bin/env bash
# <One line: what this file is>.
#
# Purpose: <why it exists / what it accomplishes>
# Usage:   <invocation, and where it runs: workstation or jump host>
# Inputs:  <args, env vars, files, required auth>
# Outputs: <stdout markers, files written, exit-code meaning>
```

Describe current behavior only. No change history, roadmap, or "legacy" framing.

## Style

- Every entry point starts `set -euo pipefail`. Keep it.
- Quote expansions (`"$var"`); prefer `$()` over backticks; `[[ ]]` over `[ ]`.
- Declare function variables `local`. Prefer `printf` over `echo` for anything
  containing variables or escapes.
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

## Help text

- Every advertised subcommand and action must exist in the matching `case`
  dispatch, and every routable action must be advertised. Update `usage()` in
  the same change that adds or removes an action.
- `./scripts/anyscale-aks.sh` subcommands and flags are public interfaces.
  Adding is cheap; renaming or removing needs explicit user approval.

## Validation gate

Run `bash -n` on every edited script before declaring done (or the
**quality: gate (fast)** task). Use a `shellcheck` pass when available, but `bash -n`
is the required floor.
