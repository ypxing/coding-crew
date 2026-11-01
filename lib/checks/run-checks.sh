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
# RUN: no command found` (the cache's null), or `<key>: modified files: <list>` (then a fail); last,
# CHECKS: pass (exit 0) | CHECKS: fail (exit 1) | DISCOVER (exit 3: no usable cache).
#
# A check that rewrites tracked files (a `lint --fix`) is not a fail by itself: every check then runs a
# second time on the rewritten tree, and any change there fails. `<key>: rewrote: <files>` lines, one per
# check that rewrote, come before the CHECKS line, on a pass or a fail; the rewrites stay in the tree, for
# the caller to commit. A file a check creates or removes that git does not ignore always fails.

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

# Prior dirt is in the before snapshot, so only what the check itself changed counts. -z: git quotes a
# path with a space or a non-ASCII byte otherwise, and the `rewrote:` names go to `git add` as written.
_tree_state() {
  git -C "$PROJECT_ROOT" status --porcelain -z --no-renames 2>/dev/null | tr '\0' '\n' | LC_ALL=C sort
}
# "<blob> <path>" per dirty or untracked file: the second pass's own check, as a second rewrite of a file
# the first pass already dirtied leaves its porcelain line as it was.
_content_state() {
  local top paths
  top=$(git -C "$PROJECT_ROOT" rev-parse --show-toplevel 2>/dev/null) || return 0
  paths=$(cd "$top" && { git diff --name-only -z HEAD 2>/dev/null; git ls-files -o -z --exclude-standard; } |
    tr '\0' '\n' | LC_ALL=C sort -u | while IFS= read -r p; do [ ! -f "$p" ] || printf '%s\n' "$p"; done)
  [ -n "$paths" ] || return 0
  paste -d' ' <(cd "$top" && git hash-object --stdin-paths <<<"$paths") <(printf '%s\n' "$paths")
}
# _changed_files <before> <after> <tracked|untracked|all> — the paths whose porcelain line differs, comma-separated.
# A deleted tracked file counts as untracked: removing a file is not a rewrite.
_changed_files() {
  LC_ALL=C comm -3 <(printf '%s\n' "$1") <(printf '%s\n' "$2") | sed -E 's/^\t//' |
    awk -v want="$3" 'NF { u = substr($0, 1, 2) == "??" || substr($0, 1, 2) ~ /D/
      if (want == "all" || (want == "untracked") == u) { p = substr($0, 4); if (!seen[p]++) printf "%s%s", (n++ ? ", " : ""), p } }'
}
_changed_content() {
  LC_ALL=C comm -3 <(printf '%s\n' "$1") <(printf '%s\n' "$2") | sed -E 's/^\t//' | cut -d' ' -f2- |
    awk 'NF && !seen[$0]++ { printf "%s%s", (n++ ? ", " : ""), $0 }'
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

REWROTE=() PASS_FAIL=0 CREATED_FAIL=0
# run_pass <1|2> — every check once. Pass 1 counts a rewrite of tracked files apart from a fail; pass 2 fails
# on any change at all.
run_pass() {
  local pass=$1 key cmd log before after cbefore="" cafter="" rc changed created
  PASS_FAIL=0
  for key in "${KEYS[@]}"; do
    case "$key" in coverage|integration) commands_field_present "$CACHE" "$key" || continue ;; esac
    cmd="$(commands_field "$CACHE" "$key")"
    if [ -z "$cmd" ]; then
      [ "$pass" = 2 ] || echo "$key: NOT RUN: no command found"
      continue
    fi
    log="$LOG_DIR/$key.log"
    [ "$pass" = 1 ] || log="$LOG_DIR/$key.pass2.log"
    echo "=== $key$([ "$pass" = 1 ] || echo " (second pass)"): $cmd"
    before="$(_tree_state)"
    [ "$pass" = 1 ] || cbefore="$(_content_state)"
    # stdin from /dev/null: a `docker compose run` would otherwise read the rest of this loop. Logged
    # through a pipe: on overlayfs a check writing straight to a file under /tmp can hang forever.
    bash "$RUN_SCRIPT" --project-root "$PROJECT_ROOT" -- "$cmd" \
      </dev/null 2>&1 | cat >"$log"
    rc=${PIPESTATUS[0]}
    after="$(_tree_state)"
    tail -n 80 "$log"
    changed="" created=""
    if [ "$pass" = 1 ]; then
      created="$(_changed_files "$before" "$after" untracked)"
      changed="$(_changed_files "$before" "$after" tracked)"
      [ -z "$changed" ] || REWROTE+=("$key: rewrote: $changed")
      changed=""
    else
      cafter="$(_content_state)"
      changed="$(_changed_files "$before" "$after" all)"
      [ "$cbefore" = "$cafter" ] || changed="$(printf '%s, %s' "$changed" "$(_changed_content "$cbefore" "$cafter")" |
        tr ',' '\n' | sed 's/^ *//' | awk 'NF && !seen[$0]++ { printf "%s%s", (n++ ? ", " : ""), $0 }')"
    fi
    if [ -n "$created" ]; then
      echo "$key: modified files: $created — the check created or removed files git does not ignore: ignore them, or name a command for it in $CACHE that leaves none"
      echo "$key: fail (exit $rc, modified files)"
      CREATED_FAIL=1
    elif [ -n "$changed" ]; then
      echo "$key: modified files: $changed — the check rewrote them again on a second run: name a non-mutating command for it in $CACHE"
      echo "$key: fail (exit $rc, modified files)"
      PASS_FAIL=1
    elif [ "$rc" -eq 0 ]; then
      echo "$key: pass"
    else
      echo "$key: fail (exit $rc)"
      PASS_FAIL=1
    fi
    echo "$key: log: $log"
  done
}

run_pass 1
# The second pass gates the tree the caller commits, so its verdict replaces the first's.
if [ "${#REWROTE[@]}" -gt 0 ]; then
  echo "=== checks rewrote files: running every check again"
  run_pass 2
fi
OVERALL=0
[ "$PASS_FAIL" = 0 ] && [ "$CREATED_FAIL" = 0 ] || OVERALL=1
[ "${#REWROTE[@]}" -eq 0 ] || printf '%s\n' "${REWROTE[@]}"
if [ "$OVERALL" -eq 0 ]; then echo "CHECKS: pass"; else echo "CHECKS: fail"; fi
exit "$OVERALL"
