# Reviewer-misses replay: results

`node scripts/eval-reviewer-misses.mjs --runs 2 --parallel 3`, base `main`, head this branch's worktree.
Reviewers on opus (the eval's default, crew-afk's reviewer model), judge on opus. Every reviewer and judge call completed (8/8 runs ok).
Head reports each case's expected miss in at least one of its two runs, and head's mean distinct finding count is within max(2 × base's, base's + 2) on both cases: promote-after-merge-207 1.0 against base's 0.0 (bound 2.0; the ratio is undefined), promote-after-merge-feature 5.5 against 3.0 (1.83x, bound 6.0).

| case | version | runs ok | caught (per expected miss) | mean findings (raw) | mean findings (distinct) | cost |
|---|---|---|---|---|---|---|
| promote-after-merge-207 | base | 2/2 | repromote-earlier-run 0/2 | 0.0 | 0.0 | $0.69 |
| promote-after-merge-207 | head | 2/2 | repromote-earlier-run 1/2 | 1.0 | 1.0 | $0.91 |
| promote-after-merge-feature | base | 2/2 | triage-diff-inverted 1/2 | 3.0 | 3.0 | $2.51 |
| promote-after-merge-feature | head | 2/2 | triage-diff-inverted 2/2 | 7.0 | 5.5 | $4.44 |

> **Case change since these runs:** `promote-after-merge-207` was a `mode: branch` replay of #207's
> per-branch review. The per-branch review now judges criteria only and raises no findings, so no case
> asks for a defect to be caught as a per-branch finding: the case is now a `mode: feature` replay of
> the feature review over #207's code (`4bcc149..b221314`). Its rows above are from the old branch mode
> and are not comparable with a re-run.

Mean distinct findings, head / base: promote-after-merge-207 n/a (within max(2x, +2)); promote-after-merge-feature 1.83x (within max(2x, +2))

Total cost: $8.55 (judge included). Base `main`, head `worktree`, 2 run(s) each. Reviewers on opus, judge on opus.

## Runs
- promote-after-merge-207 base #1: repromote-earlier-run not caught; 0 finding(s), 0 distinct — It reports no findings and says promoting from the saved block is safe.
- promote-after-merge-207 base #2: repromote-earlier-run not caught; 0 finding(s), 0 distinct — It reports no findings and does not consider a branch that an earlier run already promoted.
- promote-after-merge-207 head #1: repromote-earlier-run not caught; 1 finding(s), 1 distinct — Its only finding is a LOW doc-wording issue about conflict routing; it never says a retry can promote a branch that was already promoted.
- promote-after-merge-207 head #2: repromote-earlier-run caught; 1 finding(s), 1 distinct — It names the merge-route retry promoting from savedAllMetReview a block that a pre-upgrade run already promoted, which creates a duplicate fix issue.
- promote-after-merge-feature base #1: triage-diff-inverted caught; 3 finding(s), 3 distinct over 3 areas — Output C names the diff range at prompts.mjs:520 as empty or showing siblings' changes reversed after D1. It also reports the B3 triage-test gap and the cross-file foldReview loss.
- promote-after-merge-feature base #2: triage-diff-inverted not caught; 3 finding(s), 3 distinct over 3 areas — Output A mentions only the D3 scope wording ('has merged'), not the triage prompt's stale diff range. Its findings are the B1 conflict-test gap, the cross-file foldReview loss and the untested guard done/ fallback.
- promote-after-merge-feature head #1: triage-diff-inverted caught; 6 finding(s), 5 distinct over 3 areas — Output B says outright that findingsTriagePrompt's `git diff <feature>..<branch>` is empty after the merge. It also reports the resume duplicate fix issue (twice, counted once), the B1 test gap, the findingKey collision and the guard-test gap.
- promote-after-merge-feature head #2: triage-diff-inverted caught; 8 finding(s), 6 distinct over 3 areas — Output D reports the triage diff range, empty or reversed after the merge, in two areas (counted once). It also reports the resume duplicate promotion (two angles, counted once), unlabelled carried findings in triage, the incremental feature-review loss, crew-summary's missing labels and the guard-test gap.


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
