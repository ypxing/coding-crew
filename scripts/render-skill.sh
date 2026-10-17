#!/usr/bin/env bash
# render-skill.sh — render the committed SKILL.md bodies in place, so skills/<name>/ is what every installer copies.
# Usage: render-skill.sh   (no arguments; run after editing a fragment or a SKILL.md's markers)
# For every skill in registry.json, the text between each `<!-- fragment:<key> -->` and
# `<!-- /fragment:<key> -->` line in its SKILL.md becomes skills/_shared/fragments/<key>.md.
# A skill's scripts/<lib> is a committed link to ../../../lib/<lib>, copied through at install; this
# script never touches it.
# A missing fragment, an unmatched marker or a `{{` left in a body is a hard error naming the file: it would
# ship an instruction hole to the model.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="$ROOT/registry.json"

[[ $# -eq 0 ]] || { echo "Usage: render-skill.sh   (no arguments)" >&2; exit 2; }
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

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

# render_body <rel> — writes <rel>'s body, its marker pairs refreshed, to $TMP.
render_body() {
  local rel="$1" line key="" n=0 fragment
  local open_re='^<!-- fragment:([A-Za-z0-9_-]+) -->$' close_re='^<!-- /fragment:([A-Za-z0-9_-]+) -->$'
  : > "$TMP"
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    if [[ "$line" =~ $open_re ]]; then
      [[ -z "$key" ]] || { echo "Error: $rel:$n: fragment '${BASH_REMATCH[1]}' opens inside fragment '$key'" >&2; exit 1; }
      key="${BASH_REMATCH[1]}"
      fragment="$ROOT/skills/_shared/fragments/$key.md"
      [[ -f "$fragment" ]] || {
        echo "Error: $rel:$n needs fragment '$key', but skills/_shared/fragments/$key.md does not exist" >&2; exit 1; }
      # Stored with a trailing newline; stripped so the body's own spacing decides the layout.
      printf '%s\n%s\n' "$line" "$(cat "$fragment")" >> "$TMP"
    elif [[ "$line" =~ $close_re ]]; then
      [[ "${BASH_REMATCH[1]}" == "$key" ]] || {
        echo "Error: $rel:$n: closing marker for fragment '${BASH_REMATCH[1]}' has no matching opening marker" >&2; exit 1; }
      key=""
      printf '%s\n' "$line" >> "$TMP"
    elif [[ -z "$key" ]]; then
      printf '%s\n' "$line" >> "$TMP"
    fi
  done < "$ROOT/$rel"
  [[ -z "$key" ]] || { echo "Error: $rel: fragment '$key' is never closed" >&2; exit 1; }
  if grep -n '{{' "$TMP" >/dev/null; then
    echo "Error: unexpanded placeholder in $rel:" >&2
    grep -n '{{' "$TMP" >&2
    exit 1
  fi
}

while IFS= read -r skill; do
  [[ -n "$skill" ]] || continue
  dir=$(jq -r --arg s "$skill" '.skills[$s]["source-dir"] // $s' "$REGISTRY")
  rel="skills/$dir/SKILL.md"
  [[ -f "$ROOT/$rel" ]] || { echo "Error: skill body not found: $rel" >&2; exit 1; }
  render_body "$rel"
  cmp -s "$TMP" "$ROOT/$rel" || cp "$TMP" "$ROOT/$rel"
done < <(jq -r '.skills | keys[]' "$REGISTRY")
