#!/usr/bin/env bats

# Tests for crew-coder context document reading step

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export COPILOT_AGENT="$SCRIPT_DIR/agents/crew-coder/copilot.agent.md"
  export CLAUDE_AGENT="$SCRIPT_DIR/agents/crew-coder/claude.agent.md"
}

@test "copilot.agent.md has Read Context Documents section" {
  grep -q "## Read Context Documents" "$COPILOT_AGENT"
}

@test "copilot.agent.md extracts feature slug from issue path" {
  # Should use the sed pattern: echo "$ISSUE_PATH" | sed 's|.*\.scratch/||' | sed 's|/.*||'
  grep -q "sed 's|.*\\\\.scratch/||'" "$COPILOT_AGENT"
}

@test "copilot.agent.md checks for PRD.md at MAIN_ROOT/.scratch/FEATURE_SLUG/PRD.md" {
  grep -q "MAIN_ROOT.*\.scratch.*FEATURE_SLUG.*PRD\.md\|\.scratch.*FEATURE_SLUG.*PRD\.md.*MAIN_ROOT" "$COPILOT_AGENT"
}

@test "copilot.agent.md does not reference the retired design.md context document" {
  # design.md was consolidated into PRD.md as the single context document.
  ! grep -q 'design\.md' "$COPILOT_AGENT"
}

@test "copilot.agent.md instructs reading the PRD for context" {
  # Assert the behavioral marker, not a literal echo — the echo-only block that
  # merely announced the read was removed as redundant prescription.
  grep -qi 'read .*PRD\.md\|PRD\.md.*keep its content in memory' "$COPILOT_AGENT"
}

@test "copilot.agent.md degrades gracefully when no PRD exists" {
  grep -qi 'does not exist.*continue normally\|continue normally' "$COPILOT_AGENT"
}

@test "copilot.agent.md Read Context Documents section positioned after Environment Setup" {
  # Extract line numbers for both sections
  env_line=$(grep -n "## Environment Setup" "$COPILOT_AGENT" | cut -d: -f1)
  context_line=$(grep -n "## Read Context Documents" "$COPILOT_AGENT" | cut -d: -f1)
  
  # Context section should come after Environment Setup
  [ "$context_line" -gt "$env_line" ]
}

@test "claude.agent.md has Read Context Documents section" {
  grep -q "## Read Context Documents" "$CLAUDE_AGENT"
}

@test "claude.agent.md extracts feature slug from issue path" {
  grep -q "sed 's|.*\\\\.scratch/||'" "$CLAUDE_AGENT"
}

@test "claude.agent.md checks for PRD.md at MAIN_ROOT/.scratch/FEATURE_SLUG/PRD.md" {
  grep -q "MAIN_ROOT.*\.scratch.*FEATURE_SLUG.*PRD\.md\|\.scratch.*FEATURE_SLUG.*PRD\.md.*MAIN_ROOT" "$CLAUDE_AGENT"
}

@test "claude.agent.md does not reference the retired design.md context document" {
  # design.md was consolidated into PRD.md as the single context document.
  ! grep -q 'design\.md' "$CLAUDE_AGENT"
}

@test "claude.agent.md instructs reading the PRD for context" {
  # Assert the behavioral marker, not a literal echo — the echo-only block that
  # merely announced the read was removed as redundant prescription.
  grep -qi 'read .*PRD\.md\|PRD\.md.*keep its content in memory' "$CLAUDE_AGENT"
}

@test "claude.agent.md degrades gracefully when no PRD exists" {
  grep -qi 'does not exist.*continue normally\|continue normally' "$CLAUDE_AGENT"
}

@test "copilot.agent.md structured output mentions Acceptance Criteria section" {
  grep -q "### Acceptance Criteria" "$COPILOT_AGENT"
}

@test "copilot.agent.md mentions both feature criteria and cross-cutting requirements in output" {
  grep -qi "cross-cutting.*requirements\|requirements.*cross-cutting" "$COPILOT_AGENT"
}
