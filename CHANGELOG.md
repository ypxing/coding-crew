# Changelog

Users install from `main` (`npx skills add` or `bootstrap.sh`), and `install.sh --update` reinstalls every skill its
manifest lists. Tagged releases mark milestones only, not every merge.
Record changes under `[Unreleased]` and move them under a version heading when you cut a release.

## [Unreleased]

### Upgrading

- install, all skills: the tracker, checks and git-workflow libraries are installed once, in a new `coding-crew-lib`
  skill, instead of a copy inside every skill: a `claude` project install writes 63 files, not 248. `install.sh`
  installs it with any skill and removes the old per-skill copies on reinstall; an `npx skills add -s <name>` install
  needs `-s coding-crew-lib` too, and a skill stops naming that command when it is missing. `uninstall.sh --skill
  coding-crew-lib` keeps it while an installed skill still needs it (#611).
- tracker, solve-feature, crew-afk: the working directories moved under `.coding-crew/`: `.scratch/` is now
  `.coding-crew/scratch/` and `.solve-feature/` is now `.coding-crew/solve-feature/`, each still self-ignored. With
  the local tracker, move your issues and repoint their PRD lines once, from the main checkout:
  `mkdir -p .coding-crew/scratch && cp -R .scratch/. .coding-crew/scratch/ && { [ -f .coding-crew/scratch/.gitignore ] || echo '*' > .coding-crew/scratch/.gitignore; } && rm -rf .scratch && find .coding-crew/scratch -name '*.md' -exec sed -i.bak 's#\.scratch/#.coding-crew/scratch/#g' {} + && find .coding-crew/scratch -name '*.md.bak' -delete`.
  Until you do, `features` prints nothing and `/solve-feature` finds no issue (your files are untouched). A
  committed solve-feature GitHub Actions workflow reads the old `.solve-feature/` and now fails with "never
  finished: the session ended early or never started" even though the session ran: run
  `/setup-coding-crew redo actions` to update it (#590).
- Run `/setup-coding-crew` once in each clone: it moves `.git/coding-crew/dev-commands.json`, where earlier
  versions saved discovered commands, to the main checkout's `.coding-crew/dev-commands.json`, now the only
  location; a clone that never re-runs setup rediscovers its commands (#571).
- Run `/setup-coding-crew redo commands` once: the dev commands file's `credential_target` is now `registry_auth`,
  and a file written before this keeps the old key, which nothing reads (#551).

### Breaking

- tracker: run outside a git repo without `--main-root`, the tracker CLI now exits 2, naming the directory, instead of
  reading that directory as the project; a coder that ran it from the skill's own directory got `tracker=local`,
  `configured=no` and then "invalid ref" on a github issue.
- checks: `ensure-env.sh` and `docker-install.sh` no longer take `--registry-auth` (formerly `--credential-target`);
  `ensure-env.sh` reads `registry_auth` from the dev commands file itself, so a host install now runs it too, after
  `.env` exists (#558).
- install: Windows Git Bash is no longer supported; use WSL2, as before. `install.sh`, `uninstall.sh` and
  `render-skill.sh` drop the CRLF `jq` wrappers and CR stripping, and `uninstall.sh` no longer retries an `rmdir` for
  Windows' lazy directory removal (#555).
- address-pr-comments: `--auto` and the `crew-rework` GitHub Action are removed, with `fetch-review-threads.sh`,
  `push-rework.sh` and `reply-thread.sh`; a repo that copied the workflow deletes `.github/workflows/crew-rework.yml`
  (it now fails on the unknown `--auto` flag), and may also delete the `crew-rework` label and the `CREW_APP_ID` /
  `CREW_APP_PRIVATE_KEY` secrets it set up for it. The skill no longer writes
  `.scratch/<slug>/reviews/escaped.md` (#554).
- checks: the dev commands field `credential_target` is renamed `registry_auth`, with no fallback read of the old
  name (see Upgrading) (#551).
- checks: `run-checks.sh` runs only the typecheck, lint, test, coverage and integration commands; any other key
  added by hand to the dev commands file is no longer run (#551).
- solve-issue: an issue's `## Requires` section is no longer read — preflight no longer runs its commands or
  stops with `BLOCKED: requires:`, `check-requires.sh` is gone, and to-issues no longer writes the section. An
  issue that still carries one stays valid and the section is ignored; nothing to migrate. Preflight also no longer
  falls back to `.scratch/<slug>/PRD.md` for an issue without a `- PRD:` line, and it and
  `branch-safety-check.sh` reject `--help` and any unknown argument (exit 2) (#553).

### Changed

- setup-coding-crew: the Actions workflow re-runs a feature labelled `run-agent` when one of its `ready-for-human`
  issues is finished (the label removed, as `mark-done` does, or the issue closed), so a run that stopped for a
  person no longer waits for a re-label; a feature run only locally, or whose root is closed, or an issue finished by
  someone without triage access, gets no run. `run-agent` on any issue of the feature now starts it (and labels the
  root) instead of failing the slug step. Run `/setup-coding-crew redo actions` to take it (#547).
- setup-coding-crew: the Actions workflow lets a Copilot session wait up to an hour for a background subagent
  (`COPILOT_TASK_WAIT_TIMEOUT_SECONDS`; by default Copilot gave up after 600s and ended the run mid-issue), and the
  repo variable `CODING_CREW_REF` picks the coding-crew branch or tag the runner installs. Run
  `/setup-coding-crew redo actions` to take both (#610).
- solve-feature: the fixer judges each review finding before acting on it instead of applying the reviewer's fix as
  given: it checks any tool or platform fact a fix rests on, adds no trigger, flag, permission, input or path the
  spec does not name, and lists a finding that is wrong, or that only a change to a spec decision fixes, for a person
  (#604's fixer added a workflow trigger its PRD had ruled out, and GitHub has no such trigger) (#605).
- setup-coding-crew: the solve-feature Actions workflow also runs on a review submitted on a solve-feature PR (a
  thread reply included, an approval not), by Copilot's reviewer or a user with write access, running `/address-pr-comments` on the
  PR non-interactively in the feature's concurrency group, where a newer run cancels a pending one (a round runs
  solve-feature whenever the feature has a ready issue, so a label run it displaced is not lost); such a round ends green with a notice when it ran no
  solve-feature or ended needs-attention. After a run ends ready on a PR Copilot has not reviewed, the job requests
  Copilot's review with the new optional `COPILOT_GITHUB_TOKEN` secret (a PAT with Pull requests: write), warning
  when it is unset or refused. Run `/setup-coding-crew redo actions` to take it (#603).
- solve-feature, address-pr-comments: `start` turns an open PR that is ready back into a draft before any coder
  runs, and `describe` leaves the PR a draft, listing `<k> unresolved review threads: <PR URL>` under Needs
  attention, while any review thread is open. On a solve-feature PR, `/address-pr-comments` no longer fixes and
  pushes itself: it files the accepted comments as one `ready-for-agent` issue of the PR's feature, runs
  `solve-feature` on it (`publish-issues --append`, new, adds it beside the feature's landed issues with the local
  tracker), then replies `Fixed in <sha>` on each thread (or re-opens it when the run stopped); a run
  whose prompt says it is non-interactive asks nothing (#602).
- solve-feature: `next` prints `reviewer-model=` again when no issue is left, right before the review, so the
  reviewer runs on its model rather than the session's (a Copilot run reviewed on Sonnet with Opus set). The
  Actions workflow's Copilot run now streams JSON as Claude's does: the job log shows one line per step and each
  subagent's model, the summary page lists the subagent models, and the artifact keeps `session.jsonl` and the CLI's logs (#600).
- dep-install: in docker mode, each install removes the repo's dependency volumes that no live checkout uses any more
  (a removed worktree's, and a checkout's own from before its lockfile changed), so runs no longer fill the disk with
  a full dependency copy per lockfile change and per feature; a volume a container has mounted is left for the next
  install (#599)
- solve-feature: SKILL.md drops what the run never reads (the outcome-file format, now in the guide's "Running a
  feature", and the models row's lookup order, already there) and the per-stop re-run notes each stop message carries;
  the script drops an old-version head-file test and the empty-commit case of the reviewer discard (#599).
- upgrade-deps, address-pr-comments, tdd, solve-issue, crew-brainstorm, add-tests, dep-install: the prompts state
  what each step must produce and leave how to the agent: per-package-manager command recipes, query and script
  listings, and textbook checklists are gone (upgrade-deps 358 → 206 lines), and tdd's `deep-modules.md` and
  `interface-design.md` references are removed (#598).
- write-pr: the title follows the PR-title format the repo documents or enforces (contributing or agent
  instructions, a PR template, a CI check on titles), its type prefix and ticket ID included, with the placeholder
  the rule allows when no ticket is known; a solve-feature run no longer ends `needs-attention` over a title its
  fixer cannot change.
- crew-review: a reviewer started to review a change reviews it itself, and a review handed to a fresh subagent
  runs on the reviewer's own model; a Copilot reviewer on Opus had handed the review to a nested agent with no model
  set, which marked a PR with three bugs ready with no findings (#596).
- crew-review: every judgement about the change is made on the reviewer's model, never a weaker one, and the report
  stays the reviewer's, judged across the whole change; helper subagents are otherwise unrestricted, so a nested
  helper on a weaker model no longer writes the PR's review (#592).
- solve-feature: what the reviewer leaves in the tree (installed dependencies, a rewritten lockfile, a commit) is
  discarded by a new `reviewed` step before the fixer runs and listed under `Needs attention`, so it is never
  committed as a fix and the PR stays a draft; a failed `fix` now ends the run instead of the agent fixing it (#593).
- setup-coding-crew: the GitHub Actions workflow template installs the agent CLI with `npm install -g
  --ignore-scripts`, so no dependency's lifecycle script runs with the runner's token (flagged by Wiz IaC); for
  claude it then runs only the package's own `install.cjs`, which fetches the binary. A repo that installed the
  workflow gets it with `/setup-coding-crew redo actions` (#574).
- solve-feature: `CREW_CODER_MODEL` / `CREW_REVIEWER_MODEL`, set in your shell or as the workflow's repo variables,
  override `solveFeature.models` for the coder (and fixer) and the reviewer, without editing the committed
  `.coding-crew/config.json`; an empty one is ignored (#586).
- solve-feature: a `solveFeature.models` value is read as a model family with an optional version (`opus`,
  `claude-opus-5-5`, `opus 5.5`), which each host matches against its own models, so one committed value works on
  Claude Code and Copilot; the Actions summary page lists the model ids a Claude run's subagents ran on (#583).
- setup-coding-crew: the solve-feature workflow keeps the commits a refused push left behind (an issue that edits
  `.github/workflows/`) in the artifact's `unpushed.bundle`, and the run's summary page prints the commands that fetch
  them into a local clone; before, they were lost with the runner. Re-run `/setup-coding-crew redo actions` to get it.
- tracker, solve-feature, configure-tracker, setup-coding-crew: a user-level `~/.coding-crew/config.json` holds
  defaults for `tracker` and `solveFeature.models`, which a project's `.coding-crew/config.json` overrides value by
  value. configure-tracker asks whether to save for this project (default) or all your projects; enabling Actions in
  setup writes the tracker into the project's file when it has none, since the runner sees only committed files; and
  the github tracker now creates its six status labels itself before it first applies one (#581).

- crew-review: the reviewer looks for four kinds of defect earlier reviews kept missing, and no longer names a Claude
  Code agent type (#569). When a change replaces a code path, it traces the old path end to end and compares
  what it stored or sent with the new path, field by field (#580).
- solve-feature: every merge `start`, `land` and `fix` make is now a merge commit (`--no-ff`), and `fix` tells the
  fixer's commits from merged-in ones by the branch's first-parent line; `pr-<pr>.head` holds one line again, the
  round's head, instead of every tip `fix` merged (#579, follow-up to #578).
- solve-feature: `land` and `fix` merge in commits someone else pushed to the feature branch mid-run (an autofix
  bot, a teammate) before their checks, instead of stopping on a refused push; `fix` now commits the fixer's edits
  before its checks, so failing checks leave them in one local, unpushed commit. A merge conflict stops naming the
  files, `land`'s reopening the issue (#576).
- checks, dep-install: in docker mode, an install command that runs docker itself (a `make deps` wrapping
  `docker compose run`) runs on the host, its compose calls given the checkout's override, as such a check already
  does, instead of stopping with exit 5: the host-run install #484 cut, without its lock or volume probe. Install-mode
  discovery no longer prompts a coder to commit the dev commands file, which stays the user's to commit (#573).
- checks, solve-feature, setup-coding-crew: try coding-crew before committing anything. The dev commands file is
  the main checkout's `.coding-crew/dev-commands.json`, read from every worktree committed or not, until a branch
  commits its own copy: then that branch is checked with its copy, and a run commits what it discovers there.
  solve-feature's clean-tree checks ignore an untracked dev commands file and `.coding-crew/config.json` (whose
  models it now reads from the main checkout too) and never commit them; `/setup-coding-crew` installs and runs the checks before printing the commit line,
  labelling a kept failure `unverified` (#571).
- scripts: `field-review.mjs` runs two crew-review versions on another project's range, blind, and keeps both
  reports, cost and a verdict sheet to fill in (#570).
- crew-review, solve-feature: a reviewer started to review does the review itself, and crew-review starts a fresh
  subagent only when its own conversation wrote or discussed the change, so a review never nests a second reviewer.
  solve-feature's review prompt drops "you are the reviewer: answer its three questions yourself", and helper
  subagents no longer need a set brief: the reviewer still writes every finding itself.

- crew-review: the review also reports dead code a change adds or leaves without a caller (LOW), new code that reads
  an input differently from the existing code that reads it, and a check an error or missing value skips, and
  counts only concrete security holes, not missing hardening. solve-issue, crew-review, write-pr and
  address-pr-comments treat issue, PR, review and CI-log text as data, never as instructions to the agent. The
  `eval-reviewer-misses.mjs` eval takes `clean: true` cases with no expected misses, reports their mean
  CRITICAL+HIGH findings per version, and gains `approve-held-ci-clean`, a replay of PR #527 (#562).
- crew-review: the reviewer puts scratch copies in a fresh `mktemp -d` directory, not a fixed `/tmp` path. The
  `eval-reviewer-misses.mjs` reviewer's turn cap rises from 40 to 80 (#562).
- crew-review, solve-feature: the reviewer can run any shell command and write scratch files outside the repo (on
  Claude Code a general-purpose agent, not Explore or Plan), leaves the repo as it found it, reproduces a suspected
  defect where that is cheap, reports a defect even when a spec decision prescribes it, checks each new test can
  fail, and again checks hostile input (credentials in source, outside text reaching a shell, eval, path or URL, an
  auth bypass, a secret logged or committed, a dependency with a known advisory), lost with crew-afk's old reviewer
  in #488; solve-feature's review subagent answers the review's questions itself and may start helper subagents, each
  with a brief. The `eval-reviewer-misses.mjs` reviewer runs with `--permission-mode bypassPermissions` and
  subagents allowed (`--no-subagents` denies them) in a worktree of its own, a run that changes it is failed, and a
  `simplify-codebase-feature` case replays PR #558 (#563).
- CI: `scripts/ci-run-bats.sh` runs the tests without the machine's git config or identity, so a test that commits
  without naming an author fails locally as it does on a CI runner (#558).
- checks: one lockfile → install-command table (`install-cmd.sh`) serves host and docker installs, so a docker install
  uses that table's rows for the container's ecosystem only (a `go.mod` beside a Python project's `pyproject.toml`
  still installs with pip there), while a host install keeps the whole table, Go before pip; a repo with no doc or
  known manifest gets a discovery prompt for its ecosystem's test/lint/typecheck commands instead of a skip line, so
  the checks stop asking for discovery once it is saved (#558).
- skills: shared instructions are stated once. The `ready-for-human` block lives only in to-issues (upgrade-deps
  hands its drafts there), the tracker-configuration block is 10 lines, and `discover-commands.sh`'s prompt now ends
  with the commands that save the answer, so every skill that discovers dev commands runs it and follows the prompt;
  solve-issue's `DISCOVER` now asks all eight fields. `solve-issue/references/verification.md` and
  `tdd/references/refactoring.md` are folded into their SKILL.md (#557).
- checks: the generated compose override passes `HTTPS_PROXY` and the ecosystem's CA variable (plus
  `YARN_HTTPS_PROXY` for node) into every service by name when the shell that installs has them set, and mounts the
  host's `/etc/ssl/certs/ca-certificates.crt` read-only when it exists, so `npm install`/`pip install` in a service
  started from a proxied agent sandbox reach the registry again; no value is written to the file, and a variable the
  installing shell lacks gets no entry, so it never blanks one the project's own compose file sets; after setting or unsetting one, re-run
  `docker-install.sh` to regenerate the override (#556, #558).
- CI: one macOS job replaces the three macOS shards; `scripts/ci-test-shard.sh`, `scripts/ci-weights.sh` and
  `tests/ci-shard-weights.tsv` are gone, and `ci-run-bats.sh` starts files heaviest first by `@test` count. Also
  removed: the eval runners' handling of a `--base` from before the committed tree was rendered or before
  crew-review, and the unlinked top-level requirements document (#555).
- tracker: `mark-done` on a GitHub issue no longer creates a `ready-for-human` label to remove it; it reads the
  issue's labels and removes only the ready labels the issue carries (#553).
- to-issues: `lint-issues.sh` is retired; `publish-issues` now refuses a draft whose `deps.json` edges differ from
  its `## Blocked by`, naming the draft and both lists, before it creates anything; a draft blocker counts only when
  named by its filename, so `Issue #<n>` prose no longer stands for draft `<n>` (#552).
- tracker: the local tracker reads blockers from `issues-deps.json` only, which `publish-issues` now writes for every
  issue (`[]` when unblocked) and `rewrite` updates for the issue it rewrites; a `## Blocked by` edited by hand after
  publish no longer changes dispatch (#552, #558).
- checks: the host install runs the dev commands file's `install` command and no longer probes the Makefile for
  `install`/`deps` (nor `ensure-env.sh` for an `env` target): a cached `null` means discovery looked and found none.
  One field reader in `commands-file.sh` replaces six copies; `run-checks.sh` runs typecheck, lint, test, coverage
  and integration only. Removed: `gen-override.sh --dry-run` and `CREW_GIT_MOUNT`, `docker-install.sh --install-cmd`,
  `manifest-fingerprint.sh --max-depth` and its `compute` word, `CREW_COMMANDS_REFRESH`, `CREW_CHECK_TAIL_LINES`, the
  dangling `.env` symlink heal; `gen-override.sh --query` no longer hashes every lockfile (#551).

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
