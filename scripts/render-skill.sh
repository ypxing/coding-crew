#!/usr/bin/env bash
# render-skill.sh — render a skill's SKILL.md body for one platform.
#
# Usage: render-skill.sh <skill-name> <platform>            # prints to stdout
#        render-skill.sh <skill-name> <platform> <outfile>
#
# Body resolution (first match wins):
#   1. registry.json .skills[<skill>].body[<platform>]   — shared multi-platform body
#   2. skills/<source-dir>/<platform>.SKILL.md           — single-platform variant
#   3. skills/<source-dir>/SKILL.md                      — shared fallback
#
# Expansion inside the body:
#   {{FRAGMENT:<key>}}  → skills/<source-dir>/fragments/<platform>/<key>.md (whole line)
#   {{PLATFORM}}        → the platform name
#
# A missing fragment, or any placeholder left unexpanded, is a hard error: a body
# that renders with a `{{...}}` still in it would ship an instruction hole to the model.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="$SCRIPT_DIR/registry.json"

usage() {
  echo "Usage: render-skill.sh <skill-name> <platform> [outfile]" >&2
  exit 2
}

[[ $# -ge 2 ]] || usage
SKILL="$1"
PLATFORM="$2"
OUTFILE="${3:-}"

[[ -f "$REGISTRY" ]] || { echo "Error: registry not found: $REGISTRY" >&2; exit 1; }

# jq on Windows (Git Bash) writes stdout in text mode, so a source-dir read back as
# "tdd\r" makes `skills/$SOURCE_DIR` a directory that does not exist. Normalise every
# jq read once, here. Command substitution, not a `| tr` pipeline: render-skill.sh runs
# once per installed SKILL.md, and on Git Bash every avoided spawn is ~5-50ms. Probed,
# so a jq that already writes LF is called directly with no wrapper at all.
if [[ "$(command jq -rn '"probe"' 2>/dev/null)" == *$'\r' ]]; then
  jq() {
    local _jq_out _jq_rc
    _jq_out=$(command jq "$@")
    _jq_rc=$?
    [[ -n "$_jq_out" ]] && printf '%s\n' "${_jq_out//$'\r'/}"
    return "$_jq_rc"
  }
fi

SOURCE_DIR=$(jq -r --arg s "$SKILL" '.skills[$s]["source-dir"] // $s' "$REGISTRY")
SKILL_SRC="$SCRIPT_DIR/skills/$SOURCE_DIR"
[[ -d "$SKILL_SRC" ]] || { echo "Error: skill source not found: skills/$SOURCE_DIR" >&2; exit 1; }

BODY=$(jq -r --arg s "$SKILL" --arg p "$PLATFORM" '.skills[$s].body[$p] // empty' "$REGISTRY")
if [[ -z "$BODY" ]]; then
  if [[ -f "$SKILL_SRC/$PLATFORM.SKILL.md" ]]; then
    BODY="$PLATFORM.SKILL.md"
  else
    BODY="SKILL.md"
  fi
fi
[[ -f "$SKILL_SRC/$BODY" ]] || { echo "Error: skill body not found: skills/$SOURCE_DIR/$BODY" >&2; exit 1; }

render() {
  local line key fragment
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*\{\{FRAGMENT:([A-Za-z0-9_-]+)\}\}[[:space:]]*$ ]]; then
      key="${BASH_REMATCH[1]}"
      fragment="$SKILL_SRC/fragments/$PLATFORM/$key.md"
      if [[ ! -f "$fragment" ]]; then
        echo "Error: $SKILL/$BODY needs fragment '$key' for platform '$PLATFORM'," \
             "but skills/$SOURCE_DIR/fragments/$PLATFORM/$key.md does not exist" >&2
        exit 1
      fi
      # Fragments are stored with a trailing newline; strip it so the body's own
      # blank-line spacing decides the layout.
      printf '%s\n' "$(cat "$fragment")"
    else
      printf '%s\n' "${line//\{\{PLATFORM\}\}/$PLATFORM}"
    fi
  done < "$SKILL_SRC/$BODY"
}

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
render > "$TMP"

if grep -n '{{[A-Z]' "$TMP" >/dev/null 2>&1; then
  echo "Error: unexpanded placeholder in rendered $SKILL ($PLATFORM):" >&2
  grep -n '{{[A-Z]' "$TMP" >&2
  exit 1
fi

if [[ -n "$OUTFILE" ]]; then
  mkdir -p "$(dirname "$OUTFILE")"
  cp "$TMP" "$OUTFILE"
else
  cat "$TMP"
fi
