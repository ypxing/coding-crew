# Reviewer-misses replay: results

`node scripts/eval-reviewer-misses.mjs --runs 2 --parallel 3`, then `--resume` into the same directory, base `main`, head `feature/review-replaces-manual` (the two-pass feature review, #294).
Reviewers on opus, judge on opus. Every reviewer and judge call completed (12/12 runs ok).

| case | version | runs ok | caught (per expected miss) | mean findings (raw) | mean findings (distinct) | cost |
|---|---|---|---|---|---|---|
| afk-effectiveness-feature | base | 2/2 | signal-no-run-end 0/2; release-gate-version-only 0/2; registry-description-stale 0/2 | 4.5 | 4.5 | $0.00 |
| afk-effectiveness-feature | head | 2/2 | signal-no-run-end 0/2; release-gate-version-only 0/2; registry-description-stale 0/2 | 3.0 | 4.0 | $0.17 |
| promote-after-merge-207 | base | 2/2 | repromote-earlier-run 2/2 | 1.0 | 1.0 | $0.00 |
| promote-after-merge-207 | head | 2/2 | repromote-earlier-run 2/2 | 1.0 | 1.0 | $0.09 |
| promote-after-merge-feature | base | 2/2 | triage-diff-inverted 1/2 | 1.5 | 1.5 | $0.72 |
| promote-after-merge-feature | head | 2/2 | triage-diff-inverted 1/2 | 1.5 | 1.5 | $1.60 |

**Pass rule: FAIL.** Head caught 3 expected misses in total against base's 3 (afk-effectiveness-feature 0/6 vs 0/6, promote-after-merge-207 2/2 vs 2/2, promote-after-merge-feature 1/2 vs 1/2); the rule needs head strictly above base. Every case's distinct findings are within max(2x, +2). No miss appears in a head output's `### Dropped` list: Pass 1 never collected them, so Pass 2 dropped nothing it should have kept. Merged as a neutral change by the maintainer's decision; making Pass 1 reach unchanged code the change relies on is the follow-up.

Mean distinct findings, head / base: afk-effectiveness-feature 0.89x (within max(2x, +2)); promote-after-merge-207 1.00x (within max(2x, +2)); promote-after-merge-feature 1.00x (within max(2x, +2))

Total cost: about $13.90 (judge included): $11.32 for the 9 reviewer runs before a session limit stopped the first attempt, $2.58 for the `--resume` that reran the 3 stopped runs and judged all 12 (the table's cost column counts the reused runs as $0). Base `main`, head `worktree`, 2 run(s) each. Reviewers on opus, judge on opus.

## Runs
- afk-effectiveness-feature base #1: signal-no-run-end not caught, release-gate-version-only not caught, registry-description-stale not caught; 6 finding(s), 6 distinct — The main.mjs:822 finding says an attempt-cap exit is recorded as 'finished', not that a signal exit writes no run-end; the stale-text finding names to-issues, findings-triage and crew-summary but not the registry.json description.
- afk-effectiveness-feature base #2: signal-no-run-end not caught, release-gate-version-only not caught, registry-description-stale not caught; 3 finding(s), 3 distinct — Its findings cover folded overflow duplicates, legacy state read as a crash, and the per-branch review skipping item 3; none matches an expected miss.
- afk-effectiveness-feature head #1: signal-no-run-end not caught, release-gate-version-only not caught, registry-description-stale not caught; n/a finding(s), 4 distinct — Its findings cover the per-branch item 3 gap, folded overflow duplicates, legacy state and location-matched prose exclusion; none matches an expected miss.
- afk-effectiveness-feature head #2: signal-no-run-end not caught, release-gate-version-only not caught, registry-description-stale not caught; 3 finding(s), 4 distinct — Its LOW finding combines two defects (unmarked folded duplicates and location-matched prose loss); with the item 3 and legacy-state findings, none matches an expected miss.
- promote-after-merge-207 base #1: repromote-earlier-run caught; 1 finding(s), 1 distinct — Says the merge-only retry ignores the earlier Promoted Findings record and defers again, duplicating the fix issue.
- promote-after-merge-207 base #2: repromote-earlier-run caught; 1 finding(s), 1 distinct — Says the merge-route retry re-promotes a review that a pre-upgrade run already promoted before merge, creating a duplicate fix issue.
- promote-after-merge-207 head #1: repromote-earlier-run caught; 1 finding(s), 1 distinct — Says savedAllMetReview plus promote on the merge route creates a second fix issue for findings an older version already promoted before the merge.
- promote-after-merge-207 head #2: repromote-earlier-run caught; 1 finding(s), 1 distinct — Says the merge-route retry promotes the saved all-met review without checking for an earlier promotion, so a branch a pre-change run already promoted gets a second fix issue.
- promote-after-merge-feature base #1: triage-diff-inverted not caught; 1 finding(s), 1 distinct — Reports only the duplicate promotion after an upgrade (the unchecked Promoted Findings marker) and never mentions the triage prompt's diff.
- promote-after-merge-feature base #2: triage-diff-inverted caught; 2 finding(s), 2 distinct — Its MEDIUM finding says that after the merge the triage diff shows none of the branch's change, only sibling work in reverse; it also reports the duplicate promotion as LOW.
- promote-after-merge-feature head #1: triage-diff-inverted not caught; 1 finding(s), 1 distinct — Its one finding, given twice, is the merge-route duplicate promotion; it says the D3 scope wording was updated and never flags the diff command.
- promote-after-merge-feature head #2: triage-diff-inverted caught; 2 finding(s), 2 distinct — Names findingsTriagePrompt's `git diff featureBranch..ref` as empty or showing sibling changes reversed once promotion runs after the merge, and separately reports duplicate promotion after an upgrade.


## From an escaped.md line to a case

`/address-pr-comments` appends a line to `.scratch/<slug>/reviews/escaped.md` for each comment it
fixed on a crew-afk PR: `- <YYYY-MM-DD> <file:line> — <one-line summary> — <commit sha>`. Each is a
defect crew-afk's reviewer passed. To replay one:

1. Find the review that should have caught it. A finding comes from the feature review alone, so
   an escaped defect is a `mode: feature` replay of the feature review that ran over its code:
   `git log --merges` on `feature/<slug>` for the merge that brought `<file:line>`'s code in, and the
   drain's review range that covered it (the whole feature from its merge-base, or the drain's
   `reviewed_tip..tip` increment). `mode: branch` is reserved for a defect that should have made one
   of the issue's acceptance criteria `unmet` in its per-branch review.
2. Copy `case-template.md` to `cases/<name>.md` (its front matter defaults to `mode: feature`). Set
   `base_sha` / `head_sha` to that review's range — never the fix commit from the escaped line, which
   is after it — and `via` to a ref that keeps them reachable.
3. Fill `## PRD` from the PRD as it was at `head_sha`. Only for a `mode: branch` case, also fill
   `## Issue`, `## Implements` and `## Acceptance criteria` from the issue; a feature case drops them.
4. Write `## Expected misses` from the escaped line's summary and the fix commit's diff, and
   `## Reference judgement` with what a report must say to count as caught.
5. Check it parses and builds: `node scripts/eval-reviewer-misses.mjs --case <name> --runs 1 --dry-run`.
