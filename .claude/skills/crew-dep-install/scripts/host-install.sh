#!/usr/bin/env bash
# Detect and run the right host install command for PROJECT_ROOT.
# Checks (in order): Makefile install/deps target, then signal file fallback.
# CLAUDE.md is intentionally excluded — the LLM reads that for context.
#
# Usage: host-install.sh --project-root <path>
# Exit codes:
#   0  install ran successfully
#   1  argument error
#   2  no install method found
#   3  install command failed

set -euo pipefail

PROJECT_ROOT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root) PROJECT_ROOT="$2"; shift 2 ;;
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

# --- 1. Makefile target (install or deps, no docker) ---
if [[ -f Makefile ]]; then
  for target in install deps; do
    if make -n "$target" &>/dev/null 2>&1; then
      recipe=$(make -n "$target" 2>/dev/null || true)
      if echo "$recipe" | grep -qE 'docker (compose|run|exec)'; then
        echo "Skipping make $target — recipe invokes docker" >&2
      else
        echo "Running: make $target"
        make "$target"
        exit 0
      fi
    fi
  done
fi

# --- 2. Signal file fallback ---
run() {
  echo "Running: $*"
  "$@"
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
