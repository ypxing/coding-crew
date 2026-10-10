---
paths:
  - "orchestrator/**"
  - "skills/crew-afk/**"
  - "tests/orchestrator/**"
  - "tests/orchestrator*.bats"
  - "tests/crew-afk*.bats"
---

# crew-afk internals

How the orchestrator and its scripts behave. Loaded when working on crew-afk; the repo-wide rules are in `CLAUDE.md`.

## crew-afk's scripts (`skills/crew-afk/scripts/`)

Effects invoked by `orchestrator/lib/effects.mjs` (and runnable by hand).

- `session-init.sh` — derives the feature slug **once** and writes the sprint's own `.scratch/<slug>/sprint.env` (no
  repo-wide pointer: several sprints run in one repo); names the feature branch `<--branch-prefix><--jira KEY>-<slug>`
  in one function (`feature_branch_name`, validated with `git check-ref-format --branch`), creates the ref if missing
  and **never checks it out** (`--print-branch` prints slug, branch and default branch and stops, which `main.mjs` uses
  to make the `_feature` worktree first). `main.mjs` passes `afk.branchPrefix` as `--branch-prefix` only when set;
  `--jira` on a resume only warns. Scripts take their sprint from `--feature-slug` or the env the orchestrator exports
  (`FEATURE_SLUG`, `STATE_FILE`, `TRACE_LOG`, `SPRINT_DIR`) and exit 2 naming `--feature-slug` without either (`trace.sh`
  stays silent under `CREW_ORCHESTRATED=1`)
- `merge-branches.sh`, `sync-feature-branch.sh`, `squash-commits.sh` — run in `FEATURE_ROOT` (`Effects.featureRoot`, the
  `crew/<slug>/_feature` worktree `main.mjs` makes right after the lease, `ensureWorktree`'s `checkout` mode, removed in
  `finally` and on a signal); they refuse to run anywhere but on the feature branch and never switch a checkout
- `ensure-deps.sh` — makes a directory ready to run the project's own checks; delegates every
  install decision to `dep-install`'s `detect-mode.sh` / `host-install.sh`. It is mechanism rather
  than a worker skill read because it is the only layer that also covers `verify-worktree.sh`, which
  is a gate and cannot invoke a skill. Always exits 0. In docker mode every `--slug` call runs
  `docker-install.sh` (install-if-missing into the volumes this worktree's lockfiles name, so it
  reports `docker-present` / `docker-installed` / `failed`); the `MAIN_ROOT` call only records the mode
- `verify-worktree.sh` — the checks, and the verification receipt; in docker mode it runs the same
  install-if-missing first (a `deps` check), since a branch's lockfile may have changed
- `receipts.sh` — the two gates as facts on disk
- `lease.sh` — the feature lease (`refs/crew-lock/<slug>` under `tracker: github`): owner, acquire, reclaim, release
- `post-findings.sh` — posts the sprint's open review findings to the feature branch's PR as one review
- `promote-findings.sh` — findings and fixable integration failures → parked fix issues → Phase 2
- `merge-branches.sh`, `close-issue.sh` — the only writer of an issue's `Status:`
- `resolve-merge-conflicts.sh` — called by `merge-branches.sh` on a conflicted merge: when the only conflicts are
  `registry.json` entry `version`s (higher semver kept) and `CHANGELOG.md` entries both sides appended (both kept,
  feature side first) it stages the resolution, which `merge-branches.sh` commits, tracing each decision; anything else exits 1
  and the merge is aborted as before
- `sync-feature-branch.sh` — `preflight.mjs`'s `syncFeatureBranch`, once per run: fetches `origin/<default>` and, when the
  resumed feature branch lacks it (earlier work squash-merged), merges it in (`resolve-merge-conflicts.sh` for
  registry versions / CHANGELOG appends; any other conflict aborts cleanly and exits 1). Never bumps versions, never
  pushes; no `origin`/fetch/`origin/<default>` is a silent skip. `--dry-run` only reports
- `squash-commits.sh`, `cleanup-worktrees.sh` (also removes this owner's docker dependency volumes no worktree's override names), `crew-summary.sh`, `state.sh`, `trace.sh`
- `tracker-cli.sh` — sourced, not run: `resolve_tracker_cli <main-root>` sets `TRACKER_CLI` and `TRACKER_KIND` (from
  `cli.mjs config`) for `close-issue.sh`, `close-shipped.sh`, `issue-labels.sh`, `promote-findings.sh` and
  `session-init.sh`. A set `$CREW_TRACKER_CLI` is used as is (missing → error, no search); else, first existing file
  wins: `$CREW_INSTALL_DIR/tracker/`, `<root>/.coding-crew/tracker/`, `<root>/tracker/`, `$HOME/.coding-crew/tracker/`. No CLI, no `node` or a failing
  `config` exits the caller non-zero — never a silent `local`
- `main-root.sh` — sourced, not run: `main_root [dir]`, the one rule for MAIN_ROOT outside the orchestrator (same as
  `main.mjs`'s `gitRoot()`): the shared git dir's parent when it is `.git`, its `core.worktree` (a submodule), else the
  worktree's top level (a bare repo). `main.mjs` passes its MAIN_ROOT to every script; the helper serves hand runs and
  the gates (`receipts.sh`, `verify-worktree.sh`)
- `issue-labels.sh` — the one writer of crew-afk's status labels under `tracker: github`:
  `claim`/`release` (`in-progress`, display only), `block` (`blocked`, swapped for `in-progress`),
  `sweep` (clears a dead run's `in-progress` once the lease is held). A failed write only warns
- `close-shipped.sh` — once per run, after the lease: closes the milestone's `awaiting-merge`
  issues that a merged PR's body names (`Closes #n`), then the PRD once no work issue is left, and with it each open issue on the PRD's `Origin:` line.
  It reads the bodies itself, since GitHub can fail to link a `Closes` line. Runnable by hand
- `open-pr.sh` — `openPr` only: pushes the feature branch, creates or updates its PR with the
  tracker's closing lines (`closingRefs`) in crew-afk's own block of the body. The body above it is
  what `orchestrator/lib/pipeline/pr-body.mjs`'s `finish()` wrote: the `prWriter` role's Why / What
  changes / Risk / **Tested:** note, written by following `write-pr`'s SKILL.md (installed as an
  asset at `.coding-crew/write-pr/`), or crew-afk's `**Checks on the merged branch:**` line alone
  when the writer leaves no `## Why`.
  `--draft` (run not green: stalled, a blocked issue, capped, or an integration check that was `skipped`/red/not run)
  creates the PR as a draft or converts a ready one (`gh pr ready --undo`); without it an open draft is marked ready.
  `--note-file` puts the blocked list and reason inside the crew-afk block. A failed conversion, or a
  `--draft` create the repo refuses (the PR is then created ready), prints `PR-STATE-FAILED:` and never fails the script or sprint

Effects that run for minutes — a worker's `verify-worktree.sh` and `ensure-deps.sh` — go through `Effects.bashAsync`, so each
worker loop verifies its own branch concurrently; merge and close stay on the blocking `effects.bash`, which is what keeps
merges into the feature branch serialized.

A verify that gives no verdict — killed by a signal (`Effects.exec`'s `interrupted`; a real `timeoutMs` stays 124), or
output naming no failing check even on a second run — is retained as `verify-interrupted` / `verify-inconclusive` and
re-verified next round with no triage and no coder (`pipeline/verify.mjs`).

A retained branch is first synced with the feature branch (`pipeline.mjs`), in three steps: `mergeFeatureBranch` commits what
`resolve-merge-conflicts.sh` resolves; any other conflict gets its own conflict-only `coder` dispatch (`conflictPrompt`, at most
one per attempt, outside the retry cap and `MAX_DISPATCHES_PER_ISSUE`) whose success is read from git, not its report
(no `MERGE_HEAD`, nothing unmerged, HEAD containing the feature sha the sync merge started from, not the live ref a sibling
may have moved since); then the original route (`restart`, `fix`, `verify`) runs with a prompt that has no conflict text.

A retry re-reads an issue a human edited since the attempt that retained its branch: `state.sh retain` records a `sha256`
fingerprint of the issue's `## What to build` and `## Acceptance criteria` (checkbox marks normalised, so the `Status:` line,
`## Progress` / `## Blocked` and ticked boxes — crew-afk's own writes — never count). At resume, a different fingerprint turns a
`fix` or `verify` route into `restart` (`workerPrompt` on the retained branch, commits kept, `[RESUME] … issue edited` logged)
instead of `fixPrompt`'s "do not re-read the issue". A `conflict` retry still gets its conflict-only dispatch first, then restarts
instead of ending in `verify`. The `merge` route ignores it, as does a record with no fingerprint. An attempt whose conflict dispatch left the sync unresolved never worked from the edited issue, so it keeps the record's old fingerprint (`keepFingerprint`) and the next retry still restarts.

Per-issue order: worktree → `.worktreeinclude` → **deps** → worker dispatch → verify → review →
AC receipt → merge → close. Deps sit there because that one position is before both
consumers of them — the worker and the verify gate. `--no-deps` removes it. A retry skips any
gate whose receipt already matches the branch tip (`gatesAtTip`).

Soft wall-clock cap (`--max-wall <minutes>`, `afk.maxWallMinutes`, default 120, `0` = off): once elapsed `loop.mjs` claims and polls for nothing new, in-flight workers finish and merge, Phase 2 (`flush`) is skipped so fix issues stay parked, the integration check still runs; when that left an issue unclaimed or a fix issue parked, the summary names the cap and them, the run exits 2 and an `--open-pr` PR is a draft (a cap that cut nothing short is not a hit).

A stalled run whose unfinished issues include `ready-for-human` ones: `wrapUp` prints `## Waiting on a person` (before the PR section), one line per such issue — `#<number>` under github, the file name under local, then its title — and `When they are done (cli.mjs mark-done), re-run: /crew-afk <feature-slug>`. `crew-summary.sh` is not involved.

Idle-slot polling (`--poll-interval <seconds>`, default 30, `0` = off): while work is in flight and a slot is idle,
`loop.mjs` lists the tracker once per interval (one listing however many slots are idle) and starts any issue made
ready mid-run. An issue not seen before is first linted (`lintMidRunIssues`, the same `lint-issues.sh`); an `ERROR`
blocks it for this run only (named in the summary) and never stops the run or the others. Fix issues this run created
are not re-linted. Polling stops when nothing is in flight; with `0`, a new issue is claimed only when an attempt ends.

Once per run, before any dispatch (`orchestrator/lib/preflight.mjs`): the resumed feature branch gets `origin/<default>`
merged in when it lacks it (`sync-feature-branch.sh`; a conflict beyond registry versions / CHANGELOG appends stops the
run, `--no-sync-main` skips; runs in `_feature`, before lint and the baseline); a retained-branch record whose issue
is closed or absent from `listFeatureIssues`, or whose branch is gone, is dropped and logged (`dropStaleRetained` →
`state.sh drop-retained`; an open issue with its branch is kept, a failed or empty listing drops nothing); the assets under
`CREW_INSTALL_DIR` (the `.coding-crew/` main.mjs runs from; fixed sub-paths in
`orchestrator/lib/install-dir.mjs`) must exist, the feature branch must pass its own checks in a throwaway
`crew/<feature>/_baseline` worktree (`--no-baseline`) — started alongside dispatch (up to `maxParallel` coders begin meanwhile), no verify starts before its verdict, and a red one stops further claims, kills the dispatches already running and stops the run (exit 1, started branches kept for the next run); a git tree that already passed (a per-issue verify, an earlier baseline or integration — `sprint-state.json`'s `passing_trees`) reads `cached` for the baseline and the integration check alike, the feature's open issues must pass `to-issues`' `lint-issues.sh`
(`preflight.mjs`'s `lintIssues`, before command discovery: an `ERROR` stops the run, `WARN` is logged, exit 2 or a
failure to run it is logged and never stops; `--dry-run` reports only), and each ready, unblocked issue's `## Requires`
runs once through solve-issue's `check-requires.sh` — a failure blocks that issue, not the run
(an issue waiting on a blocker is probed when `loop.mjs` first claims it). A check
that modifies the tree fails, in the baseline and every verify.

At every drain of the queue (after Phase 1 and after Phase 2) the same mechanism runs once more on the merged
feature branch under its own `_integration` stem and cache (`--no-integration-check`; `--no-baseline` does not
turn it off). A red result is reported in the summary and keeps `openPr` from opening the PR (a PR an earlier run opened is made a draft, nothing pushed: `open-pr.sh --no-push`, whose `--draft-marker` rewrites the block's `<!-- crew-afk:draft … -->` line so it names `integration`). It is
first triaged (`orchestrator/lib/integration-fix.mjs`, a `crew-triage` dispatch): a fixable failure becomes one parked
fix issue (`promote-findings.sh defer-integration`) that Phase 2 implements, after which the next drain checks again
— at most two per run, then the run ends stalled; exit 127 or a "not fixable" verdict queues nothing and the summary
says why.

Once per drain loop, at the first drain where something merged (`orchestrator/lib/pipeline/feature-review.mjs`; `loop.mjs`'s
`featureReviewed` flag, so a later drain in the same run — after Phase 2 merged the fix issue — skips it with no log line, leaving that code to the closing review below; a drain
whose integration check is red does not set it, so the next drain whose check passes retries the review), after
the integration check, one `crew-reviewer` dispatch (slug `feature`, dir `dispatch/feature-d<drain>/`) runs in feature mode: no criteria, findings only, attributed to `feature` in the sprint
review report and, until the feature has its one findings fix issue (counted per feature, across runs), promoted into Phase 2 by the same `fixFindings` rule (default `actionable`: every finding
`crew-triage`'s findings mode judges Actionable, via `orchestrator/lib/pipeline/findings-triage.mjs`; a failed triage
falls back to the `high` rule). That fix issue holds the 8 most severe promotable findings, CRITICAL→LOW (`criteriaFile` sorts for every caller); the rest are marked `report_only` and stay open. The range (`featureReviewRange`) is the whole feature, from the merge-base with origin's default
branch (else the local default branch; with neither the review is skipped, logged) — never this run's `base_sha`, which
`session-init.sh` resets each run. After a review that wrote a report, `state.sh feature-reviewed` records
`feature_review.reviewed_tip` in `sprint-state.json`; a later run whose tip equals it dispatches no reviewer ("nothing new
since <sha>"), one whose tip descends from it reviews only `reviewed_tip..tip` minus commits on `origin/<default>` (what
`sync-feature-branch.sh` merged in), and a `reviewed_tip` that is no ancestor (history rewritten) gives the whole-feature
review again. Reviews after the one that created the fix issue are report-only (promotion cap): the count is `feature_review.promotions` in
`sprint-state.json` (`state.sh feature-review-promoted`, advanced only when a fix issue was created; absent reads as 0, and an earlier version's 2 reads as capped), so a later run starts past it too; no fix issue; the findings reach the review
report and the summary, and each one the rule would have promoted is a not-green reason, so an `--open-pr` PR is a draft naming
them (none under `fixFindings: none`). To keep LOW findings out of fix issues
altogether, use `afk.fixFindings: medium` / `--fix-findings medium`. Its prompt names the PRD file to read whole
(`PRD (read it whole; the feature's intent): <path>`, from `orchestrator/lib/prd.mjs`'s `prdPath`; no PRD, no line), and
`reviewer.md`'s Feature Mode makes a PRD requirement the merged code does not implement, a multi-issue flow it does not connect, and
a cross-cutting concern no issue owned findings, while a requirement a later ADR, `CONTEXT.md` entry or commit replaced is not. The
summary's `## Feature Review` gives the review (range, finding count, promoted or report-only, or why skipped). Not run when nothing merged; skipped (the summary says so) at a drain
whose integration check is red (that skip gives way to the next green drain's review, and only the last entry is kept), or when the wall-clock cap stopped claims with a claimable issue left (`FEATURE-REVIEW: skipped — …` names the cap);
a dispatch that leaves no review is recorded not-run as `feature` (and no `reviewed_tip`) and never fails the sprint.

The closing review (`loop.mjs`, after the drain loop, before `wrapUp`): when this run's feature review completed, one more
`runFeatureReview` with `promote: false` (`dispatch/feature-d<n>/`) covers what merged after it — the fix issue, integration
fixes — over `reviewed_tip..tip` (`increment`). Its findings the rule would promote are marked `report_only`, so they reach
`unfixedFeatureFindings` (the PR's draft reason), `post-findings.sh` and the summary's `## Feature Review` as their own
`Drain <n>:` entry; it never creates a second fix issue. Not dispatched when nothing merged since (unchanged tip, no entry),
when no review completed earlier in the run, under `--dry-run`, under a red last integration check, or once the wall-clock
cap has elapsed.

`reviewer.md`'s Feature Mode asks two questions (Coverage, Correctness) in two passes: Pass 1 collects every candidate,
unsure ones included, Pass 2 verifies each and is where the Pre-Report Gate, Common False Positives and "Zero Findings Is
Valid" apply. Dropped candidates go under `### Dropped` in the prose after the JSON; nothing parses it.

A not-green PR's crew-afk block carries `<!-- crew-afk:draft <kinds> -->` (`draftMarker` in `loop.mjs`, written into
`pr-note.md` beside `**Not green:**`), `<kinds>` a comma-separated subset of `findings,blocked,stalled,capped,wall-cap,integration`;
a green PR has none. `/address-pr-comments` on a crew-afk PR (body has `<!-- crew-afk:begin -->`; `<slug>` from the block's
`<!-- crew-afk:slug <slug> -->`, which `open-pr.sh` writes, else a `feature/<slug>` head branch) runs
`solve-issue`'s `run-checks.sh` after its fix commit and a plain `git push` (never forced) only on `CHECKS: pass`; when the
marker names only `findings` and every `crew-finding:` comment was handled, its summary prints `once CI is green: gh pr ready <n>`.

`prdPath(ctx)` (`orchestrator/lib/prd.mjs`) is the one owner of the feature's intent — its PRD, or the one issue carrying its decisions — located once per run: `.scratch/<slug>/PRD.md`;
else under `tracker: github` fetched with `tracker/cli.mjs prd` and saved as `prd-issue.md` (the saved copy when that fetch
fails, with a warning); else a saved `prd-issue.md`; else the feature's one issue with a `## Decisions` heading (local: under `issues/open/` or `issues/done/`; github: found with `tracker/cli.mjs known` and saved as `intent-issue.md`, the saved copy when `known` fails, with a warning); null when none, and null plus a `[WARN]` when two or more carry it. `pipeline/pr-body.mjs` gets the PR writer's PRD from it too,
and `pipeline/review.mjs` puts it on the per-branch review prompt's `PRD: <path>` line, which `reviewer.md` reads instead of
deriving a path from the branch name (configurable: `afk.branchPrefix`, `--jira`).

The per-branch review is a criteria gate and raises no findings: `reviewer.md`'s per-branch mode writes `findings: []` (the always-on
classes and design-standard checks are Feature Mode only), and `pipeline/review.mjs` drops any findings a branch report still carries
before it writes the review block, so no branch gets a fix issue of its own; findings come only from the feature review. Open branch
findings an earlier version left in a `sprint-review-*.md` report are still listed by `promote-findings.sh open`, never promoted: a re-review of that
branch carries them into its new block (`carried: true`), and the block `pipeline/review.mjs` writes is marked `criteria_only`, so the fold
(`report.mjs`'s `foldReview`) also carries a branch's earlier findings past it, as past a `not_run` block.
It judges the acceptance criteria only: `reviewPrompt` carries no PRD decisions, and an issue's `## Implements` is not read by
the orchestrator (`to-issues` and `lint-issues.sh` still use it).

Reviewer, triage (verify, findings, integration) and feature-review dispatches are mechanically read-only
(`pipeline/shared.mjs`'s `readOnlyDispatch`): every `crew/<feature>/*` ref, the feature branch, `_feature`'s `HEAD` (commit
and branch) and its uncommitted changes are snapshotted around the dispatch; any change (or a
snapshot git cannot take) fails it closed as not-run and logs `[READONLY-VIOLATION]`, with the dispatch's cost still
recorded. A change the orchestrator's own concurrent effects could have made is not blamed on it (`Effects`'
`refActivityMark`/`refActivitySince`): the feature branch and `HEAD` while a merge or other `_feature` ref move
ran, a crew branch while its worktree was busy (its worker dispatch, a git run there). The AC receipt is written with `receipts.sh write ac --branch <b> --sha <reviewed sha>`, so a
branch that moved during review fails `check ac --at-tip` as stale.

## The watch agent (`orchestrator/lib/pane-host/`)

Under orca or herdr, `main.mjs` calls `ensureWatchSession` (`pane-host/index.mjs`) right after
`ensurePaneWorkspace`, inside `if (options.paneHost && !options.dryRun)`. One interactive agent per slug, in the
main checkout, on `--platform` and the coder's resolved model: each adapter's `interactive({cwd, mainRoot, model,
protocol, policy})` returns its argv with the rendered `orchestrator/roles/watcher.md` (`ROLE_POLICY.watcher`:
read-only, no sub-agents, no default effort) as the initial prompt, and `worker-terminal.mjs`'s `writeLaunchScript`
(the `envScript` a worker terminal uses, not a copy) gives the host a `bash <launch.sh>` that sources crew-afk's 0600
`env.sh` first. The handle is `.scratch/<slug>/watch.json` `{host, handle}`, reused while the host reports a live agent
(orca `terminal show` `agentIdentity`; herdr `pane list` `agent_status` ≠ `unknown`), else replaced. The pane-host
adapters implement `openWatch`, `watchAlive` and `notify(effects, handle, message)`.

- Every push (`queuePaneNotice` → `notifyWatchSession`, and `main.mjs`'s final one) targets `effects._paneWatch.handle`;
  nothing reads `ORCA_TERMINAL_HANDLE` / `HERDR_PANE_ID` for a push. A failed create or a missing CLI is a `WARN` and
  `_paneWatch = null`, so pushes log `MILESTONE-PUSH-SKIPPED` and the exit code is unchanged.
- Nothing closes it, a signal and a thrown error included: orca's handle is never added to `_paneTerminals`, and
  herdr's watch workspace is not `_paneWorkspace`.
- `ctx.out` also appends to `.scratch/<slug>/traces/summary-<runId>.md` (`:` → `-`); the final push names it, or
  carries the first line of the failure when the run never reached `ctx`.

## Follow-ups (`orchestrator/lib/followup.mjs`)

`crew-afk followup start <slug> "<task>"|wait <id>|reply <id> "<answer>"` is a `main.mjs` command (it needs
`--platform`, like every command but `status`); the logic is `runFollowup`, backed by the pane-host ops
`openFollowup` / `awaitFollowup` / `replyFollowup` (`orca.mjs`, `herdr.mjs`, dispatched through `index.mjs`; a
host without all three has no follow-ups, and `supportsFollowups` is the gate every subcommand passes first).

- The worktree is `followupWorktreePath` (`crew/<slug>/_followup`) on the feature branch, made by `ensureWorktree`'s
  `checkout` mode. `_feature` and `_followup` are never both on the branch: `start` refuses while a live
  `.crew-afk.lock` pid or (github tracker) `lease.sh owner` holds it, and a later run's `checkoutWorktree` releases
  a clean `_followup` or refuses a dirty one through `releaseBranch`; `start` itself refuses a dirty `_followup`
  (`commit or discard them`) rather than let `checkoutWorktree` force-remove it.
- The worker has nobody at its terminal: `ROLE_POLICY.followup.unattended` makes each adapter's `interactive()` add
  its no-prompt flags (claude `--permission-mode bypassPermissions`, copilot `--allow-all-tools`, codex the
  `workspace-write` network/git-dir roots shared with `build()` and `--ask-for-approval never`). The watcher's argv has none.
- A host call that fails deletes the `env.sh` `writeLaunchScript` wrote (`ensureWatchSession`, `start`): only a script a
  host ran deletes it. The watch agent's env carries `CREW_PANE_HOST=<effects.paneHost>`.
- `.scratch/<slug>/followup.json` is written only after the host call succeeded; any failure after the worktree
  exists removes it again. Open until `wait` returns a final result. One writer: `followup.mjs`.
- orca: Run → terminal → `worker-start` (D14); the response is `orchestration inbox`'s `worker_done` to `run:<id>`.
  herdr: `agent prompt` / `wait` / `read`, the last `QUESTION:` / `DONE:` line (D15) below the echo of `rec.lastAnswer`
  (the pane text keeps earlier turns); `openFollowup` waits out the brief's first turn before prompting the spec. `followup.md` (`ROLE_POLICY.followup`)
  must never start a line with those markers, or the brief's own echo reads as an answer.

## Adding a new crew-afk role

1. `orchestrator/roles/<role>.md` — the protocol (whole-line `{{FRAGMENT:<key>}}` and `{{PLATFORM}}` expand at dispatch).
2. Map it in `ROLE_AGENTS` (`orchestrator/lib/adapters/render.mjs`) and give it a `ROLE_POLICY` entry next to it
   (`readOnly`, `subagents`, `effort`); each adapter's `policyArgs` turns that into its CLI's flags. A role that is not
   dispatched but started interactively (the `watcher`, the `followup` worker) goes through the adapter's `interactive()` instead of `build()`.
3. Bump crew-afk's `version` in `registry.json`; `TARGET_REPO=/tmp/test-repo ./install.sh claude --skill crew-afk` and inspect `.coding-crew/crew-afk/roles/`.

## Adding a platform

A platform is one data entry and one adapter; everything else (the platform list, `--platform` validation and help,
skill lookup, capability checks, the squash trailer) is derived from those two.

1. **Data entry** — add `<platform>` to `orchestrator/platforms.json`: `projectSkills`, `userSkills`, `configDir`,
   `configDirEnv` (where the platform keeps skills; a user-scope dir under `configDir` moves to `$<configDirEnv>`).
2. **Adapter** — `orchestrator/lib/adapters/<platform>.mjs`, registered in `adapters/index.mjs`'s `ADAPTERS`, implementing
   the contract: `cmd`, `defaultParallel`, `defaultModel`, `coAuthor` (the squash commit's trailer line), `requiredFlags`,
   `helpArgs?` (doctor), `build(spec) -> { args, input? }` (spec: `cwd`, `mainRoot`, `model`, `policy`, `protocol` and
   `protocolFile` — the rendered protocol as text and as `<outFile>.protocol.md` — `prompt`, `outFile`, `label`),
   `policyArgs(policy)` (a `ROLE_POLICY` entry → flags), `interactive({cwd, mainRoot, model, protocol, policy})`
   (the CLI's interactive argv, `cmd` first, the protocol as its initial prompt: the watch agent), `finalText(lines)`, `normalize(evt)` (a raw event → the
   one shape trace, pane text and deviation detection read; an array when one raw event holds several tool calls); optional
   capabilities `liveText`, `resume(id)`, `budget(usd)`, `resultMeta(lines)`, `env`, `modelTiers`, `modelAliasEnv`. A capability the
   adapter lacks is off for that runtime (no resume, `afk.limits` reported ignored), never a name check elsewhere.
3. **Conformance test** — `node --test tests/orchestrator/platforms.test.mjs` fails, naming the platform, until both exist
   and the adapter has every required field; pin its `policyArgs` per role and its `interactive` argv there, and add its dispatch golden
   (`UPDATE_GOLDEN=1 node --test tests/orchestrator/platform-golden-dispatch.test.mjs`).
4. **Smoke run** — `scripts/smoke-sprint.sh <platform>`: one real sprint on the CLI.
