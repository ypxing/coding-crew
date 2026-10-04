# Reviewer-misses replay: results

`node scripts/eval-reviewer-misses.mjs --runs 2 --parallel 8`, base `main`, head this branch's worktree,
reviewers on sonnet, judge on opus. Not a passing run: head reports neither expected miss in either
run (three protocol wordings were tried; this is the last, which is the committed one), and one head
run failed on an API throttle (recorded as failed, not as "not caught"). The two `feature` head
runs hit mean findings 3.0 vs base 1.5 (2.00x, on the one run that completed).

| case | version | runs ok | caught (per expected miss) | mean findings | cost |
|---|---|---|---|---|---|
| promote-after-merge-207 | base | 2/2 | repromote-earlier-run 0/2 | 0.0 | $0.10 |
| promote-after-merge-207 | head | 2/2 | repromote-earlier-run 0/2 | 0.5 | $0.28 |
| promote-after-merge-feature | base | 2/2 | triage-diff-inverted 0/2 | 1.5 | $0.76 |
| promote-after-merge-feature | head | 1/2 | triage-diff-inverted 0/1 | 3.0 | $1.03 |

Mean findings, head / base: promote-after-merge-207 n/a; promote-after-merge-feature 2.00x

Total cost: $2.17 (judge included). Base `main`, head `worktree`, 2 run(s) each.

## Runs
- promote-after-merge-207 base #1: repromote-earlier-run not caught; 0 finding(s) — No findings; it says the retry promotes exactly once but only within this run, and ignores branches already promoted by a run from before D1.
- promote-after-merge-207 base #2: repromote-earlier-run not caught; 0 finding(s) — No findings; it describes the merge-route promote from savedAllMetReview without noting that a branch promoted before the merge in an earlier run can be promoted again.
- promote-after-merge-207 head #1: repromote-earlier-run not caught; 0 finding(s) — No findings; it discusses carried findings on the merge route but never mentions an earlier run's pre-merge promotion causing a duplicate fix issue.
- promote-after-merge-207 head #2: repromote-earlier-run not caught; 1 finding(s) — Flags savedAllMetReview carrying `carried: true` findings into promotion, which is a different defect; it never says a branch an earlier run already promoted gets promoted again with a duplicate fix issue.
- promote-after-merge-feature base #1: triage-diff-inverted not caught; 1 finding(s) over 3 areas — Output C checks the scope string in review.mjs and finds the change fine, never flagging the triage prompt's diff range.
- promote-after-merge-feature base #2: triage-diff-inverted not caught; 2 finding(s) over 3 areas — Output A checks only the D3 scope string wording and never mentions the `git diff ${featureBranch}..${ref}` line in findingsTriagePrompt.
- promote-after-merge-feature head #1: triage-diff-inverted not caught; 3 finding(s) over 3 areas — Output B confirms the scope string changed and reports doc and crew-summary issues, but never says the triage prompt's diff is inverted after the merge.
- promote-after-merge-feature head #2: FAILED (API Error: Too many requests sent to ApplyGuardrail: On-demand ApplyGuardrail content filter policy (Classic tier) text units per second limit exceeded.)
