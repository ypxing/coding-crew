# Demo smoke results

One row per `scripts/smoke-sprint.sh <platform>` run that reached its crew-afk dispatch, appended by the
script: the coding-crew commit it ran at, the platform, `cost` from the claude JSON result that ends the
run's log (`?` on other platforms), and `findings` from the review solve-feature saved for its PR. Commit
the new row before `scripts/cut-release.sh`, which needs a clean tree. Rows before the commit column were
crew-afk-version / date / result / cost / dispatch-hours / findings.

| commit | date | platform | result | cost | findings |
|---|---|---|---|---|---|
| 2.21.0 | 2026-10-05 | PASS | $0.74 | 0.04 | 0 |
| 2.41.4 | 2026-10-12 | PASS | $0.94 | 0.05 | 0 |
