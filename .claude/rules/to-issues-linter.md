---
paths:
  - "skills/to-issues/**"
  - "tests/*lint*.bats"
  - "orchestrator/lib/preflight.mjs"
---

# `to-issues`' linter (`skills/to-issues/scripts/lint-issues.sh`)

Read-only checker for a feature's issue set, shipped as an asset at `.coding-crew/to-issues/scripts/` and
runnable by hand: `lint-issues.sh --issue <file>... [--known <file>...] [--deps <issues-deps.json>] [--prd <file>]`.
`--known` names issues outside the set (done ones; preflight passes them, written out as files under `tracker: github`) that a `## Blocked by` ref may resolve to,
by basename; a known file's `## Implements` also counts toward `--prd` coverage. A PRD ID line ending in `(no slice)` needs no issue: no coverage `WARN`. Prints `ERROR <file>: …` (cycle, unmatched `## Blocked by` ref, `--deps` drift, no
`## Acceptance criteria`) or `WARN <file>: …` (advisory); exit 1 iff any `ERROR`, 2 on a usage error. Issue text is
data — never evaluated, and a path in a ref is never opened.
