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

# --- github backend setup ---

@test "configure-tracker/SKILL.md checks gh auth status before any github write" {
  grep -q 'gh auth status' "$SKILL_FILE"
}

@test "configure-tracker/SKILL.md prompts for the repo, blank meaning omit repo:" {
  grep -q 'press enter to use this repository, or enter' "$SKILL_FILE"
  grep -qi 'blank' "$SKILL_FILE"
}

@test "configure-tracker/SKILL.md idempotently creates the 4 canonical github labels" {
  grep -q 'needs-triage'    "$SKILL_FILE"
  grep -q 'needs-info'      "$SKILL_FILE"
  grep -q 'ready-for-agent' "$SKILL_FILE"
  grep -q 'ready-for-human' "$SKILL_FILE"
  grep -qi 'idempotent' "$SKILL_FILE"
}

@test "configure-tracker/SKILL.md writes tracker/repo front matter using readTrackerConfig's field names" {
  grep -q 'tracker: github' "$SKILL_FILE"
  grep -q 'repo:' "$SKILL_FILE"
}

# --- ambiguous-template exit code (dormant-bug fix) ---

@test "configure-tracker/SKILL.md Step 1 branches on exit code 2 into the interactive menu" {
  grep -qE 'exits? 2' "$SKILL_FILE"
}

@test "configure-tracker-auto.sh exits 2 (not 0) when 2+ templates exist and nothing is configured yet" {
  local AUTO_SCRIPT="$SCRIPT_DIR/scripts/skill-utils/git-workflow/configure-tracker-auto.sh"
  cd "$TEMP_DIR"
  git init -q .
  mkdir -p .coding-crew/docs/templates/trackers
  cp "$SCRIPT_DIR/docs/templates/trackers/local.md"  .coding-crew/docs/templates/trackers/
  cp "$SCRIPT_DIR/docs/templates/trackers/github.md" .coding-crew/docs/templates/trackers/

  run bash "$AUTO_SCRIPT"

  [ "$status" -eq 2 ]
  [ ! -f ".coding-crew/docs/issue-tracker.md" ]
}

@test "configure-tracker-auto.sh still no-ops (exit 0) when already configured, regardless of template count" {
  local AUTO_SCRIPT="$SCRIPT_DIR/scripts/skill-utils/git-workflow/configure-tracker-auto.sh"
  cd "$TEMP_DIR"
  git init -q .
  mkdir -p .coding-crew/docs/templates/trackers
  cp "$SCRIPT_DIR/docs/templates/trackers/local.md"  .coding-crew/docs/templates/trackers/
  cp "$SCRIPT_DIR/docs/templates/trackers/github.md" .coding-crew/docs/templates/trackers/
  mkdir -p .coding-crew/docs
  echo "already here" > .coding-crew/docs/issue-tracker.md

  run bash "$AUTO_SCRIPT"

  [ "$status" -eq 0 ]
  grep -q "already here" .coding-crew/docs/issue-tracker.md
}

@test "configure-tracker-auto.sh still auto-applies (exit 0) when exactly one template exists" {
  local AUTO_SCRIPT="$SCRIPT_DIR/scripts/skill-utils/git-workflow/configure-tracker-auto.sh"
  cd "$TEMP_DIR"
  git init -q .
  mkdir -p .coding-crew/docs/templates/trackers
  cp "$SCRIPT_DIR/docs/templates/trackers/local.md" .coding-crew/docs/templates/trackers/

  run bash "$AUTO_SCRIPT"

  [ "$status" -eq 0 ]
  [ -f ".coding-crew/docs/issue-tracker.md" ]
}

# --- README documents the github backend ---

@test "README.md mentions GitHub Issues as a supported tracker backend via configure-tracker" {
  grep -qi 'GitHub Issues' "$SCRIPT_DIR/README.md"
  grep -q 'configure-tracker' "$SCRIPT_DIR/README.md"
}
