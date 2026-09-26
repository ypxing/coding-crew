# Changelog

## [1.29.136]

### Changed

- **The pane host is one setting, `CREW_PANE_HOST=orca|herdr|auto|none`.** `ORCA_ENV` and
  `HERDR_ENV` sit in the `ORCA_*`/`HERDR_*` namespaces those tools inject into their own
  terminals, and needed a both-set error. They still work, below `CREW_PANE_HOST`. Setting both
  now picks orca with a notice instead of stopping the run. `--pane-host` sets it for one run,
  and `afk.paneHost` in `~/.coding-crew/config.json` sets it for the machine. A repo's
  config.json is rejected for it, since a committed `orca` would fail preflight for everyone
  without orca. `auto` picks orca when `ORCA_TERMINAL_HANDLE` is set, else herdr when
  `HERDR_PANE_ID` is. `run` prints `PANE-HOST: <host|none>` before any sprint output, and the
  four launcher skills stop polling on `PANE-HOST: orca` instead of reading env themselves.
  `plan` shows the host and where it came from.

## [1.29.135]

### Fixed

- **`ensure-deps.sh` and `verify-worktree.sh` trace to the checked directory's sprint.** Run
  from another directory, their `DEPS`/`VERIFY` lines went to the trace log of whichever sprint
  the caller's working directory belonged to, while `ensure-deps.sh`'s markers used `--dir`'s.
  Both now resolve the log from the directory they checked. The test suite no longer appends
  to a sprint trace log in this checkout.

## [1.29.134]

### Changed

- **`crew-code-reviewer` is renamed `crew-reviewer`**, matching `crew-coder` and `crew-triage`.
  Its review assets stay at `.coding-crew/code-review/`. registry.json's new `replaces` field
  lets an agent carry its old names: installing `crew-reviewer` removes the old
  `crew-code-reviewer` shims for each platform it installs, plus its manifest entry, so the host
  doesn't keep listing a stale second reviewer. Uninstall removes them too. A user-level install
  (`TARGET_REPO=$HOME`) is cleaned the same way the next time you install at that level; until
  then, a project install warns that the old user-level copy may shadow it. Installing one
  platform over an older all-platform install keeps the old manifest entry and warns while
  another platform still has an old shim, and `--update` installs `crew-reviewer` in place of a
  manifest's `crew-code-reviewer` there too. `install.sh`/`uninstall.sh --agent` accept the old
  name, with a notice; an unknown agent name is a clear error.
- **crew-afk can run each role on a different runtime.** `.coding-crew/config.json`'s `afk`
  section maps any role (`coder`, `reviewer`, `triage`, `commandFinder`, `prdAuditor`) to an
  installed runtime and names models per runtime, e.g. a claude coder reviewed by codex. A model
  string only ever reaches its own runtime's CLI; a role moved to another runtime gets that
  runtime's default, not the coder's model. `--model` is in the launcher's vocabulary: it reaches
  every role on the `--platform` runtime, and when the coder is moved elsewhere a warning names
  the roles it still applies to. `plan` prints the role → runtime/model table, and preflight
  checks each runtime a role uses, naming the role when one isn't installed. With no config,
  every role runs on `--platform` as before.
- **Two roles are renamed:** `commandsDiscovery` → `commandFinder`, `coverageValidation` →
  `prdAuditor`. An `afk-models.json` using the old names is moved under the new ones.
- **Findings are fixed from HIGH up by default, and the threshold is a setting.**
  `afk.fixFindings` (`--fix-findings` for one run) names the lowest severity promoted into
  Phase 2: `critical`, `high` (new default — was CRITICAL only), `medium` or `none`. HIGH findings
  must name a failure scenario and pass the reviewer's pre-report gate, so they are real bugs;
  MEDIUM needs neither, so it is opt-in. `--promote critical|critical-high` still works as an old
  name for `critical|high`.
- **The PRD audit is on by default, and can fix what it finds.** `afk.PRDAudit` (`--prd-audit`)
  is `off`, `report` or `fix` (default). It now runs once when Phase 1 drains, before the flush,
  instead of after the squash, and asks only what a per-branch review cannot see: requirements no
  issue carried, flows across issues, cross-cutting concerns — it no longer re-grades criteria a
  review already passed. In `fix` mode its ✗ missing requirements become one fix issue
  (`NN-fix-prd-gaps.md`, or a GitHub issue) that Phase 2 implements with the findings fixes; its
  `Source:` line keeps it from being audited or promoted again. Nothing is queued while a Phase 1
  issue is still open; when gaps are found but not queued, the summary's `## PRD Audit` says why.
  Under `tracker: github` it audits the milestone's `PRD:` issue (a local `PRD.md` is still read
  first), and that open PRD issue no longer counts as unfinished work, which had kept gaps from
  being queued and marked every github sprint stalled. An audit that fails or times out is named
  in the summary too. Skipped at no cost when the feature has no PRD. `coverage-validation.sh` is now
  `prd-audit.sh`, its report `prd-audit.md`; `--coverage` still works, as `report`.
- **Sprint settings move into `config.json`:** `timeouts` (minutes per role, plus `merge`),
  `maxParallel`, `installDeps` and `squashCommits`, each overridden for one run by a flag.
  Timeouts are per role now: `--coder-timeout` (was `--worker-timeout`, still accepted),
  `--reviewer-timeout`, `--merge-timeout`; `--review-timeout` still sets every non-coder role.
  Two defaults drop: command finding 20 → 5 minutes (a timeout falls back to per-check
  discovery), and merge/close 10 → 5 — a repo with slow git hooks on merge commits should raise
  `timeouts.merge`. A timeout is at most 35791 minutes, where Node's timer overflows and would
  fire at once. `plan` shows each setting and the file or flag that set it; a bad value is a
  setup error, in config or on the command line, and so is a setting flag given no value.
- **`.coding-crew/afk-models.json` is replaced by `config.json`.** The first `run` that finds it
  moves its values into `afk.models.claude` and deletes it (`plan` only says it would). Those
  values only ever applied on claude, so behaviour is unchanged on every platform. An invalid
  config is now a setup error listing every problem; a malformed `afk-models.json` used to be
  ignored with a warning. An unknown key in it is still ignored, dropped from the move with a
  notice. The move happens only once a `run` has passed setup (flags, config, preflight, the
  sprint lock), so a run that fails before starting leaves the old file where it is.
- **`config.json` is read at user level too.** `~/.coding-crew/config.json` sits under the repo's
  `.coding-crew/config.json`, merged per setting with the repo's winning, so a machine can keep
  its own provider model IDs or runtime choices out of the committed file. `plan` tags each value
  with the file that set it; an invalid file's error names which one.
- **`[STEP]` dispatch markers carry `runtime=`** after `model=`.
- **The reviewer's and triage's role preamble lives in their protocol, not in each platform shim.**
  The "establish `ROOT`" block and the read-only rule were copied into all eight shims and had
  drifted: the claude and copilot shims never stated the read-only rule. Each shim is now its
  frontmatter plus `{{PROTOCOL}}`; the tool lists and codex's `sandbox_mode` still enforce it.
- **A new test holds the shims to each other:** `tests/agent-shim-consistency.bats` fails when a
  crew agent's name or description differs across platforms, or a read-only agent is given a
  write tool.

## [1.29.133]

### Changed

- **The verify gate runs every configured check, every time.** After test/lint/typecheck,
  `verify-worktree.sh` runs every other `dev-commands.json` check key that has a command
  (`coverage`, `integration`), and any failure fails the gate. `null` is how a category opts
  out. The coder's `extra_checks` report field and the gate's `--extra` flag are gone. A retry
  that skipped the coder (review-only, not-fixable recheck, clean conflict re-sync, receipt
  retry), or a fix-prompt coder that didn't name the checks again, used to verify without the
  extras an acceptance criterion needed, so the reviewer read that criterion `unmet`.
  `solve-issue` Step 5 runs the same set, so the coder isn't surprised by the gate.
- **`verify.json` names the checks set to `null` as `not_configured`,** in place of
  `not_requested`, and its check entries drop the `requested` field. The reviewer prompt reads
  "Not run by the pipeline, no command configured: …".

## [1.29.132]

### Changed

- **The verify gate keeps a record of what it did.** `verify-worktree.sh` writes
  `dispatch/<n>-<slug>.verify.json`: branch, commit, verdict, and for every check its command,
  result, exit code and full-output log, plus the cached checks it was never asked to run. The
  logs are `dispatch/<n>-<slug>.verify-<check>.log` now, not files inside the worktree, so
  they outlive it. The record replaces `<slug>.verify.ok` as the merge receipt: `merge-branches.sh`
  accepts only a `pass` verdict for the branch's current tip. `ensure-deps.sh`'s per-issue
  markers carry the same `<n>-` prefix.
- **The reviewer is given that record, and told what it cannot count.** The prompt names the
  record and every cached check that didn't run. The reviewer protocol now calls a coder's
  progress notes, commit messages and the issue's `## Progress` section claims, not evidence.
  A reviewer had passed an issue whose integration criterion rested on nothing but the coder's
  own detailed progress note.

## [1.29.131]

### Fixed

- **A criterion that needs a check beyond test/lint/typecheck can now be proven.** A coder
  names the further `dev-commands.json` checks its issue's criteria called for (`coverage`,
  `integration`) in a new `extra_checks` report field; `verify-worktree.sh --extra` re-runs
  exactly those, by name through the cache, and fails the gate if one has no command. The
  reviewer is told every check that ran, with the full-output file for the extra ones, so a
  criterion such as "branch coverage improves from 73.33%" is judged from the real figure.
  Before, these criteria were blocked `criteria-unmet` every round, even when the coder had
  run the commands and they passed.
- **A coder's own failed or un-run extra check stops the issue before the verifier.** Each
  `extra_checks` entry carries its own `checks` result, and the pre-filter demotes `complete`
  when one is `fail` or `not_run`, just as it already did for test/lint/typecheck.
- **A failed per-issue dependency install stops that issue.** On `DEPS: failed` the issue is
  blocked with the install's own reason before its coder is dispatched; it used to carry on
  and fail again at the verify gate. The sprint-level warm-up install still stops nothing.

## [1.29.130]

### Changed

- **crew-afk's pi, codex and copilot launchers now stop polling under `ORCA_ENV=1`, like
  claude's.** Orca identifies pi (through its status extension, from the first prompt on)
  and codex panes as agents, so milestone pushes and the end-of-run push reach them.
  Verified live for pi and codex, each running a sprint from its own orca pane. copilot is
  untested.

### Fixed

- **All four crew-afk launchers keep polling under `HERDR_ENV=1`.** They had stopped
  polling and waited for the end-of-run push, which herdr doesn't reliably deliver. The push
  is still sent, as an extra.

## [1.29.129]

### Added

- **Under `ORCA_ENV=1`, every crew-afk dispatch runs in an orca terminal of its own.** Each
  coder/reviewer/triage worker gets a tab titled `<slug> <agent>` showing its tool calls
  and assistant text live. The worker is still the headless `-p` process, and orca is never
  asked whether it finished: `run.sh` records the child's pid and exit code on disk, and
  crew-afk polls those. It keeps the same hard timeout, treats a pid that vanished without
  an exit code as a failure, and falls back to the plain spawn if the terminal can't be
  created. Without `ORCA_ENV`, and under `HERDR_ENV`, dispatch is unchanged. See
  `docs/orca-support.md#worker-terminals`.
- **`ORCA_ENV=1` in a checkout orca doesn't manage now stops the sprint at preflight.**
  orca only opens terminals in repos it has registered, so every worker used to fall back
  to headless with no tab and no word of why. Preflight now runs `orca worktree show
  --worktree path:<mainRoot>` and names the fix: add the repo in the orca app, or unset
  `ORCA_ENV`.

### Changed

- **crew-afk's orchestrator is reorganised, with no change in behaviour.** Pane-host code
  moves out of `dispatch.mjs` into `orchestrator/lib/pane-host/` (`herdr.mjs`, `orca.mjs`,
  one adapter each, behind `index.mjs`), so `dispatch.mjs` is back to spawning and parsing.
  `pipeline.mjs` keeps the gate order; each stage's body moves to
  `orchestrator/lib/pipeline/` (`verify`, `review`, `merge`, `finish`, `shared`). Where a
  retry re-enters the pipeline is now one table, `resumeRoute(reason)`, instead of four
  flags in `runWorker`. Comments across `dispatch.mjs`, `pipeline*` and `main.mjs` are cut
  back to the constraints they document; the history lives in this changelog.

### Fixed

- **A merge conflict is now retried through the coder, not by merging again.** A conflict
  at the merge gate was retained as `merge-failed`, whose retry skips straight to merge —
  so the same conflict recurred and the issue blocked, as two issues editing one file did
  in a live trial. It is now retained as `merge-conflict`, and its retry routes to the
  coder: the sync step leaves the feature-branch merge conflicted in the worktree
  (`[SYNC-CONFLICT-KEPT]`), the coder resolves it keeping both sides, and verify and
  review re-run on the new commit before it merges. If the sync merges cleanly after all,
  the coder is skipped. Other merge failures keep the merge-only retry.
- **Merge-conflict retries run one at a time.** Two in flight together both resolved
  against the same feature-branch tip, so whichever merged second conflicted again with
  the first's resolution and could spend its retry cap on a conflict its sibling caused.
  A conflict retry now waits (`[CONFLICT-RETRY-WAIT]`) while another is in flight; other
  issues are claimed as before.
- **A rerun after a merge conflict hit the retry cap now resolves it through the coder.**
  It took the restart route, whose sync step blocked on the same conflict straight away.
- **pi and codex worker tabs show readable `[TOOL]` lines.** Their dispatchers write the
  raw event stream to stdout, one line per token delta, and the tab followed stdout. The
  tab now follows stderr for them, which also carries the CLI's own errors (a pi that
  rejected a flag used to show an empty tab).
- **A claude or copilot run that dies on an API error now says so in the trace log and
  its tab.** A quota or auth failure arrives only as a JSON event (claude's error
  `result`, copilot's `session.error`), which no trace line was made from. It is now an
  `[AGENT-ERROR]` line.
- **A worker in an orca tab gets exactly crew-afk's env.** The tab's shell kept its own
  variables alongside crew-afk's, so one crew-afk had unset came back from the shell's
  profile: a copilot worker started with `GH_TOKEN` unset still saw it and failed to
  authenticate. `env.sh` now also unsets what crew-afk doesn't have.
- **crew-afk uses the running platform's own install for its scripts.** With installs for
  several platforms in one repo, the first found won (`.pi/` first) whatever `--platform`
  said. pi's and codex's dispatchers exist only in their own install, so a codex sprint in
  a repo also installed for pi failed every dispatch with exit 127.
- **codex workers can commit again.** codex 0.156 mounts a linked worktree's own git dir
  (`.git/worktrees/<name>`, which holds its `index.lock`) read-only even under the writable
  common dir `dispatch-codex-agent.sh` already named. Every `git add` failed with
  `Read-only file system` and every codex issue blocked. That dir is now a writable root
  too.
- **codex reviews and triage produce a result again.** They ran in codex's read-only
  sandbox, which can't write the result file crew-afk has read exclusively since the
  sidecar-only policy, so every codex review was `review-not-run` and every triage was
  `fixable`. A read-only codex agent now runs in workspace-write with the dispatch dir as
  its cwd and only writable root. `/tmp`, `$TMPDIR`, the repo and `.git` stay read-only.
- **Any retry whose branch no longer merges cleanly hands the conflict to the coder.**
  Only a `merge-conflict` retry used to keep a conflicted sync. Any other retry (a review
  or verify fix, a restart, a review-only retry) aborted it and blocked, which is what
  happens when a sibling merges while an issue waits on its fix. The conflict is now
  added to a coder retry's prompt, and a retry that would have skipped the coder becomes
  a conflict fix. A merge that fails with nothing conflicted still aborts and blocks.
- **Setting both `HERDR_ENV` and `ORCA_ENV` now names the variable to unset.**

- **A pi dispatch can no longer hang on its caller's stdin.** `dispatch-agent.sh` passes the
  prompt as an argument but left `pi`'s stdin inherited, so a `pi` that reads stdin waited
  on whatever the caller held open — a backgrounded shell hung
  `dispatch-agent-prompt-read.bats` indefinitely. `pi` now gets `/dev/null`, as codex
  already gets its prompt file.

- **`notifyTriggeringPane` with no pane host selected no longer falls through to herdr.**
  With neither `HERDR_ENV` nor `ORCA_ENV` set but an ambient `HERDR_PANE_ID` (crew-afk
  launched inside a herdr pane without opting in), each milestone push tried to spawn a
  null command. It now returns `{sent: false, reason: "no pane host"}`.
- **`receipts.sh write` no longer reports a receipt it failed to write.** It never checked
  its own `mkdir`/write, and without `set -e` a full disk or unwritable path still printed
  `RECEIPT: wrote …` and exited 0 — the pipeline took the gate as passed, and
  `close-issue.sh` later refused the close as `close-refused`, pointing at the wrong cause.
  It now exits 1 with `ERROR: cannot write <kind> receipt: <path>`.
- **A failed AC receipt write no longer reruns the coder.** `ac-receipt-failed` used to
  restart the whole issue, though the branch had already passed verify and an all-met
  review. It now carries `receipts.sh`'s error in the reason and takes the verify route:
  no coder, verify + review re-run, then the receipt is rewritten. A second failure blocks
  with that error in `## Blocked`, and a rerun after the fix resumes at verify again —
  the only blocked reason that doesn't restart the coder, since the cause is never the
  branch.
- **A blocked issue is no longer re-blocked as a stale branch on the next run.** Only an
  issue with `## Progress` counted as resumable, so one blocked before it ever wrote
  progress (a worker that reported itself blocked, a dead dispatch, a sync conflict) was
  treated as a fresh dispatch — and once siblings had merged, its own retained branch was
  flagged stale with "delete the branch or reconcile it by hand". A `## Blocked` section
  now counts too: the retained branch is reused and synced with the feature branch (a real
  conflict still blocks), and the coder is told its commits are there. Separately, a
  leftover branch with no commits of its own is now deleted and recreated rather than
  flagged stale, since there is nothing on it to lose.

## [1.29.128]

### Added

- **orca as a second pane host for crew-afk.** `ORCA_ENV=1` selects orca the way
  `HERDR_ENV=1` selects herdr (mutually exclusive — crew-afk exits at startup if both are
  set): one `terminal create --worktree path:<repo> --command "tail -f orchestrator.log"`
  log terminal, a rename of the triggering terminal via `ORCA_TERMINAL_HANDLE`, and one
  end-of-run `terminal send` into it. `doctor`/preflight check `orca status --json` for a
  reachable runtime. The herdr-named functions in `dispatch.mjs` are now backend-neutral
  (`ensurePaneWorkspace`, `ensurePaneLogTab`, `closePaneWorkspace`, `closePaneLogTab`),
  selected by `effects.paneHost`. The end-of-run push is sent only when `orca terminal show`
  reports an `agentIdentity` for the triggering terminal. Unlike herdr's `agent prompt`,
  `terminal send` types into a plain shell too, where the message would run as a command.
  Its timeout is 20s, not herdr's 5s: against a live claude pane, `terminal send` takes ~8s
  to return. Every other orca call is capped at 10s, so a quit orca can't block the sprint
  from starting or exiting. A failed log-terminal create is printed rather than swallowed.
  The pi/codex/copilot skills keep polling under `ORCA_ENV=1`, since orca isn't confirmed
  to recognise those panes as agents and skips the push when it doesn't. See
  `docs/orca-support.md`.

## [1.29.127]

### Changed

- **crew-afk's own process is no longer relaunched into a herdr-hosted pane.** herdr's `pane
  run` cannot report a real exit code back (no `pane wait`, no `exit_code` field anywhere in
  herdr's own responses), so the previous design had to fake completion-detection with a
  sentinel-file poll and an 8-hour blind timeout (`relaunchIntoDedicatedPane`,
  `waitForRelaunchSentinel`) — all removed. Under `HERDR_ENV=1`, crew-afk now just runs in
  whatever pane launched it and opens one extra tab that runs `tail -f
  orchestrator.log` (`ensureHerdrLogTab`), the same design used before that relaunch existed.
  herdr is never asked to host or report on anything load-bearing again; the log file /
  `sprint-state.json` are the only real source of a run's outcome, matching [1.29.126]'s
  `notifyTriggeringPane` fix. `CREW_AFK_RELAUNCHED` and its sentinel-file env plumbing are
  gone with it.

## [1.29.126]

### Fixed

- **A stalled `herdr agent prompt` push into an unattended triggering pane no longer reports
  success.** `notifyTriggeringPane` now passes `--wait --until working --timeout-ms 2000` —
  without it, a push herdr can't actually deliver — hit against a `--no-focus` pane that's
  never attached, exactly how crew-afk creates the triggering pane — still exited 0, so the
  existing `result.code !== 0` check could never catch it. `--wait`
  makes herdr itself confirm the target agent picked the prompt up, surfacing
  `agent_prompt_stalled` as a real, loggable failure instead of a false success.

### Added

- **The front-door process prints a `tail -f orchestrator.log` fallback into the triggering
  pane before it starts waiting on the dedicated run pane.** Every per-issue milestone and
  the final outcome were already durably logged there (`notifyMilestone` writes to `ctx.log`
  before ever attempting the herdr push) — this just tells whoever is watching the triggering
  pane where to look, so a lost push reads as "check the log" instead of a stalled sprint.

## [1.29.125]

### Fixed

- **A skipped or failed herdr milestone push is now visible in `orchestrator.log`, not just
  in a caller-supplied `effects.log`.** `notifyTriggeringPane` now returns `{sent, reason?}`
  instead of void — `effects.log` is a dead sink for most callers (buffered into an array
  nothing reads, mirrored to stderr only under `CREW_VERBOSE`, never written to
  `orchestrator.log`) — so `notifyMilestone` can log a `[MILESTONE-PUSH-SKIPPED]` line via
  `ctx.log` whenever the push didn't go out, including the no-`HERDR_PANE_ID` case, which
  previously returned silently with no log line at all.

## [1.29.124]

### Fixed

- **`ensure-deps.sh`'s mode cache no longer drops `coverage`/`integration` on merge.**
  `_merge_mode_cache`'s field list had drifted out of sync with
  `write-commands-cache.sh`'s own `FIELDS`, which already covers both — any prior run's
  `coverage`/`integration` detection was silently erased the next time install/docker-mode
  detection wrote to the same cache file.
- **A failed herdr push out of `notifyTriggeringPane` is no longer invisible.**
  `herdrExec`/`spawnWithTimeout` resolve rather than reject on a nonzero exit, so the
  existing `catch` only ever caught a thrown error (e.g. herdr missing from `PATH`) — a
  real push failure (`agent_not_ready`, no agent in that pane, herdr unreachable) went
  unlogged even as a best-effort line. Both the nonzero-exit and thrown-error paths now log
  to `ctx.log`. `notifyMilestone` also now always logs its milestone locally first, so a
  sprint's milestones are visible in `orchestrator.log`/stderr even for callers not running
  under herdr, instead of only being discoverable after the fact from the final summary.

## [1.29.123]

### Added

- **The triggering herdr pane now hears from an issue as soon as its coder finishes**, not
  just at the next terminal outcome (complete/partial/blocked). The coder is the longest
  single step in the pipeline, and verify/review/merge can still take a while after it —
  previously the triggering pane heard nothing about that issue in between, which reads as
  silence indistinguishable from a stuck sprint.

## [1.29.122]

### Fixed

- **`merge-branches.sh` no longer routes merges through `docker compose run`.** The
  docker-mode merge (added in 1.29.120) existed only so a project's commit-msg hook
  (lefthook -> commitlint -> pnpm, etc.) had its tooling available when that tooling only
  lived inside the project's docker service. Every merge now runs `git merge --no-ff
  --no-verify` on the host instead: the merge commit's message is a fixed template this
  script generates, so a hook has nothing useful to lint, and skipping it removes the need
  for the hook's tooling at all. This also removes a real hang: `MAIN_ROOT` never gets its
  own dependency install the way worker worktrees do, so the docker-mode merge's container
  was always cold — one sprint hung 16+ minutes with `pnpm commitlint --edit` stalled on a
  registry fetch inside a fresh container, blocking the whole sprint behind it (see the
  next entry). `CREW_MERGE_DOCKER` is gone with it.
- **A hung merge or close call can no longer freeze the whole sprint indefinitely.**
  `mergeAndClose` runs `merge-branches.sh`/`close-issue.sh` via `effects.bash`, which blocks
  Node's single event loop for the child's entire lifetime — the same hazard `dispatch.mjs`
  already documents and worked around for herdr dispatch, but never applied here. A new
  `--merge-timeout <minutes>` option (default 10) now bounds both calls; a timeout demotes
  the issue to `merge-failed` (retried next round like any other merge failure) and runs
  `git merge --abort` to leave the working tree clean instead of mid-merge.

## [1.29.121]

### Added

- **crew-afk now pushes a per-issue outcome notification to the triggering herdr pane**,
  not just one at the very end of the sprint. Under `HERDR_ENV=1`, a caller previously had
  to poll `[STEP]` log lines to see progress on individual issues between the sprint's
  start and its final `notifyTriggeringPane` nudge — `mergeAndClose`, `finishPartial`, and
  `finishBlocked` now each push a one-line complete/partial/blocked notification (with
  round and reason) as soon as that issue reaches a terminal outcome for the round.
  No-op off-herdr, same as the existing end-of-run notification.

### Fixed

- **Dispatch trace tagging (`--slug`, `onTrace`'s log prefix) now carries the issue's own
  `NN-<slug>` stem**, matching the `[STEP]` lines and prompt/report filenames that already
  used it, instead of the bare slug. `dispatch.mjs` also tags trace lines with `round=`
  alongside `slug=`.
- **`merge-branches.sh`'s docker-mode detection now checks every dep-install script root
  `ensure-deps.sh` checks**, not just the project root, and logs why docker mode is off at
  each guard instead of failing silently.

## [1.29.120]

### Fixed

- **`merge-branches.sh` now merges inside the project's own docker service when the sprint
  is running in docker mode**, instead of always on the host. A project whose dev tooling
  (e.g. a package manager a commit-msg hook shells out to) only exists inside its docker
  container previously had every merge commit fail closed on the host — indistinguishable
  from a real merge conflict — because the merge step never checked the same
  `agent.install-mode` flag `verify-worktree.sh` already trusts. Docker-mode merges now also
  carry `GIT_AUTHOR_NAME`/`EMAIL`/`GIT_COMMITTER_NAME`/`EMAIL` into the container, since a
  container never mounts `~/.gitconfig` and would otherwise fail the merge commit with
  "Please tell me who you are". `CREW_MERGE_DOCKER=off` is the rollback lever.

## [1.29.119]

### Changed

- **crew-afk's coder/reviewer/triage dispatches are now always headless, even under
  `HERDR_ENV=1`.** Per-worker herdr panes (`dispatchViaHerdr`) drove each dispatch as a
  long-lived interactive REPL in its own tab — idle-polling, a trust-dialog keystroke
  table, and pane-reuse bookkeeping across retries — confirmed live that headless `-p`
  already runs correctly with a herdr server active in the background, so that machinery
  bought only live per-worker pane-watching and a retry-continuity bonus headless retries
  already work fine without. `HERDR_ENV=1` still gives crew-afk's own process a dedicated
  pane (`relaunchIntoDedicatedPane`) and still nudges the triggering pane at the end of a
  run — only individual dispatches changed. `CREW_HERDR_KEEP_PANE` is gone with it.

### Added

- **claude's headless dispatches now capture cost/error/turn metadata that used to be
  discarded.** `--output-format stream-json`'s terminal `result` event carries
  `total_cost_usd`, `duration_ms`, `num_turns`, `is_error`, and `permission_denials`;
  `dispatch.mjs` only ever kept `.result` (the final text). A dispatch that ends
  `is_error: true` with no usable sidecar now counts as a process-level failure the same
  way a non-zero exit already does, and a non-empty `permission_denials` now shows up in
  the `[DISPATCH-FAIL]` trace line. Sprint-wide cost/duration/turn totals accumulate in
  `sprint-state.json` (`state.sh dispatch-cost`) and crew-summary.sh now prints a `Cost:`
  line when any were recorded. Claude-only for now — pi/codex/copilot have no confirmed
  equivalent field.

## [1.29.118]

### Fixed

- **Command discovery (`discover-commands.sh`) now only asks a model about fields still missing
  from `.coding-crew/dev-commands.json`**, instead of re-asking all eight fields whenever the
  cache was missing even one (e.g. a repo that predates `coverage`/`integration`) — a partial
  re-discovery could silently overwrite a hand-edited value (e.g. `test` set to `make testUnit`)
  with a freshly-guessed default. `--refresh`/`CREW_COMMANDS_REFRESH=1` still re-asks every
  field unconditionally, the one supported way to force a correction.

## [1.29.117]

### Changed

- **crew-afk's dispatch step now tells every platform to use the harness's own background-task
  tracking (`run_in_background`), not a manual shell `&`/`disown` with redirected output** — the
  manual form bypasses the completion notification, so no summary ever reached the caller when
  the sprint finished.

## [1.29.116]

### Fixed

- **crew-afk's `[STEP]` log lines now carry the issue number**, e.g. `slug=01-alpha` instead of
  `slug=alpha`, matching the `NN-<slug>` naming already used for dispatch stems and issue files —
  making the round-by-round trace easier to cross-reference against `.scratch/<slug>/issues/`.

## [1.29.115]

### Added

- **GitHub Issues as a second tracker backend**, selected via `configure-tracker`, usable
  across the whole pipeline (`crew-grill`/`crew-brainstorm` → `crew-afk` →
  `crew-address-findings`) alongside the existing local-file backend. GitHub is the live
  source of truth for issue content/status — no local mirror file to drift out of sync — so a
  sprint can resume on a different machine once the feature branch is pulled and `gh auth
  login` is done. `.coding-crew/docs/issue-tracker.md` gains optional YAML front matter
  (`tracker: github`/`repo: owner/name`) read by a shared `tracker-config.mjs`/
  `tracker-config.sh`; missing front matter defaults to `{tracker: "local"}`, so existing
  installs need no changes. `orchestrator/lib/tracker.mjs` is now a thin factory over
  `trackers/local.mjs` (today's logic, unchanged) and the new `trackers/github.mjs`, sharing
  markdown-body parsing via `trackers/body-format.mjs` so both backends produce identical
  `parseIssue` shapes. The GitHub backend uses one batched `gh issue list --state all` call
  per dispatch pass (no N+1), a milestone per feature slug, four pre-seeded triage labels
  (`done`/`wontfix` map to close-reason/state instead of labels), `## Blocked by` issue-number
  references as the dependency graph (no sidecar file), and a PRD-as-pinned-issue convention.
  `close-issue.sh`, `mark-issue-done.sh`, and `promote-findings.sh` all branch on the
  configured backend, re-fetching an issue's live body before closing it rather than trusting
  a cached copy. `configure-tracker` gains a `gh auth status` check, a repo-override prompt,
  and idempotent creation of the four triage labels for the `github` choice.

## [1.29.114]

### Fixed

- **Two `crew-afk run` invocations for the same feature-slug could race** — each relaunches
  into its own dedicated herdr pane with no shared state between them, so both can dispatch
  the same issue's coder under the exact same deterministic agent name; herdr rejects the
  loser (`agent_name_taken`), which used to burn a real attempt off that issue's 2-attempt
  retry cap for a collision its own code never caused. `main.mjs` now holds a pidfile lock at
  `.scratch/<slug>/.crew-afk.lock` for a run's whole lifetime, so a second `run` for the same
  slug refuses outright instead of racing (a stale lock — dead pid — is reclaimed silently).
  An `agent_name_taken` start failure is also now tagged and retried unconditionally, bypassing
  the retry cap, in case one is still hit some other way.

## [1.29.113]

### Fixed

- **A crew-afk sprint's dedicated herdr pane could be mistaken for a stray duplicate and
  killed by whatever is watching the triggering pane** — both the front-door process (waiting
  on the relaunched sprint) and the relaunched sprint itself showed up in `ps` as plain
  `node .../main.mjs run ...`, indistinguishable from a runaway duplicate invocation. Each now
  sets its own `process.title` (`crew-afk-frontdoor (waiting on dedicated pane — do not kill)`
  / `crew-afk-sprint (<feature-slug>)`), so `ps aux` is self-explanatory without needing to
  read the skill doc first.
- **`solve-issue`'s Step 5 cache-fast-path trusted `$MAIN_ROOT` literally, with no fallback if
  it was ever unset** — unlike `write-commands-cache.sh`'s own `--git-common-dir` fallback for
  exactly this case. If `$MAIN_ROOT` is empty when this check runs (e.g. a coder unsets it to
  dodge an unrelated test-env leak), it always concluded `DISCOVER` even when the real, correct
  shared `.coding-crew/dev-commands.json` cache already existed — and a wrong rediscovery
  answer then overwrites that shared cache for the rest of the sprint. Gives the check the same
  fallback, via a new `MAIN_ROOT_EFFECTIVE`, without redefining `$MAIN_ROOT` itself.
- **~90 `dep-install`/`verify-worktree` bats tests assumed `$MAIN_ROOT` is never set in their
  shell**, but crew-afk's own dispatch always exports it for every worker — so running these
  tests from inside a real dispatch environment (exactly what a coder solving an issue in this
  repo does) broke tests meant to exercise the "no `--main-root` passed" / "no `$MAIN_ROOT` set"
  fallback paths, and was the actual reason a coder would ever need to unset it (see above).
  Each affected file's `setup()` now unsets `MAIN_ROOT` itself instead of assuming the caller's
  shell never has it.
- **A not-fixable-recheck round dispatched `crew-triage` again anyway**, despite its own
  `[SKIP-WORKER]` log line promising "no triage and no coder dispatch, in case the failure was
  transient." `handleVerificationFailure` always re-triaged on any verify failure, and the
  `skippedWorker` flag meant to signal "skip that" was set but never read anywhere. The recheck
  round now reuses the prior round's triage verdict verbatim instead of paying for a redundant
  dispatch — the retry cap (2 attempts) still blocks the issue exactly as before.

## [1.29.112]

### Fixed

- **`crew-afk run` relaunched into its own dedicated herdr pane (`HERDR_ENV=1`) with a
  duplicated `run` argument** — `relaunchIntoDedicatedPane` hardcoded a `"run"` token ahead of
  the forwarded `argv`, but every platform launcher already passes `run` explicitly in that
  same `argv`, so the relaunched process saw `run run --platform ... --feature-slug ...` and
  `parseArgs` rejected the second `run` as an unrecognized argument. Dropped the redundant
  hardcoded token — `parseArgs` already defaults to command `run` when none is given, so
  nothing depended on it. Only affects the `HERDR_ENV=1` relaunch path.

## [1.29.111]

### Fixed

- **The claude, copilot, and codex `crew-afk` launcher SKILL.md bodies had drifted back over
  the 500-word budget** (`tests/crew-afk-launcher.bats`'s "it replaced ~2,400" check), each
  having grown its own sentence describing the worker process type and concurrency default.
  Trimmed those sentences to the same information in fewer words — no behavior change.

## [1.29.110]

### Fixed

- **A coder worker whose worktree found no `docker-install.done` marker fell back to hand-running
  `docker compose run` for its own install, with no locking at all** — unlike the mechanized
  `ensure-deps.sh`/`docker-install.sh` path, which already serializes every docker install
  through a shared `mkdir`-based lock. Multiple coders reaching that fallback around the same
  time (confirmed from a real `orchestrator.log`: two issue slugs both logged `DEPS: docker`
  deferred in the same round) each started their own container against the same shared named
  volume — the redundant-install/lock-contention symptom this fixes. `docker-install.md`'s
  install step now delegates to `docker-install.sh` itself (which already regenerates the
  override, checks the fingerprint stamp, and guards against docker-in-docker nesting) instead
  of reimplementing all of that by hand; on a lock timeout (exit 4) it now reports `BLOCKED`
  rather than falling back to an unlocked install. Also raises `ensure-deps.sh`'s and
  `docker-install.sh`'s shared install timeout default from 600s to 1800s, and the delegated
  call's own `--lock-timeout` to 1800s, so a large first-time install has room to finish instead
  of forcing every later caller to fall back to the (now-removed) unlocked path.

### Added

- **crew-afk's own process now runs in a dedicated herdr pane, not inside the triggering agent's
  own pane.** Under `HERDR_ENV=1`, `run` relaunches itself into a fresh tab in the shared herdr
  workspace (`relaunchIntoDedicatedPane`, reporting completion back to the front-door process via
  a sentinel file — herdr's `pane run` has no way to read back a plain command's exit code) and
  closes that tab itself once done. This frees the triggering pane for other use and makes the
  sprint's own round-by-round narration show up live, natively, in its own pane. The previous
  `tail -f` "log tab" (`ensureHerdrLogTab`/`closeHerdrLogTab`) is now redundant and removed.
- **`Sprint.installDeps()` streams the install command's own live output** (via
  `spawnWithTimeout`'s `onLine`, the same mechanism the headless dispatch path already used for a
  worker's own trace) instead of capturing it wholesale and reporting one summary line after the
  fact — previously the one step with zero visible progress for however long a cold-cache
  install took. `ensure-deps.sh`/`docker-install.sh` now `tee` the actual install command's
  output live rather than fully buffering it into a temp file, so this has something to stream.

## [1.29.109]

### Fixed

- **A crew-afk run launched from inside an existing herdr pane (`HERDR_WORKSPACE_ID` reused)
  left its log tab — the one tailing the sprint's trace log — open forever.** `closeHerdrWorkspace`
  already closes that tab when this run created its own workspace, but no-ops on a reused one, since
  closing someone else's workspace would yank the terminal out from under whoever launched it. The
  log tab it creates inside that reused workspace is still this run's own, though. A new
  `closeHerdrLogTab`, called alongside `closeHerdrWorkspace` at the end of every run regardless of
  outcome, now closes it directly.

## [1.29.108]

### Fixed

- **`add-tests` had no step that ever ran an install command**, even though its own step 1
  discovers one (`install` in `.coding-crew/dev-commands.json`). A run against a repo whose
  dependency step is only a documented Makefile target (e.g. `make deps`) could silently fall
  back to a guessed package-manager command instead of that override — the same override
  `ensure-deps.sh` already trusts. `add-tests` now declares a dependency on the `dep-install`
  skill and invokes it (unconditionally in docker mode, or on a missing-dependency failure in
  host mode) before running coverage.

## [1.29.107]

### Changed

- **`crew-afk` dispatches issues from a continuous worker pool instead of round batches.**
  Workers now pull from one live queue for the whole sprint, so a freed slot picks up
  whichever issue is dispatchable the moment it is, instead of waiting for every issue in
  the same round to finish first. Per-issue attempt tracking (`state.sh`'s new `attempt`
  subcommand) replaces the sprint-wide round counter, and an explicit per-issue retry cap
  (2 attempts before blocking) replaces the old "two dry rounds" stall detection.
  `--max-rounds` now caps attempts per issue rather than the sprint's total round count.

### Fixed

- **A sprint that hit `--max-rounds` could leave a CRITICAL review finding stuck at
  `deferred-findings` forever.** The capped exit broke out of the sprint loop without
  flushing parked fix issues to `ready-for-agent`, unlike every other exit path — a
  pre-existing bug in the old round-batch loop, carried forward until now. The `--max-rounds`
  exit now flushes findings before ending the sprint, same as a clean finish or a stall.

## [1.29.106]

### Fixed

- **`detect-mode.sh`'s git-containment check still forced `host` mode on Windows** even
  after v1.29.102's macOS symlink fix — the same root cause (a bare string comparison of two
  differently-rendered paths) but a different mismatch: `git rev-parse --show-toplevel`
  renders a Windows-absolute path as a bare drive letter (`C:/Users/...`), which a bash
  `pwd -P` comparison never matches. Removed the string comparison entirely — checking
  `-C "$PROJECT_ROOT" rev-parse`'s own exit status already answers "is this inside a git
  repo," since it resolves from inside `$PROJECT_ROOT` itself; there was never a need to
  compare rendered paths as strings in the first place.
- **`orchestrator/main.mjs` and `orchestrator/lib/dispatch.mjs` used `os.homedir()` instead
  of `$HOME`** to resolve every user-level path (agent definitions, crew-afk's own
  scripts dir). On Windows, `os.homedir()` reads `USERPROFILE`, not `HOME` — the documented,
  portable override (`TARGET_REPO=$HOME`) was silently ignored there, and a user-level
  install could never be found from a repo with no project-level copy of its own. Both now
  prefer `process.env.HOME` when set.

## [1.29.105]

### Fixed

- **A drive-letter Windows path from `git rev-parse --path-format=absolute --git-common-dir`
  was still getting the `$dir/` prefix wrongly prepended**, in `dispatch-codex-agent.sh`,
  `receipts.sh`, `verify-worktree.sh`, `detect-mode.sh`, and `ensure-env.sh` — the same five
  scripts the v1.29.100 `--path-format=absolute` fix touched, and the same underlying bug: git's
  own idea of "absolute" on Windows is `C:/Users/...`, which doesn't start with `/`, so the
  `case` guard each of these added to catch an already-absolute path never matched it and fell
  through to the relative-path branch anyway. Observed in `dispatch-codex-agent.sh` as a mangled
  `sandbox_workspace_write.writable_roots=["<worktree>/C:/Users/.../.git"]` — a codex worker's
  sandbox would have kept the real git dir read-only, the exact failure the v1.29.100 fix was
  meant to prevent. Each `case` now also matches `[A-Za-z]:*`.

## [1.29.104]

### Tests

- `dep-install-ensure-env.bats` had the same bug just fixed in `dep-install-docker-install.bats`:
  three tests set up a *dangling* symlink (target deliberately nonexistent) via a raw `ln -s`,
  which fails outright on Windows without symlink privilege — unlike a symlink to a target
  that already exists, which Windows/MSYS silently substitutes with a copy even without that
  privilege (confirmed from the CI logs: the sibling "symlinked AGENTS.md" tests elsewhere in
  the suite, which link to an existing file, already pass on Windows). Factored into a
  `make_dangling_symlink` helper that skips when the platform can't produce one.

## [1.29.103]

### Tests

- Several more bats tests hard-coded Unix/Linux-only assumptions surfaced by a Windows CI
  run: a raw `ln -s` in test setup (no fallback, unlike the scripts under test) that fails
  without symlink privilege; a `git rev-parse --git-common-dir` comparison missing the
  `--path-format=absolute` the script under test actually uses; two path-fragment assertions
  comparing against forward-slash literals against Node's native-separator output; and a
  fixed 15s dispatch-preflight timing bound that doesn't account for how much more expensive
  process spawning is under Git Bash's fork() emulation. Each now matches the same rendering
  the code under test produces, or gets a platform-specific bound.
- Skipped two `verify-worktree-docker.bats` docker-in-docker guard tests on Windows: CI logs
  show the recipe's real `docker.exe` runs instead of the test's stub even with the shell
  pinned to `sh`, so something in how GNU Make's Windows port resolves the recipe's `PATH`
  isn't reachable from this test's own prepend. The guard logic itself is still covered on
  Linux/macOS; fixing the Windows case needs an actual Windows box to iterate against.

## [1.29.102]

### Fixed

- **`detect-mode.sh` no longer falsely forces `host` mode for a project root reached through
  a symlink.** Its git-containment check compared `$PROJECT_ROOT` verbatim against
  `git rev-parse --show-toplevel`'s output, which git returns with symlinks already resolved.
  On macOS, `$TMPDIR` sits under `/var`, itself a symlink to `/private/var`, so every project
  root under a tmp dir failed this comparison and skipped the Makefile-based docker scan
  entirely, before ever looking at the Makefile. `$PROJECT_ROOT` is now canonicalized with
  `pwd -P` before the comparison.

## [1.29.101]

### Fixed

- **`detect-mode.sh`'s Makefile-target scan no longer relies on recipe text alone to catch
  docker.** A `make -n <target>` whose expanded recipe runs a nested `make` that only then
  invokes docker (or invokes it via a target chain the grep for `docker (compose|run|exec)`
  doesn't match) previously fell through to `host` mode. The scan now also shadows `docker`
  and `docker-compose` on `PATH` with stub binaries that just log their invocation, so any
  dry run that actually executes one — through however many layers of indirection — still
  flips the result to `docker`.

### Tests

- Several bats tests hard-coded assumptions that don't hold on Windows/MSYS or under root:
  path-separator comparisons, `CREW_SCRIPTS`/git mount path rendering, symlink-vs-copy `.env`
  fallback, and `chmod 000` actually denying the owner a read. Each now compares against the
  same tool's own rendering of the platform-specific value, or skips when the platform doesn't
  enforce the permission being tested, instead of asserting a Unix-specific literal.

## [1.29.100]

### Fixed

- **`git rev-parse --git-common-dir` is now called with `--path-format=absolute`** in
  `dispatch-codex-agent.sh`, `receipts.sh`, `verify-worktree.sh`, `detect-mode.sh`, and
  `ensure-env.sh`. Without it, a bare drive-letter Windows path (e.g. `C:/Users/...`) doesn't
  start with `/`, so each caller's own "is this already absolute" branch wrongly treated it as
  relative and mangled it.
- **`dep-install`'s Makefile-target scans (`detect-mode.sh`, `detect-service.sh`,
  `ensure-env.sh`, `host-install.sh`) no longer gate on `make -n <target>`'s exit status.** A
  recipe whose expanded text contains the literal word "make" (not just the `$(MAKE)` variable)
  makes some GNU Make builds — notably 3.81, the last GPLv2 version and still macOS's default —
  actually run it instead of only printing it under `-n`, so a real (sandboxed, daemon-less)
  docker failure could make the dry run exit non-zero even though the recipe text itself was
  right there in its output. Each now treats a non-empty dry-run as the "target exists" signal.
- **`ensure-env.sh` and `gen-override.sh` fall back to copying instead of symlinking** when
  `ln -s` doesn't produce a real symlink — the default on Windows without Developer Mode or
  elevation, where MSYS's own undocumented fallback can otherwise silently substitute a
  hardlink or copy that this code then trusted without verifying.

## [1.29.99]

### Fixed

- **`crew-afk` no longer tears down a worktree whose worker process status is unconfirmed.**
  `finishPartial`/`finishBlocked` only skipped closing the herdr pane when `worker.dispatch.herdrFailed`,
  but still removed the worktree underneath it — a reused herdr pane's `--wait` can falsely settle
  on a stale idle/done from a prior turn, or sit on a blocked dialog, so the underlying agent
  process may still be alive. Both paths now keep the worktree in place too when `herdrFailed`,
  matching the existing `keepWorktree` reuse path, so next round's `ensureWorktree` can reuse it in
  place instead of racing a live process for its own directory.
- **`ensure-deps.sh`'s cached-install re-run no longer aborts under bash 3.2 (macOS's stock
  `/bin/bash`) when there's no captured git env.** `env "${GIT_ENV_LINES[@]}" ...` treats an empty
  array as unbound under `set -u` on bash < 4.4; switched to `"${GIT_ENV_LINES[@]+"${GIT_ENV_LINES[@]}"}"`.
- **`dep-install`'s `ensure-env.sh`/`gen-override.sh` worktree-vs-main-root comparisons now work on
  Windows.** Both used bash's `-ef` (device/inode identity), which MSYS's NTFS emulation doesn't
  reliably support; both now compare `pwd -P`-resolved paths instead.
- **CI installs a bash >= 4 on macOS runners** before any test step runs, since Apple has frozen
  `/bin/bash` at 3.2 (GPLv2) and several scripts (`declare -A`, empty-array expansion under
  `set -u`) require bash >= 4.

### Added

- **`solve-issue` now tells a bug-fix issue to fix shared behavior at the function every caller
  routes through**, not only at the call site the issue names, so a guard added at one caller
  doesn't leave every sibling still broken.
- **`solve-issue` now commits after every TDD GREEN, not only once at the end**, via
  `commit-changes.sh --prefix "[<slug>][WIP]"`, so a dispatcher timeout that kills a run mid-loop
  still leaves a resumable commit on the branch instead of an indistinguishable-from-unstarted
  worktree. These WIP commits get squashed away before merge.
- **`tdd`'s refactor checklist now includes removing abstractions that cycle didn't earn its
  keep** (an interface with one implementation, config for a value that never changes).

## [1.29.98]

### Fixed

- **`crew-afk`'s herdr pane/tab titles now carry the issue number.** `dispatchViaHerdr` built the
  visible tab label and pane title from the bare issue slug alone (e.g. `implement-user-auth
  (coder)`), so a human scanning panes across multiple issues and rounds couldn't tell which
  pane belonged to which issue — only the internal herdr agent name carried the `i<N>-` prefix.
  Both now show `#<issueNumber> <slug>` when an issue number is known.

## [1.29.97]

### Removed

- **Dropped CodeGraph support.** `ensure-codegraph.sh` (and its dedicated pipeline step, run
  between deps and dispatch) is gone, along with the `codegraph`/`codegraph_explore` search
  fallback in `crew-coder`'s protocol and every platform file, and the codegraph-preference
  callout in `crew-brainstorm`/`crew-grill`. Workers fall back to keyword search (`Grep`/`grep`)
  unconditionally now; nothing reads or writes a `.codegraph/` index anymore.

### Changed

- **`discover-commands.sh` (used by `add-tests`) now tells its command-discovery prompt to report
  a Makefile target's own invocation** (e.g. `make test`) rather than a paraphrased "equivalent"
  command, since the recipe can hide guards, prerequisites, or CI/local conditionals a paraphrase
  would drop.

## [1.29.96]

### Added

- **`dep-install` skips a redundant install when manifests are unchanged since its own last
  successful run.** `host-install.sh` and `docker-install.sh` now fingerprint every recognised
  lockfile/manifest (`manifest-fingerprint.sh`) before doing any ecosystem detection, and skip
  straight to done on a match. Both scripts gain `--force` to bypass that fast path, and the
  skill's own retry rule (triggered by a module-not-found error) now passes it — otherwise the
  retry would see the same unchanged manifests and skip itself again, making the retry a no-op.

## [1.29.95]

### Changed

- **`upgrade-deps` now also scans for advisories on transitive-only dependencies.**
  Cross-referencing an audit against the step-2 inventory alone misses any advisory on a
  package that never gets its own row there (e.g. `follow-redirects` pulled in only via
  `axios`). After cross-referencing, the skill now scans the raw audit output a second time
  for advisories with no matching step-2 row, names the direct dependency pulling each one
  in, and checks whether another issue in the same batch already resolves it as a side effect
  of its own bump before filing a duplicate.
- **Major-bump review step 6a (tarball diff) is now a required minimum, not skippable in favor
  of the changelog text search (6e).** 6b–6d must each be attempted and their result — including
  "skipped because X" — stated in the issue; a silent omission read as "not checked" is
  indistinguishable from "checked and clean" to whoever picks up the issue next.
- **"It's just a dev-tool/config dependency" no longer excuses downgrading a major bump's
  status on its own.** That reasoning is about blast radius, not whether behavior changed, and
  a lint/build tool major can still hide a judgment-call regression (e.g. mass-suppressed lint
  rules) that the mechanical checks won't catch. Only a proven zero-code-diff still downgrades.

## [1.29.94]

### Removed

- **Dropped `crew.lock`, `--version`, `--from-lockfile`, and `bootstrap.sh`'s matching flags.**
  The pinned-version team-distribution flow only refreshed `crew.lock` when `--version` was
  explicitly passed — a plain re-install (the common case) left a previously pinned lockfile
  stale with no warning, and `--update` would silently keep "updating" against that stale pin.
  `--update` now always reads `.coding-crew/manifest.json`, which every install already writes
  unconditionally.

## [1.29.93]

### Changed

- **`crew-coder`, `crew-code-reviewer`, and `crew-triage` reports are now read exclusively from
  their `<slug>.<role>.report.json` sidecar file.** `report.mjs` no longer falls back to scanning
  a dispatch's final message for a fenced ` ```json ` block or the older markdown headings
  (`Status:`, `Branch:`) — a missing or invalid sidecar is read as the fail-closed state
  (`blocked` for a worker, `unmet` for a review, `fixable` for triage) deterministically, the
  same way for every platform and for both the headless and herdr dispatch paths.
  `dispatchViaHerdr` drops its pane-text-scraping fallback (`extractHerdrReply` and its
  echo/end-marker heuristics) to match: a herdr pane that settles idle/done with no sidecar now
  fails the same way the headless path already did, instead of reconstructing a result from
  rendered terminal text — the least robust, least-verified code in that file.
- **`crew-coder` no longer writes a per-worker `traces/<branch>.log` file.** The `[START]`/`[DONE]`
  trace was a write with no reader now that `report.mjs` only ever reads the sidecar; removed
  outright rather than trimmed further.

## [1.29.92]

### Changed

- **`upgrade-deps`'s major-bump review is now five mechanical signals instead of a single
  changelog text search.** Step 6 ("Mechanical impact signals") now runs, in order: a tarball
  diff between the current and target versions (proves zero code change when metadata/docs are
  all that moved), a structural API diff against the call sites step 5 found, breaking-change
  commit mining against the package's declared repo, a disposable-worktree
  typecheck/test/lint run at the bumped version, and — last resort — the changelog text search
  step 6 used to do alone. A major bump whose tarball diff is provably empty, with no confirmed
  export break and a clean worktree run, now downgrades to `Status: ready-for-agent` instead of
  always escalating to `ready-for-human`; every other major-bump case still escalates
  regardless of how many mechanical checks came back clean, since those checks are proxies for
  behavior that could still have changed underneath them. Step 4's `npm ls`/`why` conflict scan
  is now paired with a resolver dry-run (`npm install --dry-run`, `pnpm add --lockfile-only`, or
  `yarn up --mode=update-lockfile`) so the safety checklist reports the actual post-bump
  resolution instead of inferring it from today's tree. The skill also resolves
  `dev-commands.json`'s `typecheck` field up front (via `add-tests`'s own discovery/cache
  mechanism) so step 6d has a real command to run.

### Fixed

- **`.worktreeinclude`'s `.env` entry is now provisioned into a worktree as a real copy
  instead of a symlink.** A symlink to mainRoot's absolute path resolves to a path that
  does not exist for a worker running inside a container that bind-mounts only the
  worktree, so a from-worktree read/write of `.env` failed with ENOENT even though the
  file was "there" from the host's point of view. Every other `.worktreeinclude` entry
  (`node_modules`, `.venv`, `docker-compose.override.yml`, …) is still symlinked.

## [1.29.91]

### Changed

- **crew-afk keeps a failed herdr dispatch's pane open by default instead of closing it
  immediately.** A `DISPATCH-FAIL` used to close the tab the moment it was logged, so the one
  thing worth inspecting — what the pane actually rendered — was already gone. `CREW_HERDR_KEEP_PANE`
  is no longer opt-in for this; set `CREW_HERDR_KEEP_PANE=0` to restore the old close-on-fail
  behavior (e.g. to avoid panes piling up in unattended CI). A retry's fresh dispatch name now
  folds in the round number (`i42-r2-...`) so it never collides with a still-open kept pane from
  an earlier round under `agent_name_taken`.
- **An `AC: unmet` review verdict now reuses the coder's already-open herdr pane for its retry**,
  the same way a verify failure already did, instead of always starting the fix cold.
- **A worker dispatch that died (timeout, process crash, herdr transport failure) is now retried
  as `partial` instead of `blocked` when its branch already has commits** — there is real work
  worth resuming next round, not just a repeat failure to report.
- **A coder's own honest partial self-report now reuses its already-open herdr pane for the
  retry too**, the same one-reuse-per-issue bound `AC: unmet` and a fixable verify failure
  already get.
- **The JS-side kill on a `herdr agent prompt` call now waits 2 minutes past herdr's own
  `--timeout` before firing**, instead of racing it at the same instant. That race could let our
  own `SIGKILL` win and erase herdr's chance to ever print the `agent_prompt_stalled`/`timeout`
  JSON its exit is diagnosed from, leaving a `DISPATCH-FAIL` with empty stderr and a
  falsely-false `timedOut`; the JS-side timer now only backstops a herdr CLI that hangs without
  ever honouring its own `--timeout`. Herdr call failures also now propagate the CLI's actual
  exit code instead of always logging `1`.
- **A herdr `agent prompt` failure with no stdout/stderr at all now runs a one-off `herdr status`
  check** to say whether the server crashed or restarted mid-sprint, or is still running (a
  transport/session-specific hiccup with that one pane) — previously this logged identically to
  every other silent failure, with no way to tell which one retrying would fix.
- **`ensureWorktree` no longer stalls on a branch whose tree is byte-identical to `base`'s**, even
  though ancestry can't see it as a fast-forward (a squash elsewhere produces a new commit
  carrying the same tree). That branch holds no unique work — typically debris left by a prior
  run whose commits were later squashed into the feature branch and never cleaned up — so it's
  deleted and recreated fresh from `base` instead of stalling for a human. A real ancestry
  mismatch with actual unique content still stalls, unchanged.

### Added

- **`add-tests` skill**: discovers the project's coverage/integration commands, ranks
  under-covered files by external-dependency import > recent-diff touch > inverse coverage,
  resolves a per-ecosystem mocking convention (repo precedent > built-in defaults > ask-once,
  cached to `test-conventions.md`), routes findings to a real or explicitly-labeled
  "component test (mocked)" tier, and hands them to `to-issues` as `ready-for-agent` issues
  rather than slicing/publishing them itself. The shared `discover-commands.sh`/
  `write-commands-cache.sh` cache (`dev-commands.json`) grows two new fields, `coverage` and
  `integration`, following the same only-if-documented/else-null convention as the existing six.
- **`upgrade-deps` skill**: audits outdated npm/yarn/pnpm dependencies across a monorepo for
  security-advisory exploitability, transitive/peer conflicts, and real call-site usage, with a
  targeted changelog review for major bumps, then files `ready-for-agent`/`ready-for-human`
  issues (batched for trivial in-range bumps, one per risky package or coupled group otherwise)
  with a required safety checklist and test additions, for `crew-afk`/`solve-issue` to execute.
  Never touches `package.json`, lockfiles, or `node_modules` itself.

## [1.29.90]

### Added

- **A user-level install now honors each platform's own config-dir override instead of always
  writing under `$HOME`.** `install.sh`/`uninstall.sh` previously hardcoded `$HOME/.claude`,
  `$HOME/.copilot`, `$HOME/.pi/agent`, `$HOME/.codex` at user scope, so a user who points their
  CLI elsewhere via `CLAUDE_CONFIG_DIR`, `COPILOT_HOME`, `PI_CODING_AGENT_DIR`, or `CODEX_HOME`
  got files installed where that CLI never reads them. Both scripts now resolve each platform's
  destination through the matching env var (falling back to the `$HOME`-relative default when
  unset), and `uninstall.sh` removes from wherever `install.sh` actually wrote.

## [1.29.89]

### Fixed

- **Command discovery (`discover-commands.sh`) no longer trusts a partial `.coding-crew/dev-commands.json` as fully discovered.** It used to skip re-running discovery the moment the cache file existed at all, regardless of which of the six fields (`test`/`lint`/`typecheck`/`install`/`env`/`credential_target`) it actually contained. That let a partial write — e.g. `ensure-deps.sh`'s own `install_mode`/`docker_service` fields landing first because an earlier sprint's model dispatch failed (expired credentials, a timeout) before ever writing the six discovery fields — permanently starve every later sprint of full discovery, since the file "already existed." The skip now requires all six fields to be *present* (any value, including JSON `null`, which still means "checked, confirmed no such command") before trusting the cache; a cache missing even one field falls through and re-runs discovery.

## [1.29.88]

### Fixed

- **`install.sh` now re-execs into a newer bash instead of dying with `declare: -A: invalid
  option` on macOS.** Apple's stock `/bin/bash` is 3.2 (frozen there since the GPLv2→GPLv3
  switch) and `install.sh`'s own `#!/bin/bash` shebang is resolved by the kernel from that
  hardcoded path, not from `$PATH` — so a newer Homebrew bash already on a user's `PATH` was
  never picked up just by running the script (which is what `bootstrap.sh`'s `exec "$INSTALL"`
  does). The registry-read cache needs `declare -A` (bash ≥ 4). The script now detects bash < 4,
  hops to a findable newer bash (Homebrew's common install locations, or `PATH`), and exits with
  `brew install bash` guidance if none exists.

### Added

- **`install.sh claude --skills a,b,c` now treats that list as the full desired skill set:** a
  name present in a prior `--skills` install but missing from this one is uninstalled, instead
  of being silently left on disk forever. `write_manifest()`'s merge only adds/updates keys, so
  without this a shrunk `--skills` list had no way to actually drop anything. The new
  `prune_skills_not_in()` shells out to `uninstall.sh --skill` — the existing single writer of
  skill removal — rather than duplicating that logic, then deletes the pruned key from
  `manifest.json` so the merge doesn't resurrect it.

## [1.29.87]

### Removed

- **The `caveman` and `improve-codebase-architecture` skills are gone**, along with their
  `registry.json` entries, `install.sh`/`bootstrap.sh`/`unbootstrap.sh`/`uninstall.sh` examples,
  doc references, and structural tests. Both were third-party skills (`JuliusBrussee/crew-caveman`,
  `mattpocock/skills`) this repo no longer maintains as part of its distribution.

## [1.29.86]

### Fixed

- **`runWorker`/`runReview`/`runTriage` now delete each dispatch's `.report.json` sidecar
  before writing that round's prompt, instead of leaving a prior round's (or a prior resumed
  sprint's) sidecar sitting at the same fixed path.** `waitForSidecarReport` in `dispatch.mjs`
  treats `existsSync` as "found" the instant the herdr wait settles, so a stale sidecar from an
  earlier dispatch to the same slug was read back as this round's verdict whenever the coder's,
  reviewer's, or triage agent's turn died before writing a fresh one — a false verdict rather
  than the intended pane-scrape fallback.

## [1.29.85]

### Changed

- **The `<slug>.report.json` sidecar-first dispatch policy (already used for the crew-coder
  worker) now also covers the reviewer and triage agents.** `dispatchViaHerdr` checks each
  role's report file before scraping the pane at all: the review and triage prompts now name
  a `reportPath` and instruct the agent to write its verdict there as its last action, falling
  back to the same fenced-json-in-prose reply only if that file never lands.
  `parseReviewReport`/`parseTriageReport` accept the parsed sidecar and prefer it over the
  captured text entirely, same policy `parseWorkerReport` already had. Closes the same class of
  herdr read-capture failure (empty/garbled pane render) for review and triage that the worker
  fix already closed — a genuine verdict no longer depends on a terminal scrape succeeding.

---

Older entries have been moved to [docs/CHANGELOG-archive.md](docs/CHANGELOG-archive.md).
