#!/usr/bin/env bash
# Detect and run the right host install command for PROJECT_ROOT.
# Checks (in order): Makefile install/deps target, then signal file fallback.
# Usage: host-install.sh --project-root <path> [--main-root <path>] [--force]
#
# --force skips the manifest-fingerprint fast path: dep-install's module-not-found retry needs it.
# Exit codes: 0 installed (or manifests unchanged), 1 argument error, 2 no install method, 3 install failed

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

# .env first, best-effort, whether or not an install method is found: the checks may need one.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENSURE_ENV="$SELF_DIR/ensure-env.sh"
if [[ -f "$ENSURE_ENV" ]]; then
  if [[ -n "$MAIN_ROOT" ]]; then
    bash "$ENSURE_ENV" --project-root "$PROJECT_ROOT" --main-root "$MAIN_ROOT" >/dev/null 2>&1 || true
  else
    bash "$ENSURE_ENV" --project-root "$PROJECT_ROOT" >/dev/null 2>&1 || true
  fi
fi

# Skip when manifests are unchanged since this worktree's last install (host installs are per worktree).
FINGERPRINT="$SELF_DIR/manifest-fingerprint.sh"
STAMP="$PROJECT_ROOT/.scratch/host-install.done"
if [[ "$FORCE" -ne 1 ]] && [[ -f "$FINGERPRINT" ]] &&
   [[ "$(bash "$FINGERPRINT" check --project-root "$PROJECT_ROOT" --stamp "$STAMP" 2>/dev/null)" == "FRESH" ]]; then
  echo "Running: (skipped — manifests unchanged since last install)"
  exit 0
fi

# _mark_installed — best-effort: a failed write only costs the next call its fast path.
_mark_installed() {
  [[ -f "$FINGERPRINT" ]] && bash "$FINGERPRINT" write --project-root "$PROJECT_ROOT" --stamp "$STAMP" >/dev/null 2>&1 || true
}

if [[ -f Makefile ]]; then
  for target in install deps; do
    # Non-empty output, not exit status, means the target exists: some GNU Make builds (3.81) run a
    # recipe containing "make" even under -n, so a daemon-less docker failure would read as no target.
    recipe=$(make -n "$target" 2>/dev/null || true)
    if [[ -n "$recipe" ]]; then
      if grep -qE 'docker (compose|run|exec)' <<<"$recipe"; then
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
# Python with no uv/poetry lockfile: python-install-cmd.sh adds the dev tools pip would leave out.
python_cmd=$(bash "$SELF_DIR/python-install-cmd.sh" "$PROJECT_ROOT")
if [[ -n "$python_cmd" ]]; then
  echo "Running: $python_cmd"
  bash -c "$python_cmd"
  _mark_installed
  exit 0
fi
[[ -f Gemfile.lock       ]] && run bundle install
[[ -f Cargo.toml         ]] && run cargo fetch
[[ -f composer.json      ]] && run composer install --no-interaction
[[ -f pom.xml            ]] && run mvn dependency:resolve dependency:resolve-plugins -q
[[ -f mix.exs            ]] && run mix deps.get

csproj=$(find . -maxdepth 2 -name "*.csproj" | head -1)
[[ -n "$csproj" ]] && run dotnet restore

echo "No install method found in $PROJECT_ROOT" >&2
exit 2
