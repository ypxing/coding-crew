#!/usr/bin/env bats

# solve-issue §3's premise check: before any code is written, the issue is held against the
# code it describes. An issue is written before anyone reads that code, so it can name a function
# that does not exist, a bug already fixed, or a criterion the PRD rules out — and a coder that
# never checks builds the wrong thing, which the reviewer then passes against the same wrong
# criteria. The check belongs to solve-issue, not crew-coder: a direct /solve-issue run needs it
# too. The orchestrator side (a premise stop lands in ## Blocked, unretried; an already-met issue
# closes with no commits and unblocks its dependents) is in
# tests/orchestrator/sprint-worker-outcomes.test.mjs.

load helpers/render

setup() {
  BODY="$(rendered_skill solve-issue claude)"
  STEP3=$(awk '/^### 3\./{f=1;next} /^### /{f=0} f' "$BODY")
  STEP4=$(awk '/^### 4\./{f=1;next} /^### /{f=0} f' "$BODY")
  PREMISE=$(echo "$STEP3" | awk '/^\*\*Premise check/{f=1} /^\*\*Batch these calls/{f=0} f')
}

@test "Step 3 ends in a premise check, before any code is written" {
  [ -n "$PREMISE" ]
  echo "$PREMISE" | grep -q 'before Step 4'
}

@test "the premise check covers every criterion and every named file, symbol or behavior, with file:line" {
  echo "$PREMISE" | grep -q 'each acceptance criterion'
  echo "$PREMISE" | grep -q 'symbol or'
  echo "$PREMISE" | grep -q 'behavior the issue names'
  echo "$PREMISE" | grep -qF '`file:line`'
}

@test "drift with the same intent adapts instead of stopping, and records the mapping" {
  echo "$PREMISE" | grep -q 'Drift, same intent'
  echo "$PREMISE" | grep -qF "<issue's name> → <file:line>"
  echo "$PREMISE" | grep -q "Step 6's \`DETAILS\`"
}

@test "already met is not a stop: no code, a pinning test, reported met" {
  # Blocking a finished issue strands every issue listing it under ## Blocked by, for nothing.
  section=$(echo "$PREMISE" | awk '/^- \*\*Already met\*\*/{f=1} /^- \*\*Wrong assumption\*\*/{f=0} f')
  [ -n "$section" ]
  echo "$section" | grep -q 'write no'
  echo "$section" | grep -q 'Pin it with a test if none exists'
  echo "$section" | grep -q 'regression test'
  echo "$section" | grep -q 'still `complete`'
  ! echo "$section" | grep -q 'blocked'
}

@test "a bug already fixed is already met, not a wrong assumption" {
  section=$(echo "$PREMISE" | awk '/^- \*\*Already met\*\*/{f=1} /^- \*\*Wrong assumption\*\*/{f=0} f')
  echo "$section" | grep -q 'a bug already'
}

@test "work this issue already committed on its branch is a resume, not 'already met'" {
  # Otherwise every retried round would read its own earlier commits as pre-existing code.
  echo "$PREMISE" | grep -qF '[$ISSUE_SLUG]'
  echo "$PREMISE" | grep -q 'resumed run'
}

@test "only a wrong assumption blocks, with its own BLOCKED: line and the search as evidence" {
  section=$(echo "$PREMISE" | awk '/^- \*\*Wrong assumption\*\*/{f=1} f')
  [ -n "$section" ]
  echo "$section" | grep -q 'has no counterpart'
  echo "$section" | grep -q "bug's code path does not exist"
  echo "$section" | grep -q 'conflicts with the PRD, an ADR or another criterion'
  echo "$section" | grep -q 'Report `blocked` before writing code'
  echo "$section" | grep -qF 'BLOCKED: premise:'
  echo "$section" | grep -q 'the search as evidence'
  [ "$(echo "$PREMISE" | grep -c 'blocked')" -eq 1 ]
}

@test "the premise check does not become an escape hatch" {
  echo "$PREMISE" | grep -q 'more reading would settle'
  echo "$PREMISE" | grep -q 'a design you merely prefer'
}

@test "a bug-fix RED that never fails is kept as the regression test, not rewritten" {
  echo "$STEP4" | grep -q 'passes on its first run'
  echo "$STEP4" | grep -q 'keep it as the regression test'
  echo "$STEP4" | grep -q "Step 3's already met"
}

@test "complete admits a run with nothing to commit, only via already met" {
  outcome=$(awk '/^## Outcome/{f=1;next} /^## /{f=0} f' "$BODY")
  echo "$outcome" | grep -q "there was none: Step 3's already met"
}

@test "the premise check names no caller" {
  ! echo "$PREMISE" | grep -qiE 'crew-afk|crew-coder|orchestrat|triage|report\.json'
}
