#!/usr/bin/env bats

# Structural tests for the crew-code-reviewer agent

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export AGENT_DIR="$SCRIPT_DIR/agents/crew-code-reviewer"
}

@test "crew-code-reviewer claude.agent.md exists" {
  [ -f "$AGENT_DIR/claude.agent.md" ]
}

@test "crew-code-reviewer copilot.agent.md exists" {
  [ -f "$AGENT_DIR/copilot.agent.md" ]
}

@test "crew-code-reviewer protocol.md exists" {
  [ -f "$AGENT_DIR/protocol.md" ]
}

@test "crew-code-reviewer protocol.md contains severity levels CRITICAL and HIGH" {
  grep -q 'CRITICAL' "$AGENT_DIR/protocol.md"
  grep -q 'HIGH' "$AGENT_DIR/protocol.md"
}

@test "crew-code-reviewer agent files contain no stale crew-plan reference" {
  ! grep -r 'crew-plan' "$AGENT_DIR/"
}
