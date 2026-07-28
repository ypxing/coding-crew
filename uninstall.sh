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

MANIFEST="$REPO_ROOT/.coding-crew.manifest.json"

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
  echo "  (no args) remove everything listed in .coding-crew.manifest.json"
  echo ""
  echo "Examples:"
  echo "  ./uninstall.sh --user                        # remove all from \$HOME"
  echo "  ./uninstall.sh --user --skills tdd,caveman   # remove specific skills from \$HOME"
  exit 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
fi

for cmd in jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Error: required command '$cmd' not found" >&2; exit 1; }
done

PLATFORMS=(claude copilot pi)

# pi keeps user-level resources under ~/.pi/agent/, project-level ones under .pi/
adjust_platform_path() {
  local platform="$1" path="$2"
  if [[ "$platform" == "pi" && "$path" == .pi/* && "$REPO_ROOT" == "$HOME" ]]; then
    printf '.pi/agent/%s' "${path#.pi/}"
  else
    printf '%s' "$path"
  fi
}

remove_agent() {
  local name="$1"
  local removed=0
  local platform path full
  for platform in "${PLATFORMS[@]}"; do
    path=$(jq -r --arg n "$name" --arg p "$platform" '.agents[$n].install.shims[$p] // empty' "$SCRIPT_DIR/registry.json")
    [[ -z "$path" ]] && continue
    path=$(adjust_platform_path "$platform" "$path")
    full="$REPO_ROOT/$path"
    if [[ -f "$full" ]]; then
      rm -f "$full"
      echo "  removed $path"
      removed=1
    fi
  done
  if [[ "$removed" -eq 0 ]]; then echo "  $name: nothing found to remove"; fi
}

remove_skill() {
  local name="$1"
  local claude_dest
  claude_dest=$(jq -r --arg s "$name" '.skills[$s].install // empty' "$SCRIPT_DIR/registry.json")
  if [[ -z "$claude_dest" ]]; then
    echo "  $name: not found in registry — skipping"
    return
  fi

  local removed=0
  local platform dest full
  for platform in "${PLATFORMS[@]}"; do
    if [[ "$platform" == "claude" ]]; then
      dest="$claude_dest"
    else
      dest=$(jq -r --arg s "$name" --arg p "install-$platform" '.skills[$s][$p] // empty' "$SCRIPT_DIR/registry.json")
      [[ -z "$dest" ]] && dest="${claude_dest/.claude\//.$platform/}"
    fi
    [[ -z "$dest" ]] && continue
    dest=$(adjust_platform_path "$platform" "$dest")
    full="$REPO_ROOT/$dest"
    if [[ -d "$full" ]]; then
      rm -rf "$full"
      echo "  removed $dest/"
      removed=1
    fi
  done
  if [[ "$removed" -eq 0 ]]; then echo "  $name: nothing found to remove"; fi
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
  remove_agent "$name"

else
  # Remove everything — union of manifest (if present) and full registry
  echo "---"

  # Collect agent names: manifest + registry, deduped via sort -u
  _agent_names=()
  while IFS= read -r name; do _agent_names+=("$name"); done < <(
    { if [[ -f "$MANIFEST" ]]; then jq -r '.agents | keys[]' "$MANIFEST"; fi
      jq -r '.agents | keys[]' "$SCRIPT_DIR/registry.json"; } | sort -u
  )
  for name in "${_agent_names[@]+"${_agent_names[@]}"}"; do remove_agent "$name"; done

  # Collect skill names: manifest + registry, deduped via sort -u
  _skill_names=()
  while IFS= read -r name; do _skill_names+=("$name"); done < <(
    { if [[ -f "$MANIFEST" ]]; then jq -r '.skills | keys[]' "$MANIFEST"; fi
      jq -r '.skills | keys[]' "$SCRIPT_DIR/registry.json"; } | sort -u
  )
  for name in "${_skill_names[@]+"${_skill_names[@]}"}"; do remove_skill "$name"; done

  if [[ -f "$MANIFEST" ]]; then
    rm -f "$MANIFEST"
    echo "  removed .coding-crew.manifest.json"
  fi
fi

echo "---"
echo "Done."
