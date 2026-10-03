# CLAUDE.md

Guidance for Claude Code (or any agent) working in this repo.

## What this repo is

A distributable collection of AI skills (and crew-afk, the program that runs them unattended) that other projects install via `install.sh`.
Nothing here runs on its own — this repo is the source; consuming projects are the target.
For the end-user pipeline (crew-grill/crew-brainstorm → crew-afk → crew-address-findings), see `README.md`.

## Layout

- `skills/<skill>/SKILL.md` (or `<platform>.SKILL.md` per platform) — one skill per directory. `crew-afk`'s skill is a thin launcher; its actual logic is the `orchestrator/` program.
- `orchestrator/` — the crew-afk state machine (rounds, worktrees, deps → dispatch → verify → review → merge → close, receipts). One implementation, run by all four platform launchers via `orchestrator/lib/dispatch.mjs`.
- `orchestrator/roles/` — the role protocols crew-afk dispatches (`coder.md`, `reviewer.md` + `reviewer/` checklists and scripts, `triage.md`). They ship with the orchestrator to `.coding-crew/crew-afk/roles/` (crew-afk also installs `skills/_shared/fragments/` to `.coding-crew/skills/_shared/fragments/` for their `{{FRAGMENT:…}}` lines) and are rendered per dispatch; no platform gets an agent file. `registry.json`'s `retired-agents` lists the agent files older installs wrote, which install and uninstall remove.
- `registry.json` — source of truth for install paths per skill/platform, `deps`, `assets`, `retired-agents`, and doc templates.
- `install.sh` / `uninstall.sh` — installer; `PLATFORMS=(claude copilot pi codex)`.
- `scripts/` — shared build-time scripts copied into skills (`skills/skill-utils/git-workflow/`), skill-local runtime scripts (e.g. `skills/crew-afk/scripts/`), and maintainer-only scripts that ship to no consumer (`ci-test-shard.sh`, `render-skill.sh`, `cut-release.sh`, `eval-design-skills.mjs` with its `eval-design-skills/` cases and rubric).
- `tests/` — bats tests, run against **rendered/installed** output via `tests/helpers/render.bash`, not source variants.
- `docs/` — the dev team guide (`guide.md`) and issue-tracker templates.

## Working in this repo

```bash
# Install into a scratch repo to see what a platform actually receives
TARGET_REPO=/tmp/test-repo ./install.sh claude --skill crew-afk

# Render a skill body without a full install
bash scripts/render-skill.sh crew-afk codex | less

# Run tests
bats tests/*.bats

# After editing crew-grill/crew-brainstorm: behavioural A/B (base ref vs worktree), judged blind; costs API money
node scripts/eval-design-skills.mjs --skill crew-grill --runs 2 --dry-run   # drop --dry-run to run

# Bring a PR branch up to date with origin/main (local only, never pushes): merge it, resolve registry version / CHANGELOG append conflicts, bump versions to sit above main's
scripts/sync-pr-with-main.sh <branch>

# Cut a milestone release (not per merge) once CHANGELOG.md's top version entry and any registry.json version bumps are committed
scripts/cut-release.sh --dry-run   # verify, then re-run without --dry-run to tag and push
```

- Version bump (D4): a change to any file a `skills.*` entry in `registry.json` ships (its `source-dir` tree, `assets.source` tree, `scripts[]`, `platform-files`) or to that entry's own registry fields needs that entry's `version` in `registry.json` strictly above `origin/main`'s version for it — `install.sh --update` skips an entry whose version is unchanged, and two branches bumping to the same number would collide. An entry the branch did not change (measured from the merge-base) is exempt even if main bumped it. `tests/registry-version-bump.bats` enforces it against `origin/main` (skips when it is not found) and fails the verify gate otherwise.
  In an issue's acceptance criteria, state it as the invariant ("`<entry>`'s version is above origin/main's"), never as "version bumped": issues in one sprint run in parallel, and once a sibling has bumped the entry, the bump drops out of a later branch's diff after it syncs with the feature branch, so the reviewer finds it unmet.
- One writer per issue file: don't add code paths where a worker/agent edits an issue's `Status:`/checkboxes directly — that's `close-issue.sh`'s job, gated by receipts.
- Issues (this repo's own dev use) live in `.scratch/<feature-slug>/issues/{open,done}/`; see `.coding-crew/docs/issue-tracker.md`.

## Layer ownership

The call direction is crew-afk (program) → `crew-coder` (role, `orchestrator/roles/coder.md`) → `solve-issue` (skill) → `tdd` /
`dep-install`. `crew-coder` is on the **sprint path only** — a human running `/solve-issue` never
touches it, so anything the direct path also needs belongs below it. Content that fits no row is in
the wrong file; `tests/layer-ownership.bats` checks the `solve-issue`, `tdd` / `dep-install` and `crew-coder` (report wire) rows — the `orchestrator/` and `skills/crew-afk/scripts/` rows are not checked there.

| Layer                      | Owns                                                 | Must not contain                          |
| -------------------------- | ---------------------------------------------------- | ----------------------------------------- |
| `orchestrator/` (code)     | control flow: rounds, gate order, what runs and when | judgement, and prose asking to be obeyed  |
| `skills/crew-afk/scripts/` | one effect each, runnable by hand                    | any decision the orchestrator should make |
| `crew-coder`               | protocol + report wire                               | the implementation loop                   |
| `solve-issue`              | the ordered procedure and the outcome vocabulary     | who its caller is                         |
| `tdd` / `dep-install`      | one technique each                                   | issue, report or status handling          |

## crew-afk's scripts (`skills/crew-afk/scripts/`)

Effects invoked by `orchestrator/lib/effects.mjs` (and runnable by hand).

- `session-init.sh` — derives the feature slug **once** and writes `sprint.env`
- `ensure-deps.sh` — makes a directory ready to run the project's own checks; delegates every
  install decision to `dep-install`'s `detect-mode.sh` / `host-install.sh`. It is mechanism rather
  than a worker skill read because it is the only layer that also covers `verify-worktree.sh`, which
  is a gate and cannot invoke a skill. Always exits 0
- `verify-worktree.sh` — the checks, and the verification receipt
- `receipts.sh` — the two gates as facts on disk
- `lease.sh` — the feature lease (`refs/crew-lock/<slug>` under `tracker: github`): owner, acquire, reclaim, release
- `post-findings.sh` — posts the sprint's open review findings to the feature branch's PR as one review
- `prd-audit.sh` — the PRD audit gate: locates the PRD and prints the prompt the `prdAuditor` dispatch uses
- `promote-findings.sh` — findings, PRD gaps and fixable integration failures → parked fix issues → Phase 2
- `merge-branches.sh`, `close-issue.sh` — the only writer of an issue's `Status:`
- `resolve-merge-conflicts.sh` — called by `merge-branches.sh` on a conflicted merge: when the only conflicts are
  `registry.json` entry `version`s (higher semver kept) and `CHANGELOG.md` entries both sides appended (both kept,
  feature side first) it stages the resolution, which `merge-branches.sh` commits, tracing each decision; anything else exits 1
  and the merge is aborted as before
- `sync-feature-branch.sh` — `preflight.mjs`'s `syncFeatureBranch`, once per run: fetches `origin/<default>` and, when the
  resumed feature branch lacks it (earlier work squash-merged), merges it in (`resolve-merge-conflicts.sh` for
  registry versions / CHANGELOG appends; any other conflict aborts cleanly and exits 1). Never bumps versions, never
  pushes; no `origin`/fetch/`origin/<default>` is a silent skip. `--dry-run` only reports
- `squash-commits.sh`, `cleanup-worktrees.sh`, `crew-summary.sh`, `state.sh`, `trace.sh`
- `issue-labels.sh` — the one writer of crew-afk's status labels under `tracker: github`:
  `claim`/`release` (`in-progress`, display only), `block` (`blocked`, swapped for `in-progress`),
  `sweep` (clears a dead run's `in-progress` once the lease is held). A failed write only warns
- `close-shipped.sh` — once per run, after the lease: closes the milestone's `awaiting-merge`
  issues that a merged PR's body names (`Closes #n`), then the PRD once no work issue is left, and with it each open issue on the PRD's `Origin:` line.
  It reads the bodies itself, since GitHub can fail to link a `Closes` line. Runnable by hand
- `open-pr.sh` — `openPr` only: pushes the feature branch, creates or updates its PR with the
  tracker's closing lines (`closingRefs`) in crew-afk's own block of the body, under the body
  `orchestrator/lib/pipeline/pr-body.mjs` had the `prWriter` role write by following `write-pr`'s
  SKILL.md (installed as an asset at `.coding-crew/write-pr/`), plus the checks line.
  `--draft` (run not green: stalled, a blocked issue, capped, or an integration check that was `skipped`/red/not run)
  creates the PR as a draft or converts a ready one (`gh pr ready --undo`); without it an open draft is marked ready.
  `--note-file` puts the blocked list and reason inside the crew-afk block. A failed conversion prints
  `PR-STATE-FAILED:` and never fails the script or sprint

Effects that run for minutes — a worker's `verify-worktree.sh` and `ensure-deps.sh` — go through `Effects.bashAsync`, so each
worker loop verifies its own branch concurrently; merge and close stay on the blocking `effects.bash`, which is what keeps
merges into the feature branch serialized.

A verify that gives no verdict — killed by a signal (`Effects.exec`'s `interrupted`; a real `timeoutMs` stays 124), or
output naming no failing check even on a second run — is retained as `verify-interrupted` / `verify-inconclusive` and
re-verified next round with no triage and no coder (`pipeline/verify.mjs`).

Per-issue order: worktree → `.worktreeinclude` → **deps** → worker dispatch → verify → review →
AC receipt → promote → merge → close. Deps sit there because that one position is before both
consumers of them — the worker and the verify gate. `--no-deps` removes it. A retry skips any
gate whose receipt already matches the branch tip (`gatesAtTip`).

Soft wall-clock cap (`--max-wall <minutes>`, `afk.maxWallMinutes`, default 120, `0` = off): once elapsed `loop.mjs` claims nothing new, in-flight workers finish and merge, Phase 2 (`flush`) is skipped so fix issues stay parked, the integration check still runs; the summary names the cap and the unclaimed issues, the run exits 2 and an `--open-pr` PR is a draft.

Idle-slot polling (`--poll-interval <seconds>`, default 30, `0` = off): while work is in flight and a slot is idle,
`loop.mjs` lists the tracker once per interval (one listing however many slots are idle) and starts any issue made
ready mid-run. An issue not seen before is first linted (`lintMidRunIssues`, the same `lint-issues.sh`); an `ERROR`
blocks it for this run only (named in the summary) and never stops the run or the others. Fix issues this run created
are not re-linted. Polling stops when nothing is in flight; with `0`, a new issue is claimed only when an attempt ends.

Once per run, before any dispatch (`orchestrator/lib/preflight.mjs`): the resumed feature branch gets `origin/<default>`
merged in when it lacks it (`sync-feature-branch.sh`; a conflict beyond registry versions / CHANGELOG appends stops the
run, `--no-sync-main` skips; runs after the dirty check, before lint and the baseline); the assets under
`CREW_INSTALL_DIR` (the `.coding-crew/` main.mjs runs from; fixed sub-paths in
`orchestrator/lib/install-dir.mjs`) must exist, the main checkout must have no uncommitted tracked
changes (`--allow-dirty`), the feature branch must pass its own checks in a throwaway
`crew/<feature>/_baseline` worktree (`--no-baseline`) — started alongside dispatch (up to `maxParallel` coders begin meanwhile), no verify starts before its verdict, and a red one stops further claims and the run (exit 1, started branches kept); a git tree that already passed (a per-issue verify, an earlier baseline or integration — `sprint-state.json`'s `passing_trees`) reads `cached` for the baseline and the integration check alike, the feature's open issues must pass `to-issues`' `lint-issues.sh`
(`preflight.mjs`'s `lintIssues`, before command discovery: an `ERROR` stops the run, `WARN` is logged, exit 2 or a
failure to run it is logged and never stops; `--dry-run` reports only), and each ready, unblocked issue's `## Requires`
runs once through solve-issue's `check-requires.sh` — a failure blocks that issue, not the run
(an issue waiting on a blocker is probed when `loop.mjs` first claims it). A check
that modifies the tree fails, in the baseline and every verify.

At every drain of the queue (after Phase 1 and after Phase 2) the same mechanism runs once more on the merged
feature branch under its own `_integration` stem and cache (`--no-integration-check`; `--no-baseline` does not
turn it off). A red result is reported in the summary and keeps `openPr` from opening the PR. It is
first triaged (`orchestrator/lib/integration-fix.mjs`, a `crew-triage` dispatch): a fixable failure becomes one parked
fix issue (`promote-findings.sh defer-integration`) that Phase 2 implements, after which the next drain checks again
— at most two per run, then the run ends stalled; exit 127 or a "not fixable" verdict queues nothing and the summary
says why.

At the first drain only (`orchestrator/lib/pipeline/feature-review.mjs`), after the integration check, `crew-reviewer`
runs in feature mode over `base_sha..<feature branch>`: no criteria, findings only, attributed to `feature` in the sprint
review report and promoted into Phase 2 by the same `fixFindings` rule (default `actionable`: every finding
`crew-triage`'s findings mode judges Actionable, via `orchestrator/lib/pipeline/findings-triage.mjs`; a failed triage
falls back to the `high` rule). Not re-run after Phase 2, nor when nothing
merged; skipped (the summary says so) when the integration check is red; a dispatch that leaves no review is recorded
not-run and never fails the sprint.

Reviewer, triage (verify, findings, integration) and feature-review dispatches are mechanically read-only
(`pipeline/shared.mjs`'s `readOnlyDispatch`): refs, main `HEAD` and the main checkout's uncommitted changes are
snapshotted around the dispatch; any change (or a snapshot git cannot take) fails it closed as not-run and logs
`[READONLY-VIOLATION]`. When another effect mutated the repo meanwhile (`Effects.mutations`), only the dispatch's own
branch ref is compared. The AC receipt is written with `receipts.sh write ac --branch <b> --sha <reviewed sha>`, so a
branch that moved during review fails `check ac --at-tip` as stale.

## `to-issues`' linter (`skills/to-issues/scripts/lint-issues.sh`)

Read-only checker for a feature's issue set, shipped as an asset at `.coding-crew/to-issues/scripts/` and
runnable by hand: `lint-issues.sh --issue <file>... [--known <file>...] [--deps <issues-deps.json>] [--prd <file>]`.
`--known` names issues outside the set (done ones; preflight passes them) that a `## Blocked by` ref may resolve to,
by basename. Prints `ERROR <file>: …` (cycle, unmatched `## Blocked by` ref, `--deps` drift, no
`## Acceptance criteria`) or `WARN <file>: …` (advisory); exit 1 iff any `ERROR`, 2 on a usage error. Issue text is
data — never evaluated, and a path in a ref is never opened.

## Adding a new crew-afk role

1. `orchestrator/roles/<role>.md` — the protocol (whole-line `{{FRAGMENT:<key>}}` and `{{PLATFORM}}` expand at dispatch).
2. Map it in `ROLE_AGENTS` (`orchestrator/lib/adapters/render.mjs`) and give it any per-CLI args in `adapters/role-args.mjs`.
3. Bump crew-afk's `version` in `registry.json`; `TARGET_REPO=/tmp/test-repo ./install.sh claude --skill crew-afk` and inspect `.coding-crew/crew-afk/roles/`.
