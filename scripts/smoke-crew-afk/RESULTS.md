# Demo smoke results

One row per `scripts/smoke-crew-afk.sh <platform> [--via install|npx]` run that reached its crew-afk dispatch, appended by the
script: the coding-crew commit it ran at, the platform, the `route` the skills were installed by (`install` for
install.sh, `npx` for `npx skills add`), `cost` from the `cost=$<n>` that ends
`crew-afk.sh wait`'s line for the run (`?` when it has none: other platforms, a capped run), and
`findings` from the last review solve-feature saved for its PR: since solve-feature re-reviews after fixing
CRITICAL/HIGH/MEDIUM findings (#497), later rows count that re-review's findings, not the first review's. Commit the new row before `scripts/cut-release.sh`, which
needs a clean tree. Rows before the commit column were
crew-afk-version / date / result / cost / dispatch-hours / findings; rows before the route column were all `install`.

| commit | date | platform | route | result | cost | findings |
|---|---|---|---|---|---|---|
| 2.21.0 | 2026-10-05 | PASS | $0.74 | 0.04 | 0 |
| 2.41.4 | 2026-10-12 | PASS | $0.94 | 0.05 | 0 |
| 0850c1523431 | 2026-10-14 | claude | PASS | $1.73 | 0 |
| 71a8034d95fd | 2026-10-16 | claude | npx | PASS | $0.23 | 0 |
| ba7a6687deb3 | 2026-10-17 | claude | install | PASS | $0.21 | 0 |
| eec9e42a8969 | 2026-10-17 | claude | install | PASS | $0.14 | 0 |
| 3e0b3621389f | 2026-10-24 | claude | install | PASS | $0.28 | 1 |
| 66d790c15412 | 2026-10-25 | claude | install | PASS | $0.30 | 1 |
