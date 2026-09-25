# Findings promotion (shared policy)

How crew-afk gets CRITICAL code-review findings fixed inside the same sprint, without a
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

**Phase 1 — normal sprint.** Unchanged. When a branch's review raises findings at or above the
promotion threshold, write a *parked* fix issue with `Status: deferred-findings`. The loop's `list`
operation selects on `ready-for-agent`, so parked issues are invisible and Phase 1 drains its
original queue at its normal pace.

**Phase 2 — fix round.** When the loop is about to exit, flush the parked issues to
`ready-for-agent` and re-enter the loop instead of exiting. Fix issues are ordinary issues: they
get a worktree, TDD, `verify-worktree.sh`, AC verification, and their own code review before
merging. The squash runs after both phases, so fixes are included.

**PRD gaps join the same flush.** When Phase 1 drains, the PRD audit (afk.PRDAudit, default
`fix`) runs once, before the flush. Its ✗ missing requirements — ones no issue carried, so no
review ever checked — become one parked fix issue (`promote-findings.sh defer-gaps`), which
Phase 2 implements alongside the findings fixes. Its `Source:` line is the same depth bound, and
nothing after Phase 2 is audited again. While a Phase 1 issue is still open, gaps are not queued:
that issue's requirements would read as missing.

Findings are **not** promoted the moment they are raised. A fix branch running alongside
still-open Phase 1 issues would edit the same files as its siblings; `merge-branches.sh` aborts
on conflict, so early promotion manufactures retained branches out of nothing. Waiting until the
queue is empty removes that class of conflict entirely.

## Rules

**Severity threshold: config.json's `afk.fixFindings`, default `high`** (`--fix-findings` for one
run). It names the lowest severity fixed: `critical`, `high` (CRITICAL and HIGH), `medium`
(adds MEDIUM) or `none`. LOW is never promoted. Unattended promotion has no triage step — it
cannot dismiss a finding that is technically correct but contradicts a documented architecture
decision (which `crew-address-findings` Step 1.5 explicitly requires a human to do). That risk
is worth taking for a CRITICAL or a HIGH: the reviewer protocol requires each to name a concrete
failure scenario and pass a pre-report gate, and verification and the Phase 2 review still catch
a bad fix. It is not worth a full worktree + coder + verify + review cycle *by default* for a
MEDIUM, which needs no failure scenario. The threshold is a fixed severity string printed by
`promote-findings.sh guard`, so promotion needs no judgment call — the reviewer already assigned
severity, and the orchestrator never has to remember which severities this sprint takes.

Anything below the threshold is paid for on the way out rather than hidden: nothing subtracts an
unpromoted severity from `remind`, so every such finding is counted, named, and attributed to its
report, and the reminder states the threshold that left it open plus the setting that would have
promoted it.

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
merged code that may carry a CRITICAL finding. There is one exit from the dispatch pool — nothing
in flight and nothing left dispatchable, for any reason — and it flushes before printing
`NO MORE TASKS`, whether that's a clean finish or a stall.

**Flush runs the moment the pool is idle, with no delay to reset.** The dispatch pool has no
round-batch or dry-round counter any more (see `orchestrator/lib/loop.mjs`) — flush is tried
exactly when nothing is in flight and nothing is dispatchable, Phase 1 or Phase 2 alike, so
there is no stall-counter state that Phase 2 could inherit stale from Phase 1 in the first place.

**Nothing merged ⇒ nothing promoted, for free.** Findings only exist for branches that passed
both verification gates and merged. A sprint that stalls on a broken environment reviewed nothing,
so the parked set is empty and flush is a no-op — no separate guard needed for that case.

## Report buckets

After a sprint with promotion, `sprint-review-<TIMESTAMP>.md` distinguishes three groups:

- **Promoted** — findings at the threshold severities, fixed in Phase 2, listed under the
  `## Promoted Findings` section that `promote-findings.sh defer` appends
  (`<branch>: CRITICAL → <issue path>`).
- **Open, needs human triage** — everything the threshold did not cover on Phase 1 branches:
  LOW always, and MEDIUM unless `fixFindings` is `medium`.
- **New, found reviewing the fixes** — findings of any severity raised against Phase 2 branches,
  report-only via the depth bound.

`crew-address-findings` reads `## Promoted Findings` and skips the promoted (branch, severity)
pairs, so a later human run starts with a queue of genuinely open findings.

## End-of-sprint reminder

Promotion is deliberately partial — LOW is never promoted, MEDIUM is not promoted by default,
and Phase 2 findings are report-only — so a sprint almost always ends with findings a human
still has to look at. Every
variant therefore ends by running `promote-findings.sh remind`, which counts the findings **not**
covered by a `## Promoted Findings` marker (attributing each finding to the `## Branch:` section it
appears under) and prints either a real count or `FINDINGS: none`.

The count matters in both directions: it stops the sprint from nudging the user toward an empty
queue, and it stops a CRITICAL finding raised against a fix branch from ending the sprint in
silence. Word the reminder as *still need triage*, not *unfixed* — some findings will be correctly
dismissed once a human reads them.

## Script interface

```bash
# Which severities does this sprint promote? (CREW_FIX_FINDINGS, set by session-init.sh)
bash "<skill-dir>/scripts/promote-findings.sh" policy
# → "promote: CRITICAL" | "promote: CRITICAL, HIGH" | "promote: CRITICAL, HIGH, MEDIUM" | "promote: "

# Depth bound: is this branch's issue itself a promoted fix issue?
bash "<skill-dir>/scripts/promote-findings.sh" guard --issue "<issue-file>"
# → "guard: promotable — severities: CRITICAL, HIGH" | "guard: skip — source-guarded ..."
#   | "guard: skip — fixFindings is none"

# Park a fix issue and annotate the report. Criteria file = one "- [ ] <finding>" line per finding.
bash "<skill-dir>/scripts/promote-findings.sh" defer \
  --feature-slug "$FEATURE_SLUG" --branch "<reviewed-branch>" --slug "<issue-slug>" \
  --title "Fix review findings: <issue title>" \
  --report ".scratch/$FEATURE_SLUG/reviews/sprint-review-<TIMESTAMP>.md" \
  --criteria-file "<tmp criteria file>"
# → "defer: .scratch/<slug>/issues/open/<NN>-fix-findings-<issue-slug>.md"

# The PRD audit's missing requirements → one parked fix issue (skipped while one is still open)
bash "<skill-dir>/scripts/promote-findings.sh" defer-gaps \
  --feature-slug "$FEATURE_SLUG" --report ".scratch/$FEATURE_SLUG/prd-audit.md" \
  --criteria-file "<tmp criteria file>"
# → "defer-gaps: .scratch/<slug>/issues/open/<NN>-fix-prd-gaps.md" | "defer-gaps: skip — already queued: <path>"

# Phase 1 → Phase 2
bash "<skill-dir>/scripts/promote-findings.sh" flush --feature-slug "$FEATURE_SLUG"
# → "FLUSH: promoted=<N>" (re-enter the loop) | "FLUSH: none" (exit as normal)

# Read-only listing of parked issues
bash "<skill-dir>/scripts/promote-findings.sh" list --feature-slug "$FEATURE_SLUG"

# End-of-sprint reminder: findings no promotion covered
bash "<skill-dir>/scripts/promote-findings.sh" remind --feature-slug "$FEATURE_SLUG"
# → "FINDINGS: open=<N> (HIGH=1, MEDIUM=3, LOW=2)" + one "report: <path>" line each | "FINDINGS: none"
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
