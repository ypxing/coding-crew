# Changelog

Users install from `main` (`bootstrap.sh`), and `install.sh --update` reinstalls every skill its
manifest lists. Tagged releases mark milestones only, not every merge.
Record changes under `[Unreleased]` and move them under a version heading when you cut a release.

## [Unreleased]

- **crew-afk / docs**: crew-afk no longer knows how to launch any agent CLI: the agent you run `/crew-afk` in
  writes the command that starts a session of its own CLI, and `crew-afk.sh dispatch <slug> … -- <argv…>` runs it
  as given (`local` under the 1h cap; `orca` and `herdr` in their terminal). The per-CLI launch table, parent-process
  detection, `CREW_AGENT`, the `session=` line and status's `claude --resume` line are gone; the cost line now
  appears for any local run whose command printed a JSON result with a cost last. The release smoke passes its own
  per-platform command (#499).
- **solve-feature / setup-coding-crew**: a failed push after an issue landed now reopens the issue (committing a
  local tracker's file move) instead of leaving it counted done, so a plain re-run where git can push redoes it;
  every push stop quotes git's own reason (e.g. GitHub's `workflows` permission refusal). The Actions workflow's
  header and `/setup-coding-crew` say an issue that touches `.github/workflows/` cannot land from a runner and is
  run locally (#525).
- **setup-coding-crew / docs**: the solve-feature Actions workflow, once the session ends, approves the PR's
  `pull_request` runs GitHub held for approval, so its CI runs and shows on the PR; where GitHub refuses, it
  dispatches that workflow on the PR's branch as before (#523's dispatch alone left the PR showing a run awaiting
  approval and none of the dispatched run's checks) (#527).
- **solve-feature / docs**: the PR body solve-feature writes opens, right under its begin marker, with a visible
  line saying solve-feature wrote the PR and naming the feature slug, so a reviewer never reads agent prose as a
  person's words (#521).
- **setup-coding-crew / docs**: the solve-feature Actions workflow, once the session ends, starts the PR's CI by
  `workflow_dispatch` on its branch, for every workflow that has both `pull_request` and `workflow_dispatch`, so a
  bot-made PR's CI runs without someone approving it; add `workflow_dispatch:` to a PR workflow to opt it in. This
  repo's `ci.yml` does (#523).
- **crew-afk / docs**: `crew-afk status` and `wait` end a finished local claude run's outcome line with its cost
  and duration (`ready pr=7 cost=$1.73 (23 min)`), and `wait` on a local run returns once the run's process is
  gone, not at the outcome. The release smoke takes its RESULTS cost from that line. `docs/guide.md`'s "What a
  feature looks like on the tracker" replaces "Issue Lifecycle", "Writing Issues" and "Triage Labels", for both
  trackers (#520).
- **registry / to-issues / to-prd / upgrade-deps / solve-issue**: installing to-issues alone now brings to-prd and
  configure-tracker, upgrade-deps brings to-issues, and every skill that offers configure-tracker reaches it;
  deps no skill invokes are gone (solve-feature → dep-install, address-pr-comments → solve-issue, crew-grill and
  crew-brainstorm → to-prd, which still arrives through to-issues). `registry.json` drops its unread `description`
  fields, and `tests/skill-deps.bats` fails when deps and skill text drift. The release smoke is now
  `scripts/smoke-crew-afk.sh` (#504).
- **dep-install / add-tests / upgrade-deps / address-pr-comments / configure-tracker / tdd / setup-coding-crew**:
  the install mode's confirm-and-save rule now comes from `discover-mode.sh`'s prompt, so solve-issue and
  dep-install decide it the same way, and `discover-commands.sh` alone discovers the `install` command (the host and
  docker install guides only read it; the host guide applies whenever the mode is host). The `docker-install.sh`
  call and its `--force` retry are two copy-pasteable commands. add-tests, upgrade-deps and address-pr-comments run
  commands through the checks library's `run.sh` and invoke dep-install only after a missing-dependency failure.
  add-tests' no-coverage stop names a fix that works (set `"coverage"` or rerun discovery with `--refresh`).
  upgrade-deps publishes by invoking to-issues with its drafts and checks existing features through the tracker
  CLI; it and add-tests delete their drafts or findings file once to-issues has published. address-pr-comments handles `DISCOVER` before pushing and skips resolved threads by GraphQL `isResolved`.
  configure-tracker creates labels with `gh label create`, treating "already exists" as success (#503).
- **to-issues / to-prd / crew-grill / crew-brainstorm / tracker**: to-issues sizes an issue as one implementer's
  work, taken, finished and verified as a unit: it drafts slices as the work divides, splits one that is well beyond
  the reference size (what has been finished as one issue), and merges one that exists only to be smaller (size, a human boundary or expand–contract order are
  the only split reasons; no more parallelism, token estimates or dispatch costs), and shows the user only the
  slices that survived. Its step 6 mechanics (drafts, known issues, `deps.json`, lint, builder check, publish,
  rewrite) move to `references/publish.md`, read when that step is reached; the design skills name no downstream
  tool, only the implementer and reviewer who read what they write. to-issues writes the PRD with to-prd right
  after drafting slices and before tracing PRD IDs, and carries a design summary's `(auto)` lines, cited facts and
  cut list into the PRD or the issue's new `## Out of Scope`. to-prd no longer re-confirms decisions settled
  earlier, its Decisions guidance is a four-rule list, and a local PRD opens with `# PRD: <title>`. crew-grill and
  crew-brainstorm share one size-test fragment (`skills/_shared/fragments/size-test.md`: the do-least option and the
  subtraction pass are one test, stated once), run the light path's single tracker fetch themselves instead of
  loading the tracker-configuration fragment, and the verification-pass fragment names no skill (to-prd carries its
  own clause); crew-brainstorm
  states the light path once and drops its duplicate flow graph and principles list, asks open questions before
  offering a menu, covers anti-goals, and tags the defaults it chose `(auto)` for the hand-off; crew-grill words
  each question so "yes" takes its recommendation, points its "annoyed" lane at the light path's list instead of
  repeating it, and hands off to to-issues once; to-prd prefers the fewest
  seams; and both design skills' descriptions say how they differ (adversarial vs collaborative). The
  local tracker now writes `.scratch/.gitignore` (`*`) when it writes under `.scratch/`, so a consuming repo's tree
  stays clean after publishing; an existing one is left alone (#502).
- **solve-issue / solve-feature / crew-review / tracker**: a coder that stops short (`partial`, or `blocked` with
  changes) commits its work as `[WIP]`, so solve-feature's `land` names its report, and its "working tree left
  dirty" stop names the report too when a check rewrote files the coder left for a person; `mark-done --force` is only for a descope a person approved,
  and the CLI's exit-4 message no longer suggests it. solve-issue finds `PROJECT_ROOT` itself when its caller
  sets none, commits there, and reads a GitHub issue's `PRD: #<n>`; its preflight stops when the checks library
  is not linked and no longer prints `DEP_SCRIPTS`. crew-review's report field `prd` is renamed `spec`
  (`met|unmet|none`) — update any script that reads a standalone `/crew-review` report. Every solve-feature stop
  line reads `stopped: <what> failed: <reason>`, a run with nothing landed included (#501).
- **repo**: this repo's solve-feature workflow maps Claude Code's `haiku`, `sonnet` and `opus` aliases to
  `claude-haiku-5-5`, `claude-sonnet-5-5` and `claude-opus-5-5[1m]` (#519).
- **setup-coding-crew**: the solve-feature Actions workflow streams a Claude run's steps into the job log as they
  happen (the model, each command and subagent, a failed tool) and keeps the stream in the artifact; its summary
  page shows the outcome, the PR, the model and, on a stop, the coder's report and checks log; the repo variable
  `CREW_MODEL` pins the model. A re-run of `/setup-coding-crew` offers the new file (#518).
- **crew-afk**: `crew-afk.sh wait <slug>` blocks until the run has ended and prints its `status` line, and `/crew-afk`
  runs it in the background when the agent can, so the session that dispatched a run reports how it ended (#510).
- **repo**: `.gitattributes` merges `CHANGELOG.md` with git's `union` driver, so two branches' `[Unreleased]` entries
  no longer conflict, and solve-feature's re-run on this repo's feature branches does not stop on them (#516).
- **solve-feature / solve-issue**: a re-run on an existing branch merges the default branch in first, so its checks
  run main's later fixes (a conflict stops it, naming the files); a resumed coder whose issue's work is already
  committed still runs the checks and marks it done, instead of stopping the run with the issue open (#515).
- **scripts**: `ci-run-bats.sh` clones the bats-core ci.yml pins (v1.13.0) into `~/.cache/coding-crew/` when no `bats`
  is on PATH, so this repo's own solve-feature Actions runs, whose runner installs no bats, can run their checks (#513).
- **solve-feature / tracker**: a failed check after an issue's coder closed it no longer strands the work: `land` reopens
  the issue (the tracker CLI's new `reopen` op) and pushes its commits before it stops, so a plain re-run's coder
  picks the issue up from that work, on an Actions runner too, where the checkout goes with the job (#512).
- **setup-coding-crew**: the Actions workflow runs Claude Code as well as Copilot, picked by the repo variable
  `CREW_AGENT` (`claude` needs an `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` secret), and uploads
  `.solve-feature/` as an artifact on every run, so the checks log a stop names outlives the runner. Re-run
  `/setup-coding-crew redo actions` to update an installed workflow. crew-afk's `CREW_AFK_AGENT` is now `CREW_AGENT`
  too: one name for the agent CLI a launcher runs solve-feature with (#512).
- **setup-coding-crew / crew-afk**: the Actions workflow and crew-afk's copilot launches run Copilot with `--allow-all`
  instead of `--allow-all-tools`, so a run no longer stops at its first step: the skill's scripts sit under
  `$HOME/.copilot/skills`, outside the checkout, and Copilot's path check denied them with no one to approve. Re-run
  `/setup-coding-crew redo actions` to update an installed workflow (#511).
- **repo**: this repo runs solve-feature on GitHub Actions: `.github/workflows/solve-feature.yml` is the
  setup-coding-crew template, so labelling a feature's root issue `solve-feature` (or dispatching the workflow with its
  slug) builds it on a runner (#509).
- **copilot-instructions** (this repo's dev guide for Copilot): lists all 17 skills, points the issue-tracker section at
  the configured tracker and its CLI instead of hand-editing issue files, adds `source-dir` to the registry schema,
  and summarises CLAUDE.md's working rules (tests, CHANGELOG, comments, layer ownership) (#508).
- **setup-coding-crew**: the Actions workflow's billing comments say who pays with `github.token`: an
  organisation-owned repo bills the organisation (under its "billed to the organization" policy), a personal repo
  bills the owner's Copilot seat; a `COPILOT_GITHUB_TOKEN` PAT bills its owner's seat, and the old "Unverified" note
  is gone (#507).
- **solve-feature / crew-afk**: a run reviews its PR at most twice: `fix` ends `review-again=yes` when the review had
  a CRITICAL, HIGH or MEDIUM finding and the fixer changed something, and the run then reviews and fixes once more.
  crew-afk's local claude run drops its `$10` cap (`--max-budget-usd`), so every agent gets the same 1h limit (#497).
- **README**: the quickstart runs `/setup-coding-crew` once before the first `/crew-grill`, the diagram shows
  both ways a run ends (PR marked ready, or PR lists what needs you), every multi-issue use case ends in
  `/crew-afk <slug>`, and the full command table is collapsed (#496).
- **setup-coding-crew** (new): `/setup-coding-crew` takes a repo from a fresh install to a working `/solve-feature`
  in one run: it chooses the tracker (through configure-tracker), discovers and saves the check commands to
  `.coding-crew/dev-commands.json`, with the github tracker offers the solve-feature Actions workflow and its
  `solve-feature` label, then prints the `git add … && git commit` line for the setup files; it never commits. A
  re-run shows what is in place and redoes a step only when you name it. The Actions template moved from
  `solve-feature/hosts/github-actions.yml` to `setup-coding-crew/hosts/github-actions.yml`, and solve-feature's
  "no check commands known" stops now say to run `/setup-coding-crew` (installed with solve-feature) (#492).
- **tracker (local) / solve-feature**: `next` prints the issue's absolute path in the main checkout, not a
  `.scratch/…` path relative to it. In a worktree, where the gitignored `.scratch/` is absent, a coder couldn't find
  the relative path, used the `.solve-feature/issues/` copy instead, and the tracker rejected that as an invalid
  ref, so the issue was never closed.
- **solve-feature / crew-afk**: when a coder doesn't close its issue, the stop (and so `/crew-afk status`) now
  names the file holding the coder's own report, `.solve-feature/coder.report.md`, or says it left none. Before,
  the reason lived only in the run's conversation, out of reach of an orca or herdr run's status.
- **add-tests / upgrade-deps**: run only when a person invokes them (`/add-tests`, `/upgrade-deps`); an agent
  no longer starts them on its own (`disable-model-invocation`; for Codex, `agents/openai.yaml`). Neither names
  the skills that pick up its issues any more.
- **crew-afk / solve-feature**: `/crew-afk <feature> --branch <name>` passes the branch on to solve-feature, so a
  repo whose branch-name rule refuses `feature/<slug>` (a ticket key, say) can be dispatched to. A solve-feature
  re-run after a refused first push now pushes the branch at start, before any coder runs, rather than at the
  first issue's land (#488).
- **solve-feature / solve-issue / dep-install**: the dev commands file (checks, install command, install mode)
  no longer needs committing, and nobody has to be asked for the install mode. Discovered checks and mode are
  written to `.git/coding-crew/dev-commands.json`, outside every working tree and shared by all worktrees of the
  clone; a tracked `.coding-crew/dev-commands.json` still wins and is updated in place. `solve-feature` no
  longer stops at start without the file or the mode: its first coder discovers the checks, and in a repo with
  a compose file solve-issue's Step 2 discovers the mode (docker or host, and the service) with the new
  `discover-mode.sh`, as it does the checks. `dep-install` discovers it the same way and shows a person its
  answer to change; `detect-mode.sh`'s Makefile heuristic is gone. `discover-commands.sh` and
  `write-commands-cache.sh` move to the checks library beside the new `commands-file.sh`; add-tests,
  upgrade-deps and dep-install link `checks` instead of `git-workflow` (#488).
- **solve-feature / solve-issue**: a run whose `git fetch`, branch checkout or first push fails at `start` now
  writes `stopped: start failed: …` to `.solve-feature/outcome` instead of exiting with none, so `crew-afk status`
  and a host waiting on the file see it end. In a crew-afk worktree, solve-issue's preflight finds the
  `.scratch/…` issue in the main checkout again, so the coder gets the feature's PRD and the Blocked-by and
  Requires checks run. `crew-afk --to herdr` types the agent's command into its pane and returns, instead of
  failing after 30s while the agent it started keeps running (#488).
- **install / crew-afk**: `.coding-crew/manifest.json` records every platform installed into a root
  (`platforms`), and `install.sh --update` reinstalls for each, so updating a root that holds both a claude and
  a codex install no longer leaves only the last one. `crew-afk status` reports only worktrees it dispatched
  to; a `.worktreeinclude` directory ignored as `dir/` no longer leaves the run's worktree unclean; the release
  smoke fails when a user-level skill would shadow its project install (#488).
- **skills**: every skill follows the Agent Skills authoring practice. Each `description` says in the third
  person what the skill does and when to use it; `allowed-tools` is space-delimited; address-pr-comments
  credits the agent that runs it as co-author instead of a hard-coded `Claude Code`. The native rule (a skill
  uses another by name and reaches shared code only through the library linked into its own `scripts/`) is in
  CLAUDE.md and enforced by `tests/native-skills.bats`. solve-issue's unrun `references/test-*.sh` are gone
  (the branch-protection one now tests the real `branch-safety-check.sh`, which no longer exits 128 when a
  repo has no `origin/HEAD`), and install.sh no longer filters `test-*.sh` (#486).
- **crew-afk**: a new, thin `crew-afk` skill. `/crew-afk <feature> [--to local|orca|herdr]` resolves the
  feature's slug, prepares (or reuses) one worktree per feature at `<repo>/../<repo-name>-worktrees/<slug>`
  (`.worktreeinclude` entries linked, `.env` copied), starts one `/solve-feature <slug>` run there and returns:
  locally a detached headless agent capped at 1 hour, and at $10 on claude (needs `timeout`; macOS: `brew install coreutils`),
  or an interactive, uncapped agent in an orca terminal or a herdr pane. The run uses the agent CLI that ran
  `/crew-afk` (claude, copilot, codex or pi). `/crew-afk status [<feature>]` prints each run's outcome line, `running`,
  or why there is none, with how to continue and the claude session to resume; a second
  dispatch on a feature whose local run is still going is refused. Cut from the old crew-afk, restorable if
  missed: the `jq` live-log filter and auto-detecting orca/herdr from `ORCA_ENV`/`HERDR_ENV`. The demo smoke
  (`scripts/smoke-sprint.sh <platform>`, always the demo, now pinned at `9b9c84c`) runs through `crew-afk.sh
  dispatch --to local` and requires `ready pr=<n>`; its `--demo`, `--dir` and `--setup-only` flags are gone,
  and `RESULTS.md` rows are commit / date / platform / result / cost / findings (#485).

- **checks library, dep-install, solve-issue**: every checks script works on the one checkout it is given:
  `--main-root` is gone from `run-checks.sh`, `run.sh`, `gen-override.sh`, `docker-install.sh`, `ensure-env.sh`,
  `host-install.sh`, `resolve-mode.sh` and `preflight.sh` (and `--dep-scripts` from `run-checks.sh`), and a
  worktree reads its own committed `.coding-crew/dev-commands.json`, which `write-commands-cache.sh` now writes
  into the current checkout. Each linked worktree is its own compose project with its own dependency volumes
  (no shared DB between features); a `.env` is generated per checkout instead of linked from the main one. The
  install mode is `dev-commands.json`'s `install_mode` (`host` | `docker`) and `docker_service`, decided once by
  `dep-install` with a person and committed; absent means host, and `git config agent.install-mode` /
  `agent.install-service` are no longer read. Docker mode never falls back to the host: with no override,
  `run.sh` installs first, and a failed install stops with the service, the step and its log. Removed:
  `run.sh --describe`/`--via`, `resolve-mode.sh --deps`/`ACTION=`, `detect-service.sh`,
  `detect-compose-bypass.sh`, the `docker-compose` (v1) shim, the install lock, host-run install commands and
  their volume probe (an `install` command that runs docker itself is now refused, exit 5),
  `gen-override.sh --query owner-prefix|platform|state-path`, host-install's fingerprint fast path and
  `--force`, and `CREW_DOCKER_PLATFORM` (the override always pins the host's architecture). Also cut, restorable if a
  corporate proxy needs it: the sandbox CA bundle mount and proxy variable passthrough (`IS_SANDBOX`,
  `--sandbox`, `HTTPS_PROXY`, `NODE_EXTRA_CA_CERTS`, `REQUESTS_CA_BUNDLE`, `SSL_CERT_FILE`) (#484).

- **install, every skill**: `install.sh <platform>` installs at user level (`$HOME`) by default;
  `--project [<path>]` (or `TARGET_REPO`) installs into a repo, and `uninstall.sh` takes the same flags
  (`uninstall.sh --user` is gone). Shared code is three libraries — `lib/tracker/` (was `tracker/`),
  `lib/checks/` (`run-checks.sh` and dep-install's scripts) and `lib/git-workflow/` (was
  `scripts/skill-utils/git-workflow/`) — each installed once to `<root>/.coding-crew/lib/<name>/` and linked
  as `<skill-dir>/scripts/<name>` into each skill whose new `registry.json` `libs` names it (relative at
  project level, so a committed install survives a clone). Skills run `node <skill-dir>/scripts/tracker/cli.mjs`
  and `bash <skill-dir>/scripts/checks/…`; the tracker locator, `.coding-crew/tracker/`,
  `.coding-crew/<skill>/scripts/` and the per-skill script copies are gone, and `render-skill.sh` takes no
  platform (`{{PLATFORM}}` is no longer expanded). `registry.json` drops every `version`, `scripts`,
  `assets`, `more-assets`, `docs`, `retired-agents` and `retired-scripts`; the manifest records the platform,
  skills and libraries with no versions, and `install.sh --update` uninstalls everything it lists, then
  installs those skills again. Gone with the versions: the version-bump rule, `tests/registry-version-bump.bats`,
  and `sync-pr-with-main.sh`'s version repair (it still merges and resolves CHANGELOG appends). An install made
  before this updates with `install.sh --update` (add `--project` for a project install), then needs a
  one-time `rm -rf <root>/.coding-crew/{tracker,crew-afk,dep-install,solve-issue,to-issues,write-pr,skills}`,
  `<root>` being `~` or the repo (#483).

- **crew-afk, crew-address-findings (removed)**: the old crew-afk program — `orchestrator/`, `skills/crew-afk/`
  and everything only it used — is deleted, so `/solve-feature` is the one unattended path (a new, thin crew-afk
  that starts solve-feature runs follows). Gone with it: the `crew-address-findings` skill; solve-issue's
  `ORCHESTRATED` preflight value and orchestrated close (it always closes its issue now), `run-checks.sh
  --targeted` and the `CREW_DEFER_FULL_CHECKS` deferral (every check always runs); the `CREW_ORCHESTRATED` env
  var and `.scratch/<slug>/.orchestrated` marker, which `tracker/cli.mjs mark-done`, solve-issue, tdd and
  `solve-feature.sh start` no longer read; the tracker's `in-progress` label (configure-tracker creates six
  labels; a person still sets `blocked`, which `next` keeps skipping); `close-shipped.sh`; address-pr-comments'
  crew-afk PR path and write-pr's crew-afk block; `eval-reviewer-misses.mjs --reviewer` (it replays crew-review
  only); the `crew-afk-version:` check in `cut-release.sh` (it keys on `crew-afk-commit:`); `install.sh
  <platform> crew-coder` and `uninstall.sh --agent` (now unknown arguments). The `afk` section of
  `.coding-crew/config.json` is no longer read: delete it. `platforms.json` moves to the repo root. An existing
  install keeps its old `crew-afk` and `crew-address-findings` skill directories, `.coding-crew/crew-afk/` and
  `.coding-crew/skills/`: delete them by hand (#482).

- **crew-review, solve-feature**: `review-pr` is renamed `crew-review` and only reports: it reviews a branch
  (`<base>..HEAD`) or a PR against the spec its caller names (a file, an issue ref or the PR body), asks what the
  code at HEAD lacks, writes its JSON report to the given path or prints it, and posts nothing and marks nothing
  ready. `install.sh --update` does not remove a renamed skill: delete your old `review-pr` skill directory by hand.
  solve-feature calls crew-review by name; `start` stops on a slug the tracker's `features` does not list, always
  uses `--branch` (never the default branch) or `feature/<slug>`, and writes `.solve-feature/spec.md`; `land` opens
  the draft with a one-line body and no progress comment; `describe` writes the whole body once, then marks the
  draft ready when nothing needs a person (`fix` no longer does). Every run ends with one line in
  `.solve-feature/outcome` (`ready pr=<n>`, `needs-attention pr=<n>` or `stopped: …`), which replaces the
  `stopped`, `reviewed` files and which `hosts/github-actions.yml` now reads; `SOLVE_FEATURE_HOST` is gone (#479).

- **crew-afk**: the feature reviewer's protocol is cut to three questions, as review-pr's: what the PRD asks for that
  is missing or different and what was built that it does not need, what a real run breaks (leftover references,
  undefined names in shared text and security classes kept as checks), and which documented rule the diff breaks.
  The always-on class list, the two-pass procedure, the Pre-Report Gate and the written-list tracing step are
  replaced by a few lines; `### Dropped` stays. The always-loaded `quality.md` drops its size, style and performance
  thresholds and keeps only defects (swallowed errors, untested paths, hollow tests, a second reader, dead code, comments
  and tests that pin prose).

- **review-pr, solve-feature**: review-pr is one skill and one prompt file; `review-pr.sh` is gone (nothing reads an
  existing `.coding-crew/review-pr/` any more; delete it). The reviewer gathers the PR's spec and diff itself and
  answers three questions — what the spec asks for that is missing or different and what was built that it did not ask
  for, what a real run breaks (a concrete trigger, traced past the diff), and which documented repo rule the diff
  breaks — and is told not to report hypotheticals or preferences. `/review-pr` posts one plain review (no inline
  comments), leaves out findings earlier reviews already raised, and still marks a draft ready when the spec is met
  with no CRITICAL or HIGH finding. solve-feature runs its reviewer on the same prompt, read from review-pr's skill
  directory, runs its script from its own skill directory (nothing reads `.coding-crew/solve-feature/` any more), and
  its `start` clears an earlier run's review report.

- **solve-feature**: the PR now opens with a body a person can read. After `fix`, a fresh subagent runs write-pr
  (Why / What changes / Risk / Tested) into `.solve-feature/pr-<n>.summary.md`, and the new
  `solve-feature.sh describe <slug> <pr>` puts it, with any `Needs attention` list, at the top of the PR body and
  titles the PR after it; the spec and `Closes` lines stay below. Acceptance criteria in the spec are plain bullets,
  so GitHub no longer shows the PR as "0 of N tasks". write-pr is now a solve-feature dependency.

- **solve-feature, review-pr**: `solve-feature.sh fix` drops the guards no run has needed (PR open, head branch,
  HEAD containing the PR head, the report's `prd` value and findings shape, a reviewer-edited tree) and the
  `pr-<n>.reviewed-head` file `review-pr.sh prepare` wrote for them; the PR still stays a draft on a gap, an unmet spec,
  an unfixed finding or a fixer that changed nothing. The last line is now
  `FIX: findings=<k> needs-attention=<a> ready=<yes|no|already>` (no `fixed=`), and the progress row reads
  `<k> finding(s), fixed in <sha>`. A rejected push in `land` now stops naming the `land` to re-run, since a plain
  re-run would skip the already-closed issue and leave its spec out of the PR body.
- **solve-feature, address-pr-comments**: a solve-feature run fixes its review's findings itself instead of posting
  them. After the read-only reviewer (`review-pr.sh prepare` and its prompt), a fresh subagent fixes every finding with
  the tdd skill, and the new `solve-feature.sh fix <slug> <pr> <branch>` gates the fixes with the checks, commits and
  pushes them as one commit, adds one `review` row to the progress comment and marks the draft ready unless a spec gap
  or an unfixed finding needs a person (listed there under `Needs attention`); a fixer that left the reviewed commit
  unchanged counts nothing as fixed, so its findings are listed too. No review or review comment is posted;
  `.solve-feature/reviewed` is now written by `fix`, which the Actions host's last step checks. address-pr-comments no
  longer suggests `next: /review-pr <n>` on a solve-feature PR. `/review-pr` run by hand is unchanged (#475).
- **solve-issue**: a subagent run counts as non-interactive, so unmet criteria end it `partial` instead of a question
  nobody answers — what a solve-feature coder subagent now gets (#473).
- **solve-feature, review-pr**: no agent CLI is launched any more. Both skills run inside whichever host agent invoked
  them: each issue's coder and the reviewer are fresh subagents SKILL.md asks for, and the scripts keep only the guards
  as subcommands — `solve-feature.sh start|next|land` and `review-pr.sh prepare|post` (the old one-shot forms exit 2).
  `--agent`, `CREW_AGENT`, `--budget`, the 60/30-minute timeouts and `review-pr/scripts/agent.sh` are gone; put
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
  `roles/` tree are gone); `--agent claude|copilot` (`CREW_AGENT`) picks the coder; `next` selects issues on
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
