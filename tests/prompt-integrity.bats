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
# The coder bodies are read through helpers/render.bash: a body is protocol.md plus a
# platform block, assembled at install time, so the file a worker is given is the
# installed one. CODER_VARIANTS comes from that helper — one list, not a second copy.

# ─── P1.1 close happens after the merge, never before ────────────────────────
#
# Closing first moves the issue to done/, which issue selection never lists again — so a
# merge that then aborts on conflict orphans the branch and silently loses the work. Three
# of the four prose variants declared `review → close → merge`, which is the bug this
# section was written for; the order is one function body now
# (orchestrator/lib/pipeline.mjs: merge, then close only on the merge's success), asserted
# on a real faked-dispatch sprint in tests/orchestrator/sprint.test.mjs — "the gates run in
# order: verify → AC receipt → merge → close, and squash last".

# ─── P1.2 the verification policy is documented where it is enforced ───────────
#
# It used to be a stale dev checklist pointing at skills/afk/references/*.sh,
# a path that has not existed since the skill was renamed, while all four
# variants told the orchestrator to follow "verification.md order". The fix was to
# make the reference describe the real policy; the reference has since been deleted
# as the third description of one script (verify-worktree.sh states it, and so does
# each skill body). These assertions therefore moved onto the script and the bodies —
# the policy still has to be written down, just not three times.

@test "P1.2: crew-afk ships no verification reference for a body to point at" {
  [ ! -f "$AFK_DIR/references/verification.md" ]
}

@test "P1.2: verify-worktree.sh documents the three categories in run order" {
  ref="$AFK_DIR/scripts/verify-worktree.sh"
  grep -q 'typecheck' "$ref"
  grep -q 'lint' "$ref"
  grep -q 'test' "$ref"
}

# The bodies' half of P1.2 — "state the check order", "state the not_run policy", "a missing
# test command is fatal" — described a decision the orchestrator no longer makes in prose:
# prefilter() in orchestrator/lib/report.mjs is the policy, and it cannot disagree with
# verify-worktree.sh because tests/orchestrator/report.test.mjs asserts both halves
# (demotion on fail and on tests-not-run, lint/typecheck not_run as a recorded gap).

# ─── P1.3 no phantom "with workflow" mode ────────────────────────────────────

@test "P1.3: crew-afk does not advertise a workflow mode with no implementation" {
  ! grep -rq 'with workflow' "$AFK_DIR"
  ! grep -rq 'claude\.workflow\.js' "$AFK_DIR"
}

@test "P1.3: the scripts reference points at the current skill paths" {
  # Relocated out of the installed tree: it documents scripts for a maintainer, and
  # every installed word is a word some agent may read at runtime.
  readme="$REPO_ROOT/docs/crew-afk-scripts.md"
  [ -f "$readme" ]
  [ ! -f "$AFK_DIR/scripts/README.md" ]
  ! grep -q 'skills/afk/' "$readme"
  # Nothing calls these scripts from a body any more — the orchestrator program does. A
  # reference that still names a skill body as the caller sends a maintainer to the wrong
  # file for the call order.
  grep -q 'orchestrator/lib/' "$readme"
  ! grep -q 'skills/crew-afk/dispatch\.SKILL\.md' "$readme"
  ! grep -q 'fragments/' "$readme"
}

# ─── P1.4 the report schema has no unconsumed field ──────────────────────────

@test "P1.4: no crew-coder variant demands a Skills report section" {
  for variant in "${CODER_VARIANTS[@]}"; do
    if grep -q '^### Skills' "$(coder_variant "$variant")"; then
      echo "$variant still requires '### Skills', which no orchestrator reads" >&2
      return 1
    fi
  done
}

@test "P1.4: no crew-afk variant reads a Skills report section" {
  for variant in "${AFK_LAUNCHER_VARIANTS[@]}"; do
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
    run grep -q '^## Example Report' "$(coder_variant "$variant")"
    [ "$status" -eq 0 ] || { echo "$variant has no worked example report" >&2; return 1; }
  done
}

@test "P1.5: the surviving example is the partial one" {
  for variant in "${CODER_VARIANTS[@]}"; do
    section=$(sed -n '/^## Example Report/,$p' "$(coder_variant "$variant")")
    echo "$section" | grep -qi 'partial' || {
      echo "$variant: the surviving example is not a partial report" >&2
      return 1
    }
  done
}

@test "P1.5: the partial example shows an unmet criterion" {
  # Criteria are a JSON array now (`{"text":...,"met":false}`), not a markdown checklist —
  # the 1.28.2 report-shape fix retired the `- [ ]` rendering this used to look for.
  for variant in "${CODER_VARIANTS[@]}"; do
    section=$(sed -n '/^## Example Report/,$p' "$(coder_variant "$variant")")
    echo "$section" | grep -q '"met":false' || {
      echo "$variant: partial example has no unmet criterion ('\"met\":false')" >&2
      return 1
    }
  done
}

@test "P1.5: the partial example shows a check that does not pass" {
  # Every coder now reports checks in the same shape (the launcher report contract), so
  # there is no longer a claude-specific structured-return case to special-case here.
  for variant in "${CODER_VARIANTS[@]}"; do
    section=$(sed -n '/^## Example Report/,$p' "$(coder_variant "$variant")")
    echo "$section" | grep -q -i 'fail' || {
      echo "$variant: partial example shows no failing check" >&2
      return 1
    }
  done
}

@test "P1.5: the partial example commits its work with a WIP marker" {
  for variant in "${CODER_VARIANTS[@]}"; do
    section=$(sed -n '/^## Example Report/,$p' "$(coder_variant "$variant")")
    echo "$section" | grep -q '\[WIP\]' || {
      echo "$variant: partial example does not show the work committed as [WIP]" >&2
      return 1
    }
  done
}

@test "P1.5: no partial example claims all criteria met and all checks passing" {
  for variant in "${CODER_VARIANTS[@]}"; do
    section=$(sed -n '/^## Example Report/,$p' "$(coder_variant "$variant")")
    if echo "$section" | grep -q 'All existing tests pass'; then
      echo "$variant: partial example still describes a complete run" >&2
      return 1
    fi
  done
}
