#!/usr/bin/env bats

# Tests for the configure-tracker skill

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export TEMP_DIR=$(mktemp -d)
}

teardown() {
  rm -rf "$TEMP_DIR"
}

# --- Registry entry ---

@test "registry.json has configure-tracker entry under skills" {
  run jq -r '.skills["configure-tracker"] // empty' "$SCRIPT_DIR/registry.json"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

# --- Installation ---

@test "install.sh claude --skill configure-tracker installs SKILL.md to target repo" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill configure-tracker

  [ -f "$TEMP_DIR/.claude/skills/configure-tracker/SKILL.md" ]
}

@test "configure-tracker-auto.sh no longer ships" {
  [ ! -e "$SCRIPT_DIR/scripts/skill-utils/git-workflow/configure-tracker-auto.sh" ]
  run jq -r '.skills["configure-tracker"].scripts // empty' "$SCRIPT_DIR/registry.json"
  [ -z "$output" ]
}
