# Changelog

Users install from `main` (`npx skills add` or `bootstrap.sh`), and `install.sh --update` reinstalls every skill its
manifest lists. Tagged releases mark milestones only, not every merge.
Record changes under `[Unreleased]` and move them under a version heading when you cut a release.

## [Unreleased]

## [2.3.4]

- crew-triage, crew-grill: crew-triage now reads the code an issue touches before judging it, and runs each failed
  check through crew-grill's "would a staff engineer be embarrassed to ask this?" test (now the shared
  `worth-asking` fragment): a check the code, the docs or the issue answers is re-judged with that evidence instead
  of posted, and each posted open question carries a `checked:` receipt. On amaysim-au/product-services#393 it had
  posted three questions the repo or the issue already answered. crew-grill's text is unchanged (#658).

## [2.3.3]

- solve-feature: `next` run after a stop no longer overwrites the stop's outcome line, so the Actions job and
  `crew-afk status` name the real cause (e.g. `land`'s failed `gh pr create`) instead of `nothing landed` (#654).
- solve-feature: a failed `gh pr create` in `land` now makes the issue ready again (committing and pushing a file
  tracker's reopen) and stops at step `pr`, quoting gh's reason and naming the "Allow GitHub Actions to create and
  approve pull requests" setting, so a plain re-run opens the PR; it used to leave the issue closed with no PR, which
  no re-run got past (#653).
- crew-solve-feature workflow, crew-triage (new), to-issues, to-prd: `run-agent` added by a write+ user to an issue
  with no `Feature:` line on it or its parent no longer fails the run: it triages the issue. The new crew-triage
  skill judges it complete enough, then to-issues (non-interactive, no approve prompt) and solve-feature build it to
  the usual draft PR; otherwise it comments `## Open questions`, @mentioning the label's sender and pointing at
  `/crew-grill #<n>`, and the run removes `run-agent` and passes as `triaged #<n>: needs-grill`. to-issues and to-prd
  gain a "Non-interactive run" rule; the install action adds crew-triage and to-issues. This is a paid run where the
  label used to fail (#650).

## [2.3.2]

- crew-review, solve-feature: the reviewer and the review fixer now run every project command through `run.sh`, as
  solve-issue's coder does, so in docker mode they see the dependencies installed in the container instead of a host
  with none; a reviewer had reported an installed private package as nonexistent and the fixer stubbed it (#643).

## [2.3.1]

- tracker: `known` leaves out a `wontfix` issue (github: closed as not planned; local: `Status: wontfix`), so a
  dropped issue no longer lands in solve-feature's review spec, where the reviewer counted its criteria unmet. The
  github tracker now reports such an issue as `wontfix` instead of `done`; as a `## Blocked by` entry it still
  resolves (#640).
- dep-install: a docker-mode install with no `install` command and several manifest directories now runs each
  directory's install; the commands were joined with a space instead of `&&`, so the next directory's `cd` became
  arguments to the first install (#639).
- solve-feature workflow: with `install_mode: docker`, the install step before the agent now runs the docker-mode
  install with `NPM_TOKEN`, so a repo with private npm packages runs in docker mode on GitHub Actions instead of
  stopping on its first checks; `docker-install.sh` gains `--skip-env` so `.env`, `registry_auth` and credential
  templates never run with the token (#637).
- solve-feature: before the review, a new `sync` step merges the default branch into the feature branch, gates the
  merge with the checks and pushes it, so a PR the run marks ready no longer conflicts with a main that moved during
  the run. A conflict goes to one fresh resolver subagent; the run stops only when it is left unresolved, or when the
  checks fail on the merged tree (#633).
- solve-feature: what a coder or the fixer says a person must do or decide (`coder.notes.md`, `pr-<n>.notes.md`)
  is posted on the PR as one comment each once its work is pushed, so it survives a stop, a re-run and a fresh
  Actions runner; before, it stayed in the coder's report and nobody saw it unless relayed by hand (#622).
- tracker (github): `next` dispatches, and `features` counts, a ready issue whose `## Blocked by` names an issue of
  another feature once that issue is closed or `awaiting-merge`; an open, missing or deleted one still holds it back.
  Before, a blocker outside the feature blocked for ever (#621).
- crew-afk: an orca run starts in its worktree's idle startup terminal instead of a second terminal beside it;
  when that terminal runs an agent or a person opened another, a new terminal is created as before (#623).
- docs: README's use-case table has a "Make one small change" row: ask your agent directly, or, for a PR the crew
  builds and reviews, `/to-issues <change>` → `/crew-afk <slug>` (#487). The add-tests and upgrade-deps rows are gone
  until those skills mature; both stay in the command list. The Actions row now reads "Let the crew build on GitHub
  Actions": answer yes to `/setup-coding-crew`'s Actions question, then label any issue of the feature `run-agent`. The README also states its prerequisites, names where the crew
  runs, and drops claims it overstated (an overnight run, test-first "always", a PRD from every grill).
- crew-afk: a dispatch on a feature whose run is still going is refused on every destination, not only local: a
  second herdr or orca dispatch no longer starts a concurrent run in the same worktree. `status` and `wait` report an
  orca/herdr run whose terminal closed without an outcome as ended instead of waiting for good, and a herdr run
  starts in its new workspace's idle startup pane instead of a second tab (#617).
- docs: the Actions section says the runner has only `ubuntu-latest`'s tools and Node, so a repo's `install` command
  installs any other toolchain it needs, and that a repo admin allows GitHub Actions to create pull requests (#624).

## [2.3.0]

### Highlights

- **solve-feature on Actions is one reusable, hardened workflow.** A repo keeps a short caller that names
  `.github/workflows/crew-solve-feature.yml` at a release tag, so a change reaches it by bumping that tag (Dependabot
  can), and the runner installs that release's skills instead of cloning `main`. Only a user with write access
  starts a run; comments from users without it never reach the agent; each job has its own permissions, the agent's
  step gets no OIDC request token, `NPM_TOKEN` or Copilot PAT, and outside actions are pinned by SHA. Claude Code
  can run on AWS Bedrock through OIDC, with no Anthropic secret (#613–#616).
- **Review rounds and re-runs on Actions.** A review on a solve-feature PR, by Copilot's reviewer or a user with
  write access, runs `/address-pr-comments` on it, which files the accepted comments as an issue of the feature and
  runs solve-feature on it; Copilot's review is requested once the PR is ready. A feature labelled `run-agent` re-runs
  when one of its `ready-for-human` issues is finished, and `run-agent` on any of its issues starts it (#547, #602,
  #603).
- **A stronger review.** crew-review runs commands, reproduces suspected defects, traces a replaced code path field
  by field, and keeps every judgement on the reviewer's model; the fixer judges each finding before acting on it
  instead of applying the reviewer's fix as given (#562, #563, #569, #580, #592, #596, #605).
- **One shared library skill.** The tracker, checks and git-workflow libraries install once, in `coding-crew-lib`,
  instead of a copy in every skill: a `claude` project install writes 65 files, not 248 (#611).
- **Try it before committing anything.** The dev commands file is read from the main checkout committed or not,
  defaults for `tracker` and `solveFeature.models` can live in a user-level `~/.coding-crew/config.json`, and a model
  is named by family (`opus`, `opus 5.5`), which each host maps to its own models (#571, #581, #583).

### Upgrading

- Re-install (`npx skills add …` again, or `install.sh --update`). An `npx skills add -s <name>` install needs
  `-s coding-crew-lib` too (#611).
- A repo running solve-feature on Actions: run `/setup-coding-crew redo actions` once. It replaces the full workflow
  copy with the caller pinned at `@v2.3.0`; the old copy reads `.solve-feature/` and now fails with "never finished"
  even when the session ran. Checks show as `run / slug` and `run / solve`, so a branch rule naming `solve` needs the
  new name. A private npm registry needs the `NPM_TOKEN` secret (a read-only token), passed only to the install step
  before the agent (#590, #614, #615).
- The working directories moved under `.coding-crew/`: `.scratch/` → `.coding-crew/scratch/`, `.solve-feature/` →
  `.coding-crew/solve-feature/`. With the local tracker, move your issues and repoint their PRD lines once, from the
  main checkout:
  `mkdir -p .coding-crew/scratch && cp -R .scratch/. .coding-crew/scratch/ && { [ -f .coding-crew/scratch/.gitignore ] || echo '*' > .coding-crew/scratch/.gitignore; } && rm -rf .scratch && find .coding-crew/scratch -name '*.md' -exec sed -i.bak 's#\.scratch/#.coding-crew/scratch/#g' {} + && find .coding-crew/scratch -name '*.md.bak' -delete`.
  Until you do, `features` prints nothing and `/solve-feature` finds no issue (your files are untouched) (#590).
- Run `/setup-coding-crew` once in each clone: it moves `.git/coding-crew/dev-commands.json` to the main checkout's
  `.coding-crew/dev-commands.json`, now the only location (#571). Then `/setup-coding-crew redo commands` if the file
  has `credential_target`, now `registry_auth` (#551).
- A repo that copied the `crew-rework` workflow: delete `.github/workflows/crew-rework.yml`, and optionally the
  `crew-rework` label and the `CREW_APP_ID` / `CREW_APP_PRIVATE_KEY` secrets (#554).

### Breaking

- address-pr-comments: `--auto` and the `crew-rework` GitHub Action are removed, with `fetch-review-threads.sh`,
  `push-rework.sh` and `reply-thread.sh`; review rounds on Actions replace them. On a solve-feature PR the skill no
  longer fixes and pushes itself: it files the accepted comments as one `ready-for-agent` issue and runs
  solve-feature on it (#554, #602).
- tracker: run outside a git repo without `--main-root`, the tracker CLI exits 2, naming the directory, instead of
  reading that directory as the project.
- checks: the dev commands field `credential_target` is renamed `registry_auth`, with no fallback; `run-checks.sh`
  runs only typecheck, lint, test, coverage and integration; the host install runs the file's `install` command and
  no longer probes the Makefile. `ensure-env.sh` and `docker-install.sh` no longer take `--registry-auth`, and a
  host install now runs `registry_auth` too. Removed: `gen-override.sh --dry-run`, `CREW_GIT_MOUNT`,
  `docker-install.sh --install-cmd`, `manifest-fingerprint.sh --max-depth`, `CREW_COMMANDS_REFRESH`,
  `CREW_CHECK_TAIL_LINES` (#551, #558).
- solve-issue: an issue's `## Requires` section is no longer read (an issue that has one stays valid); preflight no
  longer falls back to `.scratch/<slug>/PRD.md`, and it and `branch-safety-check.sh` reject unknown arguments
  (#553).
- install: Windows Git Bash is no longer supported; use WSL2 (#555).
- to-issues: `lint-issues.sh` is retired; `publish-issues` refuses a draft whose `deps.json` differs from its
  `## Blocked by`. The local tracker reads blockers from `issues-deps.json` only, so a `## Blocked by` edited by hand
  after publishing no longer changes dispatch (#552).

### Added

- `coding-crew-lib/scripts/tracker/pr-comments.mjs`: a PR's reviews, comments and threads with untrusted authors'
  removed, which address-pr-comments reads through; `fetch --comments` on the github tracker filters the same way.
  Issue and PR bodies are not filtered (#616).
- Bedrock on Actions: repo variables `CREW_CLAUDE_PROVIDER=bedrock`, `CREW_AWS_ROLE_ARN`, `CREW_AWS_REGION`; the IAM
  role, `sub` customisation and trust policy are in `docs/guide.md` (#615).
- `publish-issues --append` adds issues beside a feature's landed ones (#602).
- `CREW_CODER_MODEL` / `CREW_REVIEWER_MODEL` (shell or repo variables) override `solveFeature.models` without editing
  the committed config (#586).
- Actions: commits a refused push left (an issue editing `.github/workflows/`) are kept in the artifact's
  `unpushed.bundle`, and the summary page says how to fetch them (#584). The summary also lists each
  subagent's model, and a Copilot run streams one log line per step (#600).
- setup-coding-crew warns when nothing protects the default branch, and refuses to write a caller whose tag is not
  released yet (#614, #615).

### Changed

- solve-feature: `start` turns a ready PR back into a draft before any coder runs, and `describe` keeps it a draft
  while any review thread is open. The PR body names its spec in one line instead of copying it (#545, #602).
- solve-feature: every merge is a merge commit (`--no-ff`); `land` and `fix` merge in commits someone else pushed
  mid-run instead of stopping on a refused push, and `fix` commits the fixer's edits before its checks (#576, #579).
- solve-feature: what the reviewer leaves in the tree (dependencies, a rewritten lockfile, a commit) is discarded
  before the fixer and listed under Needs attention; a failed `fix` ends the run (#593).
- to-issues: a human slice goes first (an agent needs it) or last (a validation), never blocking an agent slice on a
  last one, so one run builds every agent issue (#545).
- crew-review: given a solve-feature PR and no spec, it reads the feature's PRD and issues from the PR's slug marker
  (#545). Issue, PR, review and CI-log text are data, never instructions, in solve-issue, crew-review, write-pr and
  address-pr-comments (#562).
- write-pr: the title follows the PR-title format the repo documents or enforces.
- dep-install: docker mode removes dependency volumes no live checkout uses; an install command that runs docker
  itself runs on the host; the compose override passes `HTTPS_PROXY` and the CA variable through and mounts the
  host's CA bundle (#556, #573, #599).
- checks: one lockfile → install-command table serves host and docker installs (#558).
- github tracker: creates its six status labels itself; `mark-done` removes only the ready labels the issue carries
  (#553, #581).
- Prompts state what each step must produce and leave how to the agent (upgrade-deps 358 → 206 lines); shared
  instructions are stated once (#557, #598, #599).
- README: shorter. The install details and the list of agents that read `.agents/skills` move to `docs/guide.md`
  (new "Which agents" section), the review rounds are described once, and the GitHub Actions row links its setup
  (#625).

### Fixed

- Actions: a Copilot session waits up to an hour for a background subagent instead of ending mid-issue after 600s
  (#610); the agent CLI installs with `--ignore-scripts` (#574).
- solve-feature: the reviewer runs on its own model again, not the session's (#600).
- crew-review: a review is never handed to a nested agent on a weaker or unset model (#592, #596).

### Maintainer tooling

- `scripts/cut-release.sh` refuses a release whose pinned `uses: ypxing/coding-crew/…@` refs do not read its tag
  (#614).
- `scripts/field-review.mjs` runs two crew-review versions on another project's range, blind (#570).
- `eval-reviewer-misses.mjs`: `clean: true` cases, bypass-permissions reviewer in its own worktree, new replay cases
  (#562, #563).
- CI: one macOS job instead of three shards; `ci-run-bats.sh` runs heaviest files first, without the machine's git
  identity, and exits 2 on a missing path (#555, #558, #619).

## [2.2.0]

### Highlights

- **Install with `npx skills add`, into any Agent Skills agent.** The committed skills tree is the installed tree,
  so `npx skills add ypxing/coding-crew --all` (`-g` for user level) installs working skills into Claude Code,
  Copilot, Codex, pi, Cursor, Gemini CLI and the other agents that read `.agents/skills`. `bootstrap.sh` stays for
  pinned or offline installs (#536–#543).
- **One unattended path: `/solve-feature`.** It runs a feature's `ready-for-agent` issues in order on one branch,
  each by a fresh coder subagent gated by your checks, in one draft PR. It then reviews the whole feature against
  its spec, fixes the findings (a second round only after a critical, high or medium one), and marks the PR ready,
  or lists what needs you (#450, #463, #473, #475, #479, #497).
- **Runs inside the agent you already use.** No agent CLI is launched: the coders, reviewer and fixer are subagents
  of the session you started, on Claude Code, Copilot, Codex or pi alike (#473, #499).
- **`/crew-afk` starts a run and gets out of the way.** It starts `/solve-feature` in the feature's own worktree,
  locally (capped at 1 hour) or in an orca terminal or herdr pane, and returns. The session that started it reports
  how the run ended, with its cost; `/crew-afk status` lists every run (#485, #510, #520).
- **Set up once, optionally build on GitHub Actions.** `/setup-coding-crew` chooses the tracker and saves your
  check commands. With GitHub Issues it can also install a workflow that builds a feature when you label its root
  issue `run-agent`, on Copilot or Claude Code (#492, #509, #512, #518, #523, #527, #534).
- **A feature is one GitHub issue tree.** On the GitHub tracker a feature is its root issue (the PRD, or a
  one-slice feature's issue) plus that root's sub-issues; milestones are no longer used (#441).

### Upgrading

- Update with `install.sh --update` (`--project` for a project install), or switch to `npx skills add`. Run
  `--update` before any partial install (`--skill`, one platform of several, `uninstall.sh --skill`): those remove
  `.coding-crew/lib`, and the skills they leave alone stop with "re-install coding-crew" until updated (#538).
- Then delete what the update leaves behind, `<root>` being `~` or the repo:
  `rm -rf <root>/.coding-crew/{tracker,crew-afk,dep-install,solve-issue,to-issues,write-pr,skills,review-pr,solve-feature}`,
  plus the `crew-address-findings` and `review-pr` skill directories (#482, #483).
- GitHub tracker: a feature still filed under a milestone is invisible until moved; see "Moving off milestones"
  in the tracker's `docs/github.md` (#441).
- A copied Actions workflow: run `/setup-coding-crew redo actions`, and label root issues `run-agent` (#534).
- Delete the `afk` section of `.coding-crew/config.json`; it is no longer read. Models for the coder and reviewer
  go in `solveFeature.models.{coder,reviewer}` (#473, #482).

### Breaking

- install: `install.sh <platform>` installs at user level (`$HOME`) by default; `--project [<path>]` installs into
  a repo, and `uninstall.sh` takes the same flags (`uninstall.sh --user` is gone). Each skill carries its own
  `scripts/<lib>`; `.coding-crew/lib`, `.coding-crew/tracker/` and the per-skill script copies are gone (#483, #538).
- crew-afk: the old sprint program is removed: the orchestrator, sprints, the feature agent, `--open-pr`,
  `--platform` and the `crew-address-findings` skill. `/crew-afk <feature>` now starts a `/solve-feature` run, with
  the launch command written by the agent you run it in (#482, #485, #499).
- crew-review replaces crew-afk's reviewer. It only reports: it reviews a branch or PR against the spec you name
  and writes one JSON report (`spec`: `met|unmet|none`, `gaps`, `findings`), posting nothing (#479, #501).
- tracker: the `create-issue`, `feature-issues` and `link-blockers` ops and the `in-progress` label are gone;
  `mark-done` refuses (exit 4) an issue without `## Acceptance criteria` unless passed `--force` (#449, #482, #531).
- checks and dep-install: the install mode lives in the dev commands file (`install_mode`, `docker_service`);
  `git config agent.install-mode` is no longer read. `--main-root`, `run.sh --via`/`--describe`, `--targeted` and
  the sandbox CA and proxy passthrough are removed (#484, #488).

### Added

- `/solve-feature` (new): one feature's issues, one branch, one reviewed PR, as above. Every run ends with one line
  in `.solve-feature/outcome`: `ready pr=<n>`, `needs-attention pr=<n>` or `stopped: <what> failed: <reason>`.
  Works with a local or GitHub tracker (#450, #479, #501).
- `/crew-review` (new): a read-only review of a branch or PR against a spec, in a fresh subagent (#462, #479).
- `/setup-coding-crew` (new): tracker, check commands and the optional Actions workflow in one run; it prints the
  commit line and never commits. The workflow runs Copilot or Claude Code (`CREW_AGENT`, `CREW_MODEL`), streams the
  run into the job log, uploads `.solve-feature/` as an artifact, writes a summary page and starts the PR's CI
  (#492, #507, #512, #518, #523, #527).
- crew-afk: `--branch <name>` for repos whose branch rule refuses `feature/<slug>`, and runs report their cost and
  duration (`ready pr=7 cost=$1.73 (23 min)`) (#488, #510, #520).
- tracker: `next`, `tick`, `write-section`, `closing-refs` and `reopen` ops, on both backends (#450, #461, #470,
  #512).

### Changed

- The dev commands file no longer needs committing: discovered checks and install mode go to
  `.git/coding-crew/dev-commands.json`, shared by every worktree; a tracked `.coding-crew/dev-commands.json` still
  wins (#488).
- solve-issue: a subagent run is non-interactive, so unmet criteria end it `partial`; a `partial` or `blocked` run
  commits its work as `[WIP]`. It finds `PROJECT_ROOT` itself and reads a GitHub issue's `PRD: #<n>` (#473, #501).
- solve-feature: a re-run merges the default branch in first. A check or push that fails after an issue closed
  reopens it and pushes its commits, so a plain re-run picks it up. The PR body opens with a line saying
  solve-feature wrote it (#512, #515, #521, #525).
- to-issues sizes an issue as one implementer's work and splits only for size, a human boundary or
  expand–contract order; crew-grill and crew-brainstorm share one size test, and the local tracker keeps
  `.scratch/` out of git (#502).
- add-tests and upgrade-deps run only when a person invokes them, and run commands through the checks library like
  solve-issue (#503).
- Installing a skill brings the skills it invokes (to-issues brings to-prd and configure-tracker); every skill's
  description follows the Agent Skills authoring practice (#486, #504).
- `install.sh --update` reinstalls every platform installed into a root, not only the last (#488).
- Copilot runs with `--allow-all`, so a run's scripts under `~/.copilot/skills` are not denied (#511).

### Fixed

- tracker (local): in a worktree, `next` prints the issue's path in the main checkout, so the coder can close it.
- tracker (github): `publish-issues` right after `publish-prd` files under the new PRD instead of a second root;
  "Moving off milestones" moves closed issues too (#443, #445).
- crew-afk: `--to herdr` returns once it has typed the command instead of failing after 30s, and `wait` keeps a
  local run's cost (#488, #530).
- solve-feature: a `fix` re-run after you pushed by hand no longer reports "the fixer changed nothing" (#529).
- `branch-safety-check.sh` no longer exits 128 in a repo with no `origin/HEAD` (#486).

### Maintainer tooling

- The release smoke is `scripts/smoke-crew-afk.sh <platform> [--via install|npx]`, through `crew-afk.sh dispatch`;
  RESULTS.md records the route, and the run fails when a user-level skill would shadow the project install
  (#485, #488, #504, #537).
- SKILL.md bodies carry their fragments expanded in place (`bash scripts/render-skill.sh`), and each skill's
  `scripts/<lib>` is a committed link into `lib/`; a checkout needs symlink support (#537, #543).
- `registry.json` has no versions, so the version-bump rule is gone; `CHANGELOG.md` merges with git's `union`
  driver; `ci-run-bats.sh` fetches bats when none is installed (#483, #513, #516).
- This repo builds its own features on GitHub Actions with the setup-coding-crew workflow (#509, #519).

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
