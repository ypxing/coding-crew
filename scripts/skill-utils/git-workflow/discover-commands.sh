#!/usr/bin/env bash
set -euo pipefail

# Command discovery — mechanical gate for crew-afk (prompt-builder half)
#
# Finds the *local dev-loop* command for test/lint/typecheck once per sprint, before any
# worktree exists, by asking a model to read whatever of CLAUDE.md/AGENTS.md/Makefile/manifest
# files this repo actually has — the same reference chain solve-issue's verification.md names,
# but read by a model instead of pattern-matched by this script. Real repos document these
# commands in prose, tables, and bullet lists a regex has no reliable way to parse (a table
# with a "don't use this shortcut, it's broken" note in a column is exactly the shape that
# broke the pattern-matched approach this replaces).
#
# This script only ever decides whether a model call is needed and, if so, assembles the
# prompt for it — mirroring coverage-validation.sh's shape exactly, down to the "skipped" /
# not-skipped stdout contract loop.mjs already knows how to read (the whole of stdout becomes
# the prompt, informational preamble included, exactly as it does there). It never calls a
# model itself, and it never writes a result anywhere; a sibling script owns turning the
# model's response into .scratch/commands.json.
#
# Skips (mechanically, no model call, no tokens) when either:
#   1. none of the known source files exist — verify-worktree.sh's own ecosystem-convention
#      fallback already covers this case for free, so there is nothing to ask a model
#   2. an existing .scratch/commands.json's sourceHash already matches the current content of
#      those files — nothing has changed since the last discovery
#
# Invocation: bash "<skill-dir>/scripts/discover-commands.sh" [--refresh]
# Env: CREW_COMMANDS_REFRESH=1 has the same effect as --refresh.

REFRESH="${CREW_COMMANDS_REFRESH:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    --refresh) REFRESH=1; shift ;;
    *) echo "discover-commands.sh: unknown argument: $1" >&2; exit 1 ;;
  esac
done

MAIN_ROOT=$(git rev-parse --show-toplevel)
CACHE_FILE="$MAIN_ROOT/.scratch/commands.json"

# Fixed, deterministic order — keeps the hash (and the prompt's file order) stable across
# runs regardless of filesystem iteration order. Not tied to any one repo's stack: covers the
# doc conventions (CLAUDE.md/AGENTS.md/Makefile) plus one manifest per common ecosystem.
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

# _content_hash <file> — one file's own content, independent of its path. Used only to spot
# duplicates (a CLAUDE.md that is a symlink to AGENTS.md, or two files that happen to hold
# identical content) before either file is added to the prompt: real repos symlink one to the
# other for editor convenience, and quoting the same text twice would cost tokens for zero
# extra information without changing what the model can answer.
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

if [ "${#FOUND_FILES[@]}" -eq 0 ]; then
  echo "Command discovery: skipped (no CLAUDE.md, AGENTS.md, Makefile, or manifest found — ecosystem-convention fallback applies)"
  exit 0
fi

# _source_hash <file...> — one deterministic hash over the exact files a discovery run would
# read, so a later run can tell "nothing changed" from "something did" without re-asking a
# model. Portable across the two common sha256 tool names (GNU coreutils vs. macOS/BSD).
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

if [ "$REFRESH" != "1" ] && [ -f "$CACHE_FILE" ]; then
  CACHED_HASH=$(grep -o '"sourceHash"[[:space:]]*:[[:space:]]*"[^"]*"' "$CACHE_FILE" | sed -E 's/.*"([a-f0-9]+)"$/\1/' || true)
  if [ -n "$CACHED_HASH" ] && [ "$CACHED_HASH" = "$SOURCE_HASH" ]; then
    echo "Command discovery: skipped (cache is fresh at .scratch/commands.json)"
    exit 0
  fi
fi

echo "Command discovery: ${#FOUND_FILES[@]} source file(s) found — building discovery prompt"
echo

cat <<'PROMPT'
--- command discovery prompt (do not run this on a cheap model tier — it is genuine reasoning) ---
You are looking at one repository's own documentation and build files. Identify the command a
developer runs **locally**, during normal iteration, for each of these three categories only:

- test
- lint
- typecheck (a static/type-checking pass — not the test suite)

Rules:
- Only local dev-loop commands. Ignore build, deploy, publish, and infra-provisioning steps
  (Docker image builds, CDK/Terraform/CloudFormation, docs bundling/rendering, release/publish
  workflows) even if they appear in the same file as a test/lint/typecheck command.
- Ignore anything the source explicitly marks as CI-only, manual-only, or "not gated by CI",
  unless no other candidate exists for that category.
- Where the source recommends against a shortcut (calls it broken, misleading, or says
  "don't use it"), use the alternative it recommends instead of the discouraged shortcut.
- If a category has no discoverable local command, use null for it — do not guess one.

Respond with **only** this JSON shape, no other prose:
{"test": "<command or null>", "lint": "<command or null>", "typecheck": "<command or null>"}

--- source files ---
PROMPT

for f in "${FOUND_FILES[@]}"; do
  printf '\n### %s\n\n' "${f#"$MAIN_ROOT"/}"
  cat "$f"
done

echo
echo "--- end command discovery prompt ---"
