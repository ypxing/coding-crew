#!/usr/bin/env bash
# render-skill.sh — render a skill's SKILL.md body for one platform.
# Usage: render-skill.sh <skill-name> <platform> [<outfile>]   (stdout without <outfile>)
# A whole `{{FRAGMENT:<key>}}` line becomes skills/_shared/fragments/<key>.md and `{{PLATFORM}}` the
# platform name. A missing fragment or any placeholder left over is a hard error: it would ship an
# instruction hole to the model.
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

# jq on Windows (Git Bash) leaves a \r inside every value, so "tdd\r" names no directory; normalise
# once (see install.sh). The probe reads through `read`: `$(…)` strips the CR itself.
_jq_probe=""
IFS= read -r _jq_probe < <(command jq -rn '"probe"' 2>/dev/null) || true
if [[ "$_jq_probe" == *$'\r' ]]; then
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

BODY="SKILL.md"
[[ -f "$SKILL_SRC/$BODY" ]] || { echo "Error: skill body not found: skills/$SOURCE_DIR/$BODY" >&2; exit 1; }

render() {
  local line key fragment
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*\{\{FRAGMENT:([A-Za-z0-9_-]+)\}\}[[:space:]]*$ ]]; then
      key="${BASH_REMATCH[1]}"
      fragment="$SCRIPT_DIR/skills/_shared/fragments/$key.md"
      if [[ ! -f "$fragment" ]]; then
        echo "Error: $SKILL/$BODY needs fragment '$key', but skills/_shared/fragments/$key.md does not exist" >&2
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
