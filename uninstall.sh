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

remove_agent() {
  local name="$1"
  local claude_dest copilot_dest
  claude_dest=$(jq -r --arg n "$name" '.agents[$n].install.shims.claude // empty' "$SCRIPT_DIR/registry.json")
  copilot_dest=$(jq -r --arg n "$name" '.agents[$n].install.shims.copilot // empty' "$SCRIPT_DIR/registry.json")
  local removed=0
  for path in "$claude_dest" "$copilot_dest"; do
    [[ -z "$path" ]] && continue
    local full="$REPO_ROOT/$path"
    if [[ -f "$full" ]]; then
      rm -f "$full"
      echo "  removed $path"
      removed=1
    fi
  done
  [[ "$removed" -eq 0 ]] && echo "  $name: nothing found to remove"
}

remove_skill() {
  local name="$1"
  local skill_dest
  skill_dest=$(jq -r --arg s "$name" '.skills[$s].install // empty' "$SCRIPT_DIR/registry.json")
  if [[ -z "$skill_dest" ]]; then
    echo "  $name: not found in registry — skipping"
    return
  fi
  local full="$REPO_ROOT/$skill_dest"
  if [[ -d "$full" ]]; then
    rm -rf "$full"
    echo "  removed $skill_dest/"
  else
    echo "  $name: nothing found to remove"
  fi
  # Also remove copilot variant — explicit registry entry, or derived by replacing .claude/ with .copilot/
  local copilot_dest
  copilot_dest=$(jq -r --arg s "$name" '.skills[$s]["install-copilot"] // empty' "$SCRIPT_DIR/registry.json")
  if [[ -z "$copilot_dest" && -n "$skill_dest" ]]; then
    copilot_dest="${skill_dest/.claude\//.copilot/}"
  fi
  if [[ -n "$copilot_dest" ]]; then
    local copilot_full="$REPO_ROOT/$copilot_dest"
    if [[ -d "$copilot_full" ]]; then
      rm -rf "$copilot_full"
      echo "  removed $copilot_dest/"
    fi
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
  remove_agent "$name"

else
  # Remove everything — union of manifest (if present) and full registry
  echo "---"

  # Collect agent names: manifest + registry, deduped via sort -u
  {
    if [[ -f "$MANIFEST" ]]; then jq -r '.agents | keys[]' "$MANIFEST"; fi
    jq -r '.agents | keys[]' "$SCRIPT_DIR/registry.json"
  } | sort -u | while IFS= read -r name; do remove_agent "$name"; done

  # Collect skill names: manifest + registry, deduped via sort -u
  {
    if [[ -f "$MANIFEST" ]]; then jq -r '.skills | keys[]' "$MANIFEST"; fi
    jq -r '.skills | keys[]' "$SCRIPT_DIR/registry.json"
  } | sort -u | while IFS= read -r name; do remove_skill "$name"; done

  if [[ -f "$MANIFEST" ]]; then
    rm -f "$MANIFEST"
    echo "  removed .coding-crew.manifest.json"
  fi
fi

echo "---"
echo "Done."
