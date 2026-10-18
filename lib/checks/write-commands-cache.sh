#!/usr/bin/env bash
set -uo pipefail

# write-commands-cache.sh --response-file <path> — merges a model's answer to discover-commands.sh or
# discover-mode.sh into the clone's dev commands file (commands-file.sh beside it says which). No recognisable field is a failed discovery: exit 1, cache untouched.
# A field the response omits keeps its value, and one never written stays absent. Absent means
# "nobody asked yet"; null means "a model looked and found none", which is never re-asked, so a
# caller must not name a field it did not check.

FIELDS=(test lint typecheck install env registry_auth coverage integration install_mode docker_service)

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

# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/commands-file.sh"

# _json_value <file> <key> — the value as JSON ("<command>" or null); empty when the key is absent.
_json_value() {
  commands_field_present "$1" "$2" || return 0
  local v; v=$(commands_field "$1" "$2")
  v=${v//\\/\\\\}; v=${v//\"/\\\"}
  if [ -n "$v" ]; then printf '"%s"' "$v"; else printf null; fi
}

declare -A RESP_VAL
ANY_FOUND=0
for f in "${FIELDS[@]}"; do
  v="$(_json_value "$RESPONSE_FILE" "$f")"
  RESP_VAL["$f"]="$v"
  [ -n "$v" ] && ANY_FOUND=1
done

if [ "$ANY_FOUND" -eq 0 ]; then
  echo "ERROR: could not find any of ${FIELDS[*]} in the response — leaving any existing cache untouched" >&2
  echo "--- response was ---" >&2
  cat "$RESPONSE_FILE" >&2
  exit 1
fi

ROOT=$(git rev-parse --show-toplevel) || exit 1
CACHE_FILE=$(commands_file "$ROOT")

declare -A FINAL_VAL
declare -A HAVE_VAL
for f in "${FIELDS[@]}"; do
  if [ -n "${RESP_VAL[$f]}" ]; then
    FINAL_VAL["$f"]="${RESP_VAL[$f]}"
    HAVE_VAL["$f"]=1
    continue
  fi
  ov="$(_json_value "$CACHE_FILE" "$f")"
  if [ -n "$ov" ]; then
    FINAL_VAL["$f"]="$ov"
    HAVE_VAL["$f"]=1
  else
    HAVE_VAL["$f"]=0
  fi
done

mkdir -p "$(dirname "$CACHE_FILE")"

JSON_BODY=""
for f in "${FIELDS[@]}"; do
  [ "${HAVE_VAL[$f]}" -eq 1 ] || continue
  [ -n "$JSON_BODY" ] && JSON_BODY="$JSON_BODY, "
  JSON_BODY="$JSON_BODY\"$f\": ${FINAL_VAL[$f]}"
done

# Atomic write: a reader (discover-commands.sh, run-checks.sh) must never observe a half-written file.
TMP_FILE=$(mktemp "$CACHE_FILE.XXXXXX")
printf '{%s}\n' "$JSON_BODY" > "$TMP_FILE"
mv "$TMP_FILE" "$CACHE_FILE"

echo "Command cache written: $CACHE_FILE"
for f in "${FIELDS[@]}"; do
  if [ "${HAVE_VAL[$f]}" -eq 1 ]; then
    echo "  $f: ${FINAL_VAL[$f]}"
  else
    echo "  $f: (not yet asked)"
  fi
done
