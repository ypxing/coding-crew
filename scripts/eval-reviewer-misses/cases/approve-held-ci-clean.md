---
mode: feature
base_sha: 8cf5eb2ec7693e6cfbda9af9f212caa1824d6c17
head_sha: 47c6da430297692c3b93ca2c75c2508e22c68d09
slug: approve-held-ci
via: origin/main
clean: true
---
Replay of PR #527 ("Approve a solve-feature PR's held CI runs instead of dispatching copies") as squash-merged on
main: the diff `8cf5eb2ec769..47c6da430297` (`47c6da43` is the squash commit, `8cf5eb2e` its parent, both on main).
A clean case: no defect is known in it. Its "Start the PR's CI" step builds `gh` commands from PR data (the PR's
head branch and SHA from `gh pr view`, run ids and workflow paths from `gh api`), each quoted, so the hostile-input
check is tested where it should stay quiet. The PR had no issue: its body is the spec, frozen in `## PRD`.

## Reference judgement

No defect is known in PR #527. Checked on 2026-10-17: `git log 47c6da43..origin/main -- .github/workflows/ci.yml
.github/workflows/solve-feature.yml docs/guide.md skills/setup-coding-crew/hosts/github-actions.yml
tests/solve-feature.bats` lists six later commits (#528, #530, #535, #533, #541, #558), and `git log -L` over the
"Start the PR's CI" step in both workflow files shows none of them changed its lines; no issue or PR reports a defect
in it. The PR body itself names one unverified point (whether `GITHUB_TOKEN` may approve), which the change handles
by falling back to a dispatch with a warning; that is not a defect. Score `distinct` only. Any CRITICAL or HIGH
finding is suspect: a finding about quoting must name an input the project's own components produce that breaks it.

## PRD

<!-- PR #527's body (it had no issue), headings one level down: Approve a solve-feature PR's held CI runs instead of dispatching copies -->

### Why

A solve-feature PR is opened with the workflow's own `GITHUB_TOKEN`, so GitHub holds its `pull_request` CI runs for approval. #524 dispatched a copy of CI instead. On #526 that copy ran and passed, but the PR page still showed "1 workflow awaiting approval" and none of the dispatched run's checks. Approving the held run by API (tried by hand on #526) starts it and lists its checks on the PR.

### What changes

- After the session, "Start the PR's CI" approves each `pull_request` run GitHub holds on the PR's head commit.
- Where GitHub refuses the approval, it dispatches that run's workflow on the PR's branch as before, with a warning saying so; if both fail, the warning says the run still waits for approval.
- It acts only on workflows that have a held run, so it no longer scans `.github/workflows/` with `yq`.
- Same edit in setup-coding-crew's template and this repo's `solve-feature.yml`; header comment, `docs/guide.md`, `ci.yml`'s comment and CHANGELOG updated.

### Risk

A revert fully undoes it. Unverified: whether `GITHUB_TOKEN` (with `actions: write`) is allowed to approve; if not, the fallback gives today's behaviour, and the next solve-feature run's log shows which path it took.

**Tested:** `scripts/ci-run-bats.sh tests/*.bats`: all 46 files pass (the new test fails against the old step); the step run locally against #526 found no held run, as expected after the manual approval.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
