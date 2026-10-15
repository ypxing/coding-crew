#!/usr/bin/env bats

# The setup-coding-crew skill: what install.sh ships for it, and the one piece of its SKILL.md that is
# code rather than prose, the commit hint.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  TEMP_DIR="$(mktemp -d)"
}
teardown() { rm -rf "$TEMP_DIR"; }

@test "install.sh claude --skill setup-coding-crew ships SKILL.md, the Actions template, both discovery scripts and configure-tracker" {
  local target="$TEMP_DIR/target" skill
  mkdir -p "$target" && git -C "$target" init -q -b main
  run env TARGET_REPO="$target" bash "$REPO_ROOT/install.sh" claude --skill setup-coding-crew
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  skill="$target/.claude/skills/setup-coding-crew"
  [ -f "$skill/SKILL.md" ]
  [ -f "$skill/hosts/github-actions.yml" ]
  [ -f "$skill/scripts/checks/discover-commands.sh" ]
  [ -f "$skill/scripts/checks/write-commands-cache.sh" ]
  [ -f "$skill/scripts/tracker/cli.mjs" ]
  [ -f "$target/.claude/skills/configure-tracker/SKILL.md" ]
  [ "$(jq -c '.skills["setup-coding-crew"].deps' "$REPO_ROOT/registry.json")" = '["configure-tracker"]' ]
}
