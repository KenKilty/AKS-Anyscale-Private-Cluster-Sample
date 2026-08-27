#!/usr/bin/env bash
# Canonical local quality gate for the Anyscale private-AKS sample.
#
# Purpose: run every structural, format, lint, and security check enforced by
#          the pre-push hook, in one place. Missing required tools are reported
#          as failures with actionable install guidance.
# Usage:   ./scripts/quality-gate.sh
#          (public route: ./scripts/anyscale-aks.sh self-test quality)
# Inputs:  the working tree, .env-template and .env (variable NAMES only; values
#          and secrets are never read or printed).
# Outputs: a PASS/FAIL line per check and a final tally on stdout; exit 0 only
#          when every check passes.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"
TERRAFORM_DIR="${ROOT_DIR}/infra/terraform"
VARIABLES_TF="${TERRAFORM_DIR}/variables.tf"
ENV_TEMPLATE="${ROOT_DIR}/.env-template"
ENV_FILE="${ROOT_DIR}/.env"
TRIVY_CACHE_DIR="${ROOT_DIR}/.cache/trivy"

PASS_COUNT=0
FAILURES=()
SKIPS=()

log() { printf '%s\n' "$*"; }
pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf '  PASS  %s\n' "$1"
}
fail() {
  FAILURES+=("$1")
  printf '  FAIL  %s\n' "$1"
  if [[ -n "${2:-}" ]]; then printf '        %s\n' "$2"; fi
}
skip() {
  SKIPS+=("$1")
  printf '  SKIP  %s\n' "$1"
  if [[ -n "${2:-}" ]]; then printf '        %s\n' "$2"; fi
}
have() { command -v "$1" >/dev/null 2>&1; }

tool_hint() {
  case "$1" in
    git) printf 'https://git-scm.com/downloads' ;;
    terraform) printf 'https://developer.hashicorp.com/terraform/install' ;;
    shellcheck) printf 'brew install shellcheck  (https://www.shellcheck.net/)' ;;
    shfmt) printf 'brew install shfmt  (https://github.com/mvdan/sh)' ;;
    ruff) printf 'pipx install ruff  (https://docs.astral.sh/ruff/)' ;;
    markdownlint) printf 'npm install -g markdownlint-cli2  (https://github.com/DavidAnson/markdownlint-cli2)' ;;
    yamllint) printf 'brew install yamllint  or  pipx install yamllint' ;;
    hadolint) printf 'brew install hadolint  (https://github.com/hadolint/hadolint)' ;;
    tflint) printf 'brew install terraform-linters/tap/tflint  (https://github.com/terraform-linters/tflint)' ;;
    trivy) printf 'brew install trivy  (https://trivy.dev/)' ;;
    pyright) printf 'npm install -g pyright  (https://microsoft.github.io/pyright/)' ;;
    *) printf 'see docs/maintainer-workflows.md' ;;
  esac
}

# Collect tracked shell scripts (including the extension-less git hook).
collect_shell() {
  # Include untracked-but-not-ignored files so new scripts are checked here
  # rather than first failing in the pre-commit hook.
  git ls-files -z --cached --others --exclude-standard -- '*.sh' '.githooks/*'
}

check_env_contract() {
  local rootvars tmplvars miss extra ok=1
  rootvars="$(grep -oE '^variable "[^"]+"' "${VARIABLES_TF}" | sed -E 's/variable "([^"]+)"/\1/' | sort -u)"
  tmplvars="$(grep -oE '^TF_VAR_[A-Za-z0-9_]+=' "${ENV_TEMPLATE}" | sed -E 's/^TF_VAR_([A-Za-z0-9_]+)=/\1/' | sort -u)"
  miss="$(comm -23 <(printf '%s\n' "${rootvars}") <(printf '%s\n' "${tmplvars}"))"
  extra="$(comm -13 <(printf '%s\n' "${rootvars}") <(printf '%s\n' "${tmplvars}"))"
  if [[ -n "${miss}" || -n "${extra}" ]]; then
    ok=0
    fail "env contract: .env-template" "missing: ${miss:-none} | extra: ${extra:-none}"
  fi
  if [[ -f "${ENV_FILE}" ]]; then
    local envvars miss_e extra_e
    envvars="$(grep -oE '^[[:space:]]*(export[[:space:]]+)?TF_VAR_[A-Za-z0-9_]+=' "${ENV_FILE}" | sed -E 's/.*TF_VAR_([A-Za-z0-9_]+)=.*/\1/' | sort -u)"
    miss_e="$(comm -23 <(printf '%s\n' "${rootvars}") <(printf '%s\n' "${envvars}"))"
    extra_e="$(comm -13 <(printf '%s\n' "${rootvars}") <(printf '%s\n' "${envvars}"))"
    if [[ -n "${miss_e}" || -n "${extra_e}" ]]; then
      ok=0
      fail "env contract: .env" "missing: ${miss_e:-none} | extra: ${extra_e:-none} (names only)"
    fi
  else
    skip "env contract: .env" "no .env present (structural template check still enforced)"
  fi
  if [[ ${ok} -eq 1 ]]; then
    pass "env contract (.env-template/.env define all root variables; names only)"
  fi
}

check_no_root_defaults() {
  local n
  n="$(grep -c '^  default' "${VARIABLES_TF}" || true)"
  if [[ "${n}" -eq 0 ]]; then
    pass "no root Terraform defaults in variables.tf"
  else
    fail "root Terraform defaults present (${n})" "remove every root 'default =' from ${VARIABLES_TF}"
  fi
}

check_no_tracked_artifacts() {
  local tracked
  tracked="$(git ls-files | grep -E '(^|/)\.env$|(^|/)\.env\.[^/]+$|\.tfvars$|\.auto\.tfvars(\.json)?$|(^|/)terraform\.tfstate|(^|/)\.cache/' | grep -vE '(^|/)\.env-template$' || true)"
  if [[ -z "${tracked}" ]]; then
    pass "no tracked .env/tfvars/state/cache artifacts"
  else
    fail "tracked sensitive artifacts" "${tracked}"
  fi
}

check_terraform_fmt() {
  if ! have terraform; then
    fail "terraform fmt -check -recursive" "install terraform: $(tool_hint terraform)"
    return
  fi
  if terraform -chdir="${TERRAFORM_DIR}" fmt -check -recursive >/dev/null; then
    pass "terraform fmt -check -recursive"
  else
    fail "terraform fmt -check -recursive" "run: terraform -chdir=infra/terraform fmt -recursive"
  fi
}

check_terraform_validate() {
  if ! have terraform; then
    fail "terraform validate" "install terraform: $(tool_hint terraform)"
    return
  fi
  if terraform -chdir="${TERRAFORM_DIR}" validate >/dev/null 2>&1; then
    pass "terraform validate"
  elif terraform -chdir="${TERRAFORM_DIR}" init -backend=false -input=false >/dev/null 2>&1 &&
    terraform -chdir="${TERRAFORM_DIR}" validate >/dev/null 2>&1; then
    pass "terraform validate"
  else
    fail "terraform validate" "run: terraform -chdir=infra/terraform validate"
  fi
}

check_tflint() {
  if ! have tflint; then
    fail "tflint" "install: $(tool_hint tflint)"
    return
  fi
  tflint --chdir="${TERRAFORM_DIR}" --init >/dev/null 2>&1 || true
  if tflint --chdir="${TERRAFORM_DIR}" --recursive; then
    pass "tflint"
  else
    fail "tflint" "review findings above"
  fi
}

check_bash_n() {
  local f rc=0
  while IFS= read -r -d '' f; do
    bash -n "${f}" || rc=1
  done < <(collect_shell)
  if [[ ${rc} -eq 0 ]]; then
    pass "bash -n (shell syntax)"
  else
    fail "bash -n (shell syntax)" "one or more scripts failed syntax check"
  fi
}

check_shellcheck() {
  if ! have shellcheck; then
    fail "shellcheck" "install: $(tool_hint shellcheck)"
    return
  fi
  local files=() f
  while IFS= read -r -d '' f; do files+=("${f}"); done < <(collect_shell)
  if [[ ${#files[@]} -eq 0 ]]; then
    skip "shellcheck" "no shell scripts"
    return
  fi
  if shellcheck -x --severity=error "${files[@]}"; then
    pass "shellcheck (error severity)"
  else
    fail "shellcheck" "review findings above"
  fi
}

check_shfmt() {
  if ! have shfmt; then
    fail "shfmt -d" "install: $(tool_hint shfmt)"
    return
  fi
  local files=() f diff
  while IFS= read -r -d '' f; do files+=("${f}"); done < <(collect_shell)
  if [[ ${#files[@]} -eq 0 ]]; then
    skip "shfmt -d" "no shell scripts"
    return
  fi
  diff="$(shfmt -i 2 -ci -d "${files[@]}" 2>&1 || true)"
  if [[ -z "${diff}" ]]; then
    pass "shfmt -d (format)"
  else
    printf '%s\n' "${diff}"
    fail "shfmt -d (format)" "run: shfmt -i 2 -ci -w <files>"
  fi
}

check_py_compile() {
  local files=() f
  while IFS= read -r -d '' f; do files+=("${f}"); done < <(git ls-files -z -- '*.py')
  if [[ ${#files[@]} -eq 0 ]]; then
    skip "python compile" "no .py files"
    return
  fi
  if python3 -X pycache_prefix="${ROOT_DIR}/.cache/pycache" -m py_compile "${files[@]}"; then
    pass "python compile"
  else
    fail "python compile"
  fi
}

check_ruff() {
  if ! have ruff; then
    fail "ruff check" "install: $(tool_hint ruff)"
    return
  fi
  if ruff check .; then
    pass "ruff check"
  else
    fail "ruff check" "review findings above"
  fi
}

check_pyright() {
  if ! have pyright; then
    fail "pyright" "install: $(tool_hint pyright)"
    return
  fi
  if pyright; then
    pass "pyright"
  else
    fail "pyright" "review findings above"
  fi
}

check_markdownlint() {
  local cmd=""
  if have markdownlint-cli2; then
    cmd="markdownlint-cli2"
  elif have markdownlint; then
    cmd="markdownlint"
  fi
  if [[ -z "${cmd}" ]]; then
    fail "markdownlint" "install: $(tool_hint markdownlint)"
    return
  fi
  local files=() f
  while IFS= read -r -d '' f; do files+=("${f}"); done < <(git ls-files -z -- '*.md')
  if [[ ${#files[@]} -eq 0 ]]; then
    skip "markdownlint" "no .md files"
    return
  fi
  if "${cmd}" "${files[@]}" >/dev/null 2>&1; then
    pass "markdownlint"
  else
    "${cmd}" "${files[@]}" || true
    fail "markdownlint" "review findings above"
  fi
}

check_yamllint() {
  if ! have yamllint; then
    fail "yamllint" "install: $(tool_hint yamllint)"
    return
  fi
  local files=() f
  while IFS= read -r -d '' f; do files+=("${f}"); done < <(git ls-files -z -- '*.yml' '*.yaml')
  if [[ ${#files[@]} -eq 0 ]]; then
    skip "yamllint" "no yaml files"
    return
  fi
  if yamllint -s "${files[@]}"; then
    pass "yamllint"
  else
    fail "yamllint" "review findings above"
  fi
}

check_hadolint() {
  if ! have hadolint; then
    fail "hadolint" "install: $(tool_hint hadolint)"
    return
  fi
  local files=() f rc=0
  while IFS= read -r -d '' f; do files+=("${f}"); done < <(git ls-files -z -- '*Dockerfile*' 'Dockerfile')
  if [[ ${#files[@]} -eq 0 ]]; then
    skip "hadolint" "no Dockerfiles"
    return
  fi
  for f in "${files[@]}"; do
    hadolint "${f}" || rc=1
  done
  if [[ ${rc} -eq 0 ]]; then
    pass "hadolint"
  else
    fail "hadolint" "review findings above"
  fi
}

check_trivy() {
  if ! have trivy; then
    fail "trivy (config/vuln/secret)" "install: $(tool_hint trivy)"
    return
  fi
  mkdir -p "${TRIVY_CACHE_DIR}"
  local skip_dirs=(
    --skip-dirs ".cache"
    --skip-dirs ".git"
    --skip-dirs "**/.terraform"
    --skip-dirs ".venv"
    --skip-dirs "**/terraform.tfstate.d"
  )
  local rc=0
  trivy config --quiet --severity HIGH,CRITICAL --exit-code 1 \
    --cache-dir "${TRIVY_CACHE_DIR}" "${skip_dirs[@]}" "${ROOT_DIR}" || rc=1
  trivy fs --quiet --scanners vuln --severity HIGH,CRITICAL --exit-code 1 \
    --cache-dir "${TRIVY_CACHE_DIR}" "${skip_dirs[@]}" "${ROOT_DIR}" || rc=1
  trivy fs --quiet --scanners secret --exit-code 1 \
    --cache-dir "${TRIVY_CACHE_DIR}" "${skip_dirs[@]}" --skip-files "${ENV_FILE}" "${ROOT_DIR}" || rc=1
  if [[ ${rc} -eq 0 ]]; then
    pass "trivy (config/vuln/secret, HIGH+CRITICAL)"
  else
    fail "trivy (config/vuln/secret)" "review findings above"
  fi
}

summarize() {
  log "-----------------------------------------------------------------"
  log "Passed: ${PASS_COUNT}   Failed: ${#FAILURES[@]}   Skipped: ${#SKIPS[@]}"
  if [[ ${#SKIPS[@]} -gt 0 ]]; then
    log "Skipped (optional / no inputs):"
    local s
    for s in "${SKIPS[@]}"; do log "  - ${s}"; done
  fi
  if [[ ${#FAILURES[@]} -gt 0 ]]; then
    log "Failed checks:"
    local x
    for x in "${FAILURES[@]}"; do log "  - ${x}"; done
    log ""
    log "Gate FAILED. Install any missing required tools listed above, fix findings, and re-run:"
    log "  ./scripts/quality-gate.sh"
    return 1
  fi
  log "Gate PASSED."
  return 0
}

main() {
  log "Quality gate: ${ROOT_DIR}"
  log ""
  log "Structural contract:"
  check_env_contract
  check_no_root_defaults
  check_no_tracked_artifacts
  log ""
  log "Terraform:"
  check_terraform_fmt
  check_terraform_validate
  check_tflint
  log ""
  log "Shell:"
  check_bash_n
  check_shellcheck
  check_shfmt
  log ""
  log "Python:"
  check_py_compile
  check_ruff
  check_pyright
  log ""
  log "Docs & config lint:"
  check_markdownlint
  check_yamllint
  check_hadolint
  log ""
  log "Security (Trivy, cache under .cache/trivy):"
  check_trivy
  log ""
  summarize
}

main "$@"
