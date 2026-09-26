#!/usr/bin/env bash
# run-checks.sh — run every check .coding-crew/dev-commands.json names, each through
# dep-install's run.sh, and report each one.
#
# Usage:
#   bash scripts/run-checks.sh --project-root <path> --main-root <path> --dep-scripts <dir>
#
# Order: typecheck, lint, test, then every other check key with a command (coverage,
# integration, …) in file order — the same set, in the same order, crew-afk's verify gate runs,
# so a worker that sees every line pass has seen what the gate will see.
#
# Prints per check:
#   <key>: pass | <key>: fail (exit N)     then the tail of its output; the full log path
#   <key>: NOT RUN: no command found       the cache's `null` — its own answer, not a gap to fill
# and last, one of:
#   CHECKS: pass                           exit 0
#   CHECKS: fail                           exit 1
#   DISCOVER                               exit 3 — no usable cache: discover the commands
#                                          (references/verification.md), persist them, re-run
#
# The cache is read from MAIN_ROOT — resolved from --git-common-dir when --main-root is empty,
# so a lost MAIN_ROOT still finds the shared cache instead of concluding there is none.

set -uo pipefail

PROJECT_ROOT=""
MAIN_ROOT=""
DEP_SCRIPTS=""
TAIL_LINES="${CREW_CHECK_TAIL_LINES:-80}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root|--main-root|--dep-scripts)
      if [ $# -lt 2 ]; then echo "Error: $1 requires a value" >&2; exit 2; fi
      case "$1" in
        --project-root) PROJECT_ROOT="$2" ;;
        --main-root) MAIN_ROOT="$2" ;;
        --dep-scripts) DEP_SCRIPTS="$2" ;;
      esac
      shift 2
      ;;
    --help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$PROJECT_ROOT" ] || [ ! -d "$PROJECT_ROOT" ]; then
  echo "Error: --project-root <existing dir> is required" >&2
  exit 2
fi
RUN_SCRIPT="$DEP_SCRIPTS/run.sh"
if [ -z "$DEP_SCRIPTS" ] || [ ! -f "$RUN_SCRIPT" ]; then
  echo "Error: --dep-scripts must name dep-install's scripts directory (no run.sh at '$DEP_SCRIPTS')" >&2
  exit 2
fi

_main_root_of() {
  local dir="$1" common
  common=$(cd "$dir" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*|[A-Za-z]:*) : ;;
    *) common="$dir/$common" ;;
  esac
  common="$(cd "$dir" && cd "$(dirname "$common")" && pwd -P)/$(basename "$common")"
  dirname "$common"
}
[ -n "$MAIN_ROOT" ] || MAIN_ROOT="$(_main_root_of "$PROJECT_ROOT" 2>/dev/null || true)"
CACHE="${MAIN_ROOT:+$MAIN_ROOT/.coding-crew/dev-commands.json}"

if [ -z "$CACHE" ] || [ ! -f "$CACHE" ] || ! grep -q '"test"' "$CACHE" 2>/dev/null; then
  echo "DISCOVER"
  exit 3
fi

# Keys of dev-commands.json that are not checks — kept in step with verify-worktree.sh's own list.
NOT_CHECKS=" test lint typecheck install install_mode env credential_target docker_service "

# _cached <key> — its command; empty for `null` or an absent key. Parsed the way
# verify-worktree.sh's _load_cached_command parses it, so both read the same command.
_cached() {
  local raw
  raw=$(grep -o "\"$1\"[[:space:]]*:[[:space:]]*\(\"[^\"]*\"\|null\)" "$CACHE" 2>/dev/null | head -1 | sed -E "s/\"$1\"[[:space:]]*:[[:space:]]*//")
  case "$raw" in
    \"*\") raw="${raw#\"}"; printf '%s' "${raw%\"}" ;;
  esac
}

KEYS=(typecheck lint test)
while IFS= read -r key; do
  [[ "$NOT_CHECKS" == *" $key "* ]] || KEYS+=("$key")
done < <(grep -oE '"[a-z][a-z0-9_]*"[[:space:]]*:[[:space:]]*("|null)' "$CACHE" 2>/dev/null \
  | sed -E 's/^"([a-z0-9_]+)".*/\1/' | awk '!seen[$0]++')

LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/solve-issue-checks.XXXXXX")"
OVERALL=0
for key in "${KEYS[@]}"; do
  cmd="$(_cached "$key")"
  if [ -z "$cmd" ]; then
    echo "$key: NOT RUN: no command found"
    continue
  fi
  log="$LOG_DIR/$key.log"
  echo "=== $key: $cmd"
  # stdin from /dev/null: a `docker compose run` would otherwise read the rest of this loop.
  bash "$RUN_SCRIPT" --project-root "$PROJECT_ROOT" ${MAIN_ROOT:+--main-root "$MAIN_ROOT"} -- "$cmd" \
    </dev/null >"$log" 2>&1
  rc=$?
  tail -n "$TAIL_LINES" "$log"
  if [ "$rc" -eq 0 ]; then
    echo "$key: pass"
  else
    echo "$key: fail (exit $rc)"
    OVERALL=1
  fi
  echo "$key: log: $log"
done

if [ "$OVERALL" -eq 0 ]; then echo "CHECKS: pass"; else echo "CHECKS: fail"; fi
exit "$OVERALL"
