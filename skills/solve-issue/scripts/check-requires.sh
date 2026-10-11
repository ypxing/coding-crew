#!/usr/bin/env bash
# check-requires.sh — run what each issue's `## Requires` section says it needs, once.
#
# Usage:
#   bash scripts/check-requires.sh --project-root <dir> --issue <file> [--issue <file> …] [--timeout <s>]
#
# Each `## Requires` bullet's first backtick span is a shell command (exit 0 = satisfied), run on the host
# in <project-root> once even if two issues share it; --timeout (default 300) bounds each command.
# Prints, per issue and command:
#   REQUIRE: pass <issue> <cmd>
#   REQUIRE: fail <issue> <cmd>
#     exit <N>                          or: timed out after <s>s
#     | <output line>                   the tail of its output
# and exits 1 if any command failed, else 0. An issue with no `## Requires` prints nothing and passes.

set -uo pipefail

PROJECT_ROOT=""
ISSUES=()
TIMEOUT=300
TAIL_LINES="${CREW_REQUIRE_TAIL_LINES:-20}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root|--issue|--timeout)
      if [ $# -lt 2 ]; then echo "Error: $1 requires a value" >&2; exit 2; fi
      case "$1" in
        --project-root) PROJECT_ROOT="$2" ;;
        --issue) ISSUES+=("$2") ;;
        --timeout) TIMEOUT="$2" ;;
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
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] && [ "$TIMEOUT" -gt 0 ] || { echo "Error: --timeout must be a positive number of seconds" >&2; exit 2; }
[ "${#ISSUES[@]}" -gt 0 ] || exit 0

# _requires <issue> — the first backtick span of each `## Requires` bullet, up to the next heading.
_requires() {
  awk '/^## Requires[[:space:]]*$/{f=1;next} /^#+ /{f=0} f' "$1" 2>/dev/null \
    | sed -n 's/^[[:space:]]*[-*][[:space:]][^`]*`\([^`][^`]*\)`.*/\1/p'
}

# _run <cmd> <log> — exit code, or 124 once TIMEOUT passes. Without timeout(1), a poll under `set -m`:
# the job leads its own process group, so a child it backgrounded (`docker compose up`) dies with it.
_run() {
  local cmd="$1" log="$2" tbin=""
  command -v timeout >/dev/null 2>&1 && tbin=timeout
  [ -z "$tbin" ] && command -v gtimeout >/dev/null 2>&1 && tbin=gtimeout
  if [ -n "$tbin" ]; then
    (cd "$PROJECT_ROOT" && "$tbin" -k 5 "$TIMEOUT" bash -c "$cmd") </dev/null >"$log" 2>&1
    return $?
  fi
  set -m
  (cd "$PROJECT_ROOT" && exec bash -c "$cmd") </dev/null >"$log" 2>&1 &
  local pid=$! waited=0
  set +m
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$TIMEOUT" ]; then
      kill -TERM -- "-$pid" 2>/dev/null
      sleep 1
      kill -KILL -- "-$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
}

# Parallel indexed arrays, not an associative one: macOS ships bash 3.2.
CMDS=()
RCS=()
LOGS=()
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/check-requires.XXXXXX")"

_index_of() {
  local i
  for ((i = 0; i < ${#CMDS[@]}; i++)); do
    [ "${CMDS[$i]}" = "$1" ] && { echo "$i"; return 0; }
  done
  return 1
}

OVERALL=0
for issue in "${ISSUES[@]}"; do
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    if ! i=$(_index_of "$cmd"); then
      i=${#CMDS[@]}
      CMDS+=("$cmd")
      LOGS+=("$LOG_DIR/$i.log")
      _run "$cmd" "$LOG_DIR/$i.log"
      RCS+=("$?")
    fi
    if [ "${RCS[$i]}" -eq 0 ]; then
      echo "REQUIRE: pass $issue $cmd"
      continue
    fi
    OVERALL=1
    echo "REQUIRE: fail $issue $cmd"
    if [ "${RCS[$i]}" -eq 124 ]; then echo "  timed out after ${TIMEOUT}s"; else echo "  exit ${RCS[$i]}"; fi
    tail -n "$TAIL_LINES" "${LOGS[$i]}" | sed 's/^/  | /'
  done < <(_requires "$issue")
done

rm -rf "$LOG_DIR"
exit "$OVERALL"
