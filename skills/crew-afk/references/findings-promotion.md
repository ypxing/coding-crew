# Findings promotion (shared policy)

How crew-afk gets CRITICAL/HIGH code-review findings fixed inside the same sprint, without a
human in the loop and without looping forever. This file is the single source of truth for the
policy; each platform variant of `SKILL.md` only wires it into its own dispatch mechanics.

Mechanical steps are implemented once in `scripts/promote-findings.sh` so all four platforms
behave identically.

## Why this exists

Per-branch review runs before each merge, and its findings are **advisory** — the branch merges
regardless. That leaves CRITICAL findings on already-merged code with no route back into the
sprint: the report sits in `reviews/` until a human runs `/crew-address-findings`. Promotion
gives those findings a route, using the machinery that already exists (issue → worktree → TDD →
verify → review → merge) instead of a bespoke fix path.

## Two phases

**Phase 1 — normal sprint.** Unchanged. When a branch's review raises CRITICAL/HIGH findings,
write a *parked* fix issue with `Status: deferred-findings`. The loop's `list` operation selects
on `ready-for-agent`, so parked issues are invisible and Phase 1 drains its original queue at
its normal pace.

**Phase 2 — fix round.** When the loop is about to exit, flush the parked issues to
`ready-for-agent` and re-enter the loop instead of exiting. Fix issues are ordinary issues: they
get a worktree, TDD, `verify-worktree.sh`, AC verification, and their own code review before
merging. Squash and coverage validation run after both phases, so fixes are included.

Findings are **not** promoted the moment they are raised. A fix branch running alongside
still-open Phase 1 issues would edit the same files as its siblings; `merge-branches.sh` aborts
on conflict, so early promotion manufactures retained branches out of nothing. Waiting until the
queue is empty removes that class of conflict entirely.

## Rules

**Severity threshold: CRITICAL and HIGH only.** MEDIUM/LOW stay report-only for a human.
Unattended promotion has no triage step — it cannot dismiss a finding that is technically correct
but contradicts a documented architecture decision (which `crew-address-findings` Step 1.5
explicitly requires a human to do). That risk is worth taking for a CRITICAL, where verification
and the Phase 2 review still catch a bad fix, and is not worth a full worktree + coder + verify +
review cycle for a style nit. The threshold is a fixed severity string, so promotion needs no
judgment call — the reviewer already assigned severity.

**Grouping: one fix issue per reviewed branch**, with one acceptance criterion per finding. All
findings from one branch cite that branch's diff, so they cluster in the same files — one
worktree edits them sequentially and intra-group conflict is impossible. Different reviewed
branches touch mostly disjoint code, so those fix issues still parallelize across a batch. This
matches `crew-address-findings` Step 2, which groups findings by branch for the same reason.

**Depth bound: one generation.** Every fix issue carries a `Source:` line. Before promoting, run
`promote-findings.sh guard --issue <issue-file>`; if it prints `skip — source-guarded`, the
findings go in the report and no issue is written. So Phase 2 reviews are report-only and there
is never a Phase 3. This is the whole termination argument — no counters, no phase flag.

**No phase state.** The issue files' `Status:` lines are the only record of which phase the
sprint is in ("do any `deferred-findings` issues remain?"). Do not mirror it into
`sprint-state.json`: derived state that can disagree with its source after a crash is worse than
no state. Flush is a file rewrite for the same reason, which also makes reaching a second exit a
harmless no-op.

**Flush on every exit, not just the normal one.** A sprint that stalls on unrelated issues still
merged code that may carry a CRITICAL finding. The stall path and the "no unblocked ready issues"
path both flush before printing `NO MORE TASKS`.

**Reset stall counters when Phase 2 begins.** Entering Phase 2 with `stall` already at its limit
would trip stall detection on the first `partial` fix round, denying Phase 2 the one-dry-round
grace Phase 1 gets.

**Nothing merged ⇒ nothing promoted, for free.** Findings only exist for branches that passed
both verification gates and merged. A sprint that stalls on a broken environment reviewed nothing,
so the parked set is empty and flush is a no-op — no separate guard needed for that case.

## Report buckets

After a sprint with promotion, `sprint-review-<TIMESTAMP>.md` distinguishes three groups:

- **Promoted** — CRITICAL/HIGH findings fixed in Phase 2, listed under the `## Promoted Findings`
  section that `promote-findings.sh defer` appends (`<branch>: CRITICAL, HIGH → <issue path>`).
- **Open, needs human triage** — MEDIUM/LOW findings from Phase 1 branches.
- **New, found reviewing the fixes** — findings of any severity raised against Phase 2 branches,
  report-only via the depth bound.

`crew-address-findings` reads `## Promoted Findings` and skips the promoted (branch, severity)
pairs, so a later human run starts with a queue of genuinely open findings.

## End-of-sprint reminder

Promotion is deliberately partial — MEDIUM/LOW are never promoted, and Phase 2 findings are
report-only — so a sprint almost always ends with findings a human still has to look at. Every
variant therefore ends by running `promote-findings.sh remind`, which counts the findings **not**
covered by a `## Promoted Findings` marker (attributing each finding to the `## Branch:` section it
appears under) and prints either a real count or `FINDINGS: none`.

The count matters in both directions: it stops the sprint from nudging the user toward an empty
queue, and it stops a CRITICAL finding raised against a fix branch from ending the sprint in
silence. Word the reminder as *still need triage*, not *unfixed* — some findings will be correctly
dismissed once a human reads them.

## Script interface

```bash
# Depth bound: is this branch's issue itself a promoted fix issue?
bash "<skill-dir>/scripts/promote-findings.sh" guard --issue "<issue-file>"
# → "guard: promotable" | "guard: skip — source-guarded ..."

# Park a fix issue and annotate the report. Criteria file = one "- [ ] <finding>" line per finding.
bash "<skill-dir>/scripts/promote-findings.sh" defer \
  --feature-slug "$FEATURE_SLUG" --branch "<reviewed-branch>" --slug "<issue-slug>" \
  --title "Fix review findings: <issue title>" \
  --report ".scratch/$FEATURE_SLUG/reviews/sprint-review-<TIMESTAMP>.md" \
  --criteria-file "<tmp criteria file>"
# → "defer: .scratch/<slug>/issues/open/<NN>-fix-findings-<issue-slug>.md"

# Phase 1 → Phase 2
bash "<skill-dir>/scripts/promote-findings.sh" flush --feature-slug "$FEATURE_SLUG"
# → "FLUSH: promoted=<N>" (re-enter the loop) | "FLUSH: none" (exit as normal)

# Read-only listing of parked issues
bash "<skill-dir>/scripts/promote-findings.sh" list --feature-slug "$FEATURE_SLUG"

# End-of-sprint reminder: findings no promotion covered
bash "<skill-dir>/scripts/promote-findings.sh" remind --feature-slug "$FEATURE_SLUG"
# → "FINDINGS: open=<N> (MEDIUM=3, LOW=2)" + one "report: <path>" line each | "FINDINGS: none"
# → plus "REVIEW-GAPS: branches=<N>" + one "gap: <branch> — <reason>" line, when a review
#   never completed. Printed in addition to the findings line, never instead of it.

# A review that never ran: record the gap instead of self-reviewing inline
bash "<skill-dir>/scripts/promote-findings.sh" mark-not-run \
  --feature-slug "$FEATURE_SLUG" --branch "$BRANCH" --slug "$SLUG" \
  --report "$REPORT" --reason "reviewer dispatch timed out"
# → "mark-not-run: not_run recorded — <branch> (<reason>)" | "mark-not-run: already recorded"
```

## Reviews that never ran

Promotion reads the review report, so a review that never completed promotes nothing. That is
acceptable — review is advisory and no branch is blocked by it. What is not acceptable is the
default failure shape: a dead dispatch writes no `--out` file, nothing is appended to `reviews/`,
and `remind` globbing an empty directory prints `FINDINGS: none`. The sprint then reports a branch
nobody reviewed as though it came back clean.

`mark-not-run` closes that hole by writing a stub `## Branch:` block carrying a
`Review: not_run — <reason>` line. `remind` counts those branches separately from findings and
always prints them, so an unreviewed branch surfaces as a coverage gap. This is the same `not_run`
convention `verify-worktree.sh` uses for check commands it cannot discover: an unknown result is
recorded as unknown, never as a pass.

The orchestrator must not review the branch itself as a fallback. An inline review leaves no
artifact for promotion, `remind`, or `/crew-address-findings` to read, and it discards the
reviewer's fresh, read-only context — the whole reason review is a separate agent. Record the gap
and move on.
