#!/usr/bin/env bats

# Tests for crew-coder per-agent trace logging (replaces shared commands.log)

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export COPILOT_AGENT="$SCRIPT_DIR/agents/crew-coder/copilot.agent.md"
  export CLAUDE_AGENT="$SCRIPT_DIR/agents/crew-coder/claude.agent.md"
}

# --- commands.log section removed ---

@test "claude.agent.md does not reference commands.log" {
  ! grep -q 'commands\.log' "$CLAUDE_AGENT"
}

@test "copilot.agent.md does not reference commands.log" {
  ! grep -q 'commands\.log' "$COPILOT_AGENT"
}

# --- Per-agent trace section present ---

@test "claude.agent.md has per-agent trace section" {
  grep -q "## Command Logging\|## Agent Trace\|## Trace Logging\|per-agent trace\|TRACE_LOG\|traces/" "$CLAUDE_AGENT"
}

@test "copilot.agent.md has per-agent trace section" {
  grep -q "## Command Logging\|## Agent Trace\|## Trace Logging\|per-agent trace\|TRACE_LOG\|traces/" "$COPILOT_AGENT"
}

# --- Correct trace file path ---

@test "claude.agent.md trace file path uses traces/<branch>.log under feature dir" {
  grep -q 'traces/.*\.log\|traces.*BRANCH\|traces.*branch' "$CLAUDE_AGENT"
}

@test "copilot.agent.md trace file path uses traces/<branch>.log under feature dir" {
  grep -q 'traces/.*\.log\|traces.*BRANCH\|traces.*branch' "$COPILOT_AGENT"
}

@test "claude.agent.md trace file path is under MAIN_ROOT/.scratch/<feature-slug>/traces" {
  grep -q 'MAIN_ROOT.*scratch.*traces\|scratch.*FEATURE_SLUG.*traces\|FEATURE_SLUG.*traces' "$CLAUDE_AGENT"
}

@test "copilot.agent.md trace file path is under MAIN_ROOT/.scratch/<feature-slug>/traces" {
  grep -q 'MAIN_ROOT.*scratch.*traces\|scratch.*FEATURE_SLUG.*traces\|FEATURE_SLUG.*traces' "$COPILOT_AGENT"
}

# --- Trace format: [START] ---

@test "claude.agent.md has [START] trace entry instruction" {
  grep -q '\[START\]' "$CLAUDE_AGENT"
}

@test "copilot.agent.md has [START] trace entry instruction" {
  grep -q '\[START\]' "$COPILOT_AGENT"
}

# --- Trace format: [PHASE] ---

@test "claude.agent.md has [PHASE] trace entry instruction" {
  grep -q '\[PHASE\]' "$CLAUDE_AGENT"
}

@test "copilot.agent.md has [PHASE] trace entry instruction" {
  grep -q '\[PHASE\]' "$COPILOT_AGENT"
}

# --- Trace format: [CMD] ---

@test "claude.agent.md has [CMD] trace entry instruction" {
  grep -q '\[CMD\]' "$CLAUDE_AGENT"
}

@test "copilot.agent.md has [CMD] trace entry instruction" {
  grep -q '\[CMD\]' "$COPILOT_AGENT"
}

# --- Trace format: [READ] ---

@test "claude.agent.md has [READ] trace entry instruction" {
  grep -q '\[READ\]' "$CLAUDE_AGENT"
}

@test "copilot.agent.md has [READ] trace entry instruction" {
  grep -q '\[READ\]' "$COPILOT_AGENT"
}

# --- Trace format: [WRITE] ---

@test "claude.agent.md has [WRITE] trace entry instruction" {
  grep -q '\[WRITE\]' "$CLAUDE_AGENT"
}

@test "copilot.agent.md has [WRITE] trace entry instruction" {
  grep -q '\[WRITE\]' "$COPILOT_AGENT"
}

# --- Trace format: [DONE] ---

@test "claude.agent.md has [DONE] trace entry instruction" {
  grep -q '\[DONE\]' "$CLAUDE_AGENT"
}

@test "copilot.agent.md has [DONE] trace entry instruction" {
  grep -q '\[DONE\]' "$COPILOT_AGENT"
}

# --- [DONE] always emitted including on blocked ---

@test "claude.agent.md [DONE] instruction specifies it must always be emitted including on blocked" {
  grep -A5 '\[DONE\]' "$CLAUDE_AGENT" | grep -qi 'always\|blocked\|even on'
}

@test "copilot.agent.md [DONE] instruction specifies it must always be emitted including on blocked" {
  grep -A5 '\[DONE\]' "$COPILOT_AGENT" | grep -qi 'always\|blocked\|even on'
}

# --- [READ]/[WRITE] cover tool calls, not just bash ---

@test "claude.agent.md [READ]/[WRITE] instructions cover tool calls" {
  grep -A5 '\[READ\]\|\[WRITE\]' "$CLAUDE_AGENT" | grep -qi 'tool\|Read tool\|Write tool\|Edit tool'
}

@test "copilot.agent.md [READ]/[WRITE] instructions cover tool calls" {
  grep -A5 '\[READ\]\|\[WRITE\]' "$COPILOT_AGENT" | grep -qi 'tool\|read tool\|write tool\|edit tool'
}
