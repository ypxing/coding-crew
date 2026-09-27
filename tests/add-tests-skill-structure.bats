#!/usr/bin/env bats

# Structural tests for the add-tests skill — same pattern as uncovered-skills-structure.bats:
# this skill's only executable surface beyond prose is its consumption of the coverage/
# integration cache fields (see tests/crew-afk-discover-commands.bats /
# tests/crew-afk-write-commands-cache.bats for those), so it needs a structural test, not an
# execution-behavior suite.

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
}

@test "add-tests SKILL.md exists" {
  [ -f "$SCRIPT_DIR/skills/add-tests/SKILL.md" ]
}

@test "add-tests SKILL.md references .scratch/" {
  grep -q '\.scratch/' "$SCRIPT_DIR/skills/add-tests/SKILL.md"
}

@test "add-tests SKILL.md references to-issues" {
  grep -q 'to-issues' "$SCRIPT_DIR/skills/add-tests/SKILL.md"
}

@test "add-tests SKILL.md references test-conventions.md" {
  grep -q 'test-conventions\.md' "$SCRIPT_DIR/skills/add-tests/SKILL.md"
}

@test "add-tests records each real-tier finding's requirements as commands, probed while authoring" {
  local f="$SCRIPT_DIR/skills/add-tests/SKILL.md"
  grep -q '## Requires' "$f"
  grep -q 'Run each now' "$f"
  grep -q 'ready-for-human' "$f"
}

@test "add-tests names a working example spec and import line per helper kind" {
  grep -q 'A working example per helper kind' "$SCRIPT_DIR/skills/add-tests/SKILL.md"
  grep -q 'its import line' "$SCRIPT_DIR/skills/add-tests/SKILL.md"
}
