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
DISPATCH_VARIANTS=(pi codex copilot)
ALL_VARIANTS=(claude pi codex copilot)
CODER_VARIANTS=(claude.agent.md pi.agent.md copilot.agent.md codex.agent.toml)
REPORT_CODERS=(pi.agent.md copilot.agent.md codex.agent.toml)

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

# ─── P1.2 the verification reference documents the real policy ───────────────
#
# It used to be a stale dev checklist pointing at skills/afk/references/*.sh,
# a path that has not existed since the skill was renamed, while all four
# variants told the orchestrator to follow "verification.md order".

@test "P1.2: crew-afk verification.md does not reference the pre-rename skills/afk path" {
  ! grep -q 'skills/afk/' "$AFK_DIR/references/verification.md"
}

@test "P1.2: crew-afk verification.md documents the three categories in run order" {
  ref="$AFK_DIR/references/verification.md"
  typecheck=$(grep -n -i 'typecheck' "$ref" | head -n1 | cut -d: -f1)
  lint=$(grep -n -i '^[0-9]*\.*\s*\**lint' "$ref" | head -n1 | cut -d: -f1)
  tests=$(grep -n -i 'tests\*\*' "$ref" | head -n1 | cut -d: -f1)
  [ -n "$typecheck" ] && [ -n "$lint" ] && [ -n "$tests" ]
  [ "$typecheck" -lt "$lint" ]
  [ "$lint" -lt "$tests" ]
}

@test "P1.2: crew-afk verification.md states the not_run policy that verify-worktree enforces" {
  ref="$AFK_DIR/references/verification.md"
  grep -q 'not_run' "$ref"
  grep -q -i 'coverage gap' "$ref"
  # A missing test command is fatal; a missing lint/typecheck is not. The pre-filter
  # in the skill body and verify-worktree.sh must not be able to disagree.
  grep -q -i 'no \*\*test\*\* command' "$ref"
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

@test "P1.3: scripts README points at the current skill paths" {
  readme="$AFK_DIR/scripts/README.md"
  ! grep -q 'skills/afk/' "$readme"
  # The dispatch platforms no longer have one file each; the README must name the
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

# ─── P1.5 the partial example agrees with the partial definition ─────────────
#
# The old Example 2 was labelled `partial` but showed every criterion [x] and
# every test passing — which is the definition of `complete`. Few-shot examples
# outweigh rules, so a contradictory example is worse than none.

@test "P1.5: every crew-coder variant ships worked example reports" {
  for variant in "${CODER_VARIANTS[@]}"; do
    run grep -q 'Example 1' "$CODER_DIR/$variant"
    [ "$status" -eq 0 ] || { echo "$variant has no example report" >&2; return 1; }
    run grep -q 'Example 2' "$CODER_DIR/$variant"
    [ "$status" -eq 0 ] || { echo "$variant has no partial example" >&2; return 1; }
  done
}

@test "P1.5: the partial example shows an unmet criterion" {
  for variant in "${CODER_VARIANTS[@]}"; do
    section=$(sed -n '/Example 2/,$p' "$CODER_DIR/$variant")
    echo "$section" | grep -q '\- \[ \]' || {
      echo "$variant: partial example has no unmet '- [ ]' criterion" >&2
      return 1
    }
  done
}

@test "P1.5: the partial example shows a check that does not pass" {
  for variant in "${REPORT_CODERS[@]}"; do
    section=$(sed -n '/Example 2/,$p' "$CODER_DIR/$variant")
    echo "$section" | grep -q -i 'fail' || {
      echo "$variant: partial example shows no failing check" >&2
      return 1
    }
  done
  # The Claude variant reports checks as JSON objects with a result field.
  section=$(sed -n '/Example 2/,$p' "$CODER_DIR/claude.agent.md")
  echo "$section" | grep -q '"result": "fail"'
}

@test "P1.5: the partial example commits its work with a WIP marker" {
  for variant in "${CODER_VARIANTS[@]}"; do
    section=$(sed -n '/Example 2/,$p' "$CODER_DIR/$variant")
    echo "$section" | grep -q '\[WIP\]' || {
      echo "$variant: partial example does not show the work committed as [WIP]" >&2
      return 1
    }
  done
}

@test "P1.5: no partial example claims all criteria met and all checks passing" {
  for variant in "${CODER_VARIANTS[@]}"; do
    section=$(sed -n '/Example 2/,$p' "$CODER_DIR/$variant")
    if echo "$section" | grep -q 'All existing tests pass'; then
      echo "$variant: partial example still describes a complete run" >&2
      return 1
    fi
  done
}
