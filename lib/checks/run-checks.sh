#!/usr/bin/env bash
# run-checks.sh — run every check the clone's dev commands file (commands-file.sh) names, each through
# run.sh beside it, and report each one.
#
# Usage:
#   bash scripts/run-checks.sh --project-root <path>
#
# Order: typecheck, lint, test, coverage, integration: the checks write-commands-cache.sh writes. In docker mode with no override
# yet, the dependency install runs once first; if it fails, no check runs (CHECKS: fail).
# Prints per check `<key>: pass`, `<key>: fail (exit N)` (then its output tail and log path), `<key>: NOT
# RUN: no command found` (the cache's null), or `<key>: modified files: <list>` (the check rewrote files;
# then a fail); last, CHECKS: pass (exit 0) | CHECKS: fail (exit 1) | DISCOVER (exit 3: no usable cache).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SCRIPT="$SELF_DIR/run.sh"
PROJECT_ROOT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root)
      if [ $# -lt 2 ]; then echo "Error: $1 requires a value" >&2; exit 2; fi
      PROJECT_ROOT="$2"
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
# shellcheck source=/dev/null
. "$SELF_DIR/commands-file.sh"
CACHE=$(commands_file "$PROJECT_ROOT")

if ! commands_field_present "$CACHE" test; then
  echo "DISCOVER"
  exit 3
fi

KEYS=(typecheck lint test coverage integration)

# A check must leave the tree as it found it; prior dirt is in the before snapshot.
_tree_state() {
  git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null | LC_ALL=C sort
}
_changed_files() {
  LC_ALL=C comm -3 <(printf '%s\n' "$1") <(printf '%s\n' "$2") \
    | sed -E 's/^\t//; s/^...//' \
    | awk 'NF && !seen[$0]++ { printf "%s%s", (n++ ? ", " : ""), $0 }'
}

# Without a log dir every check would write to /<key>.log and fail, blaming the project for a full disk.
if ! LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/solve-issue-checks.XXXXXX")"; then
  echo "checks: cannot create a log dir under ${TMPDIR:-/tmp} (is the disk full?) — no check ran"
  echo "CHECKS: fail"
  exit 1
fi

# One install up front: run.sh would otherwise retry a failing install once per check.
_gitdir="$(git -C "$PROJECT_ROOT" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
if grep -qx 'INSTALL_MODE=docker' <<< "$(bash "$SELF_DIR/resolve-mode.sh" --project-root "$PROJECT_ROOT")" \
  && [ ! -f "$_gitdir/crew-compose.override.yml" ]; then
  echo "=== install (docker)"
  if ! bash "$RUN_SCRIPT" --project-root "$PROJECT_ROOT" -- true </dev/null; then
    echo "install: fail — no check ran"
    echo "CHECKS: fail"
    exit 1
  fi
fi

OVERALL=0
for key in "${KEYS[@]}"; do
  case "$key" in coverage|integration) commands_field_present "$CACHE" "$key" || continue ;; esac
  cmd="$(commands_field "$CACHE" "$key")"
  if [ -z "$cmd" ]; then
    echo "$key: NOT RUN: no command found"
    continue
  fi
  log="$LOG_DIR/$key.log"
  echo "=== $key: $cmd"
  before="$(_tree_state)"
  # stdin from /dev/null: a `docker compose run` would otherwise read the rest of this loop. Logged
  # through a pipe: on overlayfs a check writing straight to a file under /tmp can hang forever.
  bash "$RUN_SCRIPT" --project-root "$PROJECT_ROOT" -- "$cmd" \
    </dev/null 2>&1 | cat >"$log"
  rc=${PIPESTATUS[0]}
  after="$(_tree_state)"
  changed=""
  [ "$before" = "$after" ] || changed="$(_changed_files "$before" "$after")"
  tail -n 80 "$log"
  if [ -n "$changed" ]; then
    echo "$key: modified files: $changed — the check rewrote them: run it, commit the result, and re-run (a check that rewrites files on every run needs a non-mutating command in $CACHE)"
    echo "$key: fail (exit $rc, modified files)"
    OVERALL=1
  elif [ "$rc" -eq 0 ]; then
    echo "$key: pass"
  else
    echo "$key: fail (exit $rc)"
    OVERALL=1
  fi
  echo "$key: log: $log"
done

if [ "$OVERALL" -eq 0 ]; then echo "CHECKS: pass"; else echo "CHECKS: fail"; fi
exit "$OVERALL"
