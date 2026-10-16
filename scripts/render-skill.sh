#!/usr/bin/env bash
# render-skill.sh — render the committed skill tree in place, so skills/<name>/ is what every installer copies.
# Usage: render-skill.sh   (no arguments; run after editing a fragment, a lib, or a SKILL.md's markers)
# For every skill in registry.json:
#   - the text between each `<!-- fragment:<key> -->` and `<!-- /fragment:<key> -->` line in its SKILL.md
#     becomes skills/_shared/fragments/<key>.md;
#   - skills/<skill>/scripts/<lib>/ becomes an exact copy of lib/<lib>/ for each name in its `libs`,
#     and is removed for each lib/<lib>/ its `libs` does not name.
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

exec_bit() { if [[ -x "$1" ]]; then echo 1; else echo 0; fi; }

# copy_lib <name> <dest> — <dest> becomes an exact copy of lib/<name>: same files, same modes, nothing else.
copy_lib() {
  local src="$ROOT/lib/$1" dest="$2" f rel
  [[ -d "$src" ]] || { echo "Error: library source not found: lib/$1" >&2; exit 1; }
  [[ -L "$dest" || ( -e "$dest" && ! -d "$dest" ) ]] && rm -f "$dest"
  mkdir -p "$dest"
  while IFS= read -r -d '' f; do
    rel="${f#"$src"/}"
    if [[ ! -f "$dest/$rel" ]] || ! cmp -s "$f" "$dest/$rel" || [[ "$(exec_bit "$f")" != "$(exec_bit "$dest/$rel")" ]]; then
      mkdir -p "$(dirname "$dest/$rel")"
      rm -f "$dest/$rel"
      cp -p "$f" "$dest/$rel"
    fi
  done < <(find "$src" -type f -print0)
  while IFS= read -r -d '' f; do
    rel="${f#"$dest"/}"
    [[ -f "$src/$rel" ]] || rm -f "$f"
  done < <(find "$dest" -mindepth 1 ! -type d -print0)
  find "$dest" -mindepth 1 -depth -type d -empty -delete
}

while IFS= read -r skill; do
  [[ -n "$skill" ]] || continue
  dir=$(jq -r --arg s "$skill" '.skills[$s]["source-dir"] // $s' "$REGISTRY")
  rel="skills/$dir/SKILL.md"
  [[ -f "$ROOT/$rel" ]] || { echo "Error: skill body not found: $rel" >&2; exit 1; }
  render_body "$rel"
  cmp -s "$TMP" "$ROOT/$rel" || cp "$TMP" "$ROOT/$rel"
  libs=$(jq -r --arg s "$skill" '.skills[$s].libs // [] | .[]' "$REGISTRY")
  for lib_dir in "$ROOT"/lib/*/; do
    lib=$(basename "$lib_dir")
    if grep -qxF "$lib" <<< "$libs"; then
      copy_lib "$lib" "$ROOT/skills/$dir/scripts/$lib"
    else
      rm -rf "${ROOT:?}/skills/$dir/scripts/$lib"
    fi
  done
  while IFS= read -r lib; do
    [[ -z "$lib" || -d "$ROOT/lib/$lib" ]] || { echo "Error: library source not found: lib/$lib" >&2; exit 1; }
  done <<< "$libs"
done < <(jq -r '.skills | keys[]' "$REGISTRY")
