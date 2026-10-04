# Reviewer-misses replay: results

`node scripts/eval-reviewer-misses.mjs --runs 2 --parallel 3`, base `main`, head this branch's worktree.
Reviewers on opus (the eval's default, crew-afk's reviewer model), judge on opus. Every reviewer and judge call completed (8/8 runs ok).
Head reports each case's expected miss in at least one of its two runs, and head's mean distinct finding count stays within 2x of base's (1.83x on the feature case).

| case | version | runs ok | caught (per expected miss) | mean findings (raw) | mean findings (distinct) | cost |
|---|---|---|---|---|---|---|
| promote-after-merge-207 | base | 2/2 | repromote-earlier-run 0/2 | 0.0 | 0.0 | $0.69 |
| promote-after-merge-207 | head | 2/2 | repromote-earlier-run 1/2 | 1.0 | 1.0 | $0.91 |
| promote-after-merge-feature | base | 2/2 | triage-diff-inverted 1/2 | 3.0 | 3.0 | $2.51 |
| promote-after-merge-feature | head | 2/2 | triage-diff-inverted 2/2 | 7.0 | 5.5 | $4.44 |

Mean distinct findings, head / base: promote-after-merge-207 n/a; promote-after-merge-feature 1.83x

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

