#!/usr/bin/env bats

# Regression tests for the prompt-integrity defects found by the audit in
# .scratch/prompt-effectiveness-audit.md (P1). Each test here failed before its fix.
#
# These assert on prompt text because the defects are prompt text — a pipeline
# ordering claim, a dead reference, a phantom mode, a contradictory example. Where
# a behaviour is observable at runtime it belongs in a script test instead; see
# tests/workflow-integrity.bats.

load helpers/render

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
AFK_DIR="$REPO_ROOT/skills/crew-afk"
CODER_DIR="$REPO_ROOT/agents/crew-coder"

# Platform bodies are rendered (pi/codex/copilot share one source body), so these
# are platform names resolved through afk_variant, not filenames.
DISPATCH_VARIANTS=("${AFK_PROSE_DISPATCH_VARIANTS[@]}")
ALL_VARIANTS=("${AFK_PROSE_VARIANTS[@]}")
CODER_VARIANTS=(claude.agent.md pi.agent.md copilot.agent.md codex.agent.toml)
REPORT_CODERS=(claude.agent.md pi.agent.md copilot.agent.md codex.agent.toml)

# ─── P1.1 close happens after the merge, never before ────────────────────────
#
# Closing first moves the issue to done/, which step 1 never lists again — so a
# merge that then aborts on conflict orphans the branch and silently loses the
# work. The Claude variant always merged first; the other three did not.

@test "P1.1: every crew-afk variant declares a pipeline that merges before closing" {
  for variant in "${ALL_VARIANTS[@]}"; do
    run grep -q 'Pipeline order per branch:.*merge' "$(afk_variant "$variant")"
    [ "$status" -eq 0 ] || { echo "$variant: no pipeline order line" >&2; return 1; }
    if grep -q 'Pipeline order per branch:.*close → merge' "$(afk_variant "$variant")"; then
      echo "$variant declares close before merge — a failed merge would orphan the branch" >&2
      return 1
    fi
  done
}

@test "P1.1: dispatch variants invoke merge-branches.sh before close-issue.sh" {
  for variant in "${DISPATCH_VARIANTS[@]}"; do
    merge_line=$(grep -n 'scripts/merge-branches\.sh' "$(afk_variant "$variant")" | head -n1 | cut -d: -f1)
    close_line=$(grep -n 'scripts/close-issue\.sh' "$(afk_variant "$variant")" | tail -n1 | cut -d: -f1)
    [ -n "$merge_line" ] || { echo "$variant: no merge-branches.sh call" >&2; return 1; }
    [ -n "$close_line" ] || { echo "$variant: no close-issue.sh call" >&2; return 1; }
    [ "$merge_line" -lt "$close_line" ] || {
      echo "$variant: close-issue.sh (line $close_line) runs before merge-branches.sh (line $merge_line)" >&2
      return 1
    }
  done
}

@test "P1.1: dispatch variants make the close conditional on merge success" {
  for variant in "${DISPATCH_VARIANTS[@]}"; do
    run grep -qi 'only if the merge reported' "$(afk_variant "$variant")"
    [ "$status" -eq 0 ] || { echo "$variant: close is not gated on merge success" >&2; return 1; }
  done
}

# ─── P1.2 the verification policy is documented where it is enforced ───────────
#
# It used to be a stale dev checklist pointing at skills/afk/references/*.sh,
# a path that has not existed since the skill was renamed, while all four
# variants told the orchestrator to follow "verification.md order". The fix was to
# make the reference describe the real policy; the reference has since been deleted
# as the third description of one script (verify-worktree.sh states it, and so does
# each skill body). These assertions therefore moved onto the script and the bodies —
# the policy still has to be written down, just not three times.

@test "P1.2: no crew-afk variant points at a verification reference the skill no longer ships" {
  [ ! -f "$AFK_DIR/references/verification.md" ]
  for variant in "${ALL_VARIANTS[@]}"; do
    if grep -q 'references/verification\.md' "$(afk_variant "$variant")"; then
      echo "$variant points at a deleted reference" >&2
      return 1
    fi
  done
}

@test "P1.2: verify-worktree.sh documents the three categories in run order" {
  ref="$AFK_DIR/scripts/verify-worktree.sh"
  grep -q 'typecheck' "$ref"
  grep -q 'lint' "$ref"
  grep -q 'test' "$ref"
  # And every body states the same order, since the orchestrator decides nothing else.
  for variant in "${ALL_VARIANTS[@]}"; do
    grep -qi 'typecheck, then lint, then tests' "$(afk_variant "$variant")" || {
      echo "$variant does not state the check order" >&2; return 1; }
  done
}

@test "P1.2: every crew-afk variant states the not_run policy that verify-worktree enforces" {
  for variant in "${ALL_VARIANTS[@]}"; do
    body=$(afk_variant "$variant")
    grep -q 'not_run' "$body" || { echo "$variant: no not_run policy" >&2; return 1; }
    grep -qi 'coverage gap' "$body" || { echo "$variant: no coverage-gap policy" >&2; return 1; }
    # A missing test command is fatal; a missing lint/typecheck is not. The pre-filter
    # in the skill body and verify-worktree.sh must not be able to disagree.
    grep -qi 'no test command was discoverable' "$body" || {
      echo "$variant: does not treat a missing test command as a failure" >&2; return 1; }
  done
}

# ─── P1.3 no phantom "with workflow" mode ────────────────────────────────────

@test "P1.3: crew-afk does not advertise a workflow mode with no implementation" {
  for variant in "${ALL_VARIANTS[@]}"; do
    if grep -q 'with workflow' "$(afk_variant "$variant")"; then
      echo "$variant advertises \"with workflow\"" >&2
      return 1
    fi
  done
  ! grep -rq 'claude\.workflow\.js' "$AFK_DIR"
}

@test "P1.3: the scripts reference points at the current skill paths" {
  # Relocated out of the installed tree: it documents scripts for a maintainer, and
  # every installed word is a word some agent may read at runtime.
  readme="$REPO_ROOT/docs/crew-afk-scripts.md"
  [ -f "$readme" ]
  [ ! -f "$AFK_DIR/scripts/README.md" ]
  ! grep -q 'skills/afk/' "$readme"
  # The dispatch platforms no longer have one file each; the reference must name the
  # shared body and its fragments, not the deleted per-platform variants.
  grep -q 'skills/crew-afk/dispatch\.SKILL\.md' "$readme"
  grep -q 'fragments/' "$readme"
  ! grep -q 'skills/crew-afk/pi\.SKILL\.md' "$readme"
  ! grep -q 'skills/crew-afk/codex\.SKILL\.md' "$readme"
}

# ─── P1.4 the report schema has no unconsumed field ──────────────────────────

@test "P1.4: no crew-coder variant demands a Skills report section" {
  for variant in "${CODER_VARIANTS[@]}"; do
    if grep -q '^### Skills' "$CODER_DIR/$variant"; then
      echo "$variant still requires '### Skills', which no orchestrator reads" >&2
      return 1
    fi
  done
}

@test "P1.4: no crew-afk variant reads a Skills report section" {
  for variant in "${ALL_VARIANTS[@]}"; do
    if grep -q '### Skills' "$(afk_variant "$variant")"; then
      echo "$variant consumes '### Skills' — re-add it to the coder schema" >&2
      return 1
    fi
  done
}

# ─── P1.5 the worked example agrees with the partial definition ──────────────
#
# The old Example 2 was labelled `partial` but showed every criterion [x] and
# every test passing — which is the definition of `complete`. Few-shot examples
# outweigh rules, so a contradictory example is worse than none.
#
# There used to be two examples. The `complete` one only demonstrated the output
# format, which the schema immediately above it already specifies; the `partial` one
# teaches the boundary the schema cannot, so it is the one that survives. Every
# assertion below still applies to it.

@test "P1.5: every crew-coder variant ships a worked example report" {
  for variant in "${CODER_VARIANTS[@]}"; do
    run grep -q '^## Example Report' "$CODER_DIR/$variant"
    [ "$status" -eq 0 ] || { echo "$variant has no worked example report" >&2; return 1; }
  done
}

@test "P1.5: the surviving example is the partial one" {
  for variant in "${CODER_VARIANTS[@]}"; do
    section=$(sed -n '/^## Example Report/,$p' "$CODER_DIR/$variant")
    echo "$section" | grep -qi 'partial' || {
      echo "$variant: the surviving example is not a partial report" >&2
      return 1
    }
  done
}

@test "P1.5: the partial example shows an unmet criterion" {
  for variant in "${CODER_VARIANTS[@]}"; do
    section=$(sed -n '/^## Example Report/,$p' "$CODER_DIR/$variant")
    echo "$section" | grep -q '\- \[ \]' || {
      echo "$variant: partial example has no unmet '- [ ]' criterion" >&2
      return 1
    }
  done
}

@test "P1.5: the partial example shows a check that does not pass" {
  # Every coder now reports checks in the same shape (the launcher report contract), so
  # there is no longer a claude-specific structured-return case to special-case here.
  for variant in "${REPORT_CODERS[@]}"; do
    section=$(sed -n '/^## Example Report/,$p' "$CODER_DIR/$variant")
    echo "$section" | grep -q -i 'fail' || {
      echo "$variant: partial example shows no failing check" >&2
      return 1
    }
  done
}

@test "P1.5: the partial example commits its work with a WIP marker" {
  for variant in "${CODER_VARIANTS[@]}"; do
    section=$(sed -n '/^## Example Report/,$p' "$CODER_DIR/$variant")
    echo "$section" | grep -q '\[WIP\]' || {
      echo "$variant: partial example does not show the work committed as [WIP]" >&2
      return 1
    }
  done
}

@test "P1.5: no partial example claims all criteria met and all checks passing" {
  for variant in "${CODER_VARIANTS[@]}"; do
    section=$(sed -n '/^## Example Report/,$p' "$CODER_DIR/$variant")
    if echo "$section" | grep -q 'All existing tests pass'; then
      echo "$variant: partial example still describes a complete run" >&2
      return 1
    fi
  done
}
