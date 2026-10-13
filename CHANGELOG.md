# Changelog

Users install from `main` (`bootstrap.sh`), and `install.sh --update` follows each agent's and
skill's own `version` in `registry.json`. Tagged releases mark milestones only, not every merge.
Record changes under `[Unreleased]` and move them under a version heading when you cut a release.

## [Unreleased]

- **solve-issue**: a subagent run counts as non-interactive, so unmet criteria end it `partial` instead of a question
  nobody answers — what a solve-feature coder subagent now gets (#473).
- **solve-feature, review-pr**: no agent CLI is launched any more. Both skills run inside whichever host agent invoked
  them: each issue's coder and the reviewer are fresh subagents SKILL.md asks for, and the scripts keep only the guards
  as subcommands — `solve-feature.sh start|next|land` and `review-pr.sh prepare|post` (the old one-shot forms exit 2).
  `--agent`, `SOLVE_FEATURE_AGENT`, `--budget`, the 60/30-minute timeouts and `review-pr/scripts/agent.sh` are gone; put
  caps on your own launch line. Models come from `.coding-crew/config.json` `solveFeature.models.{coder,reviewer}`
  (crew-afk accepts the section and ignores it), no longer `afk.models`. The progress comment drops the final
  `REVIEW:` note (the review is on the PR). **A copied `hosts/github-actions.yml` must be copied again**: it now runs
  `copilot -p "Use the solve-feature skill on $SLUG"` and fails the job unless `review-pr.sh post` wrote
  `.solve-feature/reviewed`, so a stop or a session that ends early is red (#473).
- **solve-feature, tracker**: `closing-refs` is an op every tracker answers (local prints nothing), so the loop no
  longer reads `config` or tests for github: it adds `closing-refs`' lines to the PR body on any tracker. A ref `next`
  prints is checked only by `fetch` (the backend's own ref rule), and progress rows and stop messages show it as
  `next` printed it (`12`, not `#12`) (#470).
- **solve-feature**: leaner loop. No up-front dependency install (solve-issue already installs on demand) and no
  PR-body truncation (an over-limit body now fails `gh` loudly) (#471).
- **solve-feature**: the `Dockerfile` host recipe is gone (bring your own sandbox), and so is SKILL.md's "Where to run
  it" section; the pointer to `hosts/github-actions.yml` moved to the user guide's "solve-feature on GitHub Actions".
  SKILL.md keeps only what the agent acts on (launch, slug, where to run, how to relay a stop, flags); the loop's
  internals are in the script. A missing `timeout` now names the macOS fix (#469).
- **solve-feature, review-pr**: `--agent pi` and `--agent codex` join `claude` and `copilot`. `review-pr/scripts/agent.sh`
  is now the one owner of every agent-specific decision — `agent_known` (the agent list), `agent_cmd` (argv and
  `AGENT_STDIN_FILE`: codex reads its prompt from `<run>.<role>.codex-prompt.md` in `.solve-feature/`; the codex coder
  gets the git dir as a writable root, so it can commit in a plain clone too, and in a linked worktree the main
  checkout, so the local tracker can close the issue), `agent_coder_prompt`, `agent_model`
  (`afk.models.pi|codex.<role>`, no built-in default) and `agent_log_tail` (each agent's final text for the stop
  note) — so neither script spells an agent name. The codex reviewer runs sandboxed with `.solve-feature` as
  its one writable root; the Dockerfile installs all four CLIs (#466).
- **solve-feature**: hosts ship as recipe files under `.coding-crew/solve-feature/hosts/` — `github-actions.yml` (a
  workflow on the Copilot CLI, billed to GitHub Copilot: label the root issue `solve-feature` or dispatch it with the
  slug; copy it to `.github/workflows/`) and `Dockerfile` (claude and copilot CLIs, `gh`, docker CLI, coding-crew
  user-level) — and SKILL.md's "Where to run it" covers terminal, worktree pane, cloud Claude Code session (launch,
  don't host), GitHub Actions and docker (#464).
- **solve-feature**: each issue is coder → checks → the tracker's own close (no verifier; `verify-prompt.md` and the
  `roles/` tree are gone); `--agent claude|copilot` (`SOLVE_FEATURE_AGENT`) picks the coder; `next` selects issues on
  either tracker; dependencies are prepared headlessly before the first coder; the first landed issue pushes and opens
  a draft PR whose body carries the spec (PRD + each issue's criteria, cut at GitHub's body limit), progress is one
  comment on that PR, and the run ends by running `review-pr` on it. `--open-pr` is gone; a committed
  `.coding-crew/dev-commands.json` is required. `deps` now `solve-issue`, `dep-install`, `review-pr` (#463).
- **review-pr**: new skill — `/review-pr <n>` (`review-pr.sh <n> [--agent claude|copilot]`) runs one read-only agent
  over a checked-out PR's spec and diff, posts one review (inline where the finding is on the diff, the rest by
  severity, each marked `crew-finding:`), and runs `gh pr ready` when the spec is met with no CRITICAL/HIGH finding.
  `scripts/agent.sh` beside it owns the agent argv, coder prompt and model lookup for claude and copilot (#462).
- **address-pr-comments**: recognises a solve-feature PR (its `<!-- solve-feature:begin -->` block) for the push,
  escaped-record and summary steps; it never marks a PR ready and, on a solve-feature PR, ends with
  `next: /review-pr <n>` (#462).
- **tracker**: new `next --feature-slug <slug>` prints the ref of the next dispatchable issue — `ready-for-agent`, not
  `blocked`, every blocker done, lowest first — on both backends, or exits 3 with no output (#461).
- **tracker**: `features`' third column counts the issues dispatch would start now — `ready-for-agent`, not
  labelled `blocked`, every blocker done — instead of every open `ready-for-agent` issue, on both backends (#447).
- **solve-feature**: runs a one-slice feature, whose root issue is its only work issue, instead of finding nothing
  to do; an issue labelled `blocked` is skipped, as crew-afk skips it.
- **solve-feature**: the PR it opens (or the `gh pr create` it prints) is titled after the root issue, not the
  branch name `--fill` falls back to once the branch holds more than one commit.
- **tracker**: new `tick <ref>` checks every criterion off on either backend (a GitHub body has no file to edit), and
  `write-section <ref> --heading H --body-file F` records a section (the issue file locally, a comment on GitHub).
  `mark-done` on an issue already in `done/` now makes its `Status:` `done` in place (#450).
- **solve-issue**: Step 7 ticks through `tick` then `mark-done`, so a direct run closes a GitHub issue too; Step 8
  records `## Unmet criteria` through `write-section` (#450).
- **crew-afk**: `close-issue.sh` ticks and closes through the tracker CLI (`tick`, `mark-done --force`) on both
  backends instead of its own awk and `gh issue edit`; the local path now needs the issue under `.scratch/` (#450).
- **solve-feature** (new): `solve-feature.sh <slug>` runs one feature's `ready-for-agent` issues in order on one branch.
  After each `/solve-issue` coder run, the script itself runs the checks and then a fresh read-only verifier against
  the issue's criteria, and stops at the first failure with the log path. Progress is one comment on the feature's
  root issue, and the end prints (or, with `--open-pr`, opens) the PR. GitHub tracker only. Both `claude` processes
  run with `bypassPermissions`, so run it in a worktree, container or runner (#450).
- **tracker (github)**: `feature-issues` marks the root's entry `"root": true`, and the new `closing-refs` op prints the
  feature PR's `Closes #<n>` lines, the rule crew-afk's PR already uses (#450).
- **tracker**: `mark-done` now refuses, with exit 4, an issue whose body has no `## Acceptance criteria` section, on
  both backends; it used to close on the coder's say-so. Add the section, or pass `--force` (#449).
- **crew-afk**: `close-shipped.sh` and `issue-labels.sh sweep` run against a tracker CLI without `feature-issues` now
  name that CLI and say to run `install.sh --update`, instead of failing with `unknown op` (#445).
- **tracker (github)**: `publish-issues` run seconds after `publish-prd` now files under the PRD it created instead of
  making a second root: GitHub's issue list lags a new issue, so the issues past its newest are read by number (#445).
- **tracker (github)**: a crew-afk run scans the repo's issues for its feature's root once, not on every read, and
  `features` skips the sub-issue read of a feature whose root and sub-issues have all closed (#445).
- **tracker (github)**: `rewrite` of an issue that sits under an epic with no `Feature:` line now makes it the
  feature's root when the slug has none, its parent left as it is, instead of exiting 1 (#445).
- **tracker (github)**: "Moving off milestones" now moves every issue of the milestone, closed ones included, so an
  open issue whose blocker already closed is not left blocked after the move (#443).
- **tracker (github)**: a feature is now one root issue — the `PRD:` issue, or a single-slice feature's work issue —
  whose body carries a `Feature: <slug>` line, plus that root's sub-issues; nothing creates or reads a milestone, and
  the PRD is no longer pinned. Every issue crew-afk files (slices, promoted fix issues, integration fixes) is a
  sub-issue of the root, and a feature is read in full, past the old 30-issue cut (GitHub caps a root at 100
  sub-issues). New `feature-issues` op, which `close-shipped.sh` and `issue-labels.sh sweep` now read. **Hard switch:** after `install.sh --update`, a feature still filed under a
  milestone is invisible to crew-afk until you move it by hand — see "Moving off milestones" in
  `.coding-crew/tracker/docs/github.md` (#441).

## [2.1.0]

### Highlights

- **Run several features at once.** Each sprint works in its own `crew/<slug>/_feature` worktree and never switches
  your main checkout, so you can run one `crew-afk` per feature side by side, and uncommitted work in your checkout no
  longer blocks a run (#359, #364, #365).
- **A feature agent you can talk to.** Under orca or herdr, every sprint opens a live agent in its `_feature`
  worktree. Ask it what finished or what's stuck, and once the sprint ends it does your follow-up work in place
  (#385, #393–#397).
- **Small changes skip the ceremony.** `/crew-grill` and `/crew-brainstorm` send a request that's already one
  complete change straight to `/to-issues` with no Q&A, and `/to-issues` writes a PRD only when the work splits
  (#350, #354, #360).
- **Sharper reviews.** Each branch goes through a criteria-and-decisions gate. One reviewer then reads the whole
  feature against the PRD, side notes from per-branch reviews carry forward to it, and a closing review checks the
  fixes (#281–#297, #383, #390, #405).
- **Faster docker-mode installs.** Worktrees and sprints with the same lockfiles share one dependency install, and
  nothing is written into your repo's compose files (#379–#381).
- **Survives a flaky GitHub.** `gh` calls retry network and 5xx errors. A tracker listing that keeps failing ends
  the run cleanly with the reason, instead of crashing it (#396, #426).
- **Leaner agents.** On claude, each role starts with only the tools it needs, and per-role effort now reaches every
  platform's CLI (#355, #367, #428, #430).

### Breaking

- crew-afk: `--platform` is required for `run`/`plan`/`doctor` (`CREW_PLATFORM` and the `pi` default are gone);
  `squash-commits.sh --platform` is now `--co-author "<trailer>"` (#310).
- crew-afk: `.scratch/sprint.env` is gone. Running `state.sh`, `trace.sh`, `crew-summary.sh`,
  `ensure-deps.sh --slug` or `main.mjs status` by hand needs `--feature-slug`. A local-tracker run always uses
  `<prefix><slug>` as its feature branch (#359).
- crew-afk: the roles are no longer installable agents. `crew-coder`, `crew-reviewer` and `crew-triage` ship as
  protocols in `.coding-crew/crew-afk/roles/`, and installing crew-afk removes the old agent files.
- crew-afk: the PRD audit is gone because the feature review covers PRD coverage. `afk.PRDAudit` and
  `--prd-audit` load with a notice (#288).
- crew-afk: the watch agent and follow-up relay (`crew-afk followup …`, `afk.effort.watcher`) are replaced by the
  feature agent (#394, #395).
- dep-install: `run.sh --via nested`, `gen-override.sh --query git-env`/`--link-only` and
  `docker-install.sh --lock-timeout` are removed. After upgrading, the first sprint does one cold install. Remove old
  `wt_<proj>_<eco>_*` volumes by hand (#379, #380).
- tracker: the `repo:` override is removed, so `gh` always targets the git remote (#339, #340).
- tracker: `tracker-config.sh` and `mark-issue-done.sh` no longer ship. A `ready-for-human` issue is closed with
  `node .coding-crew/tracker/cli.mjs mark-done <n>`. `CREW_TRACKER_CLI` replaces `CREW_GITHUB_TRACKER_CLI` and
  `CREW_TRACKER_CONFIG` (#342).
- install: `uninstall.sh --agent` / `unbootstrap.sh --agent` are gone, and unknown `uninstall.sh` arguments are
  refused.

### Added

- `/write-pr` (new skill) writes a short PR title and body a reviewer can act on (Why, What changes, Risk, Tested).
  crew-afk's `--open-pr` uses it too (#289, #302).
- tracker: one CLI (`tracker/cli.mjs`) for every skill: `fetch`, `prd`, `known`, `config`, `features`,
  `publish-issues`, `publish-prd`, `rewrite`, `mark-done`. Node is now required by tracker-touching skills (#329–#342,
  #371).
- crew-afk: `--poll-interval <seconds>` (default 30) picks up issues made ready mid-run, and lints each one before it
  is claimed (#425, PR #438).
- crew-afk: `afk.branchPrefix` and `--jira <KEY>` name the feature branch `<prefix><KEY>-<slug>` (#300).
- crew-afk: run history. The summary says which run this is, why the last one ended and what to do next, and lists
  issues waiting on a person (#129).
- crew-afk: preflight lints the feature's issues and syncs a resumed branch with `origin/<default>`. Merge conflicts
  that touch only registry versions and CHANGELOG appends resolve themselves (#246).
- crew-afk: `afk.effort` sets coder, reviewer and triage effort per repo or user. The coder runs at `high` with a
  60-minute timeout (#367).
- `to-issues`: `lint-issues.sh` checks an issue set before publishing (cycles, dangling blockers, missing criteria,
  overlapping files). A builder check has a fresh agent list what a coder would still have to guess (#389, #400).
  `/to-issues <ref>` checks and rewrites an existing issue.
- `to-prd`: `Origin: #<n>` closes the origin issues along with the PRD (#317).
- Design standard shared by `crew-grill`, `crew-brainstorm`, `to-issues` and the reviewer. It reads your project's
  axes of variation from `CLAUDE.md` / `AGENTS.md`.
- `address-pr-comments`: on a crew-afk PR it pushes the fix and prints `gh pr ready <n>` when findings were the only
  reason the PR was a draft (#294).
- `dep-install`: Python projects without a uv/poetry lock get their dev tools installed (#273).

### Changed

- crew-afk: a new feature branch starts from what `origin` holds, so stale local commits stay out. A diverged branch,
  or an unreachable `origin`, stops the run at setup (#419, #420).
- crew-afk: under orca and herdr, every sprint tab lives in `_feature`, worktrees are named reliably, and a mid-turn
  feature agent still receives milestone pushes (#184, #418, #431, #433, #435).
- crew-afk: findings carry the issue they belong to. Each feature gets one fix issue holding the 8 most severe, and the
  rest are report-only. On the github tracker, fix issues embed their evidence.
- crew-afk: every platform goes through one adapter layer (`orchestrator/lib/adapters/`, `platforms.json`). Timeouts
  and signals kill a dispatch's whole process group, and verify and installs run in parallel (#309, #310).
- crew-afk: `--open-pr` on a branch with nothing merged says so instead of failing. An integration-red run turns an
  existing PR into a draft with the reason (#414).
- tdd: a red test must fail on its assertion. Tests for existing code get their red by breaking that code
  temporarily, so `add-tests` issues fit the loop (#357).
- solve-issue, tdd, to-issues: each rule is stated once in its owning skill, and solve-issue gains a comment rule
  (#406).
- `to-issues`: merges by default, traces every PRD decision in a coverage table, and quizzes only on outliers.
- install: platform list and destinations come from `orchestrator/platforms.json`. Every install removes files it no
  longer ships from installed skill directories (#308, #346).

### Fixed

- `grep -q` checks on multi-line values no longer fail at random under `pipefail`. Docker-mode checks no longer run
  on the host by mistake, and dependency volumes in use are no longer removed (#370, PR #382, PR #437).
- dep-install: two installs' `docker` shims on one `PATH` no longer exec each other forever, and the install lock works
  for non-root services (PR #382).
- tracker: on github, `rewrite` leaves exactly one triage label (#358). `publish-issues` refuses an unknown or
  about-to-be-deleted blocker (#332, #337). The milestone lookup paginates and reopens closed matches (#326).
- to-issues: a draft blocked only by an existing issue lints clean (#363).
- address-pr-comments: a crew-afk PR's slug comes only from its `<!-- crew-afk:slug -->` marker (#303).
- crew-afk: a red integration check keeps the PR's draft marker accurate, and a skipped review no longer uses up the
  run's one review (#290, #296).

### Maintainer tooling

- Tests: wording-only tests deleted (1,674 → 1,233 `@test`s), so editing a prompt no longer breaks the suite.
  `ci-run-bats.sh` starts the heaviest files first, and code comments are cut to the non-obvious why (#403, #404,
  #411, #416).
- `scripts/smoke-sprint.sh --demo` and `scripts/cut-release.sh` gate milestone releases on a demo sprint.
- `eval-reviewer-misses.mjs` replays escaped defects against base and head, now with each reviewer's real tools and
  effort. `eval-design-skills.mjs` gains `slice` and `prepublish` stages (#355, #383, #389).

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
