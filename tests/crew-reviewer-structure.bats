#!/usr/bin/env bats

# Structural tests for the crew-reviewer agent

load helpers/render

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export AGENT_DIR="$SCRIPT_DIR/orchestrator/roles"
}

@test "crew-reviewer protocol.md exists" {
  [ -f "$AGENT_DIR/reviewer.md" ]
}

@test "crew-reviewer protocol.md contains severity levels CRITICAL and HIGH" {
  grep -q 'CRITICAL' "$AGENT_DIR/reviewer.md"
  grep -q 'HIGH' "$AGENT_DIR/reviewer.md"
}

@test "crew-reviewer agent files contain no stale crew-plan reference" {
  ! grep -r 'crew-plan' "$AGENT_DIR/reviewer.md" "$AGENT_DIR/reviewer/"
}

@test "an empty diff is judged against the tree, not skipped as unmet" {
  # A coder that finds every criterion already met and already tested commits nothing
  # (solve-issue §3). Reading that as `unmet` retried the issue to a block and stranded every
  # issue behind it — for work that was already done.
  grep -qF 'Diff scope: empty' "$AGENT_DIR/reviewer.md"
  grep -q 'against the files at the branch tip' "$AGENT_DIR/reviewer.md"
  ! grep -qE 'SKIPPED: <reason — empty diff' "$AGENT_DIR/reviewer.md"
}

@test "a criterion is met at a location a branch commit maps it to, still with a cited line" {
  # A coder that adapts to a renamed file records the mapping (solve-issue §3's drift); a
  # reviewer holding the issue's stale path would otherwise fail a correct branch.
  grep -qF "<issue's name> → <file:line>" "$AGENT_DIR/reviewer.md"
  grep -q 'cite that line, which is still the evidence' "$AGENT_DIR/reviewer.md"
}

@test "the drift mapping format is the one solve-issue tells the coder to record" {
  grep -qF "<issue's name> → <file:line>" "$SCRIPT_DIR/skills/solve-issue/SKILL.md"
}

@test "feature mode is a section of the shared protocol: whole diff, no criteria, reported under feature" {
  grep -q '^## Feature Mode$' "$AGENT_DIR/reviewer.md"
  grep -qF 'Feature review:' "$AGENT_DIR/reviewer.md"
  grep -qF 'whole feature diff' "$AGENT_DIR/reviewer.md"
  grep -q 'no `AC:` verdict' "$AGENT_DIR/reviewer.md"
  grep -qF '`branch` and `slug` both `"feature"`' "$AGENT_DIR/reviewer.md"
}

@test "feature mode reads the whole PRD: unimplemented requirements, unconnected flows and unowned concerns are findings, on every platform" {
  local plat f mode
  for plat in claude copilot pi codex; do
    f="$(role_prompt reviewer "$plat")"
    mode="$(sed -n '/^## Feature Mode$/,/^## Precision$/p' "$f")"
    grep -qF 'PRD (read it whole; the feature'"'"'s intent):' <<<"$mode"
    grep -qF 'code does not implement at all' <<<"$mode"
    grep -qF 'a flow spanning several issues that the merged code does not connect' <<<"$mode"
    grep -qF 'a cross-cutting concern the PRD asks for that no issue owned' <<<"$mode"
    grep -qF 'A requirement a later ADR, `CONTEXT.md` entry or commit deliberately replaced is not a finding' <<<"$mode"
    ! grep -qF 'Area:' <<<"$mode"
    ! grep -qF 'Other areas' "$f"
    ! grep -qF 'PRD decisions this issue implements' "$f"
    ! grep -qF 'criterion and decision verdicts' "$f"
    ! grep -qF 'criteria and PRD decisions alone' "$f"
  done
}

@test "feature mode reaches every platform's rendered reviewer" {
  local plat
  for plat in claude copilot pi codex; do
    grep -q '^## Feature Mode$' "$(role_prompt reviewer "$plat")"
  done
}

@test "crew-reviewer compares a new reader of an input with the existing one, by reading only" {
  local q="$AGENT_DIR/reviewer/references/quality.md" # loaded for every review, both modes
  grep -qF '**Second reader of the same input**' "$q"
  grep -qF "citing both sides' \`file:line\`" "$q"
  grep -qF 'compare the two by reading' "$q"
}

@test "reviewer protocol: instance search, leftover references, feature mode depth" {
  local f; f="$(role_prompt reviewer claude)"
  grep -qF 'search the tree for every other instance' "$f"
  grep -qF 'names the defect class' "$f"
  grep -qF 'listing' "$f"
  grep -qF '**Leftover references**' "$f"
  grep -qF 'search code, docs, tests and `registry.json`' "$f"
  grep -qF 'a live' "$f"
  grep -qF '`retired_*` lists are exempt' "$f"
  grep -qF 'is reported at any severity' "$f"
  ! grep -qF 'report it only if CRITICAL' "$f"
  grep -qF "2000-line / top-10-files cap does not" "$f"
}

@test "a per-branch review writes findings: [], and the always-on classes and design standard are Feature Mode only, on every platform" {
  local plat f
  for plat in claude copilot pi codex; do
    f="$(role_prompt reviewer "$plat")"
    grep -qF 'A per-branch review writes `findings: []`' "$f"
    grep -qF 'Step 3 (the always-on classes) and the design-standard checks apply only to a `Feature review:` dispatch' "$f"
    ! grep -qF 'findings are still reported — the branch returns to a worker with them' "$f"
  done
}

@test "a per-branch review still reads what the change relies on (item 3) as evidence for its verdicts, on every platform" {
  local plat f
  for plat in claude copilot pi codex; do
    f="$(role_prompt reviewer "$plat")"
    grep -qF 'A per-branch review runs item 3 as evidence for its criterion verdicts' "$f"
    ! grep -qF 'A per-branch review stops after item 2' "$f"
  done
}
