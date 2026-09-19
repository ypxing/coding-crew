#!/usr/bin/env bats

# Tests for issue 05-trim-redundant-prescription
# Verifies two patterns of redundant prescription are removed:
#   1. Echo-only bash blocks for PRD check
#   2. Duplicated root derivation (second call reuses established values)
#
# A third pattern this file used to pin — per-call trace logging collapsed to a two-line
# [START]/[DONE] phase marker — no longer applies: the per-worker trace file it described
# was removed outright (nothing ever read it back), not further collapsed. See
# agents/crew-coder/protocol.md and tests/crew-coder-protocol.bats.

load helpers/render

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export COPILOT_AGENT="$(coder_variant copilot)"
  export CLAUDE_AGENT="$(coder_variant claude)"
  export SOLVE_ISSUE="$SCRIPT_DIR/skills/solve-issue/SKILL.md"
}

# --- Pattern 1: No echo-only PRD bash blocks ---

@test "claude.agent.md has no bash block that only echoes about reading PRD" {
  # The if-block that just prints "Reading PRD.md for architecture..." should be gone
  ! grep -q 'echo "Reading PRD\.md for architecture' "$CLAUDE_AGENT"
}

@test "copilot.agent.md has no bash block that only echoes about reading PRD" {
  ! grep -q 'echo "Reading PRD\.md for architecture' "$COPILOT_AGENT"
}

@test "solve-issue SKILL.md has no bash block that only echoes about reading PRD" {
  ! grep -q 'echo "Reading PRD\.md from' "$SOLVE_ISSUE"
}

# --- Pattern 2: Root derivation not duplicated ---

@test "solve-issue SKILL.md root derivation defers to already-set values without re-executing full derivation" {
  # The skill should reference already-set values, not re-run the full derivation block.
  # The "already set" guard language should remain, but the full bash derivation block
  # (PROJECT_ROOT=$(pwd) + git common-dir) should be removed or collapsed.
  ! grep -q 'MAIN_ROOT=\$(cd.*\.\.' "$SOLVE_ISSUE"
}

