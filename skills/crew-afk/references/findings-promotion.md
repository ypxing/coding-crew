# Findings promotion (shared policy)

How crew-afk gets actionable code-review findings fixed inside the same sprint, without a
human in the loop and without looping forever. This file is the single source of truth for the
policy; each platform variant of `SKILL.md` only wires it into its own dispatch mechanics.

Mechanical steps are implemented once in `scripts/promote-findings.sh` so all four platforms
behave identically.

## Why this exists

Per-branch review runs before each merge and judges only the acceptance criteria and the PRD
decisions an issue implements: it raises no findings (`findings: []`; the orchestrator drops any a
branch report still carries), so no branch gets a fix issue of its own. Findings come from the
feature review alone, on code that has already merged, with no route back into the sprint: the
report sits in `reviews/` until a human runs `/crew-address-findings`. Promotion gives those
findings a route, using the machinery that already exists (issue → worktree → TDD → verify →
review → merge) instead of a bespoke fix path.

Open findings an earlier version's branch reviews left in a `sprint-review-*.md` block are never
promoted: `promote-findings.sh open` still lists them, so they are posted or reminded.

## Two phases

**Phase 1 — normal sprint.** Unchanged. When a feature review raised findings at or above the
promotion rule (below), write a *parked* fix issue with `Status: deferred-findings`. The loop's `list`
operation selects on `ready-for-agent`, so parked issues are invisible and Phase 1 drains its
original queue at its normal pace.

**Github bodies are self-contained.** Under `tracker: github` a fix issue is read where the sprint's
`.scratch/` reports do not exist, so `defer` embeds each promoted finding's full reviewer text
(`## Review findings`), and `defer-integration` the tail of the failing output — each truncated, with absolute and `.scratch/`
paths scrubbed. `Source:` names the kind and branch rather than a report path; it is still the depth
bound. The local tracker keeps naming the report path.

**Phase 2 — fix round.** When the loop is about to exit, flush the parked issues to
`ready-for-agent` and re-enter the loop instead of exiting. Fix issues are ordinary issues: they
get a worktree, TDD, `verify-worktree.sh`, AC verification, and their own code review before
merging. The squash runs after both phases, so fixes are included.

**A fixable integration failure joins the same flush.** At every drain of the queue the project's
checks run on the merged feature branch (the integration check), which no per-branch verify saw. A
red result is triaged by `crew-triage` — a dispatch of its own, never the coder — the same way a
failed per-branch verify is. Fixable, it becomes one parked fix issue
(`promote-findings.sh defer-integration`), which the flush sends into Phase 2 beside the findings
fixes; its criterion is "the project's checks pass on the merged feature branch", with
triage's detail and the failing output's tail. The next drain's check then runs on the fixed branch.
Not fixable — a missing command (exit 127, no triage at all), a failed dependency install, or
triage's own verdict — queues nothing: the summary's `## Integration check` section gives the
reason, and the feature review is skipped for that drain. A triage dispatch that itself fails counts as fixable, once. Its `Source:` line is
the same depth bound. At most two integration fix issues are created per run: a third red drain is
reported and the run ends stalled, with no third fix issue. The same commit red again (its fix
issue blocked) is not a new drain — it is not re-triaged and gets no second fix issue.

Findings are **not** promoted the moment they are raised. A fix branch running alongside
still-open Phase 1 issues would edit the same files as its siblings; `merge-branches.sh` aborts
on conflict, so early promotion manufactures retained branches out of nothing. Waiting until the
queue is empty removes that class of conflict entirely.

## Rules

**What is fixed: config.json's `afk.fixFindings`, default `actionable`** (`--fix-findings` for one
run).

- `actionable` (the default) fixes every finding `crew-triage` judges **Actionable**, whatever its
  severity — a LOW included — and no Debatable or Dismissed one, however high its severity. Triage
  is a dispatch of its own (findings mode, on the `triage` role's runtime and model, capped by
  `afk.limits.triage`), never the reviewer's self-grade. One dispatch judges a whole review's
  findings: Actionable (local, unambiguous, no public-contract change), Debatable, or Dismiss, each
  with a one-line rationale, by the rubric `/crew-address-findings` also renders (one source:
  `skills/_shared/fragments/findings-rubric.md`). Three hard rules are applied by the
  orchestrator after triage answers (`applyFindingVerdicts`), so no verdict overrides them: a
  finding that contradicts an ADR / `CONTEXT.md`, whose fix touches a protected path (CI config,
  auth, deploy, `.env`), or whose only basis is the design standard (the reviewer reports those at
  LOW, prefixed `Design standard (criterion <n>):`) is Debatable. The rubric names the design-only
  rule too, so triage normally answers it `debatable` already; the code holds it either way. A
  fourth rule, "Necessary" — a failure that needs an input or state no current caller, user or
  documented contract produces is Debatable — is triage's judgement alone.
  The verdict and rationale are written beside each finding in the feature review's block of the
  review report.
- `critical`, `high` (CRITICAL and HIGH), `medium` (adds MEDIUM) fix by severity alone, with no
  triage dispatch; LOW is never promoted. Unattended, that has no way to dismiss a finding that is
  technically correct but contradicts a documented decision — the risk the CRITICAL/HIGH bar
  (the reviewer protocol requires a concrete failure scenario for each) was chosen to carry.
- `none` fixes nothing.

**A triage that fails falls back to the `high` rule.** A dead dispatch, a timeout, a spent
`afk.limits.triage` cap, or a verdict file that does not parse (or leaves a finding unjudged)
means no verdicts for that review: its CRITICAL and HIGH findings are promoted, the rest left
open, and the summary's `## Findings Triage` section names which review fell back and why. The
fallback is per review, so one failed triage never blocks the others.

The threshold is resolved once in `orchestrator/lib/report.mjs` and passed to `defer` as `--severities`; the verdicts are facts on
disk in the review report, so the orchestrator never has to remember them.

Anything below the threshold is paid for on the way out rather than hidden: nothing subtracts an
unpromoted severity from `remind`, so every such finding is counted, named, and attributed to its
report, and the reminder states the threshold that left it open plus the setting that would have
promoted it.

**Grouping: one fix issue per feature review**, with one acceptance criterion per finding
(`orchestrator/lib/pipeline/feature-review.mjs`).

**Depth bound.** Every fix issue carries a `Source:` line, and a branch review raises no findings,
so a fix issue's own review never promotes anything. Feature reviews promote only up to the
per-feature cap (`feature_review.promotions` in `sprint-state.json`); later ones are report-only.

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

**Nothing merged ⇒ nothing promoted, for free.** The feature review runs only at a drain where
something merged. A sprint that stalls on a broken environment reviewed nothing,
so the parked set is empty and flush is a no-op — no separate guard needed for that case.

## Report buckets

After a sprint with promotion, `sprint-review-<TIMESTAMP>.md` distinguishes three groups:

- **Promoted** — the findings the rule selected (every Actionable one, or those at the threshold
  severities), fixed in Phase 2, listed under the `## Promoted Findings` section that
  `promote-findings.sh defer` appends (`<branch>: actionable → <issue ref> (<n> finding(s))` or
  `<branch>: CRITICAL → <issue ref> (<n> finding(s))`; a marker from before the count ends at the ref).
- **Open, needs human triage** — everything the rule did not cover: Debatable and Dismissed
  findings (each carries its verdict and rationale in the report), or under a severity level LOW
  always, and MEDIUM unless `fixFindings` is `medium`.
- **Report-only** — findings of a feature review past the promotion cap, and open branch findings
  an earlier version's per-branch reviews left in the report.

`crew-address-findings` reads `## Promoted Findings` and skips what it covers — the promoted
(branch, severity) pairs, and a branch's `actionable`-verdict findings where the line says
`actionable` — so a later human run starts with a queue of genuinely open findings, led by the
Debatable ones.

## End-of-sprint reminder

Promotion is deliberately partial — Debatable and Dismissed findings are never promoted (under a
severity level, LOW never is and MEDIUM is not by default), and reviews past the cap are report-only —
so a sprint can end with findings a human still has to look at. Every
variant therefore ends by running `promote-findings.sh remind`, which counts the findings **not**
covered by a `## Promoted Findings` marker (attributing each finding to the `## Branch:` section it
appears under) and prints either a real count or `FINDINGS: none`.

The count matters in both directions: it stops the sprint from nudging the user toward an empty
queue, and it stops a CRITICAL finding raised against a fix branch from ending the sprint in
silence. Findings triage **dismissed** are not in that count or its severity breakdown: the summary
names them on a separate line (`n finding(s) dismissed by triage`) with the report holding each
rationale, and `post-findings.sh` lists them under `### Dismissed by triage`, never a severity heading.
A finding triage never judged (a failed triage, the `high` fallback) is still counted. Word the reminder as *still need triage*, not *unfixed* — some findings will be correctly
dismissed once a human reads them.

## Script interface

```bash
# Park a fix issue and annotate the report. Criteria file = one "- [ ] <finding>" line per finding.
# --severities is the list the orchestrator resolved from afk.fixFindings (orchestrator/lib/report.mjs);
# the script keeps no level table and exits 2 naming the argument when it is missing.
bash "<skill-dir>/scripts/promote-findings.sh" defer \
  --feature-slug "$FEATURE_SLUG" --branch "<reviewed-branch>" --slug "<issue-slug>" \
  --title "Fix review findings: <issue title>" \
  --report ".scratch/$FEATURE_SLUG/reviews/sprint-review-<TIMESTAMP>.md" \
  --criteria-file "<tmp criteria file>" --severities "actionable" # or "CRITICAL, HIGH": the list report.mjs resolves
# → "defer: .scratch/<slug>/issues/open/<NN>-fix-findings-<issue-slug>.md"

# A fixable red integration check on the merged feature branch → one parked fix issue
bash "<skill-dir>/scripts/promote-findings.sh" defer-integration \
  --feature-slug "$FEATURE_SLUG" --report ".scratch/$FEATURE_SLUG/dispatch/_integration/verify.out" \
  --criteria-file "<tmp criteria file>" --at "<failing commit>"
# → "defer-integration: .scratch/<slug>/issues/open/<NN>-fix-integration-<k>.md"
#   | "defer-integration: skip — already queued: <path>"   (one open at a time; the caller caps the run at two)

# Phase 1 → Phase 2
bash "<skill-dir>/scripts/promote-findings.sh" flush --feature-slug "$FEATURE_SLUG"
# → "FLUSH: promoted=<N>" (re-enter the loop) | "FLUSH: none" (exit as normal)

# Read-only listing of parked issues
bash "<skill-dir>/scripts/promote-findings.sh" list --feature-slug "$FEATURE_SLUG"

# End-of-sprint reminder: findings no promotion covered
bash "<skill-dir>/scripts/promote-findings.sh" remind --feature-slug "$FEATURE_SLUG"
# → "FINDINGS: open=<N> (HIGH=1, MEDIUM=3, LOW=2)", then — only for findings triage judged —
#   "DEBATABLE: <n> (...)" + one "debatable: <branch> [SEV] <loc> — <what> — why: <rationale>" line
#   each (leading), "ACTIONABLE: <n> (not promoted)" likewise, and "DISMISSED: <n> (...)" +
#   "dismissed: ..." lines; then one "report: <path>" line each | "FINDINGS: none"
# → plus "REVIEW-GAPS: branches=<N>" + one "gap: <branch> — <reason>" line, when a review
#   never completed. Printed in addition to the findings line, never instead of it.

# A review that never ran: record the gap instead of self-reviewing inline
bash "<skill-dir>/scripts/promote-findings.sh" mark-not-run \
  --feature-slug "$FEATURE_SLUG" --branch "$BRANCH" --slug "$SLUG" \
  --report "$REPORT" --reason "reviewer dispatch timed out"
# → "mark-not-run: not_run recorded — <branch> (<reason>)" | "mark-not-run: already recorded"
```

## Reviews that never ran

A review that never completed gives no verdict, so its branch does not merge (it is retained). What is not acceptable is the
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
