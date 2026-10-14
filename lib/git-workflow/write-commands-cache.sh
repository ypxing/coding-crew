#!/usr/bin/env bash
set -uo pipefail

# write-commands-cache.sh --response-file <path> — merges a model's discovery response into
# .coding-crew/dev-commands.json. No recognisable field is a failed discovery: exit 1, cache untouched.
# A field the response omits keeps its value, and one never written stays absent. Absent means
# "nobody asked yet"; null means "a model looked and found none", which is never re-asked, so a
# caller must not name a field it did not check.

FIELDS=(test lint typecheck install env credential_target coverage integration)

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

# _extract_field <text> <key> — the raw value token for "<key>" anywhere in <text> (a quoted string
# or null), so prose or a code fence around the object does not matter; empty when not found.
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
  echo "ERROR: could not find test, lint, typecheck, install, env, credential_target, coverage, or integration in the response — leaving any existing cache untouched" >&2
  echo "--- response was ---" >&2
  printf '%s\n' "$RESPONSE_TEXT" >&2
  exit 1
fi

# Must land on the shared main checkout even from a worker's worktree, where
# `git rev-parse --show-toplevel` returns the worktree's own root and the cache would vanish with it.
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

# Atomic write: a reader (discover-commands.sh, run-checks.sh) must never observe a half-written file.
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
