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

# --- Installation ---

@test "install.sh claude --skill configure-tracker installs SKILL.md to target repo" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill configure-tracker

  [ -f "$TEMP_DIR/.claude/skills/configure-tracker/SKILL.md" ]
}

# --- Rendered skill: the two backends, written to config.json ---

_rendered() { bash "$SCRIPT_DIR/scripts/render-skill.sh" configure-tracker claude; }

@test "rendered configure-tracker reads no .coding-crew/docs/templates/ path and offers local and github" {
  run _rendered
  [ "$status" -eq 0 ]
  [[ "$output" != *".coding-crew/docs/templates"* ]]
  [[ "$output" == *"(1) local"* ]]
  [[ "$output" == *"(2) github"* ]]
}

@test "rendered configure-tracker writes config.json's tracker section, keeping other sections" {
  run _rendered
  [[ "$output" == *".coding-crew/config.json"* ]]
  [[ "$output" == *'.tracker = {kind: $k}'* ]]
  [[ "$output" == *'{ "tracker": { "kind": "github" } }'* ]]
}

@test "rendered configure-tracker has no repo prompt and no repo: front matter" {
  run _rendered
  [[ "$output" != *"press enter to use this repository"* ]]
  [[ "$output" != *"repo:"* ]]
  [[ "$output" != *"--repo"* ]]
  [[ "$output" != *"owner/name"* ]]
}

@test "rendered configure-tracker deletes a legacy issue-tracker.md only after writing config.json" {
  run _rendered
  local write_line rm_line
  write_line=$(printf '%s\n' "$output" | grep -n '.tracker = {kind: $k}' | head -1 | cut -d: -f1)
  rm_line=$(printf '%s\n' "$output" | grep -n 'rm -f .*issue-tracker.md' | head -1 | cut -d: -f1)
  [ -n "$write_line" ] && [ -n "$rm_line" ]
  [ "$rm_line" -gt "$write_line" ]
}

@test "configure-tracker-auto.sh no longer ships" {
  [ ! -e "$SCRIPT_DIR/scripts/skill-utils/git-workflow/configure-tracker-auto.sh" ]
  run jq -r '.skills["configure-tracker"].scripts // empty' "$SCRIPT_DIR/registry.json"
  [ -z "$output" ]
  ! grep -q 'configure-tracker-auto' "$SKILL_FILE"
}

@test "configure-tracker/SKILL.md does not mention user-level path (project-level only)" {
  ! grep -q '~/.claude' "$SKILL_FILE"
}

# --- github backend setup ---

@test "configure-tracker/SKILL.md checks gh auth status before any github write" {
  grep -q 'gh auth status' "$SKILL_FILE"
}

@test "configure-tracker/SKILL.md idempotently creates the 7 github labels" {
  for l in needs-triage needs-info ready-for-agent ready-for-human awaiting-merge blocked in-progress; do
    grep -q "$l" "$SKILL_FILE"
  done
  grep -qi 'idempotent' "$SKILL_FILE"
}
