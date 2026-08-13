#!/usr/bin/env bats

# Tests for crew-coder per-agent trace logging (replaces shared commands.log)
#
# The trace is two lines per worker: [START] and [DONE]. It used to be five markers
# ([START], [PHASE], [CMD], [READ], [WRITE], [DONE]), which cost roughly ten extra
# shell round trips per worker to produce a log nobody reads mid-run. What the trace
# has to answer is "did this worker start, and how did it end" — so the negative
# assertions below are as load-bearing as the positive ones: they stop the retired
# markers being reinstated as prose.

load helpers/render

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export COPILOT_AGENT="$(coder_variant copilot)"
  export CLAUDE_AGENT="$(coder_variant claude)"
  export PI_AGENT="$(coder_variant pi)"
  export CODEX_AGENT="$(coder_variant codex)"
}

all_variants() {
  echo "$CLAUDE_AGENT" "$COPILOT_AGENT" "$PI_AGENT" "$CODEX_AGENT"
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

@test "every crew-coder variant has a [START] trace entry instruction" {
  for f in $(all_variants); do
    grep -q '\[START\]' "$f" || { echo "$(basename "$f") has no [START]" >&2; return 1; }
  done
}

# --- Trace format: [DONE] ---

@test "every crew-coder variant has a [DONE] trace entry instruction" {
  for f in $(all_variants); do
    grep -q '\[DONE\]' "$f" || { echo "$(basename "$f") has no [DONE]" >&2; return 1; }
  done
}

# --- [DONE] always emitted including on blocked ---

@test "every crew-coder variant says [DONE] is always emitted, including on blocked" {
  for f in $(all_variants); do
    grep -B2 -A2 '\[DONE\]' "$f" | grep -qi 'always\|blocked\|even on' || {
      echo "$(basename "$f") does not require [DONE] on a blocked run" >&2; return 1; }
  done
}

# --- the retired per-phase markers stay retired ---

@test "no crew-coder variant reinstates the retired [PHASE]/[CMD]/[READ]/[WRITE] markers" {
  for f in $(all_variants); do
    for marker in PHASE CMD READ WRITE; do
      if grep -q "\[$marker\]" "$f"; then
        echo "$(basename "$f") emits [$marker] again — that is ~10 round trips per worker" >&2
        return 1
      fi
    done
  done
}

@test "every crew-coder variant states the trace is two lines, not one per tool call" {
  for f in $(all_variants); do
    grep -qi 'not two per tool call\|two lines per worker' "$f" || {
      echo "$(basename "$f") does not bound the trace to start and end" >&2; return 1; }
  done
}
