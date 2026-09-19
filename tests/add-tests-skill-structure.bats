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
