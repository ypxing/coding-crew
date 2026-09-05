#!/usr/bin/env bash
# Detect which docker compose service a project's own Makefile targets use, by dry-running
# known targets and extracting the service token from an expanded `docker compose run`/`exec`
# recipe. Prints the service name to stdout if found; prints nothing (exit 0) otherwise.
#
# Usage:
#   bash scripts/detect-service.sh --project-root /path/to/worktree [--main-root /path]
#
# This is a signal *for* the cache, not a read of it: verify-worktree.sh and docker-install.sh
# already check `git config agent.install-service`, then dev-commands.json's "docker_service"
# field, before ever falling back to gen-override.sh's own first-service-in-file-order guess.
# This script is what feeds that cache when a Makefile target names its service explicitly —
# a stronger signal than file order alone, since a human wrote that target knowing which
# service its command needs (e.g. a repo with unrelated "node" and "compass" services, where
# only "node" has the project's package manager).

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

# The real services declared in the compose file — a candidate token from a Makefile recipe is
# only trusted if it names one of these. Without this cross-check, a value-taking flag before
# the actual service (`-e KEY=val`, `--entrypoint sh`) could be mistaken for the service itself.
KNOWN_SERVICES="$(bash "$GEN_OVERRIDE" --project-root "$PROJECT_ROOT" --main-root "$MAIN_ROOT" --query services 2>/dev/null || true)"
[ -n "$KNOWN_SERVICES" ] || exit 0

# _service_from_recipe <recipe text> — walks the tokens after the first `docker compose run`/
# `exec` on any line, skipping flag tokens (anything starting with `-`, including a value-taking
# flag's own value token, e.g. "KEY=val" after `-e`), and returns the first remaining token that
# is also a real compose service. Stops at the first match rather than assuming a fixed number of
# leading flags, since `--rm`, `-T`, `--remove-orphans`, etc. vary per Makefile.
_service_from_recipe() {
  local rest tok
  rest="$(printf '%s\n' "$1" | grep -oE 'docker[ -]compose[[:space:]]+(run|exec)[[:space:]]+.*' | head -1)" || true
  [ -n "$rest" ] || return 0
  rest="$(printf '%s\n' "$rest" | sed -E 's/^docker[ -]compose[[:space:]]+(run|exec)[[:space:]]+//')"
  for tok in $rest; do
    case "$tok" in
      -*) continue ;;
    esac
    if printf '%s\n' "$KNOWN_SERVICES" | grep -qxF "$tok"; then
      printf '%s\n' "$tok"
      return 0
    fi
  done
  return 0
}

for _target in install deps setup depend bootstrap prepare up build dev lint test typecheck; do
  ( cd "$PROJECT_ROOT" && make -n "$_target" ) >/dev/null 2>&1 || continue
  _recipe="$(cd "$PROJECT_ROOT" && make -n "$_target" 2>/dev/null || true)"
  printf '%s' "$_recipe" | grep -qE 'docker (compose|run|exec)' || continue
  _found="$(_service_from_recipe "$_recipe")"
  if [ -n "$_found" ]; then
    echo "$_found"
    exit 0
  fi
done
