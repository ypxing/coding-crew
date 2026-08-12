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
VARIANTS=(claude pi codex copilot)

# ─── the separate AC pass is gone ────────────────────────────────────────────

@test "no ac-verify fragment survives for any dispatch platform" {
  for platform in pi codex copilot; do
    if [ -f "$AFK_DIR/fragments/$platform/ac-verify.md" ]; then
      echo "fragments/$platform/ac-verify.md is back — the AC pass has forked from the review" >&2
      return 1
    fi
  done
}

@test "no variant dispatches a second agent to verify acceptance criteria" {
  for v in "${VARIANTS[@]}"; do
    body="$(afk_variant "$v")"
    ! grep -qi 'Verify acceptance criteria for a branch' "$body"
    ! grep -qi 'there is no dedicated verifier agent' "$body"
    ! grep -qi 'Verify acceptance criteria (after checks pass' "$body"
  done
}

@test "no variant pulls the branch diff into the orchestrator's own context" {
  # The diff is the single largest input in the pipeline and the reviewer already reads
  # it. On pi and codex the orchestrator's context is not discarded between rounds, so a
  # diff read here is paid for by every later round too.
  for v in "${VARIANTS[@]}"; do
    body="$(afk_variant "$v")"
    if grep -E '^\s*(git( -C "\$MAIN_ROOT")? diff|Diff: git diff)' "$body" | grep -qv 'Gather the diff'; then
      echo "$v reads a branch diff in the orchestrator session" >&2
      grep -nE '^\s*(git( -C "\$MAIN_ROOT")? diff|Diff: git diff)' "$body" >&2
      return 1
    fi
  done
}

@test "every variant states the folded pipeline order" {
  for v in "${VARIANTS[@]}"; do
    run grep -q 'Pipeline order per branch: verify → review (acceptance criteria + findings) → merge → close' \
      "$(afk_variant "$v")"
    [ "$status" -eq 0 ] || { echo "$v does not state the folded pipeline order" >&2; return 1; }
  done
}

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

@test "the reviewer's criteria check is a numbered review step, not just a HIGH class" {
  grep -q 'Check the acceptance criteria' "$PROTOCOL"
  # And the HIGH class no longer asks the same question a second time.
  ! grep -q 'does the implementation actually satisfy the acceptance criteria' "$PROTOCOL"
}

@test "the reviewer's findings stay advisory even though its verdict is a gate" {
  grep -qi 'advisory' "$PROTOCOL"
  grep -qiE 'nothing is blocked or re-queued|no branch is blocked' "$PROTOCOL"
}

# ─── every variant reads the verdict rather than deriving one ─────────────────

@test "every variant writes the ac receipt only on the reviewer's all-met verdict" {
  for v in "${VARIANTS[@]}"; do
    body="$(afk_variant "$v")"
    grep -q 'AC: all-met' "$body" || { echo "$v never names the all-met verdict" >&2; return 1; }
    grep -q 'receipts.sh" write ac' "$body" || { echo "$v never writes the ac receipt" >&2; return 1; }
    grep -qiE 'never re-derive it yourself' "$body" || {
      echo "$v does not forbid re-deriving the verdict" >&2; return 1; }
  done
}

@test "the file-based platforms grep the verdict out of the review report" {
  # pi and codex get the reviewer's output as a file, so reading the verdict is a
  # one-line shell command, not a judgement call.
  for v in pi codex; do
    run grep -q "grep -m1 '\^AC:' \"\$DISPATCH_DIR/\$SLUG.review.md\"" "$(afk_variant "$v")"
    [ "$status" -eq 0 ] || { echo "$v does not read the AC line from the review report" >&2; return 1; }
  done
}

@test "every variant fails closed when no verdict comes back" {
  for v in "${VARIANTS[@]}"; do
    body="$(afk_variant "$v")"
    # Joined, because these rules are prose and wrap across lines.
    flat=$(tr -s '[:space:]' ' ' < "$body")
    [[ "$flat" == *"no verdict at all"* ]] || {
      echo "$v does not name the missing-verdict case" >&2; return 1; }
    [[ "$flat" == *"fail closed"* ]] || { echo "$v does not fail closed" >&2; return 1; }
    # And the failure path is the same demotion every other gate uses.
    grep -q 'review-not-run' "$body" || {
      echo "$v has no retention reason for a review that never ran" >&2; return 1; }
  done
}

@test "no variant merges a branch whose review never completed" {
  for v in "${VARIANTS[@]}"; do
    body="$(afk_variant "$v")"
    if grep -qi 'still merges unreviewed' "$body"; then
      echo "$v still merges a branch whose review never ran, but the review now carries the AC gate" >&2
      return 1
    fi
  done
}

@test "the review gap is still recorded, not repaired by the orchestrator" {
  for v in "${VARIANTS[@]}"; do
    body="$(afk_variant "$v")"
    grep -q 'mark-not-run' "$body"
    grep -qi 'do not review the branch yourself' "$body"
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
