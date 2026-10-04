# Reviewer-misses replay: results

`node scripts/eval-reviewer-misses.mjs --runs 2 --parallel 3`, base `main`, head this branch's worktree,
reviewers on sonnet, judge on opus. Not a passing run: head reports neither expected miss in either
run. Six protocol wordings were tried over as many real runs; the committed one is the last, and a seventh run of it (below) again caught neither. The
best interim run (an earlier wording) had head report `repromote-earlier-run` in 1 of 2 runs and
`triage-diff-inverted` in 0 of 2. Sonnet reviewers still stop at the decision's own line and the
scope string; head's mean findings stay within 2x of base's.

| case | version | runs ok | caught (per expected miss) | mean findings | cost |
|---|---|---|---|---|---|
| promote-after-merge-207 | base | 2/2 | repromote-earlier-run 0/2 | 0.0 | $0.29 |
| promote-after-merge-207 | head | 2/2 | repromote-earlier-run 0/2 | 0.5 | $0.50 |
| promote-after-merge-feature | base | 2/2 | triage-diff-inverted 0/2 | 2.0 | $0.97 |
| promote-after-merge-feature | head | 2/2 | triage-diff-inverted 0/2 | 3.5 | $1.18 |

Mean findings, head / base: promote-after-merge-207 n/a; promote-after-merge-feature 1.75x

Total cost: $2.95 (judge included). Base `main`, head `worktree`, 2 run(s) each.

## Runs
Per-run judge notes: see `.scratch/eval-reviewer-misses/2026-10-04T12-04-10-285Z/`; in all 8 runs the judge found the expected miss not caught.
