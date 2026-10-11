#!/usr/bin/env bash
# Print the compose service a project's Makefile targets use (from their `make -n` docker compose
# run/exec recipes), or nothing (exit 0).
#
# Usage:
#   bash scripts/detect-service.sh --project-root /path/to/worktree [--main-root /path]
# Feeds the "docker_service" cache: a Makefile target naming its service is a stronger signal than
# gen-override.sh's first-service-in-file-order guess.

set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
MAIN_ROOT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root) PROJECT_ROOT="$2"; shift 2 ;;
    --main-root) MAIN_ROOT="$2"; shift 2 ;;
    --help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Error: unknown argument: $1" >&2; exit 1 ;;
  esac
done

[ -n "$MAIN_ROOT" ] || MAIN_ROOT="$PROJECT_ROOT"
[ -f "$PROJECT_ROOT/Makefile" ] || exit 0

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN_OVERRIDE="$SELF_DIR/gen-override.sh"
[ -f "$GEN_OVERRIDE" ] || exit 0

# A recipe token counts only if it names a real service, so a flag's value (`-e KEY=val`) never does.
KNOWN_SERVICES="$(bash "$GEN_OVERRIDE" --project-root "$PROJECT_ROOT" --main-root "$MAIN_ROOT" --query services 2>/dev/null || true)"
[ -n "$KNOWN_SERVICES" ] || exit 0

# _service_from_recipe <recipe text> — the first non-flag token after `docker compose run`/`exec` that is a real service.
_service_from_recipe() {
  local rest tok
  rest="$(printf '%s\n' "$1" | grep -oE 'docker[ -]compose[[:space:]]+(run|exec)[[:space:]]+.*' | head -1)" || true
  [ -n "$rest" ] || return 0
  rest="$(printf '%s\n' "$rest" | sed -E 's/^docker[ -]compose[[:space:]]+(run|exec)[[:space:]]+//')"
  for tok in $rest; do
    case "$tok" in
      -*) continue ;;
    esac
    if grep -qxF -- "$tok" <<<"$KNOWN_SERVICES"; then
      printf '%s\n' "$tok"
      return 0
    fi
  done
  return 0
}

for _target in install deps setup depend bootstrap prepare up build dev lint test typecheck; do
  # No exit-code gate: some GNU Make builds (3.81) run a recipe containing "make" even under -n.
  _recipe="$(cd "$PROJECT_ROOT" && make -n "$_target" 2>/dev/null || true)"
  grep -qE 'docker (compose|run|exec)' <<<"$_recipe" || continue
  _found="$(_service_from_recipe "$_recipe")"
  if [ -n "$_found" ]; then
    echo "$_found"
    exit 0
  fi
done
