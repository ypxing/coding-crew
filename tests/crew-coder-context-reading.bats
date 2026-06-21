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

@test "copilot.agent.md checks for design.md at MAIN_ROOT/.scratch/FEATURE_SLUG/design.md" {
  grep -q "MAIN_ROOT.*\.scratch.*FEATURE_SLUG.*design\.md\|\.scratch.*FEATURE_SLUG.*design\.md.*MAIN_ROOT" "$COPILOT_AGENT"
}

@test "copilot.agent.md checks for PRD.md at MAIN_ROOT/.scratch/FEATURE_SLUG/PRD.md" {
  grep -q "MAIN_ROOT.*\.scratch.*FEATURE_SLUG.*PRD\.md\|\.scratch.*FEATURE_SLUG.*PRD\.md.*MAIN_ROOT" "$COPILOT_AGENT"
}

@test "copilot.agent.md logs when reading design.md" {
  grep -q "Reading design\.md for architectural context" "$COPILOT_AGENT"
}

@test "copilot.agent.md logs when reading PRD.md" {
  grep -q "Reading PRD\.md for requirements context" "$COPILOT_AGENT"
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

@test "claude.agent.md checks for design.md at MAIN_ROOT/.scratch/FEATURE_SLUG/design.md" {
  grep -q "MAIN_ROOT.*\.scratch.*FEATURE_SLUG.*design\.md\|\.scratch.*FEATURE_SLUG.*design\.md.*MAIN_ROOT" "$CLAUDE_AGENT"
}

@test "claude.agent.md checks for PRD.md at MAIN_ROOT/.scratch/FEATURE_SLUG/PRD.md" {
  grep -q "MAIN_ROOT.*\.scratch.*FEATURE_SLUG.*PRD\.md\|\.scratch.*FEATURE_SLUG.*PRD\.md.*MAIN_ROOT" "$CLAUDE_AGENT"
}

@test "claude.agent.md logs when reading design.md" {
  grep -q "Reading design\.md for architectural context" "$CLAUDE_AGENT"
}

@test "claude.agent.md logs when reading PRD.md" {
  grep -q "Reading PRD\.md for requirements context" "$CLAUDE_AGENT"
}

@test "copilot.agent.md structured output mentions Acceptance Criteria section" {
  grep -q "### Acceptance Criteria" "$COPILOT_AGENT"
}

@test "copilot.agent.md mentions both feature criteria and cross-cutting requirements in output" {
  grep -qi "cross-cutting.*requirements\|requirements.*cross-cutting" "$COPILOT_AGENT"
}
