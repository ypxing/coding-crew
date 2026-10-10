# Changelog

Users install from `main` (`bootstrap.sh`), and `install.sh --update` follows each agent's and
skill's own `version` in `registry.json`. Tagged releases mark milestones only, not every merge.
Record changes under `[Unreleased]` and move them under a version heading when you cut a release.

## [Unreleased]

### Changed

- crew-afk: fixes from the feature review of the feature agent (#397) — a `_feature` worktree with uncommitted changes is refused whatever branch or detached HEAD it is on (it used to be removed when it was not on the feature branch); herdr closes a workspace only when this run created it, never one `worktree open` found already open; a run that reuses or adopts the feature agent pushes it a run-start notice (the brief returns it to leaving the checkout alone until the end notice); `_feature` and the workspace are kept at the end only while the agent still reports live; the launcher's `CREW_AFK` lookup falls back to the main checkout's copy before `$HOME`, and the agent's brief names every sprint source under the main checkout with how to find it; the codex feature agent gets network and writable git dirs and main checkout, with approvals on
- crew-afk: under orca or herdr the sprint's watch agent becomes a feature agent in `crew/<slug>/_feature`, beside the log tab (orca `--worktree path:<_feature>`; herdr the feature worktree's workspace, never the triggering one). It is briefed by the rewritten `followup` role (the `watcher` role and `afk.effort.watcher` are gone; `afk.effort.followup` is accepted), leaves the checkout alone until the end notice, then does the developer's follow-up work in place with edit tools and permission prompts on. `_feature` and the agent's workspace are kept while the agent is live (a signal included); a clean `_feature` is reused and a dirty one refused with its files listed. A run launched from an agent pane inside `_feature` adopts that pane and takes `<slug>` from the path (a differing `--feature-slug` exits 1). With a live agent stdout ends with one pointer line (or the summary file when the end push was not sent) instead of streaming the summary (#395, PRD #393)
- crew-afk: removed the follow-up relay (`crew-afk followup start|wait|reply`, the `followup` worker role, the `_followup` worktree and the pane hosts' follow-up ops). The watch agent only reads and reports; run `/crew-address-findings` or `/address-pr-comments` yourself for follow-up work. No interactive role's argv turns off its CLI's permission or approval prompts any more, and `followup` is an unknown command (exit 2) (#394)
- crew-afk: the reviewer protocol says a decision-prescribed defect found in a per-branch review goes in `notes` (naming the decision or criterion it amends), never in `findings`; the per-branch prompt's JSON template no longer shows a filled-in note, and a note still holding the `<path>:<line>` / `<input or state → bad outcome>` placeholder is dropped before it reaches the feature review (#390)
- crew-afk: a per-issue reviewer's side notes (`notes: [{location, concern}]` in its report, recorded with the commit it reviewed) are listed to the feature review, which must keep each as a finding or drop it with a reason under `### Dropped`; the reviewer no longer downgrades or drops a defect because a PRD decision or criterion prescribes it, and reports it naming that decision; a run whose last feature review left no report is not green (its PR is a draft, `<!-- crew-afk:draft review -->`); `eval-reviewer-misses` gains `force-keeps-stamp` and `shim-mutual-exec` (PR #382's two escapes) and a `## Notes` case section (#383)
- crew-afk: a claude follow-up worker skips claude's one-time bypass-mode accept dialog, which stalled it on an account that had never accepted it; a run that takes the feature branch back from a clean `_followup` marks the open follow-up released, so `followup start` is no longer refused until `followup.json` is deleted by hand; herdr closes the tab or workspace of a watch agent whose `pane run` failed; `watcher.md` tells the watch agent to re-run a `followup wait` its shell tool cut off; on herdr, `followup start` waits for herdr to detect the freshly started worker instead of failing at once with `agent_not_found`; on orca, `followup start` passes the watch agent as `worker-start`'s `--from`, so it no longer fails `consumer_fenced` when run from any terminal but the watch agent's, and a failed orca call reports orca's JSON error instead of its `[relay-connect]` banner (PR #388)
- crew-afk: `followup start` and a later run's `_followup` release compare worktree paths by real path, so a repo reached through a symlink (macOS `/var` → `/private/var`) no longer misreads its own `_followup` as a worktree crew-afk did not make (PR #388)
- crew-afk: on herdr, `followup wait` after a reply no longer fails for good when the worker's TUI wrapped the echoed answer over several lines or a long turn scrolled the echo out of the 400-line read (PR #388)
- crew-afk: follow-up workers run unattended (claude `bypassPermissions`, copilot `--allow-all-tools`, codex network and git dirs writable, no approvals); `followup start` refuses a `_followup` with uncommitted changes instead of replacing it; the watch agent's env carries `CREW_PANE_HOST`; a failed host call deletes the launch `env.sh`; on herdr the spec is prompted after the brief's first turn ends and a reply's response is read only below the echoed answer (#387)
- crew-afk: `crew-afk followup start <slug> "<task>"`, `followup wait <id>` and `followup reply <id> "<answer>"` (orca or herdr; exit 1 with no host) let the watch agent ask for follow-up work (`/crew-address-findings`, `/address-pr-comments`) on a finished sprint. A worker agent, briefed by the new `followup` role, runs in `crew/<slug>/_followup` on the feature branch and answers over the host's own channel (orca `orchestration` run / worker / inbox / reply; herdr `agent prompt` / `wait` / `read` with a final `QUESTION:` or `DONE:` line). `start` refuses while a run or the feature lease holds the branch or a follow-up is open; a later run removes a clean `_followup` and refuses a dirty one (#386).
- crew-afk: under orca or herdr every sprint opens (or reuses) one interactive watch agent for its slug in the main checkout, and every milestone and the final push go to it instead of the pane that launched the run. It is the sprint's `--platform` CLI briefed by a new read-only `watcher` role, started with crew-afk's env (the `env.sh` worker terminals use), recorded in `.scratch/<slug>/watch.json` and never closed. Every platform adapter gains `interactive()`; `afk.effort.watcher` is accepted. A run also writes everything it printed to `.scratch/<slug>/traces/summary-<runId>.md`, which the final push names, and the launcher skill's step 2 is one instruction for every mode (no `PANE-HOST: orca` carve-out). Outside orca and herdr nothing changes (#385, PRD #384).

- dep-install, crew-afk, solve-issue, to-issues, address-pr-comments: a `grep -q` match on a multi-line value no longer fails at random. These checks piped the value into `grep -q` under `pipefail`; grep exiting at its first matching line killed the writer with SIGPIPE, and pipefail reported a miss. As a result `detect-service.sh` could miss the Makefile's service, and `cleanup-worktrees.sh` could remove a dependency volume a worktree still named. They now read here-strings, and a lint test rejects the pattern (PR #382).
- dep-install: the `docker` shim skips any other copy of itself when it looks for the real binary, so two installs' shims on one `PATH` (a shell exporting one, a sprint running another) no longer exec each other forever; and `docker-install.sh --force` with a host-run `--install-cmd` deletes the stamp before installing, so a failed forced reinstall no longer leaves the old stamp claiming the volume is installed (PR #382 review).
- dep-install: `docker-install.sh` opens the `/crew-state` volume (sticky, world-writable) in one root run before taking its install lock, so a service running as a non-root user can take it; a lock that cannot be created and has no holder now fails within the run with an error naming the lock path (exit 3) instead of busy-looping until the run cap, and a failed take-over of a stale lock sleeps before retrying (PR #382 review).
- dep-install, crew-afk: docker-mode fixes from the feature review (#381) — the install lock now lives in its own per-lockfile-hash `wt_<proj>_<owner4>_state_<lock8>` volume at `/crew-state`, so an install that empties `node_modules` (`npm ci`) no longer deletes it and lets a second run install concurrently; the `docker` shim also reads `COMPOSE_FILE` / `COMPOSE_PATH_SEPARATOR` from the project directory's `.env` (or `--env-file`) and picks up any default override file (`compose.override.*`, `docker-compose.override.*`); `verify-worktree.sh` writes a missing crew override in a docker-mode worktree, so it still installs and runs its checks in docker; `<lock8>` and the manifest scan both skip dot-directories (`.output/`, `.claude/worktrees`).
- dep-install, crew-afk: in docker mode the dependency volumes are named `wt_<proj>_<owner4>_<eco>_<dir>_<lock8>` — `<owner4>` from the host and `MAIN_ROOT`, `<lock8>` from every manifest and lockfile — and `docker-install.sh` installs into them only when the root volume lacks its `.crew-stamp`, under a `.crew-lock` inside the volume (a lock older than `--timeout` is taken over). Two worktrees or sprints with the same lockfiles share one install (`DEPS: docker-present`), a different lockfile gets its own, and nobody reinstalls into a volume another run is reading. Every `ensure-deps.sh --slug` call (issue, `_baseline`, `_integration`) installs; the `MAIN_ROOT` call only records `install_mode`/`docker_service`. A failed docker install is `DEPS: failed <cmd> (exit N) (see <sprint dir>/docker-install-<stem>.log)`, so a failed `_baseline` install ends the run `[BASELINE-RED]` — `DEPS: docker-failed` and its run-wide stop are gone, and so are `.scratch/docker-install.{done,fingerprint}` and `docker-install.sh`'s 30s lock and exit 4 (`--lock-timeout` is removed). `verify-worktree.sh` installs if missing before its first check (a `deps` check), and `cleanup-worktrees.sh` removes this owner's volumes no worktree's `crew-compose.override.yml` names. After upgrading, the first sprint does one cold install; remove old `wt_<proj>_<eco>_*` volumes by hand (#380).
- dep-install, crew-afk, solve-issue: in docker mode every `docker compose` call — crew's, a project recipe's (with or without `-f`, `COMPOSE_FILE` or `-p`), a coder's — loads its worktree's own override from `<git dir>/crew-compose.override.yml`, added by a `docker`/`docker-compose` shim that `run.sh`, `docker-install.sh` and every dispatched agent's `PATH` put first. No `docker-compose.override.yml` is written or linked into the repo any more, so a project's own is left alone; `ensure-deps.sh` deletes a generated one an older install left at the repo root. `run.sh --via nested` is `host`, `--describe` prints `OVERRIDE=`, `gen-override.sh --query git-env` and `--link-only` are gone, and an install command using `-f`/`COMPOSE_FILE`/`-p` is run instead of refused (#379).
- tracker: on github, `rewrite` makes its `--status` the issue's only triage label — it removes whichever of `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human` the issue carries (it used to remove only `needs-triage`, leaving two statuses), and exits 3 for a missing issue, 1 with gh's stderr on any other label-read failure (#358).
- dep-install: `run.sh` no longer pipes the mode verdict into `grep -q`, so a docker-mode check can't run on the host when the pipe closes early (it printed `write error: Broken pipe` and a false `TEST: pass`) (#370).
- to-prd: the reuse-a-listed-slug question is skipped when `to-issues` handed it the slug (already confirmed); six negated greps in `skills-tracker-cli-only`, `crew-coder-context-reading` and `human-issue-shared` bats tests now actually fail their test when they match (#374).
- tracker: a `features` op lists the tracker's features (`<slug>`, `open|closed`, ready-for-agent count; local: the `.scratch/<slug>/` directories with `issues/`, github: every milestone, open and closed), and `crew-afk`, `to-issues` and `to-prd` resolve a feature slug from it, so a github milestone is found instead of reported as having no issues; `to-prd` asks before reusing a listed slug. `add-tests` hands `to-issues` a transient `findings.md` instead of writing a `PRD.md`, no prompt names the local `issues/open` / `issues/done` layout (`tests/skills-tracker-cli-only.bats` checks it), and both tracker docs gain a "Reopen an issue" section. `.coding-crew/config.json` and `dev-commands.json` are documented as committed team state (#371).
- docs, evals: the guide's light-path paragraph and the design-skills eval (round-one instruction, `brainstorm-vague-ask` reference judgement) now say a failing check prints nothing about the light path (#372).
- crew-grill, crew-brainstorm: when a light-path check does not hold, the skill goes straight to its questions and prints nothing about the light path (it used to print a line naming the failed check) (#360).
- to-issues: `lint-issues.sh --deps` compares `deps.json` only with the `## Blocked by` edges between drafts, so a draft blocked by an existing (`--known`) issue lints clean with `[]` in `deps.json` (the form `publish-issues` requires), and a `deps.json` that still lists such an edge (a resumed sprint's does) lints clean too (#363).
- crew-afk: the coder runs at `high` effort and its default timeout is 60 minutes; `afk.effort` (role → effort, repo over user) sets coder, reviewer and triage effort, the startup print shows each with its origin; a coder killed on timeout keeps its context size in the cost ledger (#367).
- crew-afk: the orchestrator and every script resolve the same main checkout — inside a submodule the submodule's own checkout (never `.git/modules`), in a bare repo's worktree that worktree — through one rule (`scripts/main-root.sh`, `main.mjs` passes its `MAIN_ROOT` to every script); the feature lease points at a commit origin already has, so acquiring it no longer pushes the main checkout's unpushed commits (#365).
- crew-afk: a sprint's wrap-up cleanup sweeps only the `worktree-agent-*` / `.claude/worktrees/` worktrees inside its own `crew/<slug>/` worktree directory, so it no longer removes another sprint's or the main checkout's clean agent worktrees (#365).
- crew-afk: the feature-review fixes for concurrent sprints — `_feature` only displaces a crew-made worktree (a user's own worktree on `feature/<slug>` is a refusal); a run launched from a linked worktree resolves the main checkout; the behind-origin warning fires when the orchestrator creates the branch; `crew-summary.sh` and the guide resolve merge conflicts in a temporary worktree; `trace.sh --feature-slug` finds the main checkout from a linked worktree (#364).
- crew-afk: a sprint keeps its feature branch in its own `crew/<slug>/_feature` worktree and never switches the main
  checkout, so one `crew-afk` per feature can run at once in a repo. The worktree is removed when the run ends; the
  branch stays. Uncommitted changes in the main checkout no longer stop a run (`--allow-dirty` is accepted and does
  nothing); a main checkout sitting on `feature/<slug>` does, with "switch it to another branch". The per-issue
  reviewer, verify triage and PR writer run in `_feature`. Under orca every worktree is named to orca and its worker
  terminal is scoped to it; under herdr `_feature` is the sprint's workspace (#359).

### Breaking

- crew-afk: `.scratch/sprint.env` is no longer written, so hand runs of `state.sh`, `trace.sh`, `crew-summary.sh`,
  `ensure-deps.sh --slug` and `main.mjs status` need `--feature-slug` (exit 2 without). A local-tracker run started off
  the default branch no longer adopts the current branch as the feature branch; it always uses `<prefix><slug>` (#359).
- tracker: the `repo:` override is removed — `gh` always targets the git remote; a front matter naming `repo:` fails with
  "`repo` is no longer supported" (#339, #340).
- tracker: `.coding-crew/scripts/tracker-config.sh` and `mark-issue-done.sh` no longer ship (installs delete them). A
  `ready-for-human` issue's last step is now `node .coding-crew/tracker/cli.mjs mark-done <n>` (`~/.coding-crew/…` for a
  user-level install); older issues' `bash .coding-crew/scripts/mark-issue-done.sh <n>` step stops working.
  `CREW_TRACKER_CLI` replaces `CREW_GITHUB_TRACKER_CLI` and `CREW_TRACKER_CONFIG` (#342).
- crew-afk: `--platform` is required for `run`/`plan`/`doctor` (`CREW_PLATFORM` and the `pi` default are gone);
  `squash-commits.sh --platform` is replaced by `--co-author "<trailer>"` (#310).
- crew-afk: the PRD audit is gone — the feature review checks PRD coverage. `prd-audit.sh`, `promote-findings.sh
  defer-gaps` and the `## PRD Audit` section are removed; a config still setting `afk.PRDAudit` (or the audit role) or
  `--prd-audit` loads with one notice (#288).
- crew-afk: the roles are no longer agents — `crew-coder`, `crew-reviewer` and `crew-triage` leave `registry.json`; their
  protocols ship in `.coding-crew/crew-afk/roles/` and are rendered per dispatch. Installing crew-afk removes the old
  agent files (`retired-agents`); `./install.sh <platform> crew-coder` installs crew-afk with a note.
- install: `uninstall.sh --agent` / `unbootstrap.sh --agent` are gone, and unknown `uninstall.sh` arguments are refused
  instead of removing everything.

### Added

- `write-pr` (new skill): short PR title and body for a human reviewer — Why, What changes, Risk, Tested. Run as
  `/write-pr`; crew-afk's `--open-pr` uses it too (#289, #302).
- tracker: `tracker/cli.mjs` is the one CLI skills use. Read ops `fetch`, `prd`, `known`, `config`; write ops
  `publish-issues`, `publish-prd`, `rewrite`, `mark-done`. The backends move to a shared `tracker/` tree installed on every
  install to `.coding-crew/tracker/`. Node is now required by the tracker-touching skills (#329, #330, #339).
- crew-afk: `--poll-interval <seconds>` (default 30, `0` off) picks up issues made ready mid-run.
- crew-afk: `afk.branchPrefix` in `config.json` (default `feature/`) and `--jira <KEY>` name the feature branch
  `<prefix><KEY>-<slug>`; an invalid key stops the run before any branch is made. PR blocks carry
  `<!-- crew-afk:slug <slug> -->` (#300).
- crew-afk: run history — `state.sh run-end` records why each run exited; the summary prints
  `Run <n> for this feature; previous: <reason>` and a next step (`/address-pr-comments <PR url>` when findings were
  posted). A stalled run with `ready-for-human` issues prints `## Waiting on a person` (#129).
- crew-afk: `resolve-merge-conflicts.sh` auto-resolves merges whose only conflicts are `registry.json` versions and
  `CHANGELOG.md` appends; a retained branch's other sync conflicts get a conflict-only coder dispatch.
- crew-afk: preflight runs `lint-issues.sh` over the feature's open issues and stops on an `ERROR`; a resumed feature
  branch is synced with `origin/<default>` once per run (`--no-sync-main` opts out); stale retained-branch records are
  dropped (`state.sh drop-retained`, #246).
- crew-afk: `doctor` fails when a platform CLI lacks a flag its adapter requires; `[DEVIATION]` (coder ran the full test
  suite) is listed under `## Deviations`.
- `to-issues`: `lint-issues.sh`, a read-only issue-set checker, runs before any publish. `ERROR`: cycles, unmatched
  `## Blocked by`, `--deps` drift, no acceptance criteria. `WARN`: >10 criteria, malformed `## For a human`, two issues
  on the same file without a dependency path, a PRD ID no issue implements.
- `to-issues`: `/to-issues <ref>` checks an existing issue against the design standard and rewrites or splits it.
- `to-prd`: `Origin: #<n>` under `Actor:` makes crew-afk close the origin issues with the PRD; decisions record
  `path:line` facts for what they change, and "every/always/only/never" decisions name the easy-to-miss cases (#317).
- `crew-grill`, `crew-brainstorm`, `to-prd`: a verification pass re-checks cited counts, `path:line` and "nothing else
  does X" claims before the summary or publish. Designs stay proportionate: the problem is sized first and a do-least
  option is always offered.
- Design standard (`skills/_shared/fragments/design-standard.md`) shared by `crew-grill`, `crew-brainstorm`,
  `to-issues` and the reviewer: four criteria in priority order; axes of variation come from the project's `CLAUDE.md`.
  It, the reviewer's overrides, solve-issue's check lookup and to-issues' context budget also read `AGENTS.md`.
- `address-pr-comments`: on a crew-afk PR it pushes its fix commit and prints `gh pr ready <n>` when findings were the
  only draft reason; fixed comments are appended to `.scratch/<slug>/reviews/escaped.md` (#294).
- `dep-install`: Python projects without a uv/poetry lock get dev tools (`requirements-dev.txt`, `'.[dev]'`, `--group
  dev`) (#273).
- `solve-issue`: under `CREW_DEFER_FULL_CHECKS=1`, `run-checks.sh --targeted` runs only the test files the branch
  changed; other checks print `deferred` for the verify gate (#266).

### Changed

- tdd: a red test must fail on its assertion (an import or setup error is not red yet), and a test for code that already exists gets its red by temporarily breaking that code, so `add-tests` issues no longer conflict with tdd's failure-first rule; when such a test fails because the code contradicts its intended behaviour, tdd stops and solve-issue reports `blocked`. add-tests: each finding names the behaviours to cover and requires each new test to fail without its behaviour. (#357)
- crew-afk: on copilot and pi, each role's `effort` now reaches the CLI too (`--reasoning-effort` / `--thinking`: coder `medium`, reviewer and triage `high`), so every platform honours `ROLE_POLICY`'s effort; the command finder and PR writer still run at the CLI's default. (#355)
- crew-afk: on claude, each role's `effort` from `ROLE_POLICY` now reaches the CLI as `--effort` (coder `medium`, reviewer and triage `high`); before, only codex read it, so claude ran every role at the CLI's default effort. (#355)
- `eval-reviewer-misses`: `--effort <level>` and `--subagents` set the reviewer's effort and allow the Agent tool, so model, effort and sub-agent settings can be compared on the same cases; results record both. New case `lightweight-flow-feature` replays #355's first feature review and its three misses (`$TRACKER` undefined in crew-grill/crew-brainstorm, the eval harness's stale `close` stage and conflicting `round1` case). (#355)
- crew-afk: on claude, the reviewer and triage may now spawn sub-agents (no longer `--disallowedTools Agent`); whether to is the agent's call. The coder still may not. Other platforms were never restricted. (#355)
- crew-grill, crew-brainstorm, crew-afk: the light path's `node "$TRACKER" fetch` now works: both skills render the tracker-configuration lookup that sets `$TRACKER`, and a test fails any rendered skill that runs a tracker op without it. The reviewer's always-on Leftover references class now covers removed prompt steps and quoted phrases, and a new Undefined names in shared text class checks that a fragment's variables and terms are defined in every file it renders into. (#355)
- crew-afk, crew-grill, crew-brainstorm: the feature review still finds the intent issue after it is closed (moved to `done/`); the light path's "no fork" check states its own topics instead of citing a gate crew-brainstorm lacks; crew-brainstorm's HARD-GATE, anti-pattern section and flow allow the light path; both skills' registry descriptions name the hand-off to `to-issues`. (#354)
- crew-grill, crew-brainstorm, to-issues, crew-afk: a source that is already one complete change takes the light path: `/crew-grill` and `/crew-brainstorm` check it, print one `Light path:` line and hand off to `to-issues` without Q&A (a failing check runs the Q&A as before). `to-issues` alone decides on a PRD: one slice gets none and carries its own `## Decisions` (slug derived, shown in the quiz); two or more slices, or two or more origin issues, invoke `to-prd`. crew-brainstorm no longer asks for a slug. crew-afk's feature review reads the one issue with `## Decisions` as the intent when there is no PRD (`intent-issue.md` under github). (#350)
- crew-afk reviews: per-branch review is a criteria-and-PRD-decisions gate with no findings. The feature review is one
  reviewer reading the whole PRD, once per run (whole feature first, then only commits since its last review); a
  report-only closing review covers what merged after it, and its findings keep the PR a draft. The reviewer answers in
  two passes (collect, then verify) and starts from "does the change do what the issue and PRD intend" (#281–#297).
- crew-afk findings: each carries `issue` beside `criterion`; triage answers only `actionable` or `debatable`; a feature
  gets one fix issue holding the 8 most severe promotable findings, the rest stay open as `report_only`. Under
  `tracker: github`, fix issues embed their evidence. `fixFindings` resolves only in `orchestrator/lib/report.mjs`.
- crew-afk dispatch: every role goes through its platform adapter (`orchestrator/lib/adapters/`) with one `build()`,
  `normalize` event shape, `coAuthor` and `policyArgs`; platform facts come only from `orchestrator/platforms.json`.
  Argv over 128 KiB is rejected, not truncated; a missing `pi`/`codex` CLI exits 127. codex trace lines read
  `tool=shell` (#309, #310).
- crew-afk processes: every child leads its own process group; a timeout or SIGINT/SIGTERM/SIGHUP kills the whole group
  (exit 124, or 128+signal). Verify and dependency installs run asynchronously; merge and close stay serialized.
- crew-afk verify: a verify ended by a signal is *interrupted* (re-verified next round, no coder); empty failure output
  is re-run once; a tree verified with uncommitted files is not cached as passing.
- crew-afk baseline and caps: a red baseline kills running dispatches and exits 1 at once, keeping their branches; the
  wall-clock cap counts as hit only when it left work undone.
- crew-afk `--open-pr`: a `prWriter` role writes the PR body (title from the writer, else PRD, else slug); an
  integration-red run pushes nothing but turns an existing PR into a draft with the reason in its block.
- crew-afk coder prompt: ends with each named skill's installed `SKILL.md` path; under `tracker: github` it points at
  `gh issue view` (a GitHub issue with no local copy used to report `blocked`). The four launchers render from one
  `SKILL.md` with `{{PLATFORM}}`.
- crew-afk and `add-tests` command discovery read `README.md` and use `uv run` / `poetry run` / `vendor/bin/` per lockfile.
- `to-issues`: merge by default (one slice per PRD, split only for a named reason); a coverage table traces every PRD
  `D<n>`/`B<n>`; the quiz asks only about outliers. `ready-for-human` issues share a `human-issue` fragment with
  `upgrade-deps`, and end with a "Mark it done" step.
- skills reach the tracker only through the tracker CLI — no `gh` command or per-tracker branch is left; a shared
  `tracker-configuration` fragment finds the CLI (also from a linked worktree) and treats a CLI failure as something to
  fix, not work around (#331, #333). Tracker choice lives in `.coding-crew/config.json`'s `tracker` section (invalid is an
  error, never silent `local`); `configure-tracker` writes it, and install migrates a legacy `issue-tracker.md` (#339–#341).
- install: platform list and skill destinations come from `orchestrator/platforms.json` (`scripts/lib/platforms.sh`);
  `registry.json` skill entries drop `install*`/`body`/`platform-files`. Every skill's version moves, so the next
  `--update` reinstalls each once (#308). Fragments live flat at `skills/_shared/fragments/<key>.md`.
- install: every install removes files in installed skill and asset directories that the run did not write (printed as
  `<path> (removed)`), replacing the hand-kept retired-file lists. Files a user added there are removed too (#346).
- installer: `uninstall.sh` sweeps only legacy paths an earlier install wrote (#313).
- registry: skill descriptions say what each skill is for, not how it works (#319).
- tests: `scripts/ci-run-bats.sh tests/*.bats` runs one bats process per file (~6x faster); `ORCHESTRATOR_PREFETCH` is
  removed.

### Fixed

- tracker: `publish-issues` exits 1, publishing nothing, when a `## Blocked by` names an unknown file, or when
  `--replace` would delete an open blocker; under github, draft refs become `Issue #<n>` so the blocker is read (#332, #337).
- `crew-afk` (github): the milestone check paginates and includes closed milestones (past 30, the create failed with
  HTTP 422 and the fix issue was lost); a closed match is reopened (#326).
- `crew-afk`: a red integration check rewrites the PR's `crew-afk:draft` marker so `/address-pr-comments` no longer
  suggests marking a red PR ready (#296); a feature review skipped on a red integration check no longer uses up the
  run's one review (#290); the incremental review prompt no longer says "an earlier run" (#297);
  `session-init.sh` no longer warns about `--jira` when the branch already matches (#301).
- `to-issues`/`upgrade-deps`: the Kind A Undo text restores `ready-for-human`; `mark-issue-done.sh` no longer resets
  that label's colour (#304).
- `write-pr`: What changes names only files present in the `--stat` (#302).
- `crew-afk`: PRD decisions in `**D1**:` / `**D1** (auto):` form are read; `scripts/tracker/mark-issue-done.sh` is
  executable.

### Maintainer tooling

- `scripts/smoke-sprint.sh --demo` runs one sprint on a pinned demo repo and appends to `scripts/smoke-sprint/RESULTS.md`;
  `scripts/cut-release.sh` requires a passing demo smoke log or `--no-demo-smoke "<reason>"`.
- `scripts/eval-reviewer-misses.mjs` replays escaped defects against a base ref and head, judged blind (cases #283,
  #284, #281); `scripts/eval-design-skills.mjs` renders fragments and gains a `to-issues` `slice` stage.
- `CLAUDE.md` gains `## Axes of variation` and asks a crew-afk mechanism change to cite its incident count.

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
