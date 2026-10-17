# Shared bats helper: paths to skill bodies as a consuming repo receives them.
#
# The committed SKILL.md is the rendered body (scripts/render-skill.sh expands its fragments in place,
# and tests/rendered-tree.bats fails when it is stale), and every platform receives the same one.

RENDER_HELPER_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# rendered_skill <skill> — prints the path to the skill's SKILL.md
rendered_skill() {
  local dir
  dir=$(jq -r --arg s "$1" '.skills[$s]["source-dir"] // $s' "$RENDER_HELPER_REPO_ROOT/registry.json")
  [ -f "$RENDER_HELPER_REPO_ROOT/skills/$dir/SKILL.md" ] || return 1
  printf '%s\n' "$RENDER_HELPER_REPO_ROOT/skills/$dir/SKILL.md"
}

# The platform list, from platforms.json (helpers/platforms.bash).
source "$(dirname "${BASH_SOURCE[0]}")/platforms.bash"
