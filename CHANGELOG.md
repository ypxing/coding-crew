# Changelog

## [1.20.0] - 2026-08-12

### Changed

- **`crew-afk` (1.18.0) — the orchestrator's mechanism moved out of the prompt and into scripts (audit P3).** An orchestrator is a state machine, and the parts of this one that were prose behaved like prose: a sprint re-derived the feature slug with `jq -r .feature_slug "$(ls -1 .scratch/*/sprint-state.json | head -n1)"` — an alphabetical-first glob that picks the wrong feature in any repo with two sprint dirs — sitting directly beneath a comment reading "Never re-derive it"; `[DISPATCH]` was traced twice, once by `dispatch-agent.sh` and once by an instruction to echo the same line; and the summary was a ~430-word print template filled in from lists carried in context since round 1, which is the one place a dropped entry is invisible (a retained branch missing from the summary reads as a clean teardown)
  - `session-init.sh` now writes **`sprint.env`** (`.scratch/<feature-slug>/sprint.env`, plus a `.scratch/sprint.env` pointer) exporting `MAIN_ROOT`, `FEATURE_SLUG`, `FEATURE_BRANCH`, `SPRINT_DIR`, `STATE_FILE`, `TRACE_LOG`, `DISPATCH_DIR`, `REVIEW_DIR`. Every body sources it at the top of each bash block; the slug is resolved once, where the issues actually live
  - New **`trace.sh`**: each script traces its own step (`SESSION`, `DISPATCH`, `VERIFY`, `MERGE`, `CLOSE`, `PROMOTE`, `FLUSH`, `CLEANUP`, `SQUASH`, `MODEL`, `ROUND`, `STATE`, `EXIT`), so a step that ran is always traced and a step that was skipped can no longer be traced as if it had run. The duplicate `[DISPATCH]` echo is gone. It resolves the log through `sprint.env` and is a silent no-op with no sprint present — tracing must never fail the caller making progress
  - New **`state.sh`** (`complete` / `retain` / `blocked` / `coverage-gap` / `model` / `round` / `resume` / `get`) replaces the raw jq one-liners and the "append to `all_merged` / `all_partial` / `all_blocked`" bookkeeping. `get merged` and `get retained` now feed `cleanup-worktrees.sh`, so the certified lists come from disk; `retain` is the one entry point for every branch that must survive, and `complete` clears the retention so a stale branch is never offered for resume
  - New **`crew-summary.sh`** renders the rollup, `## Verification Failures`, `## Coverage Gaps`, `## Retained Branches`, `## Promoted Findings` and the findings reminder from `sprint-state.json` and the review reports. A review gap is still never suppressed by a clean findings count, and still never counted as a finding — but that rule is now executed once instead of restated in four bodies
  - Orchestrator bodies: **4,345 → 2,828 words** (Claude) and **4,130 → 2,442 words** shared (pi/codex/copilot render at ~3,240), with the deleted text being narration of script internals, print templates, and re-explanations of decisions a script already enforces
- Covered by `tests/crew-afk-state.bats` (30 tests): `sprint.env` contents and that it names the sprint the issues live in rather than the alphabetically-first one, `trace.sh` resolution and its no-op path, per-script `MERGE`/`CLOSE`/`EXIT` markers, `state.sh` retain/complete/idempotence/`resume`/`get` disjointness, `crew-summary` rendering including the gap-vs-findings interaction and promoted-findings read-back, that no body re-derives the slug or hand-rolls a script's trace marker, and a 3,000-word budget per body
  - Six prose assertions in `tests/retain-partial-work.bats`, `tests/crew-afk-review-gaps.bats` and `tests/crew-afk-pre-merge-review.bats` were rewritten to assert the script's behaviour instead of the sentence that described it — the P0 half of the audit, applied where P3 touched. Suite: 455 → 487 tests


## [1.19.0] - 2026-08-12

### Changed

- **Unified dispatch skill rendering via fragments** — the `crew-afk` skill variants (pi, codex, copilot) were three ~5,000-word files that were 85–90% identical and drifting. They now render from a shared `dispatch.SKILL.md` body by inlining platform-specific fragments from `fragments/<platform>/<key>.md`. A missing fragment or surviving `{{...}}` placeholder is a hard error — preventing body gaps from shipping to consumers
  - New `scripts/render-skill.sh <skill> <platform>` — renders bodies by substituting `{{FRAGMENT:<key>}}` and `{{PLATFORM}}` inline. `install.sh` calls it for every skill it installs
  - Rendered bodies are self-contained and require no build inputs; fragment directories are build inputs and never installed. A fragment tree left by an older install is pruned on re-install
  - Parity held by `tests/shared-dispatch-body.bats`: tests run against the **rendered** body (not a source variant), asserting identical section structure and pipeline order across platforms, and verifying install renders and ships no build inputs
- **Platform file support in registry.json** — each skill may declare `platform-files`, a map of paths that are installed only for specific platforms. Other platform-specific files are copied to `platform-files` and pruned on re-install
- `install.sh` now idempotent across platforms: files from unselected platforms are deleted on re-install, so downgrading (e.g., pi-only) cleans up `.claude/`, `.copilot/`, `.codex/` artifacts
## [1.18.0] - 2026-08-12

### Fixed

- **`crew-afk` (1.16.0) — a code review that never ran was reported as a clean review.** Review is advisory by design and never blocks a merge, but the failure shape made "advisory" decay into "reported as clean": a dead reviewer dispatch (timeout, killed process, crashed CLI) writes no `--out` file, so nothing is appended to `.scratch/<slug>/reviews/`, so `remind` globs an empty directory and prints `FINDINGS: none`. The sprint ended telling the user there was nothing to triage, on branches nobody had looked at
  - Observed in the wild as the orchestrator improvising `Reviewer timed out. I'll perform the review inline` — a fallback that appears in no variant, because none of them specified what to do when a reviewer fails. An inline self-review is strictly worse than none: it writes no report, so `defer` has nothing to read (it hard-dies on a missing `--report`), CRITICAL/HIGH findings never reach Phase 2, and the review exists only in the orchestrator transcript, lost at session end. It also discards the reviewer's fresh read-only context, which is the entire reason review is a separate agent
  - New `promote-findings.sh mark-not-run` records the gap as a stub `## Branch:` block carrying `Review: not_run — <reason>`, **creating the report if no branch produced one** — that is the load-bearing part, since an absent file is what made the gap invisible. Idempotent per branch, so a dispatch retried and failed twice counts once
  - `remind` now counts unreviewed branches separately from findings and prints `REVIEW-GAPS: branches=<N>` with a `gap: <branch> — <reason>` line each, *in addition* to the findings line and never folded into its count (a not_run branch produces no findings by definition). `No open review findings.` can no longer stand alone while a gap exists
  - All four variants now specify the failure path explicitly and forbid the inline self-review, so the model has an instruction to follow instead of a hole to improvise into
  - Same `not_run` convention `verify-worktree.sh` already uses for undiscoverable check commands: an unknown result is recorded as unknown, never as a pass
- Covered by `tests/crew-afk-review-gaps.bats` (14 tests), including the exact silent-loss case (zero findings + one unreviewed branch), that the marker is not miscounted as a finding, that promotion subtraction still works alongside a gap, and that all four variants carry the failure path and the `REVIEW-GAPS` handling

### Notes

- Not related to the v1.17.3 dispatcher fix, though it surfaced while investigating the same sprint: verified that bash 4.4 and 5.2 perform the offending whole-string substitution in 0ms even at 100KB, so Linux was never affected by that bug
- The reviewer's timeout exposure itself is unchanged and still open: reviews run as serial blocking calls while coders are backgrounded in parallel, and review cost scales with diff size and finding count. This release makes a timed-out review *visible*, not less likely

## [1.17.3] - 2026-08-12

### Fixed

- **`crew-afk` (1.15.1) — both dispatchers burned 40–140s of CPU per worker before starting work.** `dispatch-agent.sh` (pi) and `dispatch-codex-agent.sh` (codex) validate that an agent definition's instruction body is not blank, and both did it with `[[ -n "${VAR//[[:space:]]/}" ]]`. Pattern substitution over a multi-KB string is O(n²) in bash 3.2 — the system `/bin/bash` on macOS, which is where `#!/usr/bin/env bash` lands by default — so answering a yes/no question rebuilt the whole string one character at a time
  - Measured on macOS bash 3.2: **40s** for `crew-coder.md` (10KB body), **142s** for `crew-code-reviewer.md` (15KB). Paid on every dispatch, serially and single-threaded, before any model call — so a 4-coder sprint with 4 reviews spent roughly **12 minutes** of pure CPU deciding that non-empty strings were non-empty, while starving the parallel workers it had just spawned
  - Replaced with `[[ "$VAR" =~ [^[:space:]] ]]`, which short-circuits on the first non-space character: **0.005s vs 47s** on the same 10KB input, identical semantics across `""`, `"   "`, `"\n\t "`, and `"x"`
  - Linux CI never saw this: bash 4+ does not have the quadratic behaviour, so the bug was invisible to the matrix and only ever hurt macOS users
- Covered by `tests/dispatch-blank-body-check.bats` (5 tests): the check still rejects a whitespace-only body on both platforms, still accepts a body whose only content sits 4KB in (so a first-N-chars shortcut cannot pass), neither script reintroduces the pattern substitution, and a realistic 10KB body completes well inside a deliberately loose 15s bound. Against the previous code the bound test measures **76s**

### Changed

- Test suite wall time drops from **~330s to ~74s** (`tests/codex-platform.bats` alone: 263.5s → 10.4s). The suite was never bloated — 23 of its 27 files already finished in under a second, and 78% of the total runtime was this one production bug being exercised three times

## [1.17.2] - 2026-08-11

### Added

- **Release automation** (`.github/workflows/release.yml`): pushing a `vX.Y.Z` tag now publishes the matching GitHub Release automatically, with notes lifted from that version's `CHANGELOG.md` section and the title taken from the tag annotation
  - This closes a silent distribution failure: `bootstrap.sh` and `install.sh` resolve `--version latest` through GitHub's `/releases/latest` redirect, which only sees Release **objects** — a bare tag is invisible to it. `v1.15.0`, `v1.16.0`, and `v1.17.0` were each tagged hours to days before their Release existed, so every `--version latest` install in those windows resolved to `v1.14.1` and wrote it into `crew.lock`. The lockfile was correct; the release process was not
  - Fatal if the tagged version has no `CHANGELOG.md` section — a release with no notes is the failure mode being removed. Idempotent: re-running (or re-pushing a tag) edits the existing release instead of failing
- **CI release parity check** (`release-parity` job in `ci.yml`): fails the build when any `v*` tag has no corresponding GitHub Release, so the gap is caught on the next push rather than from a consumer's stale `crew.lock`
  - Backfilled the three tags this check found already orphaned: `v1.8.1`, `v1.9.1`, `v1.10.0` (the last had never been pushed at all)

### Changed

- **`crew-grill`** (1.2.0): Phase 1 now filters every frontier node through **two** gates instead of one. The existing router (now **Gate 2 — Consequence**) only ever decided *who owns a fork*; it never asked whether the node was a fork at all, so questions a staff engineer would have looked up sailed through it and reached the user. **Gate 1 — Competence** is that missing question: *would a staff engineer on this team need to ask this, or would they be embarrassed to?* Seven disqualifiers retire a node before it can be routed — **discoverable**, **already answered** (in this conversation or the plan handed over), **testable** by a read-only experiment, **conventional**, **analysis** dressed up as preference ("will this scale?" — the user's answer would be a guess), **deferrable** to implementation time, and **rubber-stamp** (asking permission, not asking for a decision)
  - The root cause was textual: every mention of homework was scoped to the repo — "look up anything discoverable **in the codebase**", "already settled by an **existing repo pattern**" — so a silent repo read as "not discoverable" and licensed asking the user. Lookups now explicitly cover project docs, dependency and vendor documentation, and the open web, and research is *required* before any question turning on third-party behaviour: a library's API, a service's limits, a format's spec are never the user's to answer
  - `wire formats and external contracts` left the *annoyed* list, which had been inviting questions about the one area most likely to be answerable from a vendor's docs. The bullet now splits along the same fact/decision line the gates draw: *what the wire format requires* is a lookup you owe, *which of our shipped formats we break* is a decision you owe the user
  - Ecosystem convention now counts as precedent alongside repo pattern, under the same citation discipline — `path:line` for the repo, the doc or spec for a convention — because an uncited convention is exactly how a preference gets laundered into a fact
  - Each `❓` carries a `checked:` clause naming what was consulted. It is Gate 1's receipt, in the spirit of `crew-afk`'s gate receipts: a prose gate with no artifact cannot be seen to have run, and a question with nothing to cite is research that has not happened yet
  - Two consistency fixes the new gate would otherwise fight: *escalation is cheap* is now scoped to trading between lanes and "never resurrects a node that failed Gate 1", and a quiet round is no longer a smell when its nodes were discharged with citations — with Gate 1 working, quiet rounds are the expected case, and the old rule would have pushed the model back toward asking to prove it was grilling
  - The `~4` cap is restated as "as few as the frontier genuinely blocks on" with the depth instruction made mechanical: drop the round's weakest question outright and spend the freed slot deepening the strongest. A forced deletion produces an edit; an open-ended "review your questions" produces a verdict
  - Gate 1 research is expensive, so the Phase 1 summary and the Phase 2 handoff now carry the **established facts and their citations** into `PRD.md`'s `## Decisions` section — otherwise the implementing agent re-derives them, or re-asks them
  - Covered by `tests/crew-grill-question-gates.bats` (10 tests), all of which fail against the previous wording

## [1.17.1] - 2026-08-11

### Fixed

- **`install.sh` / `bootstrap.sh`**: the `crew.lock` round trip worked in neither direction — three bugs that compounded
  - `write_lockfile` records the release as `v1.17.0`, but `--from-lockfile` built its tarball URL as `v${version}` → `.../tags/vv1.17.0.tar.gz` → 404. Any lockfile written by `--version` was uninstallable, which is the entire team-distribution path in the README. Versions are now normalised to bare semver on read (`lock_bare_version`), so both `v1.2.0` and `1.2.0` lockfiles resolve
  - `--update` compared the lockfile's `v1.17.0` against `fetch_latest_release_version`'s `1.17.0` with plain `==`, so the `Already at v… — nothing to update` branch was unreachable: every `--update` re-downloaded the tarball, reinstalled everything, and announced `Update available: vv1.17.0 → v1.17.0`
  - `crew.lock` never recorded the platform, so `--update` (which prefers the lockfile over the manifest) fell back to `all` and widened a `pi`-only install into `.claude/`, `.copilot/`, and `.codex/`. `write_lockfile` now records `platform`, and both `--update` and `--from-lockfile` install for it; lockfiles predating the field fall back to `manifest.json`'s platform, then to `all`
  - Item versions are also read tolerantly: `write_lockfile` emits `{"version": "1.2.3"}` but the update path read `.agents[$n]` as a string (getting the whole object), so every item looked changed. `run_update_from_lockfile` now rewrites entries in the same object form it reads, instead of flattening them to bare strings and breaking the next run
  - `bootstrap.sh` normalises `--version 1.2.0` to the `v`-prefixed tag before building its own tarball URL
  - Covered by four new tests in `tests/install.bats`

## [1.17.0] - 2026-08-11

### Added

- **`crew-afk`** (1.14.0): the verify and acceptance-criteria gates are now mechanical instead of prose — `skills/crew-afk/scripts/receipts.sh` records the gated commit SHA at `.scratch/<feature-slug>/dispatch/<issue-slug>.<verify|ac>.ok`
  - `verify-worktree.sh` writes the `verify` receipt on exit 0 and clears it on failure; `merge-branches.sh` refuses any `crew/<feature>/<issue>` branch whose receipt is missing or stale (commits landed after verification), while non-`crew/` branches stay ungated
  - `close-issue.sh` refuses to close an issue without a receipt for **that issue's own slug**, so a sibling branch's evidence can no longer close it — the failure mode observed in one sprint, which merged a branch whose `VERIFY` result was `fail` and then reported `merged=2` after a single dispatch
  - All four platform variants record the `ac` receipt after `AC: all-met`, covered by a parity test so a variant cannot silently drop it. `CREW_RECEIPTS=off` disables receipt *checking* for tests and out-of-sprint script use
  - Covered by `tests/crew-afk-receipts.bats`

- **`crew-afk`** (1.15.0): worktree/branch teardown is now a mechanical step — `skills/crew-afk/scripts/cleanup-worktrees.sh` replaces the hand-rolled `git worktree remove` / `git branch -D` / `git worktree prune` snippets in all four platform variants
  - Removes each merged branch's worktree **before** its ref (git refuses to delete a ref a worktree still has checked out), then prunes stale worktree metadata
  - Fails safe: a `--retain` branch is never touched, a worktree with uncommitted changes is never removed, and a *swept* branch whose commits are not already in `HEAD` is never deleted (override with `--force`) — while branches passed as `--merged` are exempt from the ancestry test, since cleanup runs after squash and a squashed merge leaves no ancestry to check. Every refusal is reported as `kept`, not as a failure, and the run ends with a machine-readable `CLEANUP: removed=N kept=M failed=K` line
  - **Sweeps** leftovers no variant ever named: `crew/<feature-slug>/*` worktrees stranded by an earlier round or a crashed sprint, plus the runtime-managed `worktree-agent-*` worktrees under `.claude/worktrees/` that Claude's `isolation: worktree` creates. Those accumulated indefinitely because cleanup only ever listed branches the orchestrator remembered
  - Idempotent by construction, so it is safe to re-run at any time — including out of band, to clear a repo that already leaked worktrees: `bash scripts/cleanup-worktrees.sh --feature-slug <slug> --dry-run`
  - Covered by `tests/crew-afk-cleanup-worktrees.bats`

## [1.16.0] - 2026-08-11

### Added

- **`crew-afk`** (1.13.0): CRITICAL/HIGH review findings are now routed back into the same sprint as a second fix phase instead of waiting for a human. Policy lives in `skills/crew-afk/references/findings-promotion.md`; the mechanical half is `scripts/promote-findings.sh` (`guard` / `defer` / `flush` / `list` / `remind`) so all four platform variants behave identically
  - **Phase 1** — after a branch's review is written, its CRITICAL/HIGH findings become a *parked* fix issue with `Status: deferred-findings` (one issue per reviewed branch, one acceptance criterion per finding). Parked issues are invisible to the loop's `ready-for-agent` selection, so they never delay the original queue. Grouping per branch rather than per finding is deliberate: findings from one branch cite one diff, so they cluster in the same files and cannot conflict with each other
  - **Phase 2** — when the loop is about to exit, via *either* the no-issues path or the stall path, `flush` flips parked issues to `ready-for-agent`, resets the stall counter, and re-enters the loop. Fix issues run the identical pipeline: worktree, TDD, `verify-worktree.sh`, AC verification, their own review, merge
  - Termination is structural, not counted: every fix issue carries a `Source:` line and `guard` refuses to promote findings raised against a `Source:`-bearing issue, so there is never a Phase 3. Phase is deliberately *not* mirrored into `sprint-state.json` — the on-disk `Status:` lines are the only record, which is what makes flush idempotent and crash-safe
  - MEDIUM/LOW are never promoted. Because promotion is partial by design, every variant ends the sprint with `promote-findings.sh remind`, which counts the findings **not** covered by a promotion marker and prints either `## Next Step` with a real count and the report paths, or `No open review findings.` — so the user is never nudged toward an empty queue, and a CRITICAL raised against a Phase 2 fix branch (report-only by the depth bound) never ends the sprint in silence
  - Self-tests in `skills/crew-afk/references/test-promote-findings.sh` (not installed — `install.sh` skips `test-*.sh`)

### Changed

- **`crew-address-findings`** (1.3.0): skips findings listed under a report's `## Promoted Findings` section — those `(branch, severity)` pairs were auto-promoted and already fixed in a later round of the same sprint. Findings from the same branch at *other* severities are still triaged normally, and skipped pairs are reported once under **Skipped**

## [1.15.0] - 2026-08-11

### Added

- **`crew-grill`**: Phase 1 now routes every frontier decision before asking it, so the user is only interrupted for choices they'd regret not being consulted on. Each node gets a single counterfactual — *if I decide this myself and the user only finds out at review time, would they be annoyed I didn't ask?* — which sorts it into one of three lanes: **Ask** (full `❓`/`➡️` treatment, and the round waits), **Notify** (one `🔎 Decided on your behalf:` line, no response required), or **Silent** (nothing in-flight). Trivia is *not* reported as it happens: listing it for the user to check merely trades a questioning burden for a reporting burden.
  - *Annoyed* topics are named explicitly and always asked: schema/migrations/data model, wire formats and external contracts, auth/permissions/PII, anything costing money or moving scope, user-visible behaviour, and **conflicting** in-repo precedent (two live patterns means the user picks the winner)
  - A claimed repo precedent must cite `path:line`. An uncited precedent is not a precedent and escalates to Notify or Ask
  - Bias is stated asymmetrically — **escalation is cheap, silence is expensive** — because silently deciding something important is a far worse failure than asking about something trivial. Notify is the release valve, so the Silent criteria never have to be perfect
  - Guards both directions: a round with zero questions that touched an *annoyed* topic is flagged as a routing smell, Notify is capped at ~3 per round (more than that means they were really Silent), and a user override forces a re-check of anything derived from it

### Changed

- **`crew-grill`**: the `~4 questions per round` cap is now explicitly a *budget* to spend on **depth rather than breadth** — sub-questions on the consequential fork and assumption-probing — on the grounds that trivia both consumes slots consequential questions need and trains the user to skim, degrading the answers to the questions that mattered
- **`crew-grill`**: the instruction "The *decisions* are the user's — put each one and wait" contradicted the new routing and was reworded rather than supplemented: "A decision with one dominant answer is not a decision — it is a fact lookup plus a default, and it is yours. Genuine forks are the user's: put each one and wait"
- **`crew-grill`**: the Phase 1 summary and the Phase 2 PRD handoff now carry Silent/Notify decisions tagged `(auto)`. Since these were never put to the user, `PRD.md`'s `## Decisions` section is the only place a reviewer or `crew-code-reviewer` can catch them

## [1.14.1] - 2026-08-08

### Fixed

All of the following were found by running the pi crew-afk pipeline end to end against a fresh
`git init` repo with no remote, no lint command and no typecheck command — the configuration under
which a sprint previously failed at every stage. Regression tests live in
`tests/workflow-integrity.bats`.

- **`feature-branch-setup.sh`**: `git symbolic-ref refs/remotes/origin/HEAD` exits 128 when a repo has no remote or an unset `origin/HEAD`. With `set -euo pipefail` and stderr suppressed, that aborted the script — and therefore `session-init.sh` — with **exit 128 and no output**. Failure is now swallowed explicitly so the `main` default applies. Affected both `crew-afk` and `solve-issue`
- **`crew-coder` (all platforms)**: the worker no longer closes its own issue. `solve-issue` step 7 moved the file to `issues/done/` before the orchestrator ran check verification, acceptance-criteria verification, and code review. A result later demoted to `partial` was then invisible to the next round (which lists only `issues/open/`), so the issue was never re-dispatched and its unmerged branch was silently orphaned. New **Issue Ownership** section in all four agent variants; `solve-issue` step 7 gains an explicit carve-out for orchestrated runs; dispatchers export `CREW_ORCHESTRATED=1`
- **`crew-afk` (all four variants)**: the schema pre-filter demoted any `complete` result whose report contained `not_run`, while `verify-worktree.sh` deliberately treats a missing lint/typecheck as a non-fatal coverage gap. Since `crew-coder` is *required* to report `not_run` for absent commands, every sprint in a repo without both lint and typecheck stalled at zero merges. The pre-filter now demotes on `fail`, or on `not_run` for the **test** category only, matching `verify-worktree.sh`
- **`squash-commits.sh`**: an issue with no `## What to build` section made `grep -v` filter everything out and return 1, killing the script under `pipefail` before the existing `-z "$TITLE"` slug fallback could run. The sprint ended with commits unsquashed and no error message. The fallback is now reachable
- **`session-init.sh` / `crew-afk` (all variants) / `squash-commits.sh`**: the feature slug was derived three incompatible ways (first issue's slug, branch basename minus `-NN-`, branch minus `feature/` and JIRA prefix). Running `/crew-afk` without a path argument created a second `.scratch/<first-issue-slug>/` tree and wrote sprint state, traces and `session-start-sha` there while the issues, PRD and dispatch files stayed in the real feature directory. `session-init.sh` now derives the slug from the issue path and records it as `.feature_slug` in `sprint-state.json`, which is the single source of truth everywhere downstream
- **`crew-coder` / `crew-code-reviewer` (pi)**: both pinned `model: sonnet`, a Claude alias. `dispatch-agent.sh` forwarded it as `pi --model sonnet`, which fuzzy-matched an inaccessible `amazon-bedrock` entry and killed **every** dispatch with `Validation error: The provided model identifier is invalid` and an empty report. Neither definition pins a model now, matching the policy `tests/model-policy.bats` already asserted for the reviewer
- **`crew-afk` (pi, codex)**: the per-branch reviewer dispatch omitted `$MODEL_FLAG`, so review ran on a different model than the sprint was asked to use — and, before the fix above, failed outright
- **`close-issue.sh`**: now idempotent. An issue already in `done/` is normalised and reported as `already closed` (exit 0) instead of aborting the orchestrator mid-pipeline
- **`crew-code-reviewer`**: only emits `## Session Review Summary` for multi-branch invocations. Per-branch dispatch (what `crew-afk` does) produced N duplicate "session" summaries, dependency audits and one-row totals tables in the appended report
- **`crew-coder` (all platforms)**: "Never write files outside `$PROJECT_ROOT`" contradicted the same file's requirement to write a trace log under `$MAIN_ROOT`. The rule now names its two exceptions
- **`verify-worktree.sh`**: pluralises `(2 categories not run)`

### Changed

- **`crew-coder` / `crew-code-reviewer` (pi)**: `tools:` no longer lists `grep`, `find` and `ls` — tool names carried over from the Claude definitions that the pi CLI does not provide. pi ignores unknown names silently, so the agents were being told they had capabilities they lacked
- **`dispatch-agent.sh`**: preflights the frontmatter `tools:` list against pi's tool registry and warns on unknown names, so the next cross-platform copy-paste is caught at dispatch time
- **`install.sh`**: warns when a user-level copy of `crew-afk`, `crew-coder`, `crew-code-reviewer` or `solve-issue` exists that may shadow the project install (pi resolves the user-level definition first, which makes a project install look like a no-op)

## [1.14.0] - 2026-08-07

### Added

- **New platform: `codex`** — `./install.sh codex` (and `bootstrap.sh codex`) installs skills to `.agents/skills/` (the repo/user location Codex actually scans) and agents to `.codex/agents/<name>.toml` (Codex's custom-agent format)
- **`crew-coder` / `crew-code-reviewer`**: `codex.agent.toml` definitions with `name`, `description`, `developer_instructions`, `model_reasoning_effort`, and `sandbox_mode` (`workspace-write` for the coder, `read-only` for the reviewer)
- **`crew-afk`**: `codex.SKILL.md` variant plus `scripts/dispatch-codex-agent.sh` — each worker runs as its own `codex exec` process pinned to the issue's worktree via `--cd`, with the report captured through `--output-last-message`; Codex's native subagents are deliberately not used for implementation because they share the parent's working root
- **`squash-commits.sh`**: `--platform codex` writes a Codex `Co-authored-by` trailer

### Changed

- **`install.sh`**: installing over existing files no longer prints a unified diff. A changed file is reported as a single `path (updated)` line; unchanged files are silent. This supersedes the diff-before-overwrite behaviour added in 1.0.0

### Fixed

- **`install.sh`**: skills that ship a platform-specific `SKILL.md` variant (`crew-afk` under `pi` and `codex`) no longer report `SKILL.md` as updated on every re-install. The variant is now resolved before the copy loop and written straight to `SKILL.md`, instead of copying the shared fallback and selecting the variant afterwards — which compared the incoming shared file against the previously installed variant and always saw a difference

## [1.13.1] - 2026-07-28

### Fixed

- **`uninstall.sh`**: read the manifest from `.coding-crew/manifest.json` (where `install.sh` writes it) instead of the legacy top-level `.coding-crew.manifest.json`, with a fallback to the legacy path for repos installed by older versions
- **`uninstall.sh`**: `.coding-crew/` is removed only when empty, so a customised `docs/issue-tracker.md` and the tracker templates survive an uninstall
- **`install.sh`**: `--update` now actually falls back to the legacy `.coding-crew.manifest.json` its error message already advertised, and reports the canonical manifest path when neither exists

## [1.13.0] - 2026-07-28

### Added

- **New platform: `pi`** — `./install.sh pi` (and `bootstrap.sh pi`) installs agents to `.pi/agents/` and skills to `.pi/skills/`, or `~/.pi/agent/{agents,skills}/` for a user-level install, which is where pi actually discovers them
- **`crew-coder` / `crew-code-reviewer`**: `pi.agent.md` definitions using pi's built-in tool names (`read`, `bash`, `edit`, `write`, `grep`, `find`, `ls`)
- **`crew-afk`**: `pi.SKILL.md` variant plus `scripts/dispatch-agent.sh` — pi has no native subagent tool, so each worker runs as its own `pi -p` process in the issue's worktree, with the agent definition supplying system prompt, tool allowlist, and model; reports are written to `.scratch/<slug>/dispatch/<slug>.report.md`
- **`verify-worktree.sh`**: check discovery now falls back to `AGENTS.md` when `CLAUDE.md` is absent
- **`install.sh` / `bootstrap.sh`**: `--version latest` resolves the newest published GitHub release before pinning, so `crew.lock` always records a concrete tag (never the moving `latest` alias)

### Fixed

- **`install.sh`**: agents are now deduplicated per platform, so a `platform=all` skill install writes the agent shims for every platform instead of only the first
- **`install.sh`**: SSH git remotes (`git@github.com:owner/repo.git`) are normalised to `https://` before being used for release lookups or written into `crew.lock`

## [1.8.0] - 2026-06-21

### Added

- **`crew-code-reviewer`**: Reads `.scratch/<feature-slug>/design.md` and `PRD.md` before per-branch review; documented architectural constraints (e.g. tracker abstraction rules) now inform finding severity and proposed fixes
- **`crew-address-findings`**: Step 1.5 loads `.scratch/<feature-slug>/design.md` and `PRD.md` before triage; findings whose proposed fix contradicts a documented design decision are classified Dismiss or Debatable
- **`crew-coder`**: Per-agent trace logging to `.scratch/<feature-slug>/traces/<branch>.log` with `[START]`, `[PHASE]`, `[CMD]`, `[READ]`, `[WRITE]`, `[DONE]` events
- **`crew-afk`**: Orchestrator trace logging to `.scratch/<feature-slug>/traces/orchestrator.log` with `[SESSION]`, `[ROUND]`, `[DISPATCH]`, `[RESULT]`, `[MERGE]`, `[EXIT]` events
- **`crew-afk`**: Coverage validation at exit now checks `issues/done/` (sibling of `issues/open/`)
- **`solve-issue`**: Reference test script `references/test-blocked-dep-path.sh`

### Changed

- **`crew-afk`**: Session SHA and sprint reviews now written under `.scratch/<feature-slug>/` (not `.scratch/` root)
- **`crew-afk`**: Step 5 Agent A delegates to `mark-done` operation from `issue-tracker.md` instead of hardcoding `sed` + `mv`
- **`crew-afk`**: `FEATURE_SLUG` derivation in orchestrator trace uses `sed 's|^feature/||'` + JIRA-strip, matching `session-init.sh`
- **`crew-afk`**: Issue Tracker Conventions blocked-issue description references tracker's `done` set abstractly (no hardcoded path)
- **`crew-afk`**: `session-init.sh` creates `issues/open/` instead of `issues/`, archives `traces/` dir as `traces-<timestamp>/`, writes `session-start-sha` under feature dir, removes `commands.log` handling, adds `.gitignore` safety warning
- **`crew-address-findings`**: Auto-detect scans `.scratch/*/reviews/*.md` grouped by feature; auto-selects when single result; moves report to feature-scoped `reviews/done/` on completion
- **`solve-issue`**: Blocked dependency check uses `$(dirname "$ISSUE_PATH")/../done/` for the `issues/open/` layout
- **`crew-brainstorm`**: Explicit do-not-commit guard for `design.md` (`git add -f` named as anti-pattern)
- **`to-prd`**: Explicit do-not-commit guard for `PRD.md` (`git add -f` named as anti-pattern)
- **`docs/agents/issue-tracker.md`** and **`docs/templates/trackers/local.md`**: `list` op greps `issues/open/*.md`; `mark-done` moves `open/` → `done/` as siblings; workspace layout diagram updated; both files kept in sync

### Fixed

- **`crew-coder`**: `commands.log` section removed from both `claude.agent.md` and `copilot.agent.md`

## [1.7.0] - 2026-06-21

### Added

- **to-issues**: Cross-cutting requirements extraction from design.md/PRD.md with automatic mapping to vertical slices
- **to-issues**: Context Documents section in issue template (references to design.md and PRD.md)
- **to-issues**: Cross-cutting Requirements section with checklist format for 10 requirement categories
- **to-issues**: Part of Flow section for multi-issue flow annotations
- **crew-coder**: Context document reading step that automatically reads design.md/PRD.md before implementation
- **solve-issue**: Step 1.5 "Validate Issue Context" to read context documents and validate cross-cutting requirements
- **crew-afk**: Coverage validation step at exit that compares design.md/PRD.md requirements against completed issues

### Changed

- **to-issues**: Enhanced issue template with optional sections (Context Documents, Cross-cutting Requirements, Part of Flow)
- **to-issues**: Extraction logic scans design.md for error handling, logging, security, performance, testing, architecture constraints, data validation, observability, interfaces & contracts, and multi-issue flows
- **to-issues**: Falls back to PRD.md Decisions section when design.md doesn't exist
- **crew-coder**: Structured output now includes both feature acceptance criteria and cross-cutting requirements
- **solve-issue**: Validation now checks both feature criteria and cross-cutting requirements before completion
- **crew-afk**: Summary format includes coverage report section before per-issue details

### Fixed

- **crew-afk**: JIRA prefix stripping in coverage-validation.sh now matches session-init.sh behavior
- **crew-coder**: Context reading instructions now explicitly specify using View/Read tools instead of bash comment placeholders
- **solve-issue**: Context reading instructions now explicitly specify using View/Read tools instead of bash comment placeholders

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [1.5.0] - 2026-06-20

### ⚠️ BREAKING CHANGES

**`crew-plan` renamed to `crew-grill`**

The skill has been renamed to better reflect its role as the grill/interview phase of the design pipeline. The new `crew-brainstorm` skill now serves as the full end-to-end design orchestrator.

| Old Name    | New Name     |
| ----------- | ------------ |
| `crew-plan` | `crew-grill` |

**Migration:** Uninstall and reinstall:

```bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/unbootstrap.sh | bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash
```

### Added

- **`crew-brainstorm` skill**: Full design pipeline — captures slug, explores context, conducts Q&A, proposes approaches, builds `design.md` section by section, then auto-transitions to `to-prd` and `to-issues`.

### Changed

- **`to-issues`**: Reads `design.md` from the feature workspace when present, feeding it as context for issue generation. Issue template gains an optional `## Interfaces` section. Skill version bumped to `1.2.0`.

---

## [1.4.0] - 2026-06-20

### ⚠️ BREAKING CHANGES

**`address-code-review` renamed to `crew-address-findings`**

The skill has been renamed to clarify its purpose (acts on the `crew-code-reviewer` report, not inline PR comments) and avoid confusion with `address-pr-comments`.

| Old Name              | New Name                |
| --------------------- | ----------------------- |
| `address-code-review` | `crew-address-findings` |

**`grill-me` and `grill-with-docs` removed**

Both skills have been removed and replaced by the new `domain-modeling` skill and an inlined grill loop inside `crew-plan`.

| Removed            | Replacement            |
| ------------------ | ---------------------- |
| `/grill-me`        | `/crew-plan`           |
| `/grill-with-docs` | `/crew-plan with docs` |

> Note: `crew-plan` was itself renamed to `crew-grill` in v1.5.0.

**Tracker install simplified to project-level only**

The `--user` flag and user-level tracker fallback path have been removed from `install.sh` and all skills. All tracker operations now target the project-level path only.

**Migration:** Uninstall and reinstall:

```bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/unbootstrap.sh | bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash
```

### Added

- **`domain-modeling` skill**: Extracted from `grill-with-docs`. Handles CONTEXT.md glossary and ADR updating behavior. Reference format files live under `skills/domain-modeling/references/`.

### Changed

- **`crew-plan`**: Inlines the grill interview loop directly; lite mode runs the grill only; `with docs` mode invokes the new `domain-modeling` skill.
- **`improve-codebase-architecture`**: Updated dep reference from `grill-with-docs` to `domain-modeling`.
- **`crew-afk`, `solve-issue`, `crew-address-findings`, `to-issues`, `to-prd`, `configure-tracker`**: Simplified tracker lookup to project-level only (no user-level fallback).

### Removed

- **`grill-me` skill**: Use `/crew-plan` instead.
- **`grill-with-docs` skill**: Use `/crew-plan with docs` instead.

---

## [1.3.0] - 2026-06-20

### Added

- **`configure-tracker` skill**: Interactive menu to select and install an issue tracker template. Presents available templates from `docs/templates/trackers/`, then writes the chosen template to `docs/agents/issue-tracker.md` in the target repo.

---

## [1.2.0] - 2026-06-17

### ⚠️ BREAKING CHANGES

**`crew-` prefix removed from skills (except `crew-afk` and `crew-plan`)**

Skills have been renamed to drop the `crew-` prefix. `crew-afk` and `crew-plan` are unchanged.

| Old Name                             | New Name                        |
| ------------------------------------ | ------------------------------- |
| `crew-karpathy-guidelines`           | `karpathy-guidelines`           |
| `crew-tdd`                           | `tdd`                           |
| `crew-dep-install`                   | `dep-install`                   |
| `crew-solve-issue`                   | `solve-issue`                   |
| `crew-address-code-review`           | `address-code-review`           |
| `crew-address-pr-comments`           | `address-pr-comments`           |
| `crew-improve-codebase-architecture` | `improve-codebase-architecture` |
| `crew-grill-me`                      | `grill-me`                      |
| `crew-grill-with-docs`               | `grill-with-docs`               |
| `crew-to-issues`                     | `to-issues`                     |
| `crew-to-prd`                        | `to-prd`                        |
| `crew-caveman`                       | `caveman`                       |

**Migration:** Uninstall and reinstall:

```bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/unbootstrap.sh | bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash
```

Install paths change accordingly: `.claude/skills/tdd/`, `.claude/skills/solve-issue/`, etc.

---

## [1.1.0] - 2026-06-16

### Added

- **`--version` flag for bootstrap**: `bash -s -- --version v1.0.0` pins the install to a specific GitHub release tag instead of always pulling `main`
- **Automatic doc updates in `crew-solve-issue`**: New Step 4.5 prompts the agent to update `README.md`, `CLAUDE.md`, or `docs/` when a change affects user-facing behavior, public API, or architecture. Purely internal changes skip the step.

---

## [1.0.0] - 2026-06-16

### ⚠️ BREAKING CHANGES

**Skill and agent names now use `crew-` namespace prefix**

All skills and agents have been renamed to prevent collisions when installed alongside other skill registries:

| Old Name                        | New Name                             |
| ------------------------------- | ------------------------------------ |
| `crew:afk`                      | `crew-afk`                           |
| `crew:plan`                     | `crew-plan`                          |
| `solve-issue`                   | `crew-solve-issue`                   |
| `address-code-review`           | `crew-address-code-review`           |
| `address-pr-comments`           | `crew-address-pr-comments`           |
| `tdd`                           | `crew-tdd`                           |
| `karpathy-guidelines`           | `crew-karpathy-guidelines`           |
| `dep-install`                   | `crew-dep-install`                   |
| `grill-me`                      | `crew-grill-me`                      |
| `grill-with-docs`               | `crew-grill-with-docs`               |
| `to-issues`                     | `crew-to-issues`                     |
| `to-prd`                        | `crew-to-prd`                        |
| `improve-codebase-architecture` | `crew-improve-codebase-architecture` |
| `caveman`                       | `crew-caveman`                       |
| `coder` (agent)                 | `crew-coder`                         |
| `code-reviewer` (agent)         | `crew-code-reviewer`                 |

**Migration:**

If you have existing skills installed, you must uninstall and reinstall:

```bash
# Uninstall old version
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/unbootstrap.sh | bash

# Install new version
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash
```

All skill invocations now use the `crew-` prefix:

- `/crew:afk` → `/crew-afk`
- `/crew:plan` → `/crew-plan`
- `/crew:solve-issue` → `/crew-solve-issue`
- etc.

Install destination directories also use the prefix: `.claude/skills/crew-afk/`, `.claude/skills/crew-tdd/`, etc.
Agent files also use the prefix: `.claude/agents/crew-coder.md`, `.claude/agents/crew-code-reviewer.md`.

### Added

- **Lockfile-based version pinning**: `install.sh --from-lockfile crew.lock` installs specific versions from a lockfile, enabling reproducible team distributions
- **Lockfile update command**: `install.sh --update` with an existing `crew.lock` checks for newer releases, upgrades, and rewrites the lockfile with updated versions
- **Diff-before-overwrite**: When installing over existing files, `install.sh` now prints a unified diff to show exactly what changed before overwriting
- **CI coverage**: Automated tests now run on macOS, Linux, and Windows (Git Bash)

### Changed

- `registry.json`: All skill and agent keys, install paths, and dependency references updated to use `crew-` prefix
- `install.sh`: Identifier validation updated for `crew-` style names
- `README.md`: All examples updated to use new skill and agent names
- `CLAUDE.md`: Documentation updated to reflect new naming convention

