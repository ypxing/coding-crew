#!/usr/bin/env bash
set -uo pipefail

# write-commands-cache.sh — turns a model's discovery response into .scratch/commands.json
#
# The sibling of discover-commands.sh: that script decides whether a model call is needed and
# builds its prompt; this one takes the model's answer and persists it, stamped with the same
# source hash, so a later discover-commands.sh run can tell the cache is still fresh without
# asking a model again.
#
# This script does not trust the caller for the hash — it recomputes it itself from the exact
# same candidate-file list and algorithm discover-commands.sh uses (duplicated intentionally;
# see verify-worktree.sh's own duplicated-with-a-comment precedent for _main_root_of). Trusting
# a hash the caller supplied would let a stale or wrong value make a stale cache look fresh.
#
# Field extraction is intentionally not a JSON parser: the prompt asks for a flat, single-line
# object with only string/null values, so a per-key "name": "value"|null regex is enough, and
# it still finds the fields even when the model wraps the object in prose or a markdown code
# fence — no fence-stripping needed, since the regex just looks for the substring anywhere in
# the response text.
#
# A response with none of the three fields recognisable is treated as a failed discovery, not
# as "everything is null": it exits non-zero and never touches any existing cache file, so a
# bad model response cannot destroy a prior good cache.
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

if [ -z "$TEST_VALUE" ] && [ -z "$LINT_VALUE" ] && [ -z "$TYPECHECK_VALUE" ]; then
  echo "ERROR: could not find test, lint, or typecheck in the response — leaving any existing cache untouched" >&2
  echo "--- response was ---" >&2
  printf '%s\n' "$RESPONSE_TEXT" >&2
  exit 1
fi

[ -z "$TEST_VALUE" ] && TEST_VALUE="null"
[ -z "$LINT_VALUE" ] && LINT_VALUE="null"
[ -z "$TYPECHECK_VALUE" ] && TYPECHECK_VALUE="null"

MAIN_ROOT=$(git rev-parse --show-toplevel)
CACHE_FILE="$MAIN_ROOT/.scratch/commands.json"

# Same fixed, deterministic file list and hashing algorithm as discover-commands.sh — kept in
# sync by hand, not by sourcing, so each script stays runnable and testable on its own.
CANDIDATE_FILES=(
  "$MAIN_ROOT/CLAUDE.md"
  "$MAIN_ROOT/AGENTS.md"
  "$MAIN_ROOT/Makefile"
  "$MAIN_ROOT/package.json"
  "$MAIN_ROOT/pyproject.toml"
  "$MAIN_ROOT/Cargo.toml"
  "$MAIN_ROOT/go.mod"
  "$MAIN_ROOT/Gemfile"
  "$MAIN_ROOT/composer.json"
)

# Same dedup-by-content as discover-commands.sh (kept in sync by hand, not by sourcing, for
# the same reason as the candidate list and hashing algorithm below): a symlinked or
# duplicated CLAUDE.md/AGENTS.md must drop out of the hash input on both sides, or the two
# scripts would compute different hashes for the same repo state and the cache would never
# read as fresh.
_content_hash() {
  cat "$1" | if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | awk '{print $1}'
}

FOUND_FILES=()
SEEN_HASHES=()
for f in "${CANDIDATE_FILES[@]}"; do
  [ -f "$f" ] || continue
  h=$(_content_hash "$f")
  dup=0
  if [ "${#SEEN_HASHES[@]}" -gt 0 ]; then
    for seen in "${SEEN_HASHES[@]}"; do
      if [ "$seen" = "$h" ]; then dup=1; break; fi
    done
  fi
  if [ "$dup" -eq 0 ]; then
    FOUND_FILES+=("$f")
    SEEN_HASHES+=("$h")
  fi
done

_source_hash() {
  {
    local f
    for f in "$@"; do
      printf '%s\n' "=== $f ==="
      cat "$f"
    done
  } | if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | awk '{print $1}'
}

SOURCE_HASH=$(_source_hash "${FOUND_FILES[@]}")

mkdir -p "$MAIN_ROOT/.scratch"

# Atomic write: a reader (discover-commands.sh, or verify-worktree.sh once it consumes this
# cache) must never observe a half-written file.
TMP_FILE=$(mktemp "$MAIN_ROOT/.scratch/commands.json.XXXXXX")
cat > "$TMP_FILE" <<JSON
{"sourceHash": "$SOURCE_HASH", "test": $TEST_VALUE, "lint": $LINT_VALUE, "typecheck": $TYPECHECK_VALUE}
JSON
mv "$TMP_FILE" "$CACHE_FILE"

echo "Command cache written: .scratch/commands.json"
echo "  test: $TEST_VALUE"
echo "  lint: $LINT_VALUE"
echo "  typecheck: $TYPECHECK_VALUE"
