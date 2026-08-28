#!/usr/bin/env bash
set -uo pipefail

# write-commands-cache.sh — turns a model's discovery response into .coding-crew/dev-commands.json
#
# The sibling of discover-commands.sh: that script decides whether a model call is needed and
# builds its prompt; this one takes the model's answer and persists it. The file is committed
# and human-editable, so there is no staleness stamp to compute or compare — once it exists,
# discover-commands.sh trusts it as-is until a human clears it or passes --refresh.
#
# Field extraction is intentionally not a JSON parser: the prompt asks for a flat, single-line
# object with only string/null values, so a per-key "name": "value"|null regex is enough, and
# it still finds the fields even when the model wraps the object in prose or a markdown code
# fence — no fence-stripping needed, since the regex just looks for the substring anywhere in
# the response text.
#
# A response with none of the five fields recognisable is treated as a failed discovery, not
# as "everything is null": it exits non-zero and never touches any existing cache file, so a
# bad model response cannot destroy a prior good (possibly hand-edited) cache.
#
# install is the fourth field, consumed by ensure-deps.sh in place of its own mechanical
# Makefile-target/lockfile heuristic when present — see discover-commands.sh's header comment
# for why that script never reads CLAUDE.md itself.
#
# env is the fifth field, consumed the same way by ensure-env.sh in place of its own mechanical
# .env.example-or-empty convention.
#
# Usage: bash "<skill-dir>/scripts/write-commands-cache.sh" --response-file <path>

RESPONSE_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --response-file)
      if [ $# -lt 2 ]; then
        echo "ERROR: --response-file requires a value" >&2
        exit 1
      fi
      RESPONSE_FILE="$2"
      shift 2
      ;;
    *)
      echo "write-commands-cache.sh: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [ -z "$RESPONSE_FILE" ]; then
  echo "ERROR: --response-file <path> is required" >&2
  exit 1
fi

if [ ! -f "$RESPONSE_FILE" ]; then
  echo "ERROR: response file does not exist: $RESPONSE_FILE" >&2
  exit 1
fi

RESPONSE_TEXT=$(cat "$RESPONSE_FILE")

# _extract_field <key> — prints the raw value token for "<key>": <value> found anywhere in
# RESPONSE_TEXT: either a quoted string (with its quotes) or the bare word null. Empty output
# means the key was not found at all, which the caller treats as null, not as failure — only
# when every key comes back empty is the whole response considered unparseable.
_extract_field() {
  local key="$1"
  printf '%s\n' "$RESPONSE_TEXT" \
    | grep -o "\"$key\"[[:space:]]*:[[:space:]]*\(\"[^\"]*\"\|null\)" \
    | head -1 \
    | sed -E "s/\"$key\"[[:space:]]*:[[:space:]]*//"
}

TEST_VALUE=$(_extract_field test || true)
LINT_VALUE=$(_extract_field lint || true)
TYPECHECK_VALUE=$(_extract_field typecheck || true)
INSTALL_VALUE=$(_extract_field install || true)
ENV_VALUE=$(_extract_field env || true)

if [ -z "$TEST_VALUE" ] && [ -z "$LINT_VALUE" ] && [ -z "$TYPECHECK_VALUE" ] && [ -z "$INSTALL_VALUE" ] && [ -z "$ENV_VALUE" ]; then
  echo "ERROR: could not find test, lint, typecheck, install, or env in the response — leaving any existing cache untouched" >&2
  echo "--- response was ---" >&2
  printf '%s\n' "$RESPONSE_TEXT" >&2
  exit 1
fi

[ -z "$TEST_VALUE" ] && TEST_VALUE="null"
[ -z "$LINT_VALUE" ] && LINT_VALUE="null"
[ -z "$TYPECHECK_VALUE" ] && TYPECHECK_VALUE="null"
[ -z "$INSTALL_VALUE" ] && INSTALL_VALUE="null"
[ -z "$ENV_VALUE" ] && ENV_VALUE="null"

# MAIN_ROOT resolution — must land on the *shared* main checkout even when this script runs
# from inside a crew-afk worktree (solve-issue's own DISCOVER fallback, Step 5, can invoke
# this from a worker's worktree cwd when the sprint-level cache never got written): prefer
# the $MAIN_ROOT env var the orchestrator/dispatcher already exports (dispatch.mjs,
# dispatch-agent.sh), then fall back to _main_root_of's --git-common-dir trick (mirrors
# verify-worktree.sh's own helper of the same name), which resolves the main worktree's root
# from any linked worktree without needing an env var at all. `git rev-parse --show-toplevel`
# alone — the prior behaviour — returns the *current* worktree's own root, which is wrong
# from inside a linked worktree: the cache would be written where no later reader (this
# script's own USE_CACHE fast path, verify-worktree.sh, another issue's solve-issue) ever
# looks, and would vanish with the worktree besides.
_main_root_of() {
  local dir="$1" common
  common=$(cd "$dir" && git rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*) : ;;
    *) common="$(cd "$dir" && cd "$(dirname "$common")" && pwd -P)/$(basename "$common")" ;;
  esac
  dirname "$common"
}

MAIN_ROOT="${MAIN_ROOT:-}"
if [ -z "$MAIN_ROOT" ]; then
  MAIN_ROOT=$(_main_root_of "$(pwd)") || MAIN_ROOT=$(git rev-parse --show-toplevel)
fi
CACHE_FILE="$MAIN_ROOT/.coding-crew/dev-commands.json"

mkdir -p "$MAIN_ROOT/.coding-crew"

# Atomic write: a reader (discover-commands.sh, or verify-worktree.sh once it consumes this
# cache) must never observe a half-written file.
TMP_FILE=$(mktemp "$MAIN_ROOT/.coding-crew/dev-commands.json.XXXXXX")
cat > "$TMP_FILE" <<JSON
{"test": $TEST_VALUE, "lint": $LINT_VALUE, "typecheck": $TYPECHECK_VALUE, "install": $INSTALL_VALUE, "env": $ENV_VALUE}
JSON
mv "$TMP_FILE" "$CACHE_FILE"

echo "Command cache written: .coding-crew/dev-commands.json"
echo "  test: $TEST_VALUE"
echo "  lint: $LINT_VALUE"
echo "  typecheck: $TYPECHECK_VALUE"
echo "  install: $INSTALL_VALUE"
echo "  env: $ENV_VALUE"
