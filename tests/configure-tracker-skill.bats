#!/usr/bin/env bats

# Tests for the configure-tracker skill

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export SKILL_FILE="$SCRIPT_DIR/skills/configure-tracker/SKILL.md"
  export TEMP_DIR=$(mktemp -d)
}

teardown() {
  rm -rf "$TEMP_DIR"
}

# --- Source file exists ---

@test "skills/configure-tracker/SKILL.md exists" {
  [ -f "$SKILL_FILE" ]
}

# --- Registry entry ---

@test "registry.json has configure-tracker entry under skills" {
  run jq -r '.skills["configure-tracker"] // empty' "$SCRIPT_DIR/registry.json"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "registry.json configure-tracker install path is .claude/skills/configure-tracker" {
  run jq -r '.skills["configure-tracker"].install // empty' "$SCRIPT_DIR/registry.json"
  [ "$status" -eq 0 ]
  [ "$output" = ".claude/skills/configure-tracker" ]
}

# --- Installation ---

@test "install.sh claude --skill configure-tracker installs SKILL.md to target repo" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill configure-tracker

  [ -f "$TEMP_DIR/.claude/skills/configure-tracker/SKILL.md" ]
}

# --- Skill content: menu behaviour ---

@test "configure-tracker/SKILL.md references .coding-crew/docs/templates/trackers/ directory" {
  grep -q '\.coding-crew/docs/templates/trackers' "$SKILL_FILE"
}

@test "configure-tracker/SKILL.md describes listing .md files from trackers directory" {
  grep -qE '\.md|list|menu' "$SKILL_FILE"
}

# --- Skill content: write paths ---

@test "configure-tracker/SKILL.md mentions project-level path .coding-crew/docs/issue-tracker.md" {
  grep -q '\.coding-crew/docs/issue-tracker.md' "$SKILL_FILE"
}

@test "configure-tracker/SKILL.md does not mention user-level path (project-level only)" {
  ! grep -q '~/.claude' "$SKILL_FILE"
}

# --- Auto-select behaviour ---

@test "configure-tracker/SKILL.md auto-selects when exactly one template is found" {
  grep -qE 'exactly one|one template|skip.*Step 2|automatically' "$SKILL_FILE"
}
