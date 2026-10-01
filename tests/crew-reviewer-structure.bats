#!/usr/bin/env bats

# Structural tests for the crew-reviewer agent

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export AGENT_DIR="$SCRIPT_DIR/agents/crew-reviewer"
}

@test "crew-reviewer claude.agent.md exists" {
  [ -f "$AGENT_DIR/claude.agent.md" ]
}

@test "crew-reviewer copilot.agent.md exists" {
  [ -f "$AGENT_DIR/copilot.agent.md" ]
}

@test "crew-reviewer protocol.md exists" {
  [ -f "$AGENT_DIR/protocol.md" ]
}

@test "crew-reviewer protocol.md contains severity levels CRITICAL and HIGH" {
  grep -q 'CRITICAL' "$AGENT_DIR/protocol.md"
  grep -q 'HIGH' "$AGENT_DIR/protocol.md"
}

@test "crew-reviewer agent files contain no stale crew-plan reference" {
  ! grep -r 'crew-plan' "$AGENT_DIR/"
}

@test "an empty diff is judged against the tree, not skipped as unmet" {
  # A coder that finds every criterion already met and already tested commits nothing
  # (solve-issue §3). Reading that as `unmet` retried the issue to a block and stranded every
  # issue behind it — for work that was already done.
  grep -qF 'Diff scope: empty' "$AGENT_DIR/protocol.md"
  grep -q 'against the files at the branch tip' "$AGENT_DIR/protocol.md"
  ! grep -qE 'SKIPPED: <reason — empty diff' "$AGENT_DIR/protocol.md"
}

@test "a criterion is met at a location a branch commit maps it to, still with a cited line" {
  # A coder that adapts to a renamed file records the mapping (solve-issue §3's drift); a
  # reviewer holding the issue's stale path would otherwise fail a correct branch.
  grep -qF "<issue's name> → <file:line>" "$AGENT_DIR/protocol.md"
  grep -q 'cite that line, which is still the evidence' "$AGENT_DIR/protocol.md"
}

@test "the drift mapping format is the one solve-issue tells the coder to record" {
  grep -qF "<issue's name> → <file:line>" "$SCRIPT_DIR/skills/solve-issue/SKILL.md"
}

@test "feature mode is a section of the shared protocol: whole diff, no criteria, reported under feature" {
  grep -q '^## Feature Mode$' "$AGENT_DIR/protocol.md"
  grep -qF 'Feature review:' "$AGENT_DIR/protocol.md"
  grep -qF 'whole feature diff' "$AGENT_DIR/protocol.md"
  grep -q 'no `AC:` verdict' "$AGENT_DIR/protocol.md"
  grep -qF '`branch` and `slug` both `"feature"`' "$AGENT_DIR/protocol.md"
}

@test "feature mode reaches every platform's rendered reviewer, and no platform file restates it" {
  local plat
  for plat in claude copilot pi codex; do
    f=$(ls "$AGENT_DIR"/$plat.* | head -1)
    grep -q '{{PROTOCOL}}' "$f"
    ! grep -q 'Feature Mode' "$f"
  done
  TARGET_REPO="$BATS_TEST_TMPDIR/repo"; mkdir -p "$TARGET_REPO"; git -C "$TARGET_REPO" init -q
  TARGET_REPO="$TARGET_REPO" "$SCRIPT_DIR/install.sh" claude crew-reviewer >/dev/null
  grep -q '^## Feature Mode$' "$TARGET_REPO/.claude/agents/crew-reviewer.md"
}

@test "crew-reviewer compares a new reader of an input with the existing one, by reading only" {
  local q="$AGENT_DIR/assets/references/quality.md" # loaded for every review, both modes
  grep -qF '**Second reader of the same input**' "$q"
  grep -qF "citing both sides' \`file:line\`" "$q"
  grep -qF 'compare the two by reading' "$q"
}
