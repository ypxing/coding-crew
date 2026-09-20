#!/usr/bin/env bash
# Detect and run the right host install command for PROJECT_ROOT.
# Checks (in order): Makefile install/deps target, then signal file fallback.
# CLAUDE.md is intentionally excluded — the LLM reads that for context.
#
# Usage: host-install.sh --project-root <path> [--main-root <path>] [--force]
#
# --force skips the manifest-fingerprint fast path below and always reinstalls — dep-install's
# own retry rule uses this on a module-not-found error, since a FRESH verdict there would
# otherwise make the retry a no-op (see manifest-fingerprint.sh's own header comment on what
# a FRESH verdict does and does not prove).
#
# Exit codes:
#   0  install ran successfully, or skipped because manifests are unchanged since last time
#   1  argument error
#   2  no install method found
#   3  install command failed

set -euo pipefail

PROJECT_ROOT=""
MAIN_ROOT=""
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root) PROJECT_ROOT="$2"; shift 2 ;;
    --main-root)    MAIN_ROOT="$2";    shift 2 ;;
    --force)        FORCE=1;          shift   ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$PROJECT_ROOT" ]]; then
  echo "Error: --project-root is required" >&2
  exit 1
fi

if [[ ! -d "$PROJECT_ROOT" ]]; then
  echo "Error: PROJECT_ROOT does not exist: $PROJECT_ROOT" >&2
  exit 1
fi

cd "$PROJECT_ROOT"

# --- 0. .env (mechanical, mirrors docker-install.sh's own ensure-env.sh call) ---
# Unconditional and best-effort, regardless of whether an install method is found below:
# verify-worktree.sh runs test/lint/typecheck either way, and those can need a .env that
# was never this script's job to create until now. ensure-env.sh itself never reads .env*
# content — it only creates the file (from .env.example, or empty) if one is missing.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENSURE_ENV="$SELF_DIR/ensure-env.sh"
if [[ -f "$ENSURE_ENV" ]]; then
  if [[ -n "$MAIN_ROOT" ]]; then
    bash "$ENSURE_ENV" --project-root "$PROJECT_ROOT" --main-root "$MAIN_ROOT" >/dev/null 2>&1 || true
  else
    bash "$ENSURE_ENV" --project-root "$PROJECT_ROOT" >/dev/null 2>&1 || true
  fi
fi

# --- 0b. skip if manifests are unchanged since this worktree's own last successful install ---
# STAMP lives per-worktree (unlike docker's shared-volume marker) since host installs land in
# this worktree's own node_modules/.venv/etc., not somewhere shared across worktrees.
FINGERPRINT="$SELF_DIR/manifest-fingerprint.sh"
STAMP="$PROJECT_ROOT/.scratch/host-install.done"
if [[ "$FORCE" -ne 1 ]] && [[ -f "$FINGERPRINT" ]] &&
   [[ "$(bash "$FINGERPRINT" check --project-root "$PROJECT_ROOT" --stamp "$STAMP" 2>/dev/null)" == "FRESH" ]]; then
  echo "Running: (skipped — manifests unchanged since last install)"
  exit 0
fi

# _mark_installed — record this run's fingerprint so the next call can skip. Best-effort:
# a write failure here just costs the next call its fast path, not this one's success.
_mark_installed() {
  [[ -f "$FINGERPRINT" ]] && bash "$FINGERPRINT" write --project-root "$PROJECT_ROOT" --stamp "$STAMP" >/dev/null 2>&1 || true
}

# --- 1. Makefile target (install or deps, no docker) ---
if [[ -f Makefile ]]; then
  for target in install deps; do
    # A non-empty dry-run is the "target exists" signal, not exit status — a recipe
    # containing the literal word "make" can make some GNU Make builds (macOS's default
    # 3.81 included) actually run it under -n instead of only printing it, so a real
    # (sandboxed, daemon-less) docker failure could otherwise be mistaken for "no such
    # target" even though the recipe text we want is right there in the output.
    recipe=$(make -n "$target" 2>/dev/null || true)
    if [[ -n "$recipe" ]]; then
      if echo "$recipe" | grep -qE 'docker (compose|run|exec)'; then
        echo "Skipping make $target — recipe invokes docker" >&2
      else
        echo "Running: make $target"
        make "$target"
        _mark_installed
        exit 0
      fi
    fi
  done
fi

# --- 2. Signal file fallback ---
run() {
  echo "Running: $*"
  "$@"
  _mark_installed
  exit 0
}

[[ -f uv.lock            ]] && run uv sync --frozen
[[ -f bun.lockb          ]] && run bun install --frozen-lockfile
[[ -f pnpm-lock.yaml     ]] && run pnpm install --frozen-lockfile
[[ -f package-lock.json  ]] && run npm ci
[[ -f yarn.lock          ]] && run yarn install --frozen-lockfile
[[ -f poetry.lock        ]] && run poetry install --no-root
[[ -f go.sum             ]] && run go mod download
[[ -f go.mod             ]] && run go mod download
[[ -f requirements.txt   ]] && run pip install -r requirements.txt --quiet
[[ -f pyproject.toml     ]] && run pip install --quiet .
[[ -f Gemfile.lock       ]] && run bundle install
[[ -f Cargo.toml         ]] && run cargo fetch
[[ -f composer.json      ]] && run composer install --no-interaction
[[ -f pom.xml            ]] && run mvn dependency:resolve dependency:resolve-plugins -q
[[ -f mix.exs            ]] && run mix deps.get

# *.csproj (glob)
csproj=$(find . -maxdepth 2 -name "*.csproj" | head -1)
[[ -n "$csproj" ]] && run dotnet restore

echo "No install method found in $PROJECT_ROOT" >&2
exit 2
