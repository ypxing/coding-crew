#!/usr/bin/env bash
# Detect and run the right host install command for PROJECT_ROOT.
# Checks (in order): the dev commands file's "install" command, then the lockfile table.
# Usage: host-install.sh --project-root <path>
# Exit codes: 0 installed, 1 argument error, 2 no install method, 3 install failed

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

# .env first, best-effort, whether or not an install method is found: the checks may need one.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SELF_DIR/ensure-env.sh" --project-root "$PROJECT_ROOT" >/dev/null 2>&1 || true

# shellcheck source=/dev/null
. "$SELF_DIR/commands-file.sh"
cached=$(commands_field "$(commands_file "$PROJECT_ROOT")" install)
if [[ -n "$cached" ]]; then
  echo "Running: $cached"
  bash -c "$cached" || exit 3
  exit 0
fi

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
# Python with no uv/poetry lockfile: python-install-cmd.sh adds the dev tools pip would leave out.
python_cmd=$(bash "$SELF_DIR/python-install-cmd.sh" "$PROJECT_ROOT")
if [[ -n "$python_cmd" ]]; then
  echo "Running: $python_cmd"
  bash -c "$python_cmd"
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
