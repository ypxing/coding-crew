#!/usr/bin/env bats

# A code review that never ran must be reported as a gap, not as silence.
#
# The failure chain this covers: the reviewer dispatch dies (timeout, crashed CLI,
# killed process) -> no --out file -> nothing appended to .scratch/<slug>/reviews/ ->
# `remind` globs that directory, finds zero reports, and prints "FINDINGS: none".
# The sprint then ends telling the user there is nothing to triage, when in fact a
# branch merged completely unreviewed. Review is advisory by design, but "advisory"
# must not silently degrade into "reported as clean".

load helpers/render

SCRIPT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/skills/crew-afk/scripts/promote-findings.sh"
SKILL_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/skills/crew-afk"

setup() {
  export TEMP_DIR=$(mktemp -d)
  cd "$TEMP_DIR"
  export SLUG="my-feature"
  mkdir -p ".scratch/$SLUG/reviews" ".scratch/$SLUG/issues/open"
  export REPORT=".scratch/$SLUG/reviews/sprint-review-20260812.md"
}

teardown() {
  rm -rf "$TEMP_DIR"
}

# --- mark-not-run writes the gap ------------------------------------------------

@test "mark-not-run creates the review report when the dispatch died before any report existed" {
  [ ! -f "$REPORT" ]

  run bash "$SCRIPT" mark-not-run --feature-slug "$SLUG" --branch "crew/my-feature/alpha" \
    --slug alpha --report "$REPORT" --reason "reviewer dispatch timed out"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not_run"* ]]

  [ -f "$REPORT" ]
  grep -q '^## Branch: crew/my-feature/alpha (alpha)' "$REPORT"
  grep -q '^Review: not_run' "$REPORT"
  grep -q 'reviewer dispatch timed out' "$REPORT"
}

@test "mark-not-run appends to a report that already has reviewed branches" {
  cat > "$REPORT" <<'EOF'
## Branch: crew/my-feature/alpha (alpha)

### Findings
[LOW] naming nit
File: a.py:1
EOF

  run bash "$SCRIPT" mark-not-run --feature-slug "$SLUG" --branch "crew/my-feature/beta" \
    --slug beta --report "$REPORT" --reason "reviewer exited 137"
  [ "$status" -eq 0 ]

  grep -q '^## Branch: crew/my-feature/alpha (alpha)' "$REPORT"
  grep -q '^## Branch: crew/my-feature/beta (beta)' "$REPORT"
  [ "$(grep -c '^Review: not_run' "$REPORT")" -eq 1 ]
}

@test "mark-not-run is idempotent for the same branch" {
  bash "$SCRIPT" mark-not-run --feature-slug "$SLUG" --branch "crew/my-feature/alpha" \
    --slug alpha --report "$REPORT" --reason "timed out" >/dev/null
  run bash "$SCRIPT" mark-not-run --feature-slug "$SLUG" --branch "crew/my-feature/alpha" \
    --slug alpha --report "$REPORT" --reason "timed out again"
  [ "$status" -eq 0 ]

  [ "$(grep -c '^## Branch: crew/my-feature/alpha' "$REPORT")" -eq 1 ]
  [ "$(grep -c '^Review: not_run' "$REPORT")" -eq 1 ]
}

@test "mark-not-run requires a reason so the gap is explainable" {
  run bash "$SCRIPT" mark-not-run --feature-slug "$SLUG" --branch "b" --slug s --report "$REPORT"
  [ "$status" -ne 0 ]
}

# --- remind surfaces the gap ----------------------------------------------------

@test "remind reports a review gap when the only branch went unreviewed" {
  # The exact silent-loss case: zero findings, because nothing ran.
  bash "$SCRIPT" mark-not-run --feature-slug "$SLUG" --branch "crew/my-feature/alpha" \
    --slug alpha --report "$REPORT" --reason "reviewer dispatch timed out" >/dev/null

  run bash "$SCRIPT" remind --feature-slug "$SLUG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"REVIEW-GAPS: branches=1"* ]]
  [[ "$output" == *"crew/my-feature/alpha"* ]]
  [[ "$output" == *"reviewer dispatch timed out"* ]]
}

@test "remind counts findings and gaps independently" {
  cat > "$REPORT" <<'EOF'
## Branch: crew/my-feature/alpha (alpha)

### Findings
[HIGH] unsanitised input
File: a.py:10
[MEDIUM] missing test
File: a.py:20
EOF
  bash "$SCRIPT" mark-not-run --feature-slug "$SLUG" --branch "crew/my-feature/beta" \
    --slug beta --report "$REPORT" --reason "killed" >/dev/null

  run bash "$SCRIPT" remind --feature-slug "$SLUG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"FINDINGS: open=2"* ]]
  [[ "$output" == *"HIGH=1"* ]]
  [[ "$output" == *"MEDIUM=1"* ]]
  [[ "$output" == *"REVIEW-GAPS: branches=1"* ]]
}

@test "the not_run marker is not itself counted as a finding" {
  bash "$SCRIPT" mark-not-run --feature-slug "$SLUG" --branch "crew/my-feature/alpha" \
    --slug alpha --report "$REPORT" --reason "timed out" >/dev/null

  run bash "$SCRIPT" remind --feature-slug "$SLUG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"FINDINGS: none"* ]]
}

@test "remind reports multiple gaps across several branches" {
  for b in alpha beta gamma; do
    bash "$SCRIPT" mark-not-run --feature-slug "$SLUG" --branch "crew/my-feature/$b" \
      --slug "$b" --report "$REPORT" --reason "timed out" >/dev/null
  done

  run bash "$SCRIPT" remind --feature-slug "$SLUG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"REVIEW-GAPS: branches=3"* ]]
}

@test "remind is unchanged when every branch was reviewed" {
  cat > "$REPORT" <<'EOF'
## Branch: crew/my-feature/alpha (alpha)

### Findings
[LOW] nit
File: a.py:1
EOF

  run bash "$SCRIPT" remind --feature-slug "$SLUG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"FINDINGS: open=1"* ]]
  [[ "$output" != *"REVIEW-GAPS"* ]]
}

@test "a promoted finding is still subtracted when the report also has a gap" {
  cat > "$REPORT" <<'EOF'
## Branch: crew/my-feature/alpha (alpha)

### Findings
[HIGH] unsanitised input
File: a.py:10

## Promoted Findings

- crew/my-feature/alpha: CRITICAL, HIGH → .scratch/my-feature/issues/open/02-fix.md
EOF
  bash "$SCRIPT" mark-not-run --feature-slug "$SLUG" --branch "crew/my-feature/beta" \
    --slug beta --report "$REPORT" --reason "timed out" >/dev/null

  run bash "$SCRIPT" remind --feature-slug "$SLUG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"FINDINGS: none"* ]]
  [[ "$output" == *"REVIEW-GAPS: branches=1"* ]]
}

# --- every variant specifies the failure path -----------------------------------

@test "all four skill variants forbid an inline self-review and name mark-not-run" {
  for v in claude pi codex copilot; do
    run grep -q 'mark-not-run' "$(afk_variant "$v")"
    [ "$status" -eq 0 ]
    # The orchestrator must not substitute its own judgement for the reviewer's.
    run grep -qi 'do not review the branch yourself' "$(afk_variant "$v")"
    [ "$status" -eq 0 ]
  done
}

@test "all four skill variants state that an unreviewed branch still merges" {
  for v in claude pi codex copilot; do
    run grep -qi 'unreviewed' "$(afk_variant "$v")"
    [ "$status" -eq 0 ]
  done
}

# Rendering the reminder is no longer prose in four variants — crew-summary.sh does it,
# so the four bodies only have to call it; its branching is tested in tests/crew-afk-state.bats.
@test "all four variants delegate the end-of-sprint reminder to crew-summary.sh" {
  for v in claude pi codex copilot; do
    run grep -q 'crew-summary.sh' "$(afk_variant "$v")"
    [ "$status" -eq 0 ] || { echo "$v does not call crew-summary.sh" >&2; return 1; }
    # The reminder must still be described as the last thing printed, and the
    # unreviewed-branch case must still be named.
    run grep -qi 'last thing printed' "$(afk_variant "$v")"
    [ "$status" -eq 0 ] || { echo "$v does not say the reminder prints last" >&2; return 1; }
    run grep -q 'Unreviewed Branches' "$(afk_variant "$v")"
    [ "$status" -eq 0 ] || { echo "$v never mentions unreviewed branches" >&2; return 1; }
  done
}

@test "remind's documented tokens all actually appear in the script" {
  # Guards against the prose and the script drifting apart.
  for token in 'FINDINGS: none' 'FINDINGS: open=' 'REVIEW-GAPS: branches=' 'gap: '; do
    run grep -q "$token" "$SCRIPT"
    [ "$status" -eq 0 ]
  done
}
