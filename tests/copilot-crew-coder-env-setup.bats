#!/usr/bin/env bats

# Tests for copilot crew-coder environment setup section

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export COPILOT_AGENT="$SCRIPT_DIR/agents/crew-coder/copilot.agent.md"
}

@test "copilot.agent.md reads MAIN_ROOT from prompt" {
  grep -q 'MAIN_ROOT' "$COPILOT_AGENT"
}

@test "copilot.agent.md reads Working directory from prompt" {
  grep -q 'Working directory' "$COPILOT_AGENT"
}

@test "copilot.agent.md sets PROJECT_ROOT from Working directory value" {
  # Must not use bare PROJECT_ROOT=$(pwd) — must derive from Working directory
  grep -q 'PROJECT_ROOT.*Working directory\|Working directory.*PROJECT_ROOT' "$COPILOT_AGENT"
}

@test "copilot.agent.md has no bare PROJECT_ROOT=\$(pwd) in env setup section" {
  # The env setup section must not contain the bare pwd assignment
  ! grep -q 'PROJECT_ROOT=\$(pwd)' "$COPILOT_AGENT"
}

@test "copilot.agent.md has worktree verification block" {
  # Must check that .git is a file, not a directory
  grep -q '\.git.*directory\|directory.*\.git' "$COPILOT_AGENT"
}

@test "copilot.agent.md reports blocked when .git is a directory" {
  grep -q 'blocked' "$COPILOT_AGENT"
}

@test "copilot.agent.md trace log path uses MAIN_ROOT/.scratch/<feature-slug>/traces" {
  grep -q 'MAIN_ROOT.*scratch.*traces\|scratch.*FEATURE_SLUG.*traces\|FEATURE_SLUG.*traces' "$COPILOT_AGENT"
}

@test "copilot.agent.md trace log path includes branch name" {
  grep -q 'traces/.*\.log\|traces.*BRANCH\|BRANCH.*traces' "$COPILOT_AGENT"
}

@test "copilot.agent.md BRANCH derived from git rev-parse abbrev-ref HEAD" {
  grep -q 'git rev-parse --abbrev-ref HEAD' "$COPILOT_AGENT"
}
