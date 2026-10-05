# Demo smoke results

One row per `scripts/smoke-sprint.sh <platform> --demo` run past `--setup-only`, appended by the
script. `cost` and `dispatch-hours` sum the run's `sprint-state.json` dispatches; `findings` counts
the findings in its sprint review reports, folded as `orchestrator/review-rollup.mjs` folds them (one
record per branch, latest wins). Commit the new row before `scripts/cut-release.sh`, which needs a
clean tree.

| version | date | result | cost | dispatch-hours | findings |
|---|---|---|---|---|---|
