# Changelog

Users install from `main` (`bootstrap.sh`), and `install.sh --update` follows each agent's and
skill's own `version` in `registry.json`. Tagged releases mark milestones only, not every merge.
Record changes under `[Unreleased]` and move them under a version heading when you cut a release.

## [Unreleased]

- `crew-afk`: `session-init.sh` no longer warns that `--jira` was ignored when the resumed or kept branch is
  already the one `--jira` would name (#301).
- `crew-afk`: the feature branch is named `<afk.branchPrefix><KEY>-<feature-slug>` — `afk.branchPrefix` in
  `config.json` (default `feature/`, `""` for none) and `--jira <KEY>`, which the explicit-slug path used to ignore;
  an invalid key or ref stops the run before any branch is made. The per-issue review prompt names the PRD on a
  `PRD:` line, and `open-pr.sh` writes `<!-- crew-afk:slug <slug> -->` into its block, so nothing derives the slug
  from the branch name. `feature-branch-setup.sh` is no longer installed (an `--update` removes it).
  `address-pr-comments`: a crew-afk PR is one with the crew-afk block; its slug comes from that marker (#300).
- `crew-afk`: the incremental feature review's prompt no longer tells the closing review that "an earlier run"
  reviewed up to its base — the base is the last feature review's tip, often from this same run (#297).
- `crew-afk`: a red integration check that turns an open PR back into a draft now rewrites its crew-afk block's
  `<!-- crew-afk:draft … -->` marker to name `integration`, so `/address-pr-comments` no longer reads a stale
  `findings`-only marker and suggests marking a red PR ready (#296).
- `crew-afk`: the feature reviewer answers Coverage and Correctness in two passes — it collects every candidate defect,
  unsure ones included, then verifies each before it becomes a finding, listing dropped ones under `### Dropped`. A
  report-only closing review covers what merged after the run's feature review (the fix issue, integration fixes) before
  the PR; its findings are posted to the PR and keep it a draft. A not-green PR's block names its draft reasons in a
  `<!-- crew-afk:draft <kinds> -->` marker (#294).
- `address-pr-comments`: on a crew-afk PR it pushes its fix commit (plain `git push`, never forced) once `solve-issue`'s
  checks pass, and prints `once CI is green: gh pr ready <n>` when findings were the PR's only draft reason and every
  posted finding was handled. Other PRs are still not pushed (#294).
- `crew-afk`: a feature review skipped because the integration check was red no longer uses up the run's one review —
  the next drain whose integration check passes runs it (#290).
- `crew-afk`: the feature review is one reviewer that reads the whole PRD, once per run (at the first drain that merged
  something, not again after Phase 2): no planner, no areas. It reports a PRD requirement the merged code does not implement,
  an unconnected multi-issue flow, or an unowned cross-cutting concern as a finding. The branch review checks acceptance
  criteria only (no `PRD decisions this issue implements:` block). `orchestrator/lib/prd.mjs`'s `prdPath` is the one PRD
  lookup, also used for the PR body; `eval-reviewer-misses` replays the single-reviewer prompt and drops `--max-areas` and
  `## Merged issues` (#287).
- `write-pr` / `crew-afk`: PR bodies are a short Why / What changes / Risk / **Tested:** note (no Evidence or Merge Danger);
  crew-afk adds its checks line only when the writer fails. Command discovery and the PR writer now record their cost, the
  summary's by-role line gains an `other` bucket so the roles sum to the run total, and unknown-cost dispatches read
  "stopped dispatch(es), cost unknown" (#289).
- `crew-afk`: the PRD audit is gone — the feature review checks PRD coverage. No audit dispatch, `prd-audit.md`, "Fix PRD
  gaps" issue or `## PRD Audit` summary section; `prd-audit.sh` and `promote-findings.sh defer-gaps` are removed. A config
  still setting `afk.PRDAudit`, or the old audit role under `afk.runtime`/`models`/`timeouts`/`limits`, and the
  `--prd-audit` flag load with one notice each instead of failing (#288).
- `eval-reviewer-misses`: a feature case's `## Merged issues` section gives each merged issue branch its `## Implements` IDs,
  so a decision the replayed planner leaves out goes to the area holding its issue's files, as in a sprint; filled in for
  `afk-effectiveness-feature` (#284).
- `eval-reviewer-misses`: a replayed feature case with 2+ areas now builds each area's prompt with the same `Other areas` block
  the sprint's feature review writes (one shared `areaReviewArgs` helper), and normalizes the planner's answer against the
  merged issues as `planAreas` does (#283).
- `crew-afk`: every PRD decision reaches a feature-review area, and each area sees the others. `parsePrdDecisions` reads any
  `- **<ID>**` line (`**D1**:` and `**D1** (auto):` were dropped); a decision the planner gives no area joins the area holding
  most of its issues' files, else the smallest; with 2+ areas each reviewer's prompt carries an `Other areas` reference block,
  and the reviewer reports a file in its area still relying on behaviour another area's decision changed. New replay case
  `afk-effectiveness-feature` for `eval-reviewer-misses.mjs` (#281).
- `crew-afk`: at run start (`preflight.mjs`'s `dropStaleRetained`, after the feature-branch sync), a retained-branch
  record is dropped and logged (`[RETAINED-DROPPED] slug=… — <why>`) when its issue is closed or no longer in the tracker
  (`listFeatureIssues`, `local` and `github` alike), or its branch no longer exists. A dropped record no longer counts
  toward `Partial`, `## Retained Branches`, the stall verdict or the PR's draft reasons. An open issue whose branch exists
  is kept; a failed or empty listing drops nothing; `--dry-run` only reports. New `state.sh drop-retained`, runnable by
  hand (#246; once, sprint `crew-afk-maintenance`: a shipped issue's record kept two runs `STALLED` and PR #244 a draft).
- `write-pr` (new skill): writes a PR title (what the change does, not a slug) and a body for a human reviewer, adapted
  from mattpocock/skills' `pr`: Summary (the smallest pseudocode, call tree, file tree, Mermaid diagram or diff-sketch
  that makes the change clear), Evidence (before/after) and Merge Danger (one-way or two-way door, blast radius). Run it
  by hand as `/write-pr`; crew-afk's `--open-pr` uses it too.
- `to-issues`: `lint-issues.sh`, a read-only checker for an issue set, installed at `.coding-crew/to-issues/scripts/`
  (see `crew-afk` and `to-issues` below for where it runs and what it checks).
- `crew-afk`: the roles are no longer agents. `crew-coder`, `crew-reviewer` and `crew-triage` leave `registry.json` (with
  crew-afk's `agent-deps`); their protocols live in `orchestrator/roles/{coder,reviewer,triage}.md` (reviewer checklists
  and scripts in `orchestrator/roles/reviewer/`), ship with the orchestrator to `.coding-crew/crew-afk/roles/`, and are
  rendered per dispatch (`{{FRAGMENT:…}}` expanded; a missing fragment fails the dispatch before spawning). No
  `.claude/agents/`, `.github/agents/`, `.pi/agents/` or `.codex/agents/` file is written or read. Installing crew-afk
  removes every file in the new `retired-agents` list (old per-platform agent files and shims, `.coding-crew/agents/`,
  `.coding-crew/code-review/`); `--update` of an install whose manifest lists agents installs crew-afk and drops them;
  `./install.sh <platform> crew-coder` installs crew-afk with a note. `dispatch-agent.sh`, `dispatch-codex-agent.sh` and
  the unused `references/test-*.sh` are deleted and removed from installs.
- `crew-afk`: every role, plain roles included (command finder, PRD auditor, PR writer), dispatches through its platform's adapter
  in `orchestrator/lib/adapters/`. claude: protocol via `--append-system-prompt-file`, coder `--disallowedTools Agent`,
  auto-memory off. pi: `--append-system-prompt`, the role's `--tools`, `--mode json` (final text and cost read from the
  event stream). codex: protocol and task on stdin (`codex exec … -`), the role's `-c model_reasoning_effort=…`; read-only
  and plain roles run sandboxed with only their result directory writable. A missing `pi`/`codex` CLI fails with exit 127
  naming it. Each argv string is checked against 128 KiB (and, on Windows, the command line against 32,767 characters)
  instead of being truncated.
- `crew-afk`: the four launchers render from one `SKILL.md` with `{{PLATFORM}}`; every platform's frontmatter pre-approves the shell
  (`allowed-tools: Bash, shell`).
- `crew-afk`: the coder's prompt ends with each named skill's installed SKILL.md path (`solve-issue`, `dep-install`, `tdd`); the
  report JSON is defined once, in the coder protocol. The coder reads the issue where the prompt points — a local file, or
  under `tracker: github` the `gh issue view` command it gives (it used to report `blocked` on every GitHub issue with no
  local copy).
- `crew-afk`: `doctor` runs each active platform CLI's `--help` (`codex exec --help` for codex) and reports a PROBLEM, exit 1, when a
  flag its adapter declares in `requiredFlags` is missing; a flag folded into brackets (`--append-system-prompt[-file]`)
  counts.
- `crew-afk`: script lookup also checks `CLAUDE_CONFIG_DIR`, `COPILOT_HOME`, `PI_CODING_AGENT_DIR`, `CODEX_HOME` (after the project
  install, before the `$HOME` defaults).
- `crew-afk`: process groups — every spawned child (a pane-hosted worker too) leads its own group; a timeout (`exec`, `bashAsync`,
  `spawnWithTimeout`) or SIGINT/SIGTERM/SIGHUP to the orchestrator kills the whole group, grandchildren included (exit
  124, or 128+signal: SIGHUP — terminal closed, SSH dropped — exits 129).
- `crew-afk`: run history — `state.sh run-end --reason <text> --code <n>` writes `last_exit {run, reason, code, at}` from every exit
  after `run-start` (finished, stalled, `attempt cap`, wall-clock cap, baseline red, a preflight stop, an error,
  `signal <SIG>`); `run-start` counts `runs`, keeps the previous `last_exit` as `previous_exit` (`unknown` for a state from
  a version that wrote none) and logs `previous run ended without an exit (killed or crashed)` when the last run wrote
  none. The summary prints `Run <n> for this feature; previous: <reason>`, and its Next Step names
  `/address-pr-comments <PR url>` when findings were posted to a PR (`/crew-address-findings` otherwise). Only a run's
  first `[MILESTONE-PUSH-SKIPPED]` is a warning.
- `crew-afk`: preflight runs `to-issues`' `lint-issues.sh` over the feature's open issues (with `issues-deps.json` / PRD when present,
  and each done issue as a `--known` file, written out under `tracker: github`) before command discovery or any worktree:
  an `ERROR` stops the run, quoting each line; `WARN` is logged; a linter that exits 2 or cannot run is logged without
  stopping; `--dry-run` only reports. The `to-issues` assets are a crew-afk dep, and a missing `lint-issues.sh` joins the
  missing-assets stop.
- `crew-afk`: a resumed feature branch that lacks `origin/<default>` (earlier work squash-merged) gets it merged in once per run,
  before the baseline (`sync-feature-branch.sh`). Registry-version / CHANGELOG-append conflicts are auto-resolved; any
  other conflict aborts the merge and stops the run. No `origin` or no fetch skips silently; `--no-sync-main` opts out,
  `--dry-run` only reports.
- `crew-afk`: `--poll-interval <seconds>` (default 30, `0` = off): idle slots poll the tracker for issues made ready mid-run (one
  listing per interval), lint them first and block a bad one for this run only.
- `crew-afk`: a red baseline kills the dispatches already running and stops workers still installing deps (`[BASELINE-RED]`), so the
  run exits 1 at once; their branches are kept, unverified, and retried by a coder next run (a free attempt). A red
  baseline is re-checked after a sync conflict dispatch returns.
- `crew-afk`: the wall-clock cap counts as hit only when it left an issue unclaimed or a fix issue parked (a run that finished
  everything after minute 120 is green); a hit exits 2 even when the attempt cap also ended the run. Past the cap or a red
  baseline the poller lists the tracker no more.
- `crew-afk`, `add-tests`: command discovery reads `README.md` (after `Makefile`, before the manifests) and asks for tools through the runner
  their install leaves them under: `uv run` with a `uv.lock` (else `poetry run` with a `poetry.lock`), `vendor/bin/` with
  a `composer.json` (also `add-tests`). Bare `pytest` / `ruff` / `mypy` left the first demo sprint's baseline red.
- `crew-afk`: a worker's `verify-worktree.sh` and per-worktree `ensure-deps.sh` run asynchronously, so branches verify concurrently;
  merge and close stay blocking and serialized; timeouts still map to exit 124.
- `crew-afk`: a verify ended by a signal (not its own timeout) is *interrupted*, not failed: no triage, no coder, re-verified next
  round for free. Output naming no failing check is run a second time before triage; if still empty the issue is
  re-verified next round, never recoded. A verify that ran with uncommitted files in the worktree no longer caches its
  tree as passing (`[TREE-NOT-CACHED]`).
- `crew-afk`: `resolve-merge-conflicts.sh` (new): a merge whose only conflicts are `registry.json` entry `version`s (higher semver
  kept) and `CHANGELOG.md` entries both sides appended (both kept, feature side first; `--head-is-branch` labels
  decisions by side) is completed and each decision printed and traced (`[SYNC-AUTO-RESOLVED]`), so no coder is
  redispatched. Any other conflict still aborts. Used by `merge-branches.sh`, `sync-feature-branch.sh` and a retained
  branch's sync.
- `crew-afk`: a retained branch's sync conflict that script cannot resolve gets its own conflict-only coder dispatch (recorded under
  a `conflict` role, never resumed as the coder's session), outside the retry and dispatch caps, judged from git: no
  `MERGE_HEAD`, no unmerged paths, and HEAD containing the feature-branch commit the sync merge started from (not the live
  ref a sibling may have moved since, #269). The original route then runs with a prompt that has no conflict text.
- `crew-afk`: a retry of a retained branch re-reads an issue a human edited since: `state.sh retain` records a fingerprint of
  `## What to build` and `## Acceptance criteria` (checkbox marks normalised; crew-afk's own writes excluded), and a
  different one at resume turns `fix` / `verify` into `restart` (`workerPrompt` on the retained branch). `merge` and a
  record without a fingerprint are unchanged.
- `crew-afk`: a coder's `[DEVIATION]` (its trace shows the `dev-commands.json` `test` command run in full, also inside a subshell or
  a quoted `bash -lc '…'`) is logged and listed under `## Deviations` in the summary; the issue is not failed. crew-afk
  sets `CREW_BASE_REF` to the feature branch for `run-checks.sh --targeted` (see `solve-issue`).
- `crew-afk`: the read-only guard snapshots every `crew/<feature>/*` ref, the feature branch, `HEAD` and the main checkout's
  uncommitted changes around every reviewer and triage dispatch. A move is excused only when the orchestrator's own git
  could have made it (a merge moving the feature branch or `HEAD`, a branch-moving git or worktree activity for a crew
  branch; worktree paths compared by realpath; `resolve-merge-conflicts.sh` in a worktree is not a main-checkout move). A
  violated dispatch's cost is still recorded.
- `crew-afk`: per-branch review is a criteria-and-PRD-decisions gate with no findings: `reviewer.md`'s per-branch mode and
  `reviewPrompt` ask for `findings: []`, and the orchestrator drops any a branch report still carries, so no branch gets
  its own fix issue (an `unmet` verdict still returns the branch to its coder). The prompt carries a
  `PRD decisions this issue implements:` block (the PRD's `- **D<n>** —` / `- **B<n>** —` lines for the issue's
  `## Implements`; PRD from `.scratch/<slug>/PRD.md`, else fetched once per run under `tracker: github`, else
  `prd-issue.md`); a contradicted decision is `unmet`, `detail` naming its ID. Per-branch promotion and
  `promote-findings.sh guard` are removed. Open branch findings an earlier version left in a `sprint-review-*.md` report
  are carried into the branch's new block (`"carried": true`, `criteria_only: true`, also past a `not_run` block), still
  listed by `promote-findings.sh open`, `post-findings.sh` (as `(earlier review)`) and the summary, and never promoted.
- `crew-afk`: the feature review covers the whole feature (merge-base with origin's default branch, else the local one), then only
  commits added since its last review (`feature_review.reviewed_tip`, `state.sh feature-reviewed`); an unchanged tip
  dispatches no reviewer, and the wall-clock cap with a claimable issue left skips it. A whole-feature review is split by
  a planner into up to `maxParallel` areas, each read by its own concurrent reviewer given an `Area:` block of its files
  and its PRD decisions' full text; findings join one `feature` block and are promoted once. A failed planner gives one
  whole-diff area; a failed area is recorded not-run as `feature-<n>`, and a later feature review closes an earlier
  run's not-run area. An incremental review stays one reviewer.
- `crew-afk`: a feature gets one findings fix issue (`feature_review.promotions` in `sprint-state.json`, counted per feature across
  runs, advanced only when a fix issue was created; an earlier version's 2 reads as capped). It holds the 8 most severe
  promotable findings (`criteriaFile` sorts CRITICAL→LOW for every caller); the rest, and a `duplicate_of` target at a
  report-only drain, are marked `report_only` and stay open, so the run is not green. `--fix-findings medium` keeps LOW
  findings out of fix issues.
- `crew-afk`: the reviewer protocol opens with the goal-first question (does the change do what the issue and PRD intend, and what
  does it break, wherever that code lives), puts unchanged code whose correctness the change affects in scope at any
  severity, reads callers, callees and the state the change touches, and gains a HIGH class, *second reader of the same
  input* (new code parsing an input existing code already interprets is compared with it). In feature mode it applies
  the design standard's criteria 2–4: a design-only finding is LOW, cites `file:line`, is prefixed
  `Design standard (criterion <n>):`, and never makes a criterion unmet.
- `crew-afk`: every finding carries `issue` (what is wrong) beside `criterion` (what the fix must achieve); triage sees `issue` first,
  and `post-findings.sh` posts `issue`, `criterion`, triage's verdict and rationale (the separate "Dismissed by triage"
  section is gone; a finding posted under the old format is not posted again).
- `crew-afk`, `crew-address-findings`: crew-afk's findings triage answers only `actionable` or `debatable` (a `dismiss` is recorded as `actionable`; ADR /
  protected-path rules still force Debatable); `/crew-address-findings` keeps all three. The rubric gains two hard rules:
  a finding based only on the design standard is Debatable, and so is one whose failure needs an input or state no
  current caller, user or documented contract produces ("Necessary").
- `crew-afk`: the `fixFindings` level → severities is resolved only in `orchestrator/lib/report.mjs` and passed to
  `promote-findings.sh defer` as the required `--severities`; the script's level table and `policy` subcommand are gone
  (`crew-summary.sh` takes `--promoted <list>`), and `CREW_PROMOTE` is no longer read.
- `crew-afk`: under `tracker: github`, fix issues carry their evidence instead of a pointer to a gitignored report: `defer` embeds
  each promoted finding's reviewer text under `## Review findings` (none of the `report_only` ones), `defer-gaps` the
  audit's per-requirement evidence, `defer-integration` the failing output's tail. `Source:` names the kind
  (`review (<branch>)`, `PRD audit (prd-audit)`, `integration check (integration)`); absolute and `.scratch/` paths are
  scrubbed. Each `## Promoted Findings` marker ends with its count (`→ <ref> (<n> finding(s))`, also in the `PROMOTE`
  trace), so the summary renders a github fix issue with no network call.
- `crew-afk`: the PRD audit no longer waits on open fix issues (any with a `Source:` line); an open work issue still skips it.
- `crew-afk`: with `--open-pr`, a `prWriter` role (default timeout 10 min) follows `write-pr` over the PR's whole range (merge-base
  with origin's default branch, the run's `base_sha` only when there is none) with the PRD and review report. Its body
  goes at the top of crew-afk's block, above a checks line from the integration check's record and the `Closes` lines.
  The PR takes the writer's title (else the PRD's, else the slug); an open PR still titled with the slug is renamed, a
  title a human set is kept. No `## Summary` from the writer still opens the PR, and the summary says why. `open-pr.sh`
  gains `--body-file` and `--title`.
- `crew-afk`: an integration-red run pushes nothing and opens no PR, but turns a PR an earlier run opened into a draft with the
  reason in its crew-afk block (`open-pr.sh --no-push`, draft state only). An issue blocked without a branch (a failing
  `## Requires`) is listed with its reason in the note (`state.sh blocked` records `blocked_reasons`). A repo that
  refuses drafts gets a ready PR, with `PR-STATE-FAILED:` naming why. Under `tracker: github` a fix issue created but not
  yet listed past the cap still counts as work left undone.
- `to-prd`, `crew-afk`: a PRD may carry `Origin: #<n>[, #<n>…]` under its `Actor:` line; `closingRefs` adds `Closes #n`
  for each when it adds the PRD's own, and `close-shipped.sh` closes each open origin issue in the run that closes the
  PRD.
- `crew-afk`: both tracker backends export `listFeatureIssues(mainRoot, { featureSlug })` (every issue in every state, one shape) and
  `fixIssuesCreatedReady`; the orchestrator reads issues only through them (`tests/orchestrator/tracker-boundary.test.mjs`).
  No behaviour change.
- `crew-grill`, `crew-brainstorm`, `to-issues`, `crew-afk`: one design standard, `skills/_shared/fragments/design-standard.md` (`{{FRAGMENT:design-standard}}`), rendered into
  `crew-grill`, `crew-brainstorm`, `to-issues` and the reviewer: four criteria in priority order (necessary > correct >
  reusable along real axes > fewest moving parts > says what it does), with failure signals and a guard against cutting
  structure the design needs now. Criterion 2 counts the axes of variation the project's `CLAUDE.md` names, else only two
  or more real callers or implementations now.
- `crew-grill`, `crew-brainstorm`: the design stays proportionate to the problem. The problem is sized first (how often,
  the manual workaround's cost, what breaks if nothing is done — looked up, not asked); every question deciding how much
  to build includes the do-least option, and a larger recommendation needs evidence it falls short and names the
  follow-on components it drags in. A subtraction pass before approval proposes cutting what nothing depends on;
  `crew-grill` carries the cuts into the PRD's Out of Scope. Sizing never replaces asking, and a stated requirement is
  priced, never relitigated.
- `to-prd`: each decision that changes existing behaviour records, as `path:line` facts, what relies on what it changes;
  `## Compatibility & Migration` names where existing data of a changed format lives. A decision line ending in
  `(no slice)` needs no issue.
- `to-issues`: merge by default — one slice for the whole PRD, split only for a named reason (context budget, human
  boundary, parallelism worth having, expand–contract order from `## Compatibility & Migration`). `Blocked by` edges come
  only from its two edge rows. A coverage table traces every PRD `D<n>`/`B<n>` to its slices; the quiz asks only about
  outliers (each split and edge with its reason, design-standard failures with `file:line`, uncovered IDs, HITL choices)
  then one approve/adjust prompt. A slice adding a parser, validator or gate for an input the repo already holds examples
  of carries a criterion that it accepts them, as committed fixtures. A criterion needing a paid run, a manual
  measurement or a person goes to the PRD's human steps or a `ready-for-human` issue.
- `to-issues`: `/to-issues <ref>` checks an existing issue against the design standard; one that stays one slice is
  rewritten in place (`gh issue edit` under `github`, the file under `local`, its column-0 `Source:` line kept), one that
  splits gets children. Auto-promoted fix issues (a column-0 `Source:` line outside a fence) are exempt. A missing
  `<feature-slug>` milestone is created first. `docs/guide.md` names it the `needs-triage → ready-for-agent` step.
- `to-issues`, `upgrade-deps`: a shared `human-issue` fragment defines the `## For a human` block (Kind A / Kind B,
  `Check:` / `Undo:` per step) for `ready-for-human` issues.
- `to-issues`: `lint-issues.sh` runs before any `publish` (an `ERROR` publishes nothing; under `tracker: github` existing milestone
  issues are passed as `--known`). `ERROR`: cycles, unmatched `## Blocked by` refs (resolved by basename, `--known`
  included; prose like `schema/API` and `_None_` / `—` placeholders are not refs), `--deps` drift, no acceptance
  criteria. `WARN`: more than 10 criteria; a `ready-for-human` issue missing `## For a human` or any of its five parts
  (and not asked for `## What to build` / `## Implements`); two issues naming the same file with no `Blocked by` path
  between them; a PRD ID no issue implements (a `--known` file's `## Implements` counts, `(no slice)` exempt).
- `solve-issue`: under `CREW_DEFER_FULL_CHECKS=1`, `run-checks.sh` runs `typecheck` and `lint`, and tests through
  `--targeted`: only the real test files the branch changed since `CREW_BASE_REF` (else the merge-base), and only those a
  suite argument they replace would have selected (`*`/`?`/`[…]` within a directory, `**/` across any number, a directory
  by what it holds). It reports `test: pass|fail (targeted)`, or `test: deferred (…)` when none is left or the runner
  takes no file arguments (`make`, `go`, `cargo`, `gradle`, `mvn`, …; seen through env assignments, `env`/`time` and
  `bundle exec`/`poetry run`-style wrappers). Other checks print `<key>: deferred …` for the verify gate. Each check's
  output reaches its log through a pipe, which fixes bats hanging on overlayfs (#266).
- `dep-install`: a Python project with no uv/poetry lockfile gets its dev tools installed, on the host and in docker
  (`python-install-cmd.sh`): `requirements.txt` adds `requirements-dev.txt` / `dev-requirements.txt` when present,
  `pyproject.toml` installs `'.[dev]'` and `--group dev` (pip ≥ 25.1) when defined; both dev files count toward the
  reinstall fingerprint (#273).
- `address-pr-comments`: on a crew-afk PR, each accepted and fixed comment (not crew-afk's own `crew-finding:` ones) is
  appended to `.scratch/<slug>/reviews/escaped.md` as a defect crew-afk's review let through; a failed write is reported
  and never stops the skill.
- `crew-address-findings`: the `## Promoted Findings` line format names the optional trailing ` (<n> finding(s))` count.
- install: shared fragments live flat at `skills/_shared/fragments/<key>.md` (the `common/`, per-platform and skill-local
  `fragments/<platform>/` lookups are gone), installed as a registry `more-assets` entry that install, uninstall and the
  version gate all see. Installing removes the old fragment directories.
- install: any install removes the retired agent files on every platform. `uninstall.sh --agent` / `unbootstrap.sh --agent` are
  gone, and unknown `uninstall.sh` arguments are refused instead of removing everything.
- `scripts/tracker/mark-issue-done.sh` (and its `.coding-crew/scripts/` copy) is executable.
- `scripts/smoke-sprint.sh --demo` runs one sprint on a pinned outside demo repo (`scripts/smoke-sprint/demo/`), passing
  only when crew-afk exits 0, every issue is done and every `check` passes on `feature/<slug>`; it prints
  `crew-afk-version:` and `crew-afk-commit: <sha>` (`-dirty` when uncommitted), makes `--dir` absolute, and appends a
  row to `scripts/smoke-sprint/RESULTS.md`. `scripts/cut-release.sh` refuses to tag without `--demo-smoke <log>` (a
  clean demo PASS for HEAD's crew-afk version that HEAD descends from, nothing but `CHANGELOG.md` / `RESULTS.md` changed
  since) or `--no-demo-smoke "<reason>"`.
- `scripts/eval-reviewer-misses.mjs` replays the two bugs PR #208 shipped with against a base ref and the head, judged
  blind; escaped defects are `mode: feature` replays from `case-template.md`, and `RESULTS.md` gives the steps from an
  `escaped.md` line to a case.
- `scripts/eval-design-skills.mjs` renders `{{FRAGMENT:…}}` lines, writes every prompt on `--dry-run`, and gains a
  `slice` stage with a `to-issues` rubric and three replay cases.
- `CLAUDE.md` gains `## Axes of variation` and asks a crew-afk mechanism change to cite its incident count.
  `ORCHESTRATOR_PREFETCH=1` starts the node-suite prefetch only for a bats run that includes an orchestrator wrapper.

## [2.0.0]

First milestone release, with a new baseline. The 1.x line (v1.1.0–v1.29.157, plus untagged
1.30–1.38) was retired, so its history now lives only in git (`git log`).

### What ships

- **Platforms:** Claude Code, GitHub Copilot CLI, OpenAI Codex CLI and pi, installed by
  `bootstrap.sh` / `install.sh` and updated per entry with `--update`.
- **Planning:** `/crew-grill` and `/crew-brainstorm` → `/to-prd` → `/to-issues`, with local
  markdown issues or GitHub Issues (`/configure-tracker`).
- **`/crew-afk` sprint:** one `crew-coder` per issue, each in its own worktree. Every issue goes
  through deps → TDD → verify → `crew-reviewer` → acceptance-criteria gate → merge → close, with
  `crew-triage` deciding whether a failure gets a retry.
- **Feature-level gates:** an integration check on the merged feature branch, one review of the
  whole feature diff, a PRD audit, and actionable findings and fixable failures promoted into a
  Phase 2 fix pass.
- **GitHub tracker:** status labels, ticked criteria on close, and `Closes #n` lines (including
  the PRD once no work issue is left) in the PR that `--open-pr` opens.
- **Follow-up skills:** `/crew-address-findings`, `/solve-issue`, `/address-pr-comments`,
  `/add-tests`, `/upgrade-deps`, `/domain-modeling`, `tdd`, `dep-install`.
