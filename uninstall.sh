#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
  echo "Usage: ./uninstall.sh [--project [<path>]]"
  echo "       ./uninstall.sh [--project [<path>]] --skill <skill-name>"
  echo "       ./uninstall.sh [--project [<path>]] --skills <a,b,c>"
  echo ""
  echo "  --project: uninstall from a repo (<path>, else the current repo); default \$HOME."
  echo "             TARGET_REPO=<path> does the same"
  echo "  --skill:   remove a single skill, and each library no skill left in the manifest uses"
  echo "  --skills:  remove multiple skills (comma-separated), the same way"
  echo "  (no args)  remove every skill and library, and .coding-crew/manifest.json"
  echo ""
  echo "Examples:"
  echo "  ./uninstall.sh                               # remove all from \$HOME"
  echo "  ./uninstall.sh --skills tdd,to-issues        # remove specific skills from \$HOME"
  echo "  ./uninstall.sh --project                     # remove all from the current repo"
  exit 1
}

MODE="all"
LIST=""
PROJECT=false
PROJECT_PATH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage ;;
    --skill|--skills)
      [[ -n "${2:-}" && "${2:-}" != -* ]] || { echo "Error: $1 requires a skill name or comma-separated list" >&2; usage; }
      MODE="skills"; LIST="$2"; shift 2 ;;
    --project)
      PROJECT=true; shift
      if [[ $# -gt 0 && "$1" != -* ]]; then PROJECT_PATH="$1"; shift; fi ;;
    *) echo "Error: unknown argument '$1'" >&2; usage ;;
  esac
done

# The same levels as install.sh: $HOME unless --project or TARGET_REPO names a repo.
if [[ "$PROJECT" == "true" ]]; then
  if [[ -n "$PROJECT_PATH" ]]; then
    [[ -d "$PROJECT_PATH" ]] || { echo "Error: --project path does not exist: $PROJECT_PATH" >&2; exit 1; }
    REPO_ROOT="$(cd "$PROJECT_PATH" && pwd)"
  else
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  fi
else
  REPO_ROOT="${TARGET_REPO:-$HOME}"
fi
LEVEL="project"
[[ "$REPO_ROOT" != "$HOME" ]] || LEVEL="user"

MANIFEST="$REPO_ROOT/.coding-crew/manifest.json"
LIB_DEST=".coding-crew/lib"

for cmd in jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Error: required command '$cmd' not found" >&2; exit 1; }
done

# jq on Windows (Git Bash) leaves a \r inside every value; normalise once (see install.sh).
# The probe reads through `read`: `$(…)` strips the CR itself, so it would never see one.
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

source "$SCRIPT_DIR/scripts/lib/platforms.sh"

# rmdir that tolerates Windows' lazy directory-entry removal: a child deleted a
# moment ago can keep the parent looking non-empty for a few milliseconds, which
# would otherwise abort the prune walk and leave empty platform dirs behind.
rmdir_if_empty() {
  local dir="$1"
  rmdir "$dir" 2>/dev/null && return 0
  [[ -d "$dir" ]] || return 0
  sleep 0.2
  rmdir "$dir" 2>/dev/null
}

# Remove now-empty directories up from a removed path, stopping at $root (REPO_ROOT, or the
# platform's own override root when resolve_dest moved it).
prune_empty_dirs() {
  local root="$1" rel="$2" dir
  root=$(cd "$root" 2>/dev/null && pwd) || return 0
  dir="$(dirname "$root/$rel")"
  while [[ "$dir" != "$root" && "$dir" == "$root"/* ]]; do
    rmdir_if_empty "$dir" || break
    echo "  removed ${dir#$root/}/"
    dir="$(dirname "$dir")"
  done
}

# A name from the manifest or the command line becomes a path: nothing but a plain name gets through.
plain_name() { [[ "$1" =~ ^[a-zA-Z0-9_.-]+$ && "$1" != "." && "$1" != ".." ]]; }

# A skill is removed by name, whether or not the registry still has it: --update uninstalls the
# skills an older install recorded.
remove_skill() {
  local name="$1"
  if ! plain_name "$name"; then
    echo "  '$name': not a skill name — skipping"
    return
  fi

  # Both scopes' paths: an earlier install may have written the other, so the dead copy goes too.
  local removed=0
  local platform full candidate
  for platform in "${PLATFORMS[@]}"; do
    platform_skills_dir "$platform"
    while IFS= read -r candidate; do
      [[ -n "$candidate" ]] || continue
      resolve_dest "$platform" "$candidate"
      full="$_DEST_ROOT/$_DEST_REL"
      if [[ -d "$full" ]]; then
        rm -rf "$full"
        echo "  removed $candidate/"
        prune_empty_dirs "$_DEST_ROOT" "$_DEST_REL"
        removed=1
      fi
    done < <(platform_scope_paths "$platform" "$_PLATFORM_SKILLS/$name")
  done
  if [[ "$removed" -eq 0 ]]; then echo "  $name: nothing found to remove"; fi
}

remove_lib() {
  local name="$1"
  plain_name "$name" || return 0
  if [[ -e "$REPO_ROOT/$LIB_DEST/$name" || -L "$REPO_ROOT/$LIB_DEST/$name" ]]; then
    rm -rf "${REPO_ROOT:?}/$LIB_DEST/$name"
    echo "  removed $LIB_DEST/$name/"
  fi
}

# manifest_list <key> — the names under the manifest's .skills or .libs, one per line. An install made
# before libraries keyed skills by name with a version each; both forms read the same.
manifest_list() {
  [[ -f "$MANIFEST" ]] || return 0
  jq -r --arg k "$1" '.[$k] // [] | if type == "object" then keys[] else .[] end' "$MANIFEST" | tr -d '\r'
}

# Drop .coding-crew/lib/ and .coding-crew/ only when empty: config.json is the user's and must survive.
prune_coding_crew_dirs() {
  if [[ -d "$REPO_ROOT/$LIB_DEST" ]]; then
    rmdir_if_empty "$REPO_ROOT/$LIB_DEST" && echo "  removed $LIB_DEST/" || true
  fi
  if [[ -d "$REPO_ROOT/.coding-crew" ]]; then
    rmdir_if_empty "$REPO_ROOT/.coding-crew" && echo "  removed .coding-crew/" || true
  fi
}

# After removing <names> (one per line): drop them from the manifest, and remove each library it lists
# that no remaining skill's registry entry names. No skill left removes the manifest itself.
update_manifest() {
  local removed="$1" remaining="" needed="" keep_libs="" name lib
  [[ -f "$MANIFEST" ]] || return 0
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    grep -qxF "$name" <<< "$removed" || remaining+="$name"$'\n'
  done < <(manifest_list skills)
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    needed+="$(jq -r --arg s "$name" '.skills[$s].libs // [] | .[]' "$SCRIPT_DIR/registry.json" | tr -d '\r')"$'\n'
  done <<< "$remaining"
  while IFS= read -r lib; do
    [[ -n "$lib" ]] || continue
    if grep -qxF "$lib" <<< "$needed"; then keep_libs+="$lib"$'\n'; else remove_lib "$lib"; fi
  done < <(manifest_list libs)
  if [[ -z "$remaining" ]]; then
    rm -f "$MANIFEST"
    echo "  removed .coding-crew/manifest.json"
    prune_coding_crew_dirs
    return 0
  fi
  jq --arg s "$remaining" --arg l "$keep_libs" \
    '.skills = ($s | split("\n") | map(select(. != ""))) | .libs = ($l | split("\n") | map(select(. != "")))' \
    "$MANIFEST" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
  prune_coding_crew_dirs
}

echo "Target: $REPO_ROOT ($LEVEL-level)"
echo "---"

if [[ "$MODE" == "skills" ]]; then
  _removed=""
  IFS=',' read -ra _arr <<< "$LIST"
  for _s in "${_arr[@]}"; do
    _s="${_s// /}"
    [[ -n "$_s" ]] || continue
    remove_skill "$_s"
    _removed+="$_s"$'\n'
  done
  update_manifest "$_removed"
else
  _skill_names=()
  while IFS= read -r name; do
    name="${name%$'\r'}"
    [[ -n "$name" ]] && _skill_names+=("$name")
  done < <(
    { manifest_list skills
      jq -r '.skills | keys[]' "$SCRIPT_DIR/registry.json"; } | tr -d '\r' | sort -u
  )
  for name in "${_skill_names[@]+"${_skill_names[@]}"}"; do remove_skill "$name"; done

  while IFS= read -r name; do
    [[ -n "$name" ]] && remove_lib "$name"
  done < <(
    { manifest_list libs
      jq -r '[.skills[] | (.libs // [])[]] | unique[]' "$SCRIPT_DIR/registry.json"; } | tr -d '\r' | sort -u
  )

  if [[ -f "$MANIFEST" ]]; then
    rm -f "$MANIFEST"
    echo "  removed .coding-crew/manifest.json"
  fi
  prune_coding_crew_dirs
fi

echo "---"
echo "Done."
