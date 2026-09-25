#!/usr/bin/env bats

# Tests for D3: coder tool inheritance via disallowedTools denylist
# Asserts:
#   - No tools: allowlist in claude.agent.md frontmatter
#   - disallowedTools contains Agent and nothing else
#   - No enumerated tool allowlist and no hardcoded mcp__-prefixed server name in any agent file

load helpers/render

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export CLAUDE_AGENT="$(coder_variant claude)"
  export COPILOT_AGENT="$(coder_variant copilot)"
  export REVIEWER_CLAUDE="$SCRIPT_DIR/agents/crew-reviewer/claude.agent.md"
  export REVIEWER_COPILOT="$SCRIPT_DIR/agents/crew-reviewer/copilot.agent.md"
}

# Extract YAML frontmatter (between first pair of --- delimiters)
frontmatter() {
  awk 'BEGIN{f=0} /^---/{f++; next} f==1{print}' "$1"
}

# --- No tools: allowlist in claude.agent.md frontmatter ---

@test "claude.agent.md has no tools: key in frontmatter" {
  run bash -c "$(declare -f frontmatter); frontmatter '$CLAUDE_AGENT' | grep -q '^tools:'"
  [ "$status" -ne 0 ]
}

# --- disallowedTools is present and contains Agent ---

@test "claude.agent.md has disallowedTools in frontmatter" {
  frontmatter "$CLAUDE_AGENT" | grep -q 'disallowedTools'
}

@test "claude.agent.md disallowedTools contains Agent" {
  frontmatter "$CLAUDE_AGENT" | grep -q 'Agent'
}

@test "claude.agent.md disallowedTools contains only Agent (no other entries)" {
  # Count non-empty entries after disallowedTools — should be exactly 1
  count=$(frontmatter "$CLAUDE_AGENT" | awk '/disallowedTools/{f=1; next} f && /^  - /{print} f && /^[^ ]/{f=0}' | grep -c '.')
  [ "$count" -eq 1 ]
}

# --- No hardcoded mcp__-prefixed server name in any agent file ---

@test "claude.agent.md has no hardcoded mcp__ server name" {
  ! grep -q 'mcp__' "$CLAUDE_AGENT"
}

@test "copilot.agent.md has no hardcoded mcp__ server name" {
  ! grep -q 'mcp__' "$COPILOT_AGENT"
}

@test "crew-reviewer claude.agent.md has no hardcoded mcp__ server name" {
  ! grep -q 'mcp__' "$REVIEWER_CLAUDE"
}

@test "crew-reviewer copilot.agent.md has no hardcoded mcp__ server name" {
  ! grep -q 'mcp__' "$REVIEWER_COPILOT"
}
