#!/usr/bin/env bats

# Stage B: the acceptance-criteria check lives inside the code review.
#
# It used to be a second, independent pass over the same diff the reviewer already reads —
# a whole extra agent per branch on claude/codex, and on pi/copilot a full branch diff
# pulled into the orchestrator's own context, where it stayed for the rest of the sprint.
# The reviewer's HIGH class #1 was already "does the implementation satisfy the acceptance
# criteria?", so the two passes asked overlapping questions of identical input.
#
# Now the reviewer returns both halves of one read: an `AC:` verdict line that gates the
# merge, and findings that stay advisory. Independence is preserved — the reviewer is
# read-only and is not the coder — and the receipt gate is unchanged: `close-issue.sh`
# still refuses to close an issue without an `ac` receipt for its own slug.
#
# The gate therefore has to fail closed. A reviewer that dies, times out, or answers
# without a verdict is a criteria check that did not happen, so the branch is retained,
# not merged. These tests lock both halves in: the fold, and the fail-closed default.

load helpers/render

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
AFK_DIR="$REPO_ROOT/skills/crew-afk"
PROTOCOL="$REPO_ROOT/agents/crew-code-reviewer/protocol.md"

# ─── the separate AC pass is gone ────────────────────────────────────────────
#
# Four body assertions lived here — no `ac-verify` fragment, no second agent dispatched to
# verify criteria, no branch diff pulled into the orchestrator's own context, and the folded
# `verify → review (acceptance criteria + findings) → merge → close` order stated verbatim.
# They policed bodies that are launchers now. The fold is structural in
# orchestrator/lib/pipeline.mjs (one `runReview()` call, whose parsed verdict is the gate)
# and asserted end to end in tests/orchestrator/sprint.test.mjs: the gate order from the
# trace log, an `AC: unmet` verdict retaining the branch and writing no receipt, and an
# empty review report reading as a gap rather than a pass. `tests/crew-afk-launcher.bats`
# keeps a launcher from naming the pipeline again.

# ─── the reviewer carries the verdict ────────────────────────────────────────

@test "the reviewer protocol requires an AC verdict line in every branch block" {
  grep -q 'AC: all-met' "$PROTOCOL"
  grep -q 'AC: unmet' "$PROTOCOL"
  # It is parsed, so its wording and position are not the model's choice.
  grep -qiE 'never omitted|required, exactly as shown' "$PROTOCOL"
}

@test "the reviewer answers unmet for a branch it could not review" {
  # An empty diff, an unscopable diff, or a failed dispatch must not read as a pass.
  section=$(awk '/AC: unmet — not verified/{f=1} f' "$PROTOCOL")
  [ -n "$section" ]
  echo "$section" | grep -qi 'must not merge on an absent check'
}

@test "the reviewer treats already-run checks as evidence it cannot produce itself" {
  # Observed in a real codex sprint: the issue's criterion was "a test covers it and
  # `npm test` passes", verify-worktree.sh had already run the suite green in the worktree,
  # and the read-only reviewer answered `unmet — npm test was not executed in this
  # inspection-only review`. The branch was retained every round, forever. Fail-closed is
  # right; demanding evidence the reviewer is structurally unable to produce is not.
  grep -qi 'Execution is not your job' "$PROTOCOL"
  grep -qi 'treat a stated `pass` as the evidence' "$PROTOCOL"
  # Without leaking into a blanket pass.
  grep -qi 'not_run`, or not stated at all, is evidence of nothing' "$PROTOCOL"
  grep -qi 'Never run the checks yourself' "$PROTOCOL"
}

@test "the reviewer's criteria check is a numbered review step, not just a HIGH class" {
  grep -q 'Check the acceptance criteria' "$PROTOCOL"
  # And the HIGH class no longer asks the same question a second time.
  ! grep -q 'does the implementation actually satisfy the acceptance criteria' "$PROTOCOL"
}

@test "the reviewer's findings stay advisory even though its verdict is a gate" {
  grep -qi 'advisory' "$PROTOCOL"
  grep -qiE 'nothing is blocked or re-queued|no branch is blocked' "$PROTOCOL"
}

# ─── the verdict is read, never re-derived ───────────────────────────────────

@test "the launcher platforms read the verdict in code, not in prose" {
  # pi and codex get the reviewer's output as a file, and the orchestrator program parses
  # the AC line out of it (orchestrator/lib/report.mjs, covered by
  # tests/orchestrator/report.test.mjs). What must hold here is that the launcher does not
  # re-acquire the job: a body that greps the verdict is a body back in the pipeline.
  grep -q "AC:" "$REPO_ROOT/orchestrator/lib/report.mjs"
  for v in "${AFK_LAUNCHER_VARIANTS[@]}"; do
    body="$AFK_DIR/$v.SKILL.md"
    [ -f "$body" ]
    if grep -q 'review.md' "$body"; then
      echo "$v launcher reads the review report itself" >&2
      return 1
    fi
  done
}

# ─── the dependency audit is no longer run for output nobody reads ───────────

@test "the dependency audit is gated on a multi-branch review or a manifest diff" {
  # Its output has exactly one consumer: the multi-branch session summary. crew-afk
  # dispatches per branch, so an ungated run was generated and discarded every time.
  grep -q 'dependency-audit.sh' "$PROTOCOL"
  grep -qE 'only\*\* for a multi-branch review' "$PROTOCOL"
  grep -q 'manifest or lockfile' "$PROTOCOL"
  # The context script stays unconditional — it is what selects the checklists.
  grep -qE 'bash "\$CR/scripts/review-context\.sh" --root "\$ROOT"' "$PROTOCOL"
}
