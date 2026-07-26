#!/usr/bin/env bats

# Tests for issue 05-trim-redundant-prescription
# Verifies three patterns of redundant prescription are removed:
#   1. Echo-only bash blocks for PRD check
#   2. Duplicated root derivation (second call reuses established values)
#   3. Per-call trace logging collapsed to phase-level

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export COPILOT_AGENT="$SCRIPT_DIR/agents/crew-coder/copilot.agent.md"
  export CLAUDE_AGENT="$SCRIPT_DIR/agents/crew-coder/claude.agent.md"
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

# --- Pattern 3: Per-call logging replaced by phase-level ---

@test "claude.agent.md does not instruct logging before every individual Bash command" {
  # Per-call instruction "before every Bash command" should be removed
  ! grep -q 'before every Bash command\|Log \[CMD\] before every' "$CLAUDE_AGENT"
}

@test "copilot.agent.md does not instruct logging before every individual shell command" {
  # Per-call instruction "before every shell command" should be removed
  ! grep -q 'before every shell command\|Log \[CMD\] before every' "$COPILOT_AGENT"
}

@test "claude.agent.md still mentions [CMD] marker for phase-level command logging" {
  # Commands are still logged, just at phase level not per-call
  grep -q '\[CMD\]' "$CLAUDE_AGENT"
}

@test "copilot.agent.md still mentions [CMD] marker for phase-level command logging" {
  grep -q '\[CMD\]' "$COPILOT_AGENT"
}

# --- Phase transitions and start/done markers preserved ---

@test "claude.agent.md still has [START] marker" {
  grep -q '\[START\]' "$CLAUDE_AGENT"
}

@test "copilot.agent.md still has [START] marker" {
  grep -q '\[START\]' "$COPILOT_AGENT"
}

@test "claude.agent.md still has [PHASE] logging instruction" {
  grep -q '\[PHASE\]' "$CLAUDE_AGENT"
}

@test "copilot.agent.md still has [PHASE] logging instruction" {
  grep -q '\[PHASE\]' "$COPILOT_AGENT"
}

@test "claude.agent.md still has [DONE] marker including for blocked" {
  grep -q '\[DONE\]' "$CLAUDE_AGENT"
  grep -A5 '\[DONE\]' "$CLAUDE_AGENT" | grep -qi 'always\|blocked'
}

@test "copilot.agent.md still has [DONE] marker including for blocked" {
  grep -q '\[DONE\]' "$COPILOT_AGENT"
  grep -A5 '\[DONE\]' "$COPILOT_AGENT" | grep -qi 'always\|blocked'
}
