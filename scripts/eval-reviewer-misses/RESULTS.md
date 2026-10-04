# Reviewer-misses replay: results

`node scripts/eval-reviewer-misses.mjs --runs 2 --parallel 3`, base `main`, head this branch's worktree,
reviewers on sonnet, judge on opus. Not a passing run: head reports neither expected miss in either
run. Six protocol wordings were tried over as many real runs; the committed one is the last. The
best interim run (an earlier wording) had head report `repromote-earlier-run` in 1 of 2 runs and
`triage-diff-inverted` in 0 of 2. Sonnet reviewers still stop at the decision's own line and the
scope string; head's mean findings stay within 2x of base's.

| case | version | runs ok | caught (per expected miss) | mean findings | cost |
|---|---|---|---|---|---|
| promote-after-merge-207 | base | 2/2 | repromote-earlier-run 0/2 | 1.0 | $0.19 |
| promote-after-merge-207 | head | 2/2 | repromote-earlier-run 0/2 | 0.0 | $0.35 |
| promote-after-merge-feature | base | 2/2 | triage-diff-inverted 0/2 | 1.5 | $0.76 |
| promote-after-merge-feature | head | 2/2 | triage-diff-inverted 0/2 | 2.5 | $1.01 |

Mean findings, head / base: promote-after-merge-207 0.00x; promote-after-merge-feature 1.67x

Total cost: $2.31 (judge included). Base `main`, head `worktree`, 2 run(s) each.

## Runs
- promote-after-merge-207 base #1: repromote-earlier-run not caught; 1 finding(s) — A's finding is that carried findings get promoted from the saved block, which is a different defect from re-promoting a branch an earlier run already promoted.
- promote-after-merge-207 base #2: repromote-earlier-run not caught; 1 finding(s) — C reports stale carried findings being promoted on retry, not a branch an earlier pre-merge run already promoted getting a second fix issue.
- promote-after-merge-207 head #1: repromote-earlier-run not caught; 0 finding(s) — D considers duplicate promotion from an earlier run but dismisses it, saying the 'already queued' dedupe prevents it, so it does not report the defect.
- promote-after-merge-207 head #2: repromote-earlier-run not caught; 0 finding(s) — B reports no findings and never raises the risk of a duplicate fix issue.
- promote-after-merge-feature base #1: triage-diff-inverted not caught; 1 finding(s) over 3 areas — Mentions only the D3 scope string ('has merged') and never says the triage prompt's git diff is inverted after the merge.
- promote-after-merge-feature base #2: triage-diff-inverted not caught; 2 finding(s) over 3 areas — Checks only the scope string wording for D3 and reports doc and promote-throw issues, not the inverted feature..branch diff.
- promote-after-merge-feature head #1: triage-diff-inverted not caught; 4 finding(s) over 3 areas — Findings are about merge-route duplication, savedAllMetReview, a stale comment and crew-summary labelling; none is about the triage prompt's diff.
- promote-after-merge-feature head #2: triage-diff-inverted not caught; 1 finding(s) over 3 areas — Reports a duplicate fix issue on the merge-route retry and nothing about the diff line in findingsTriagePrompt.
