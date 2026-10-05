Status: ready-for-agent

## Context Documents

- PRD: #147

Read this document before implementing. It contains architecture decisions, integration constraints, and technical context essential for this issue.

## Parent

#119

## What to build

With `--open-pr`, the feature PR is a draft whenever the run did not finish green, and an integration check that could not run reports `skipped` instead of `pass`.

A run is green iff exit 0, no blocked issue, and integration `pass` or `cached` (PRD D7). `pullRequest` (`orchestrator/lib/loop.mjs:551`) passes `--draft` to `open-pr.sh` when the run is not green; `open-pr.sh` (`skills/crew-afk/scripts/open-pr.sh:76-98`) creates with `gh pr create --draft`, converts an existing ready PR with `gh pr ready --undo`, and on a green run marks an existing draft ready with `gh pr ready`. `runFeatureChecks` (`orchestrator/lib/preflight.mjs:236-240`) returns `status: "skipped"` for the `_integration` stem when its worktree cannot be created; the `_baseline` stem keeps returning `pass`. This is #119's spec, extended by D8.

## Implements

D7, D8, B3 — seam: sprint suite (`tests/orchestrator/sprint-integration.test.mjs` / `sprint-github.test.mjs` via `CREW_FAKE_DISPATCH`) and `tests/crew-afk-open-pr.bats` with a fake `gh`

## Acceptance criteria

- [ ] A stalled run with `--open-pr` and no existing PR creates the PR as a draft
- [ ] A stalled run with an existing open, ready PR converts it to draft
- [ ] A green run with an existing draft PR marks it ready; a green run with no PR creates it ready (unchanged)
- [ ] An integration worktree that cannot be created yields `skipped` in the summary's integration section, and the PR is a draft; a baseline worktree that cannot be created still lets the run proceed
- [ ] The PR body's crew-afk block (between the `crew-afk:begin`/`end` markers) names each blocked issue and the not-green reason on a non-green run, and has no blocked list on a green run; text outside the markers is preserved
- [ ] The summary's `## Pull Request` section states draft vs ready and why
- [ ] A failed `gh pr ready` / `gh pr ready --undo` is reported in that section and never fails the sprint

## Blocked by

None - can start immediately

## Interfaces

### Exposes:

- `isGreen({ exitCode, blocked, integration, capped })` (or equivalent single predicate in `loop.mjs`) used by `pullRequest`; `capped` defaults to `false` until #157 sets it.
- `open-pr.sh --draft` flag.
- `runFeatureChecks` status union: `"pass" | "cached" | "fail" | "skipped"`.
