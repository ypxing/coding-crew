#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Pre-scan for --user flag
INSTALL_LEVEL="project"
_filtered=()
for _arg in "$@"; do
  if [[ "$_arg" == "--user" ]]; then
    INSTALL_LEVEL="user"
  else
    _filtered+=("$_arg")
  fi
done
set -- "${_filtered[@]+"${_filtered[@]}"}"
unset _filtered _arg

if [[ "$INSTALL_LEVEL" == "user" ]]; then
  REPO_ROOT="$HOME"
else
  REPO_ROOT="${TARGET_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
fi

# Current manifest location; fall back to the legacy top-level file if present.
MANIFEST="$REPO_ROOT/.coding-crew/manifest.json"
LEGACY_MANIFEST="$REPO_ROOT/.coding-crew.manifest.json"
if [[ ! -f "$MANIFEST" && -f "$LEGACY_MANIFEST" ]]; then
  MANIFEST="$LEGACY_MANIFEST"
fi

usage() {
  echo "Usage: ./uninstall.sh [--user]"
  echo "       ./uninstall.sh [--user] --skill <skill-name>"
  echo "       ./uninstall.sh [--user] --skills <a,b,c>"
  echo "       ./uninstall.sh [--user] --agent <agent-name>"
  echo ""
  echo "  --user:   uninstall from \$HOME; default uninstalls from current project repo"
  echo "  --skill:  remove a single skill"
  echo "  --skills: remove multiple skills (comma-separated)"
  echo "  --agent:  remove a single agent"
  echo "  (no args) remove everything listed in .coding-crew/manifest.json"
  echo ""
  echo "Examples:"
  echo "  ./uninstall.sh --user                        # remove all from \$HOME"
  echo "  ./uninstall.sh --user --skills tdd,to-issues   # remove specific skills from \$HOME"
  exit 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
fi

for cmd in jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Error: required command '$cmd' not found" >&2; exit 1; }
done

# jq on Windows (Git Bash) writes stdout in text mode, so every line arrives with a
# trailing \r that lands inside the value — a path read as ".pi/skills/tdd\r" is not
# the path that was installed. Normalise once here; see install.sh for the long form.
# Command substitution rather than a `| tr -d '\r'` pipeline: one spawn per lookup
# instead of three, which is what Git Bash's emulated fork() charges for. `$?` after
# an assignment is jq's own status. Probed once so a jq that already writes LF calls
# the binary directly. Defined after the dependency check so `command -v jq` still
# reports a missing binary.
if [[ "$(command jq -rn '"probe"' 2>/dev/null)" == *$'\r' ]]; then
  jq() {
    local _jq_out _jq_rc
    _jq_out=$(command jq "$@")
    _jq_rc=$?
    [[ -n "$_jq_out" ]] && printf '%s\n' "${_jq_out//$'\r'/}"
    return "$_jq_rc"
  }
fi

PLATFORMS=(claude copilot pi codex)

# Registry skill paths are Claude-style; codex reads skills from .agents/skills, every
# other platform from .<platform>/skills.
default_skill_dest() {
  local platform="$1" claude_dest="$2"
  case "$platform" in
    codex) printf '%s' "${claude_dest/.claude\//.agents/}" ;;
    *) printf '%s' "${claude_dest/.claude\//.$platform/}" ;;
  esac
}

# pi keeps user-level resources under ~/.pi/agent/, project-level ones under .pi/
# Copilot is the mirror image: ~/.copilot/{agents,skills} at user level, but
# .github/{agents,skills} at project level (Copilot never scans .copilot/ in a repo).
adjust_platform_path() {
  local platform="$1" path="$2"
  if [[ "$platform" == "pi" && "$path" == .pi/* && "$REPO_ROOT" == "$HOME" ]]; then
    printf '.pi/agent/%s' "${path#.pi/}"
  elif [[ "$platform" == "copilot" && "$path" == .copilot/* && "$REPO_ROOT" != "$HOME" ]]; then
    printf '.github/%s' "${path#.copilot/}"
  else
    printf '%s' "$path"
  fi
}

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

# Mirrors install.sh's resolve_dest: each platform's own CLI can be told to read its
# config from somewhere other than the dot-dir default under $HOME (CLAUDE_CONFIG_DIR,
# COPILOT_HOME, PI_CODING_AGENT_DIR, CODEX_HOME). A user-level uninstall must remove
# from wherever install.sh actually wrote, or a copy under an active override is left
# behind while this script reports removing it. Sets $_DEST_ROOT/$_DEST_REL; only ever
# differs from ($REPO_ROOT, $path) at user scope with the platform's env var set.
_DEST_ROOT=""; _DEST_REL=""
resolve_dest() {
  local platform="$1" path="$2" env_name prefix
  _DEST_ROOT="$REPO_ROOT"; _DEST_REL="$path"
  [[ "$REPO_ROOT" == "$HOME" ]] || return 0
  case "$platform" in
    claude)  env_name=CLAUDE_CONFIG_DIR;   prefix=".claude/" ;;
    copilot) env_name=COPILOT_HOME;        prefix=".copilot/" ;;
    pi)      env_name=PI_CODING_AGENT_DIR; prefix=".pi/agent/" ;;
    codex)   env_name=CODEX_HOME;          prefix=".codex/" ;;
    *) return 0 ;;
  esac
  local env_val="${!env_name:-}"
  [[ -n "$env_val" && "$path" == "$prefix"* ]] || return 0
  _DEST_ROOT="$env_val"
  _DEST_REL="${path#$prefix}"
}

# Walk up from a removed path removing now-empty directories, stopping at $root —
# normally REPO_ROOT, but the platform's own override root when resolve_dest moved it.
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

# Every path a platform's resource may occupy in this target: the path install.sh writes
# now, plus any path an earlier version wrote. Copilot project installs used to land in
# .copilot/, so uninstall sweeps both or the dead copy survives a clean uninstall.
removal_candidates() {
  local platform="$1" path="$2" adjusted
  adjusted=$(adjust_platform_path "$platform" "$path")
  printf '%s\n' "$adjusted"
  [[ "$adjusted" != "$path" ]] && printf '%s\n' "$path"
  return 0
}

remove_agent() {
  local name="$1"
  local removed=0
  local platform path full candidate old
  # A renamed agent's old names (registry.json `replaces`) share its paths with the name swapped,
  # and an install that predates the rename still has them on disk.
  local -a names=("$name")
  while IFS= read -r old; do
    old="${old%$'\r'}"
    [[ -n "$old" ]] && names+=("$old")
  done < <(jq -r --arg n "$name" '.agents[$n].replaces // [] | .[]' "$SCRIPT_DIR/registry.json")
  for platform in "${PLATFORMS[@]}"; do
    path=$(jq -r --arg n "$name" --arg p "$platform" '.agents[$n].install.shims[$p] // empty' "$SCRIPT_DIR/registry.json")
    path="${path%$'\r'}"
    [[ -z "$path" ]] && continue
    for old in "${names[@]}"; do
      while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        resolve_dest "$platform" "$candidate"
        full="$_DEST_ROOT/$_DEST_REL"
        if [[ -f "$full" ]]; then
          rm -f "$full"
          echo "  removed $candidate"
          prune_empty_dirs "$_DEST_ROOT" "$_DEST_REL"
          removed=1
        fi
      done < <(removal_candidates "$platform" "${path//$name/$old}")
    done
  done
  # Agent assets install once to a platform-neutral path and are always overwritten by
  # install.sh, so uninstall owns them too.
  local assets_dest
  assets_dest=$(jq -r --arg n "$name" '.agents[$n].install.assets.dest // empty' "$SCRIPT_DIR/registry.json")
  assets_dest="${assets_dest%$'\r'}"
  if [[ -n "$assets_dest" && -d "$REPO_ROOT/$assets_dest" ]]; then
    rm -rf "$REPO_ROOT/$assets_dest"
    echo "  removed $assets_dest/"
    prune_empty_dirs "$REPO_ROOT" "$assets_dest"
    removed=1
  fi
  if [[ "$removed" -eq 0 ]]; then echo "  $name: nothing found to remove"; fi
}

remove_skill() {
  local name="$1"
  local claude_dest
  claude_dest=$(jq -r --arg s "$name" '.skills[$s].install // empty' "$SCRIPT_DIR/registry.json")
  claude_dest="${claude_dest%$'\r'}"
  if [[ -z "$claude_dest" ]]; then
    echo "  $name: not found in registry — skipping"
    return
  fi

  local removed=0
  local platform dest full candidate
  for platform in "${PLATFORMS[@]}"; do
    if [[ "$platform" == "claude" ]]; then
      dest="$claude_dest"
    else
      dest=$(jq -r --arg s "$name" --arg p "install-$platform" '.skills[$s][$p] // empty' "$SCRIPT_DIR/registry.json")
      dest="${dest%$'\r'}"
      [[ -z "$dest" ]] && dest=$(default_skill_dest "$platform" "$claude_dest")
    fi
    [[ -z "$dest" ]] && continue
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
    done < <(removal_candidates "$platform" "$dest")
  done
  if [[ "$removed" -eq 0 ]]; then echo "  $name: nothing found to remove"; fi

  # Skill assets install once to a platform-neutral path and are always overwritten, so
  # they are removed here for the same reason agent assets are: a stale orchestrator left
  # behind is an executable no installed skill body matches any more.
  local assets_dest
  assets_dest=$(jq -r --arg s "$name" '.skills[$s].assets.dest // empty' "$SCRIPT_DIR/registry.json")
  assets_dest="${assets_dest%$'\r'}"
  if [[ -n "$assets_dest" && -d "$REPO_ROOT/$assets_dest" ]]; then
    rm -rf "$REPO_ROOT/$assets_dest"
    echo "  removed $assets_dest/"
    prune_empty_dirs "$REPO_ROOT" "$assets_dest"
  fi
}

echo "Target: $REPO_ROOT ($INSTALL_LEVEL-level)"

MODE="${1:-all}"

if [[ "$MODE" == "--skill" ]]; then
  name="${2:-}"
  [[ -z "$name" ]] && { echo "Error: --skill requires a skill name" >&2; usage; }
  echo "---"
  remove_skill "$name"

elif [[ "$MODE" == "--skills" ]]; then
  list="${2:-}"
  [[ -z "$list" ]] && { echo "Error: --skills requires a comma-separated list" >&2; usage; }
  echo "---"
  IFS=',' read -ra _arr <<< "$list"
  for _s in "${_arr[@]}"; do
    _s="${_s// /}"
    [[ -n "$_s" ]] && remove_skill "$_s"
  done

elif [[ "$MODE" == "--agent" ]]; then
  name="${2:-}"
  [[ -z "$name" ]] && { echo "Error: --agent requires an agent name" >&2; usage; }
  echo "---"
  # An agent's old name (registry.json `replaces`) means its replacement, which removes both.
  replacement=$(jq -r --arg n "$name" '[.agents | to_entries[] | select((.value.replaces // []) | index($n)) | .key][0] // empty' "$SCRIPT_DIR/registry.json")
  replacement="${replacement%$'\r'}"
  if [[ -n "$replacement" ]]; then
    echo "  $name was renamed to $replacement — removing $replacement and its old name"
    name="$replacement"
  fi
  remove_agent "$name"

else
  # Remove everything — union of manifest (if present) and full registry
  echo "---"

  # Collect agent names: manifest + registry, deduped via sort -u.
  # jq on Windows emits CRLF, so every line is stripped of a trailing \r before use.
  _agent_names=()
  while IFS= read -r name; do
    name="${name%$'\r'}"
    [[ -n "$name" ]] && _agent_names+=("$name")
  done < <(
    # A name some registry agent `replaces` is removed along with that agent, not on its own.
    # Filtered in jq: `grep -vxF -f` needs a non-empty pattern list, and BSD grep reads an
    # empty pattern as match-all even under -x.
    { if [[ -f "$MANIFEST" ]]; then jq -r '.agents | keys[]' "$MANIFEST"; fi
      jq -r '.agents | keys[]' "$SCRIPT_DIR/registry.json"; } | tr -d '\r' | sort -u |
      jq -R -r --slurpfile reg "$SCRIPT_DIR/registry.json" \
        'select(. as $n | [$reg[0].agents[].replaces // [] | .[]] | index($n) | not)'
  )
  for name in "${_agent_names[@]+"${_agent_names[@]}"}"; do remove_agent "$name"; done

  # Collect skill names: manifest + registry, deduped via sort -u
  _skill_names=()
  while IFS= read -r name; do
    name="${name%$'\r'}"
    [[ -n "$name" ]] && _skill_names+=("$name")
  done < <(
    { if [[ -f "$MANIFEST" ]]; then jq -r '.skills | keys[]' "$MANIFEST"; fi
      jq -r '.skills | keys[]' "$SCRIPT_DIR/registry.json"; } | tr -d '\r' | sort -u
  )
  for name in "${_skill_names[@]+"${_skill_names[@]}"}"; do remove_skill "$name"; done

  if [[ -f "$MANIFEST" ]]; then
    rm -f "$MANIFEST"
    echo "  removed ${MANIFEST#$REPO_ROOT/}"
  fi
  # Tracker helper scripts are mechanism, not user text: install.sh always overwrites
  # them, so uninstall removes them. issue-tracker.md and the templates stay.
  if [[ -d "$REPO_ROOT/.coding-crew/scripts" ]]; then
    while IFS= read -r name; do
      name="${name%$'\r'}"
      [[ -n "$name" ]] || continue
      if [[ -f "$REPO_ROOT/$name" ]]; then
        rm -f "$REPO_ROOT/$name"
        echo "  removed $name"
      fi
    done < <(jq -r '.docs.scripts // {} | .[].dest // empty' "$SCRIPT_DIR/registry.json" 2>/dev/null || true)
    rmdir_if_empty "$REPO_ROOT/.coding-crew/scripts" || true
  fi
  # Drop .coding-crew/ only when nothing is left in it — issue-tracker.md and
  # tracker templates are user-customisable and must survive an uninstall.
  if [[ -d "$REPO_ROOT/.coding-crew" ]]; then
    rmdir_if_empty "$REPO_ROOT/.coding-crew" && echo "  removed .coding-crew/" || true
  fi
fi

echo "---"
echo "Done."
