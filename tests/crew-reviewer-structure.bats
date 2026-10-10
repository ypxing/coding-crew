#!/usr/bin/env bats

# Structural tests for the crew-reviewer agent

load helpers/render
load helpers/platforms

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
  for plat in "${PLATFORMS[@]}"; do
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
  for plat in "${PLATFORMS[@]}"; do
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
  grep -qF 'search code, docs, tests, scripts and `registry.json`' "$f"
  grep -qF 'prompt step or' "$f"
  grep -qF '**Undefined names in shared text**' "$f"
  grep -qF 'every file it renders into defines each one' "$f"
  grep -qF 'a live' "$f"
  grep -qF '`retired_*` lists are exempt' "$f"
  grep -qF 'is reported at any severity' "$f"
  ! grep -qF 'report it only if CRITICAL' "$f"
  grep -qF "2000-line / top-10-files cap does not" "$f"
}

@test "a per-branch review writes findings: [], and the always-on classes and design standard are Feature Mode only, on every platform" {
  local plat f
  for plat in "${PLATFORMS[@]}"; do
    f="$(role_prompt reviewer "$plat")"
    grep -qF 'A per-branch review writes `findings: []`' "$f"
    grep -qF 'Step 3 (the always-on classes) and the design-standard checks apply only to a `Feature review:` dispatch' "$f"
    ! grep -qF 'findings are still reported — the branch returns to a worker with them' "$f"
  done
}

@test "a per-branch review still reads what the change relies on (item 3) as evidence for its verdicts, on every platform" {
  local plat f
  for plat in "${PLATFORMS[@]}"; do
    f="$(role_prompt reviewer "$plat")"
    grep -qF 'A per-branch review runs item 3 as evidence for its criterion verdicts' "$f"
    ! grep -qF 'A per-branch review stops after item 2' "$f"
  done
}

@test "feature mode asks Coverage and Correctness in two passes: Pass 1 collects without judging, Pass 2 applies the gate, on every platform" {
  local plat f mode pass1
  for plat in "${PLATFORMS[@]}"; do
    f="$(role_prompt reviewer "$plat")"
    mode="$(sed -n '/^## Feature Mode$/,/^## Precision$/p' "$f")"
    grep -qF '**Coverage.**' <<<"$mode"
    grep -qF '**Correctness.**' <<<"$mode"
    grep -qF '**Pass 1 — Collect candidates.**' <<<"$mode"
    grep -qF '**Pass 2 — Verify each candidate.**' <<<"$mode"
    pass1="$(sed -n '/Pass 1 — Collect candidates/,/Pass 2 — Verify each candidate/p' <<<"$mode")"
    grep -qF 'including ones you are not yet sure of' <<<"$pass1"
    grep -qF 'Do not judge yet' <<<"$pass1"
    sed -n '/Pass 2 — Verify each candidate/,$p' <<<"$mode" | grep -qF 'Apply the Pre-Report Gate and Common False Positives'
    # The drop-early rules are Pass 2's, never applied before the candidates are collected.
    grep -qF 'In Feature Mode the gate is Pass 2' "$f"
    grep -qF 'never before Pass 1 has collected every candidate' "$f"
  done
}

@test "feature mode lists dropped candidates under ### Dropped after the JSON; the report JSON and branch mode are unchanged" {
  local plat f mode
  for plat in "${PLATFORMS[@]}"; do
    f="$(role_prompt reviewer "$plat")"
    mode="$(sed -n '/^## Feature Mode$/,/^## Precision$/p' "$f")"
    grep -qF '### Dropped' <<<"$mode"
    grep -qF 'location, suspicion, why dropped' <<<"$mode"
    grep -qF 'in the prose after the JSON' <<<"$mode"
    grep -qF '{"severity": "CRITICAL", "location": "<path>:<line>", "issue": "<what is wrong, one sentence>", "criterion": "<one verifiable fix criterion>"}' "$f"
    grep -qF 'A per-branch review writes `findings: []`' "$f"
  done
}

@test "the reviewer takes the PRD path from the prompt's PRD: line, never from the branch name, on every platform" {
  local plat f
  for plat in "${PLATFORMS[@]}"; do
    f="$(role_prompt reviewer "$plat")"
    grep -qF 'the prompt'"'"'s `PRD: <path>` line' "$f"
    ! grep -qF "sed 's|^feature/||'" "$f"
  done
}

@test "per-branch notes: the report carries concerns outside the criteria; Feature Mode checks each, and a PRD decision excuses no defect, on every platform" {
  local plat f mode
  for plat in "${PLATFORMS[@]}"; do
    f="$(role_prompt reviewer "$plat")"
    mode="$(sed -n '/^## Feature Mode$/,/^## Precision$/p' "$f")"
    # per-branch mode defines `notes`, and a prose-only concern reaches nobody
    grep -qF '"notes": []' "$f"
    grep -qF '`{"location": "<path>:<line>", "concern": "<input or state → bad outcome>"}`' "$f"
    grep -qF 'a concern written only in prose reaches nobody, so in a per-branch review it goes in' "$f"
    # Feature Mode: every listed concern is a Pass 1 candidate that ends as a finding or a Dropped line
    grep -qF 'Concerns per-issue reviewers noted outside their criteria:' <<<"$mode"
    grep -qF 'every listed' <<<"$mode"
    grep -qF 'is a Pass 1 candidate too: each ends in Pass 2 as a finding or a `### Dropped` line' <<<"$mode"
    # code matching the PRD is not evidence; a prescribed defect is a finding naming the decision
    grep -qF 'Code that matches the PRD or a criterion is not evidence that it is correct' <<<"$mode"
    grep -qF 'A defect a decision' <<<"$mode"
    grep -qF 'prescribes is a finding that names that decision' <<<"$mode"
    ! grep -qF 'downgraded or dropped' "$f"
  done
}
