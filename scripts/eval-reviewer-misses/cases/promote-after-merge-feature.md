---
mode: feature
base_sha: 485c6b9
head_sha: b221314
slug: promote-after-merge
via: origin/feature/promote-after-merge
---
Replay of the feature review of PR #208 (promote-after-merge): the whole feature diff `485c6b9..b221314`,
split into areas by the planner, one reviewer per area. The SHAs are reachable through
`origin/feature/promote-after-merge`; fetch it before running if they do not resolve.

## Expected misses

- triage-diff-inverted: `findingsTriagePrompt` (`orchestrator/lib/prompts.mjs`) still tells triage to read the change with `git diff <feature>..<branch>`. Findings are now promoted after the branch merged, so that diff shows other branches' work inverted and not the branch's own change.

## Reference judgement

The bug: `promote()` now runs after `mergeAndClose()` (PRD D1), but `findingsTriagePrompt` in `orchestrator/lib/prompts.mjs` still says "the change with git diff ${featureBranch}..${ref}". Once the branch is merged into the feature branch, `featureBranch..ref` holds only what the feature gained since the branch's tip, inverted, so the triage agent judges findings against the wrong change. PRD D3 only names the `scope` string ("which has not merged yet") as needing a change; the prompt's diff line is unchanged code whose correctness the change affects, found by reading `findingsTriagePrompt`'s body, not the diff. A review reports it caught only if it says the triage prompt's diff is wrong after the merge move (any severity, in any area). Reporting only the `scope` string wording is not it.

## PRD

### Problem Statement

Actor: a maintainer running crew-afk unattended on a feature.
Origin: #197

A per-branch fix issue is created when its source branch's review passes, *before* that branch merges. When the merge then fails (conflict, blocked), the fix issue is claimed anyway and blocks on a premise check every run until the source lands (#194 on #189's unmerged `prd-decisions.mjs`). Each re-review of the unmerged source promotes again, creating duplicates: 3 of ~22 per-branch fix issues so far were promoted more than once (#163/#165, #169/#170/#173, #194/#198), and the duplicate titles then collide in the sprint's slug-keyed state (#198 kept unclaimed because #194 was blocked).

Separately, findings raised in an `unmet` review are never triaged or promoted, and the review rollup folds per branch with the later block winning, so a finding the later review does not repeat disappears from the summary, `remind` and the PR's posted findings (#191's LOW, found only by `/crew-address-findings`, fixed by hand in 9d20877).

### Solution

Promotion moves after merge and close, as `references/findings-promotion.md` already describes: a fix issue exists only once its source has merged, so it is never claimable early and a branch is promoted at most once. And a branch's review block carries forward every finding from its earlier review blocks that the new review does not repeat, so those findings reach the summary, `remind`, the PR and promotion.

### Behaviours

- **B1** — given a branch whose review is `all-met` but whose merge conflicts, no fix issue is created (either tracker), at `runHousekeeping` (`orchestrator/lib/pipeline.mjs`) with fake effects
- **B2** — given a branch that merges and closes and has promotable findings, exactly one fix issue is created, after `close-issue.sh` succeeded, at `runHousekeeping`
- **B3** — given an earlier `unmet` review block for a branch with a finding the later `all-met` review does not repeat, the later block written to `sprint-review-*.md` contains that finding with `"carried": true`, and promotion's triage sees it, at `runReview` / `promote` (`orchestrator/lib/pipeline/review.mjs`)
- **B4** — given a finding the later review does repeat (same severity, file path, issue text), it appears once, not carried, at `runReview`
- **B5** — given review blocks for one branch across two `sprint-review-*.md` files where the later block is a `not_run` stub, the rollup's record for the branch keeps the earlier block's findings marked carried, at `orchestrator/review-rollup.mjs` / `parseReviewAggregate`
- **B6** — given a carried finding, `crew-summary.sh`'s counts, `promote-findings.sh remind` and `post-findings.sh` include it, labelled as from an earlier review, at those scripts

### Decisions

- **D1** — `promote(ctx, worker, review, outcome)` moves from before `mergeAndClose()` (`orchestrator/lib/pipeline.mjs:753`) to after it returns with `outcome.status === "complete"`. `mergeAndClose` (`orchestrator/lib/pipeline/merge.mjs:13`) stays synchronous end to end — that is what serializes merges; promote's `await` (findings triage) runs after it. A failed merge or close promotes nothing; the retry re-reviews and promotes at its own merge.
- **D2** — With D1, a fix issue's source is always already done when it is created: under github `awaiting-merge` (set by `close-issue.sh:149-157`) counts as `done` for `## Blocked by` (`orchestrator/lib/trackers/github.mjs:106-114,184`); under local the source is in `done/`, so `flush` flipping every parked issue (`promote-findings.sh:631`) is correct as is. No `--blocked-by`, no flush change.
- **D3** — The fix-issue body's "The branch already merged — these are follow-up fixes" (`promote-findings.sh` `_defer_local`, `_defer_github`) stays: it is now true. The triage `scope` string in `promote()` ("which has not merged yet") changes to say the branch has merged.
- **D4** — Carry-forward happens when the review block is written (`runReview`, `review.mjs`), not only at fold time: the carried findings are then physically in the latest block, so `annotateFindings` (`report.mjs:512`) writes triage verdicts beside them and every downstream reader (rollup, `remind`, summary, `post-findings.sh`, `promote`) works unchanged off the latest block.
- **D5** — One owner in `orchestrator/lib/report.mjs`, e.g. `carryFindings(earlierRecords, latestFindings) → findings` (latest's findings, then each earlier unrepeated finding with `carried: true`, deduped among themselves). Earlier records come from every `sprint-review-*.md` under `sprint.reviewDir` (`.scratch/<slug>/reviews`, per feature, so across runs), in file-name order, via `parseReviewAggregate`-level parsing of all blocks for that branch (not the folded one).
- **D6** — A finding repeats another when severity, file path (`location` with any trailing `:line[-line]` / `#L…` removed) and whitespace-normalised, case-folded `issue` text are all equal. A reworded repeat shows twice (once carried) — accepted over fuzzy matching.
- **D7** — The fold (`parseReviewAggregate`, and `review-rollup.mjs`'s cross-file fold, which must call the same function, not a copy) stays later-block-wins for verdict, detail and findings, except that a `not_run` block (written by `promote-findings.sh mark-not-run`) keeps the previous record's findings, marked carried.
- **D8** — `findingsFromStructured` (`report.mjs:262`) preserves `carried`; `review-rollup.mjs` passes it through; `crew-summary.sh`, `promote-findings.sh remind` and `post-findings.sh` label a carried finding as from an earlier review (e.g. `(earlier review)`). Counts include carried findings.
- **D9** — The retry coder's prompt is unchanged: `fixPrompt` (`orchestrator/lib/prompts.mjs:95`) still gets only the unmet-criterion `detail`, keeping its smallest-change contract. Carried findings reach code only through promotion at merge.
- **D10** — `CLAUDE.md`'s per-issue order becomes `… verify → review → AC receipt → merge → close → promote`; `references/findings-promotion.md` is checked for any wording that says otherwise.
- **D11** — `crew-afk`'s version in `registry.json` is above origin/main's.

### Compatibility & Migration

Review blocks already in `.scratch/<slug>/reviews/sprint-review-*.md` have no `carried` field; they are read as not carried and are valid earlier records for D5. A resumed feature whose earlier run promoted a fix issue before merge keeps that issue; nothing migrates it.

### Testing Decisions

- Test at the highest existing seams: `runHousekeeping` with fake effects for ordering (B1, B2), `runReview`/`promote` for carry-forward (B3, B4), `parseReviewAggregate` and `review-rollup.mjs` for the fold (B5), and the bash scripts against a fixture review report for labels and counts (B6).
- Prior art: `tests/orchestrator/` node suites — `report.test.mjs`, `review-rollup.test.mjs`, `sprint-findings-triage.test.mjs`, `sprint-github.test.mjs`, `sprint-worker-outcomes.test.mjs`; `tests/crew-afk-pre-merge-review.bats`, `tests/crew-afk-promotion-threshold.bats`, `tests/crew-afk-review-gaps.bats`, `tests/promote-findings-github.bats` for the scripts. Existing tests asserting promote-before-merge order are updated, not deleted.

### Out of Scope

- `promote-findings.sh defer` deduplicating by `Source: review (<branch>)` (#197 AC5) — with D1 a branch is promoted once, at its single merge; every observed duplicate came from re-promotion before merge.
- The issue number in github's issue slug (#197 AC6) — the only same-title collision seen was a duplicate fix issue, which D1 removes; it would touch ~114 `.slug` uses and need a `sprint-state.json` key migration.
- `--blocked-by <source>` on github fix issues (#197 AC1) — the blocker is already resolved when the issue is created (D2); it would add only GitHub's native dependency link.
- A source-aware `flush` and a summary line for parked fix issues it skips (#197 AC3) — with D1 no parked fix issue has an unmerged source.
- Sending an unmet review's Actionable findings to the retry coder (#197 AC8's first half) — widens the retry's scope beyond its criterion and makes a later review's silence ambiguous (fixed vs. dropped); D4/D1 promote them at merge instead.
- Fuzzy matching of reworded findings (D6).
- Github fix issues being claimable while other Phase 1 issues are in flight (they are created `ready-for-agent`, not parked) — pre-existing, unrelated to ordering.

### Further Notes

- If the process dies between close and promote, that branch gets no fix issue; its findings remain unpromoted in the review report, so `remind` still counts them.

