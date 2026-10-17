#!/usr/bin/env bash
# Detect and run the right host install command for PROJECT_ROOT.
# Checks (in order): the dev commands file's "install" command, then install-cmd.sh's lockfile table.
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

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd -P)"
cd "$PROJECT_ROOT"

# .env first, best-effort, whether or not an install method is found: the checks may need one.
bash "$SELF_DIR/ensure-env.sh" --project-root "$PROJECT_ROOT" >/dev/null 2>&1 || true

# shellcheck source=/dev/null
. "$SELF_DIR/commands-file.sh"
cached=$(commands_field "$(commands_file "$PROJECT_ROOT")" install)
if [[ -n "$cached" ]]; then
  echo "Running: $cached"
  bash -c "$cached" || exit 3
  exit 0
fi

cmd=$(bash "$SELF_DIR/install-cmd.sh" "$PROJECT_ROOT")
if [[ -n "$cmd" ]]; then
  echo "Running: $cmd"
  bash -c "$cmd" || exit 3
  exit 0
fi

echo "No install method found in $PROJECT_ROOT" >&2
exit 2
