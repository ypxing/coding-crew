# Changelog

Users install from `main` (`bootstrap.sh`), and `install.sh --update` follows each agent's and
skill's own `version` in `registry.json`. Tagged releases mark milestones only, not every merge.
Record changes under `[Unreleased]` and move them under a version heading when you cut a release.

## [Unreleased]

### Changed

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
