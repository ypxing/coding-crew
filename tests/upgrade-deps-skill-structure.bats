#!/usr/bin/env bats

# Structural tests for the upgrade-deps skill — same pattern as
# add-tests-skill-structure.bats: this skill's only executable surface beyond prose is its
# consumption of dep-install's install-mode detection and issue-tracker.md's publish
# operation, both already covered by their own suites, so it needs a structural test, not an
# execution-behavior suite.

load helpers/render

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export SKILL="$SCRIPT_DIR/skills/upgrade-deps/SKILL.md"
}

@test "upgrade-deps SKILL.md exists" {
  [ -f "$SKILL" ]
}

@test "upgrade-deps SKILL.md references .scratch/" {
  grep -q '\.scratch/' "$SKILL"
}

@test "upgrade-deps SKILL.md references dep-install for install-mode detection" {
  grep -q 'dep-install' "$SKILL"
}

@test "upgrade-deps SKILL.md references the issue-tracker.md lookup chain" {
  # The preamble now comes from the shared fragment (skills/_shared/fragments/<platform>/
  # tracker-configuration.md) via {{FRAGMENT:...}}, so assert against the rendered body.
  local f="$(rendered_skill upgrade-deps claude)"
  grep -q 'issue-tracker.md' "$f"
  grep -q 'git rev-parse --show-toplevel' "$f"
}

@test "upgrade-deps SKILL.md never modifies package.json or lockfiles" {
  grep -q 'Never modify `package.json`' "$SKILL"
}

@test "upgrade-deps SKILL.md defaults major bumps to ready-for-human" {
  grep -q 'ready-for-human' "$SKILL"
  grep -q 'ready-for-agent' "$SKILL"
}

@test "upgrade-deps SKILL.md requires the safety checklist on non-batch issues" {
  grep -q 'Safety checklist' "$SKILL"
}
