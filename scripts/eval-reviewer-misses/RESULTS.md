# Reviewer-misses replay: results

`node scripts/eval-reviewer-misses.mjs --runs 2 --parallel 3`, base `main`, head this branch's worktree,
reviewers on sonnet, judge on opus. Not a passing run: head reports neither expected miss in either
run. The reviewer protocol was then made generic (AC8: nothing in it names an eval case's bug), and
this run of that wording again caught neither; earlier case-tuned wordings did no better in the
best interim run (`repromote-earlier-run` 1 of 2, `triage-diff-inverted` 0 of 2). Sonnet reviewers
still stop at the decision's own line and the scope string; head's mean findings stay within 2x of base's.

| case | version | runs ok | caught (per expected miss) | mean findings | cost |
|---|---|---|---|---|---|
| promote-after-merge-207 | base | 2/2 | repromote-earlier-run 0/2 | 0.0 | $0.26 |
| promote-after-merge-207 | head | 2/2 | repromote-earlier-run 0/2 | 0.0 | $0.42 |
| promote-after-merge-feature | base | 2/2 | triage-diff-inverted 0/2 | 2.0 | $0.96 |
| promote-after-merge-feature | head | 2/2 | triage-diff-inverted 0/2 | 2.0 | $1.17 |

Mean findings, head / base: promote-after-merge-207 n/a; promote-after-merge-feature 1.00x

Total cost: $2.80 (judge included). Base `main`, head `worktree`, 2 run(s) each.

## Runs
Per-run judge notes: see `.scratch/eval-reviewer-misses/2026-10-04T12-16-30-221Z/`; in all 8 runs the judge found the expected miss not caught.
