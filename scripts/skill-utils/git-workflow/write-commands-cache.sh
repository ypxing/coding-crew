#!/usr/bin/env bash
set -uo pipefail

# write-commands-cache.sh — merges a model's discovery response into .coding-crew/dev-commands.json
#
# The sibling of discover-commands.sh: that script decides whether a model call is needed and
# builds its prompt; this one takes the model's answer and persists it. The file is committed
# and human-editable, so there is no staleness stamp to compute or compare — once a field
# exists, discover-commands.sh trusts it as-is until a human clears it or passes --refresh.
#
# Field extraction is intentionally not a JSON parser: the prompt asks for a flat, single-line
# object with only string/null values, so a per-key "name": "value"|null regex is enough, and
# it still finds the fields even when the model wraps the object in prose or a markdown code
# fence — no fence-stripping needed, since the regex just looks for the substring anywhere in
# the response text.
#
# A response with none of the six fields recognisable is treated as a failed discovery, not
# as "everything is null": it exits non-zero and never touches any existing cache file, so a
# bad model response cannot destroy a prior good (possibly hand-edited) cache.
#
# Merge, not overwrite: a caller is free to answer only the fields it actually investigated
# (solve-issue's own Step 5 DISCOVER fallback only ever determines test/lint/typecheck; a
# dep-install session resolving a docker-install.md credential-target cache miss only ever
# determines that one field). A field this response is silent on keeps whatever an earlier
# write already resolved for it; a field neither this response nor any earlier write ever
# touched is omitted from the file entirely, rather than defaulted to null. That omission is
# load-bearing: a key that is *present* with value `null` means "a model already looked and
# confirmed no command exists" (trust it, never ask again) — a key that is *absent* means
# "nobody has asked yet" (dep-install's on-demand path may still resolve it, cheaply, since
# it is already running in a live session with file access, then write the answer back here).
# Collapsing those two into the same "null" would make discover-commands.sh's own
# bootstrap-once skip permanently foreclose a category nobody ever actually checked.
#
# Because a response is authoritative for whatever field it does name, a full re-discovery
# (discover-commands.sh --refresh, which always asks about all six) is expected to overwrite
# every field it names, including turning a previously-cached command back to null if the
# model no longer finds one. Callers that only ever investigate a subset of fields must not
# name the fields they did not check — naming one as null when it was never actually asked
# would overwrite a real cached answer with a false "confirmed absent".
#
# install is the fourth field, consumed by ensure-deps.sh in place of its own mechanical
# Makefile-target/lockfile heuristic when present — see discover-commands.sh's header comment
# for why that script never reads CLAUDE.md itself.
#
# env is the fifth field, consumed the same way by ensure-env.sh in place of its own mechanical
# .env.example-or-empty convention.
#
# credential_target is the sixth field: the full command (if any) that runs the Makefile target
# whose recipe generates package-manager credential config files (.npmrc, pip.conf,
# .cargo/credentials.toml, …) from a template or env vars — same shape as install/env (a
# runnable command, not a bare target name), so ensure-env.sh can eval it directly. Determining
# it the first time still needs a model reading Makefile comments/prose — that judgment does not
# reduce to a regex — but nothing requires re-asking on every docker-install run once it has been
# cached: ensure-deps.sh forwards a cached value to docker-install.sh's own --credential-target
# flag, which passes it straight to ensure-env.sh.
#
# Usage: bash "<skill-dir>/scripts/write-commands-cache.sh" --response-file <path>

FIELDS=(test lint typecheck install env credential_target)

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

# _extract_field <text> <key> — prints the raw value token for "<key>": <value> found anywhere
# in <text>: either a quoted string (with its quotes) or the bare word null. Empty output means
# the key was not found at all in that text — the caller distinguishes "not found" from "found
# and null" itself, since they mean different things (see the merge comment above).
_extract_field() {
  local text="$1" key="$2"
  printf '%s\n' "$text" \
    | grep -o "\"$key\"[[:space:]]*:[[:space:]]*\(\"[^\"]*\"\|null\)" \
    | head -1 \
    | sed -E "s/\"$key\"[[:space:]]*:[[:space:]]*//"
}

declare -A RESP_VAL
ANY_FOUND=0
for f in "${FIELDS[@]}"; do
  v="$(_extract_field "$RESPONSE_TEXT" "$f" || true)"
  RESP_VAL["$f"]="$v"
  [ -n "$v" ] && ANY_FOUND=1
done

if [ "$ANY_FOUND" -eq 0 ]; then
  echo "ERROR: could not find test, lint, typecheck, install, env, or credential_target in the response — leaving any existing cache untouched" >&2
  echo "--- response was ---" >&2
  printf '%s\n' "$RESPONSE_TEXT" >&2
  exit 1
fi

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

OLD_TEXT=""
[ -f "$CACHE_FILE" ] && OLD_TEXT=$(cat "$CACHE_FILE")

declare -A FINAL_VAL
declare -A HAVE_VAL
for f in "${FIELDS[@]}"; do
  if [ -n "${RESP_VAL[$f]}" ]; then
    FINAL_VAL["$f"]="${RESP_VAL[$f]}"
    HAVE_VAL["$f"]=1
    continue
  fi
  ov=""
  [ -n "$OLD_TEXT" ] && ov="$(_extract_field "$OLD_TEXT" "$f" || true)"
  if [ -n "$ov" ]; then
    FINAL_VAL["$f"]="$ov"
    HAVE_VAL["$f"]=1
  else
    HAVE_VAL["$f"]=0
  fi
done

mkdir -p "$MAIN_ROOT/.coding-crew"

JSON_BODY=""
for f in "${FIELDS[@]}"; do
  [ "${HAVE_VAL[$f]}" -eq 1 ] || continue
  [ -n "$JSON_BODY" ] && JSON_BODY="$JSON_BODY, "
  JSON_BODY="$JSON_BODY\"$f\": ${FINAL_VAL[$f]}"
done

# Atomic write: a reader (discover-commands.sh, or verify-worktree.sh once it consumes this
# cache) must never observe a half-written file.
TMP_FILE=$(mktemp "$MAIN_ROOT/.coding-crew/dev-commands.json.XXXXXX")
printf '{%s}\n' "$JSON_BODY" > "$TMP_FILE"
mv "$TMP_FILE" "$CACHE_FILE"

echo "Command cache written: .coding-crew/dev-commands.json"
for f in "${FIELDS[@]}"; do
  if [ "${HAVE_VAL[$f]}" -eq 1 ]; then
    echo "  $f: ${FINAL_VAL[$f]}"
  else
    echo "  $f: (not yet asked)"
  fi
done
