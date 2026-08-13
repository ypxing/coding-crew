#!/usr/bin/env bats

# Tests for the PRD context-document read on the worker path.
#
# The read used to live in crew-coder ("## Read Context Documents") *and* in
# solve-issue §1.5 — two reads of one file, one per worker. It now lives only in
# solve-issue, which every crew-coder variant invokes, so these assert it there and
# assert the duplicate is gone from the agent definitions. What must not regress is
# the *behaviour*: both resolution paths (the issue's Context Documents section and
# the conventional .scratch/<feature-slug>/PRD.md) and graceful degradation.

load helpers/render

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export SOLVE_ISSUE="$SCRIPT_DIR/skills/solve-issue/SKILL.md"
  export COPILOT_AGENT="$(coder_variant copilot)"
  export CLAUDE_AGENT="$(coder_variant claude)"
  export PI_AGENT="$(coder_variant pi)"
  export CODEX_AGENT="$(coder_variant codex)"
}

# --- the read lives in solve-issue, once ---

@test "solve-issue has a PRD read step" {
  grep -q '^### 1.5' "$SOLVE_ISSUE"
  grep -qi 'PRD' "$SOLVE_ISSUE"
}

@test "solve-issue resolves the PRD from the issue's Context Documents section" {
  grep -q '## Context Documents' "$SOLVE_ISSUE"
  grep -q 'MAIN_ROOT' "$SOLVE_ISSUE"
}

@test "solve-issue falls back to MAIN_ROOT/.scratch/FEATURE_SLUG/PRD.md" {
  # The fallback is what crew-coder used to provide: an issue with no Context
  # Documents section must still find the feature's PRD.
  grep -q 'MAIN_ROOT/\.scratch/\$FEATURE_SLUG/PRD\.md' "$SOLVE_ISSUE"
  grep -q "sed 's|.*\\.scratch/||'" "$SOLVE_ISSUE"
}

@test "solve-issue instructs keeping the PRD in memory for the run" {
  grep -qi 'keep it in memory\|keep its content in memory' "$SOLVE_ISSUE"
}

@test "solve-issue degrades gracefully when no PRD exists" {
  grep -qi 'No PRD is normal\|continue normally' "$SOLVE_ISSUE"
}

@test "solve-issue does not reference the retired design.md context document" {
  ! grep -q 'design\.md' "$SOLVE_ISSUE"
}

# --- and no longer in the agent definitions ---

@test "no crew-coder variant duplicates the PRD read solve-issue performs" {
  for f in "$COPILOT_AGENT" "$CLAUDE_AGENT" "$PI_AGENT" "$CODEX_AGENT"; do
    if grep -q '## Read Context Documents' "$f"; then
      echo "$(basename "$f") still reads the PRD itself — solve-issue already does" >&2
      return 1
    fi
  done
}

@test "no crew-coder variant references the retired design.md context document" {
  for f in "$COPILOT_AGENT" "$CLAUDE_AGENT" "$PI_AGENT" "$CODEX_AGENT"; do
    ! grep -q 'design\.md' "$f"
  done
}

@test "every crew-coder variant still derives the feature slug exactly once" {
  # Needed for the trace path; deriving it twice was the duplication that was cut.
  for f in "$COPILOT_AGENT" "$CLAUDE_AGENT" "$PI_AGENT" "$CODEX_AGENT"; do
    count=$(grep -c "FEATURE_SLUG=\$(echo" "$f")
    [ "$count" -eq 1 ] || { echo "$(basename "$f") derives FEATURE_SLUG $count times" >&2; return 1; }
  done
}

@test "every crew-coder variant points at solve-issue for the PRD read" {
  for f in "$COPILOT_AGENT" "$CLAUDE_AGENT" "$PI_AGENT" "$CODEX_AGENT"; do
    grep -qi 'solve-issue.*reads the PRD' "$f" || {
      echo "$(basename "$f") does not say solve-issue reads the PRD" >&2; return 1; }
  done
}

# --- report schema still names both criteria sections ---

@test "copilot.agent.md structured output mentions Acceptance Criteria section" {
  grep -q "### Acceptance Criteria" "$COPILOT_AGENT"
}

@test "copilot.agent.md mentions both feature criteria and cross-cutting requirements in output" {
  grep -qi "cross-cutting.*requirements\|requirements.*cross-cutting" "$COPILOT_AGENT"
}
