# AFK Sprint Scripts

Reference for the scripts in `skills/crew-afk/scripts/`, extracted from the afk-run skill files to
improve maintainability and reduce duplication.

This file lives in `docs/` and is **not** installed. It documents scripts an orchestrator only ever
invokes by name from the skill body, so shipping it into a consumer repo added ~2,000 words of
exploration bait to every install for no runtime benefit.

## Scripts

### `dispatch-agent.sh` (pi only)

**Purpose**: Run a crew agent as an isolated `pi -p` subprocess — pi has no built-in subagent tool, and the orchestrator wants a child process per worker on every platform anyway, so `orchestrator/lib/dispatch.mjs` execs this script for pi (and `dispatch-codex-agent.sh` for codex; claude and copilot are invoked directly).

**Usage**:
```bash
bash scripts/dispatch-agent.sh --agent crew-coder --dir <worktree> \
  --prompt-file <file> [--out <report-file>] [--log <trace-file>] [--model <alias|inherit>]
```

**What it does**:
- Resolves the agent definition: `$MAIN_ROOT/.pi/agents/<name>.md`, then `~/.pi/agent/agents/<name>.md`
- Strips YAML frontmatter and passes the body via `--append-system-prompt`
- Maps frontmatter `tools:` onto `--tools` and `model:` onto `--model` (`--model inherit` passes nothing, so the worker uses the orchestrator's session model)
- Runs `pi -p` with the worktree as cwd and `MAIN_ROOT` exported
- Streams the agent's final report to stdout and, with `--out`, to a file

**Exit code**: pi's exit code; `2` for bad arguments, a missing agent definition, or a missing `pi` CLI.

**Parallelism**: the orchestrator launches one invocation per issue with `&` and then `wait`.

---

### `dispatch-codex-agent.sh` (Codex only)

**Purpose**: Run a crew agent as an isolated `codex exec` subprocess. Codex can spawn native subagents, but they share the parent's working root — a sprint worker must own a git worktree and write its report to a known file, so it runs as its own process instead.

**Usage**:
```bash
bash scripts/dispatch-codex-agent.sh --agent crew-coder --dir <worktree> \
  --prompt-file <file> [--out <report-file>] [--log <trace-file>] [--model <name|inherit>] \
  [--sandbox <read-only|workspace-write|danger-full-access>]
```

**What it does**:
- Resolves the agent definition: `$MAIN_ROOT/.codex/agents/<name>.toml`, then `~/.codex/agents/<name>.toml` (the same custom-agent file Codex reads natively)
- Reads `developer_instructions` from the `'''` block and prepends it to the task prompt (codex exec has no `--append-system-prompt`)
- Maps `model` onto `--model` (`--model inherit` passes nothing, so the worker uses the session model), `model_reasoning_effort` onto `-c model_reasoning_effort=...`, and `sandbox_mode` onto `--sandbox` (override with `--sandbox` or `CREW_CODEX_SANDBOX`)
- Runs `codex exec --cd <worktree>`, adds `--add-dir $MAIN_ROOT` so traces and reports under `.scratch/` are writable, and enables network access for `workspace-write` so dep installs work
- Writes the agent's final report via `--output-last-message` when `--out` is given

**Exit code**: codex's exit code; `2` for bad arguments, a missing agent definition, or a missing `codex` CLI.

**Parallelism**: the orchestrator launches one invocation per issue with `&` and then `wait`.

---

### `ensure-deps.sh`

**Purpose**: Make a directory ready to run the project's own checks, mechanically, with no
package-manager knowledge of its own. `dep-install` is failure-triggered, which is right for a
human's direct `solve-issue` run; a sprint is the opposite case. The orchestrator creates every
worktree fresh, and one consumer of the deps is not a model at all: `verify-worktree.sh` runs
`npm test` / `pytest` in the worktree, has no dep recovery path, and being a gate it cannot invoke a
skill. A resumed or retained worktree therefore reached the merge gate with no deps, scored
`TEST: fail`, and cost a whole round. Provisioning a gate depends on has to be mechanism.

Docker mode is mechanized too, for the one MAIN_ROOT call only: generating the override and
running the ecosystem's install command inside the container are both deterministic
(`dep-install`'s `docker-install.sh`, the docker-mode sibling of `host-install.sh`), so this script
does them once, before any worktree exists — the volume every worktree's install shares is by
design, so the install itself must run once, not once per worktree. What stays with the skill:
reading the Makefile for a credential target, picking a different service or entrypoint by hand,
and deciding whether an install failure is `BLOCKED` — real judgement, so a per-worktree docker call
never attempts an install itself; it only checks whether the shared one already happened.

On the host path, this script's own mechanical detection (a Makefile `install`/`deps` target, then
signal-file/lockfile convention) can be overridden by a documented install command: if one-time
command discovery (`discover-commands.sh` / `write-commands-cache.sh`, see below) already cached an
`install` field at `$MAIN_ROOT/.scratch/commands.json`, that command runs instead — the one place a
CLAUDE.md/AGENTS.md/Makefile override reaches this script without it ever reading those files
itself. This only works if command discovery ran first; the orchestrator's `main.mjs` runs it before
the sprint-level `ensure-deps.sh` call for exactly that reason.

**Usage**:
```bash
bash scripts/ensure-deps.sh --dir <path> [--slug <issue-slug>] [--timeout <sec, default 600>]
```

- `--dir` (required) — the directory to provision: `$MAIN_ROOT` once per sprint, then each worktree.
- `--slug` — the issue slug, which enables the marker cache below. Omit it outside a sprint.
- `--timeout` — cap on the install, so a hung package manager cannot hang the sprint behind it.
  Applied with `timeout`/`gtimeout` when the host has one; hosts without it (macOS) run uncapped,
  because the cap is a safety net rather than the contract.

**Output**: exactly one `DEPS:` line, and **always exit 0**.

| Line | Meaning |
| --- | --- |
| `DEPS: present` | the ecosystem's dep dir is already in `--dir` — inherited via `.worktreeinclude`, or left by a prior round |
| `DEPS: installed <cmd>` | either the discovered `install` override from `.scratch/commands.json` ran `<cmd>`, or (when there is none) `host-install.sh` ran it — same line shape either way, since `<cmd>` is always the exact command that ran |
| `DEPS: none` | no manifest, no discovered install override, no `dep-install` scripts resolvable, or `host-install.sh` found no install method (exit 2) — not a failure |
| `DEPS: docker` | `detect-mode.sh` says `USE_DOCKER`, persisted to this worktree's local `agent.install-mode` git config, and deferred to the worker's own up-front `dep-install` invocation — the docker-install path was off, not found, had nothing to do (no compose file/service/ecosystem), or the shared install lock was busy |
| `DEPS: docker-installed <cmd>` | the one MAIN_ROOT call: `docker-install.sh` ran `<cmd>` inside the container and wrote `$MAIN_ROOT/.scratch/docker-install.done` |
| `DEPS: docker-present` | a worktree call, and `$MAIN_ROOT/.scratch/docker-install.done` already exists — the shared install already ran, nothing to do here |
| `DEPS: docker-failed <cmd> (exit N)` | the one MAIN_ROOT call's install failed; the verbatim tail goes to stderr, no marker is written |
| `DEPS: failed <cmd> (exit N)` | either the discovered install override or the host install failed; the verbatim tail of its output goes to stderr |
| `DEPS: skipped` | `CREW_DEPS=off` |

**Order of operations**:
1. `CREW_DEPS=off` → `DEPS: skipped`.
1b. Resolve `$MAIN_ROOT_EFFECTIVE` (the `MAIN_ROOT` env var, else `git -C <dir> rev-parse
   --show-toplevel`, else `<dir>`) and read `$MAIN_ROOT_EFFECTIVE/.scratch/commands.json`'s
   `"install"` field, if the file exists — `CACHED_INSTALL`, consumed by steps 3 and 5. A missing
   cache, a missing file, or a cached `null` all mean the same thing: nothing to override.
2. Resolve `dep-install`'s scripts: `$CREW_DEP_INSTALL_SCRIPTS`, then per candidate root
   (`$MAIN_ROOT`, `--dir`'s repo, this script's own repo) `.coding-crew/dep-install/scripts` — the
   platform-neutral copy `install.sh` ships — then the four `.<platform>/skills/dep-install/scripts`
   dirs, then `skills/dep-install/scripts` for development. None found → `DEPS: none`. Moved ahead
   of the presence guard so step 2b can call `detect-mode.sh` before that guard runs.
2b. **`--slug` absent only** (the one MAIN_ROOT call): run `detect-mode.sh --project-root <dir>`
   right away. `USE_DOCKER` → skip the presence guard entirely and go straight to step 4 — a
   host-side dep dir already sitting in `$MAIN_ROOT` (predating `.worktreeinclude` excluding it, or
   a contributor's own local install) is a different store from the docker volume step 4 warms, so
   it must not read as "nothing to do" and skip generating `docker-compose.override.yml` for the
   whole sprint. A worktree call (`--slug` set) is unaffected — there, an inherited dep dir via
   `.worktreeinclude` genuinely means there is nothing to do, so the guard runs first for it.
3. **The presence guard**, and the reason resume and `.worktreeinclude` repos cost nothing: one row
   per ecosystem (`node_modules`, `.venv`, `vendor/bundle`, `vendor`, `target`, `deps`) mapping a dep
   dir to its manifests. A manifest with its dep dir present → `DEPS: present`. No manifest at all,
   no `Makefile` `install`/`deps` target, none of `go.sum` / `go.mod` / `pom.xml`, and no
   `CACHED_INSTALL` from step 1b → `DEPS: none`. A non-empty `CACHED_INSTALL` counts as a
   dependency step on its own — a custom bootstrap script documented in CLAUDE.md/AGENTS.md has no
   lockfile for this heuristic to find, which is exactly the case the override exists for. Skipped
   by step 2b, above.
3b. **The marker cache** — only for the two outcomes that would otherwise be re-probed every round
   (`none`, `failed`), one of which runs a whole install command to learn nothing new. Step 3 has
   already run, so a worktree that has since acquired its deps reports `present` regardless.
4. `detect-mode.sh --project-root <dir>` (reusing step 2b's verdict when this is that call, instead
   of running it twice); `USE_HOST` → step 5. `USE_DOCKER` → write `git -C <dir>
   config --local agent.install-mode docker` (so a verdict reached only via the Makefile heuristic
   is not lost), then:
   - **`--slug` present** (a worktree call): `$MAIN_ROOT/.scratch/docker-install.done` exists →
     `DEPS: docker-present`; otherwise `DEPS: docker` — a worktree never runs the install itself,
     because the volume it would write into is shared by every other worktree on purpose.
   - **`--slug` absent** (the one MAIN_ROOT call `main.mjs` makes, via `sprint.installDeps()`,
     after one-time command discovery and before any worktree exists):
     `CREW_DOCKER_INSTALL=off` or `docker-install.sh` not resolvable → `DEPS: docker`. Otherwise run
     `docker-install.sh --project-root <dir> --main-root <MAIN_ROOT> --timeout <timeout>` (its own
     lock, so a concurrent caller waits rather than corrupts the shared volume). Exit 0 → write the
     marker, `DEPS: docker-installed <cmd>`. Exit 2 (nothing to do) or 4 (lock busy) → `DEPS: docker`,
     unchanged from before this existed. Anything else → `DEPS: docker-failed <cmd> (exit N)`.
5. `CACHED_INSTALL` from step 1b, if any, runs in `<dir>` under the timeout cap in place of step
   5's own guess: exit 0 → `installed <cmd>`, anything else → `failed <cmd> (exit N)` — a
   documented command that fails is a real failure, never reinterpreted as `none`. No
   `CACHED_INSTALL` → `host-install.sh --project-root <dir>` under the same cap. Exit 0 →
   `installed`, 2 → `none`, anything else → `failed`.

**Marker**: `$SPRINT_DIR/dispatch/<slug>.deps.<ok|skip>`, containing the outcome line. `ok` for
`present`/`installed`, `skip` for `none`/`failed`. Written only with `--slug` and only inside a
sprint. **A cache, never the guard** — step 3 is the guard (step 2b can skip it for the MAIN_ROOT
call). Separately, `docker-installed` writes
`$MAIN_ROOT/.scratch/docker-install.done` — scoped to `MAIN_ROOT`, not to `$SPRINT_DIR` or the
feature slug, so it is reused by every feature sprint against this checkout, the same way the
named docker volume it warms already is.

**Escape hatch**: `CREW_DEPS=off` skips everything, mirroring `CREW_RECEIPTS=off`. The orchestrator's
`--no-deps` removes both of its call sites instead. `CREW_DOCKER_INSTALL=off` rolls back only the
docker mechanization, independently of `CREW_DEPS`, to the always-deferred `DEPS: docker` behaviour.

**Exit code**: **always 0** for any install outcome — a repo with no dependency step must not stall a
sprint, and a failed install is diagnosed by the check that follows it, exactly as
`dependency-audit.sh` treats a missing audit tool. Non-zero only for a usage error (no `--dir`, an
unknown flag, a `--dir` that does not exist): exiting 0 on a typo would report "deps are fine" about
a directory nobody looked at.

**Traces**: one `DEPS` line via `trace.sh`, and a silent no-op outside a sprint.

---

### `docker-install.sh` (`dep-install`'s script, called by `ensure-deps.sh`)

**Purpose**: The docker-mode sibling of `dep-install`'s `host-install.sh` — deterministic install,
not judgement, so `ensure-deps.sh` can call it mechanically for the one MAIN_ROOT call. It lives
under `skills/dep-install/scripts/`, not `skills/crew-afk/scripts/`, because `dep-install`'s own
skill guide can call it too, as the deterministic path for the common case; the guide's manual
`docker compose run` instructions remain for the entrypoint-override and multi-service cases it
doesn't cover.

**Usage**:
```bash
bash scripts/docker-install.sh --project-root <path> --main-root <path> \
  [--service <name>] [--timeout <sec, default 600>] [--lock-timeout <sec, default 30>]
```

**What it does**:
1. Queries `gen-override.sh --query ecosystem/services/container-src/manifest-dirs` (all
   read-only detection) rather than re-parsing the compose file and manifests itself.
2. Picks a service: `--service`, then `git config --local agent.install-service`, then the first
   service `gen-override.sh` found. No compose service at all → exit 2.
3. Builds one `sh -c "cd <dir> && <cmd> && cd <dir> && <cmd> …"` for every manifest directory,
   using the same per-directory signal-file priority `host-install.sh` uses on the host path, so a
   project installs the same way in both modes.
4. Takes an `mkdir`-based lock at `$MAIN_ROOT/.scratch/.docker-install.lock` before running
   anything that writes into the shared named volume — `flock` is not on every host (macOS ships
   none), `mkdir` is atomic everywhere. Lock not acquired within `--lock-timeout` → exit 4.
5. Runs `ensure-env.sh --project-root <dir>` (no `--credential-target`; that inference is
   `dep-install`'s own judgement, not this script's) and `gen-override.sh` to (re)write the
   override, then `docker compose -f <project-root>/<compose-file> -f <main-root>/docker-compose.override.yml
   run --rm <service> sh -c "<built command>"` under the timeout cap.

**Platform**: `gen-override.sh` also queries/emits `platform` — the override carries a `platform:`
key matching the host architecture (`CREW_DOCKER_PLATFORM`, default `host`; see `gen-override.sh`'s
own header comment), so an amd64-pinned project compose file or image never reaches an arm64 host
as a mismatch warning (or the qemu-emulation flakiness behind it): the override's later `-f` always
wins that key in the compose merge. `CREW_DOCKER_PLATFORM=off` restores the project's own pin
unchanged, for images that are genuinely single-arch with emulation already set up on purpose.

**Exit codes**: `0` success (prints `Running: docker compose run --rm <service> …` on stdout, the
same convention `host-install.sh` uses for `ensure-deps.sh` to read the command back), `1` argument
error, `2` nothing to do (no compose file, no service, no supported ecosystem, no manifest
directory matched an install command), `3` the install command failed inside the container (tail on
stderr), `4` lock not acquired within `--lock-timeout`.

**What stays out, on purpose**: reading the Makefile for a credential-generation target, recovering
from a failure by trying a different entrypoint or service, and deciding whether a failure is
`BLOCKED` — all judgement, so `ensure-deps.sh` treats every non-zero exit as "nothing more this
mechanism can do," not as something to retry differently.

---

### `receipts.sh`

**Purpose**: Turn crew-afk's two pipeline gates into facts on disk, so the mechanical steps downstream can refuse to run without them. Before this existed both gates were prose instructions to the orchestrator; a sprint that skipped them merged a branch with failing checks and closed a second issue off the first issue's branch.

**Usage**:
```bash
bash scripts/receipts.sh write verify --dir <worktree>      # written by verify-worktree.sh
bash scripts/receipts.sh write ac     --branch <branch>     # after "AC: all-met"
bash scripts/receipts.sh check verify --branch <branch>     # enforced by merge-branches.sh
bash scripts/receipts.sh check ac     --issue <issue-path>  # enforced by close-issue.sh
bash scripts/receipts.sh clear verify --dir <worktree>
bash scripts/receipts.sh path  verify --dir <worktree>
```

**Receipt location**: `<main-root>/.scratch/<feature-slug>/dispatch/<issue-slug>.<verify|ac>.ok`, alongside the worker reports. Contents are the commit SHA that was gated.

**What each gate enforces**:
- `verify` — `merge-branches.sh` refuses any `crew/<feature>/<issue>` branch without a receipt whose SHA equals the branch tip. Commits added after verification make the receipt stale, so unverified work cannot ride in on an earlier pass. Non-`crew/` branches are not gated.
- `ac` — `close-issue.sh` refuses to close an issue without a receipt for **that issue's own slug**, derived from the filename exactly as the orchestrator derives branch names. A sibling's receipt does not satisfy it. Existence only: by close time the branch may be merged and deleted, so there is no tip to compare.

**Escape hatch**: `CREW_RECEIPTS=off` disables checking (writes still happen). Intended for tests and for driving these scripts outside a sprint — setting it during a sprint re-opens the exact hole the receipts close.

**Exit code**: 0 when the receipt is written/cleared or the check passes, non-zero on a missing or stale receipt and on bad arguments.

---

### `cleanup-worktrees.sh`

**Purpose**: Tear down a sprint's worktrees and the branch refs for merged branches in one mechanical, idempotent step. Cleanup used to be prose repeated in four variants, so an orchestrator that ran out of loop budget never got there — and no variant ever named the runtime-managed worktrees Claude creates for `isolation: worktree` agents, so `.claude/worktrees/agent-*` plus their `worktree-agent-*` refs accumulated across every sprint.

**Usage**:
```bash
bash scripts/cleanup-worktrees.sh [--main-root <path>] [--feature-slug <slug>] \
  [--merged <branch>[,<branch>...]]... [--retain <branch>[,<branch>...]]... [--dry-run] [--force]
```

**What it does**:
- Removes each candidate branch's worktree **first**, then deletes the ref — git refuses to delete a ref that a worktree still has checked out — and finishes with `git worktree prune`
- Sweeps candidates nobody passed in: `crew/<feature-slug>/*` worktrees (when `--feature-slug` is given) and runtime-managed `worktree-agent-*` / `.claude/worktrees/*` worktrees
- Never touches a `--retain` branch (partial / verification-failed / criteria-unmet / review-not-run); never removes a worktree with uncommitted changes
- Refuses to delete a *swept* branch whose commits are not already in `HEAD` unless `--force`. Branches passed with `--merged` are exempt: cleanup runs after `squash-commits.sh`, which soft-resets the feature branch, so a genuinely merged branch tip is never an ancestor of `HEAD` by then — requiring ancestry there would keep every merged branch forever
- Prints one line per branch (`removed` / `kept <reason>` / `skipped`) and a final `CLEANUP: removed=N kept=M failed=K`
- `--main-root` defaults to the repo's main worktree, resolved via `--git-common-dir`, so it works when invoked from inside a linked worktree

**Exit code**: 0 on success, including "nothing to do" and any safety refusal; 1 on bad arguments, a non-git main root, or a ref that could not be deleted.

**Idempotent**: re-running is a clean no-op, so it is also the way to clear a repo that already leaked worktrees (`--dry-run` first).

---

### `trace.sh`

**Purpose**: Append one line to the sprint's orchestrator trace log. Every script that performs a pipeline step calls it directly, so a marker is emitted by the code that did the work rather than by a prose instruction to echo it afterwards — a step that ran is always traced, and a step that was skipped can never be traced as if it had run. `[DISPATCH]` used to be logged twice (once by `dispatch-agent.sh`, once by the prompt).

**Usage**:
```bash
bash scripts/trace.sh [--log <file>] <MARKER> "<key=value ...>"
```

**Log resolution**: `--log`, then `$TRACE_LOG`, then `$MAIN_ROOT/.scratch/sprint.env`. With none of those it exits 0 without writing — tracing must never fail the caller that is making progress.

**Markers written by scripts**: `SESSION` (session-init), `DEPS` (ensure-deps), `DISPATCH` (dispatch-agent / dispatch-codex-agent), `VERIFY` (verify-worktree), `MERGE` (merge-branches), `CLOSE` (close-issue), `PROMOTE` / `FLUSH` / `REVIEW result=not_run` (promote-findings), `CLEANUP` (cleanup-worktrees), `SQUASH` (squash-commits), `MODEL` / `ROUND` / `STATE` (state.sh), `EXIT` (crew-summary). The orchestrator writes only what it decides itself: `ACVERIFY`, and `DISPATCH` on Copilot.

---

### `state.sh`

**Purpose**: The sprint's bookkeeping. Completions, retentions, blocks, the resolved model, the round counter and coverage gaps were prose instructions to "append to `all_merged` / `all_partial` / `all_blocked`" plus raw jq one-liners in the prompt — a list carried across a long sprint loses entries, and a dropped entry becomes a branch reported as cleaned up that was never deleted.

**Usage**:
```bash
bash scripts/state.sh model <alias>
bash scripts/state.sh round <n> [--issues <count>]
bash scripts/state.sh complete --slug <slug> --branch <branch>
bash scripts/state.sh retain   --slug <slug> --branch <branch> --reason <reason>
bash scripts/state.sh blocked  --slug <slug> [--branch <branch>] [--reason <text>]
bash scripts/state.sh coverage-gap --slug <slug> --categories <lint,typecheck>
bash scripts/state.sh resume --slug <slug>
bash scripts/state.sh get <merged|retained|completed|partial|blocked|model|round|rounds|feature-slug|state-file>
bash scripts/state.sh show
# any command also accepts [--feature-slug <slug>] [--state-file <path>]
```

**Notes**:
- `retain` is the single entry point for every branch that must survive the sprint (`partial`, `verification-failed`, `criteria-unmet`, `review-not-run`, `merge-failed`, `blocked`). Its reason string is what the summary prints, and `get retained` is what feeds `cleanup-worktrees.sh --retain`, so a recorded branch cannot be deleted. `complete` clears the retention, so a stale branch is never offered for resume.
- `resume` answers `resume: <branch>` or `no prior branch` — the recorded name plus a ref-existence check, previously a jq call and a `git branch --list` in the prompt.
- The state file is resolved from `--state-file`, `--feature-slug`, `$STATE_FILE`, or `.scratch/sprint.env` — never by globbing `.scratch/*/sprint-state.json`, which picks the alphabetically-first feature.

**Exit code**: 0 on success; 1 on bad arguments or an unresolvable state file.

---

### `crew-summary.sh`

**Purpose**: Render the end-of-sprint summary and the findings reminder from `sprint-state.json` and the review reports. This was ~430 words of print template filled in from lists the orchestrator had carried since round 1 — the one place where a dropped entry is invisible, because a retained branch missing from the summary reads as a clean teardown and a review gap missing from the reminder reads as a clean review.

**Usage**:
```bash
bash scripts/crew-summary.sh [--feature-slug <slug>] [--stalled] [--no-reminder]
```

**What it prints**: the `Rounds / Model / Merged / Partial / Blocked` rollup, then `## Verification Failures`, `## Coverage Gaps`, `## Retained Branches` and `## Promoted Findings` — each omitted when empty. It writes the `EXIT` trace line, then ends with `promote-findings.sh remind` rendered as `## Next Step`, `No open review findings.`, and/or `## Unreviewed Branches`. A gap is never suppressed by a clean findings count, and gaps are never added to the findings count.

**Use `--no-reminder`** for the per-round rollup, so the reminder is printed exactly once, last.

---

### `session-init.sh`

**Purpose**: Initialize a new afk-run session with feature branch setup and state tracking.

**Usage**:
```bash
bash scripts/session-init.sh [--jira TICKET-123]
```

**What it does**:
- Parses optional `--jira TICKET-123` flag for JIRA ticket integration
- Detects default branch (main/master)
- Creates or switches to feature branch (deriving slug from first issue if on default branch)
- Initializes `.scratch/<feature-slug>/issues/` directory structure
- Archives previous command log and starts fresh
- Saves session-start SHA for code review
- Validates git repository and checks for jq dependency
- Creates/updates sprint state file to track base SHA per branch
- Writes `sprint.env` — the one file the orchestrator sources, exporting `MAIN_ROOT`, `FEATURE_SLUG`, `FEATURE_BRANCH`, `SPRINT_DIR`, `STATE_FILE`, `TRACE_LOG`, `DISPATCH_DIR`, `REVIEW_DIR` and `CREW_SCRIPTS`. The slug is known here exactly once, so it is written here instead of being re-derived downstream from a branch name or an alphabetical glob.
- Traces the `SESSION` line

**Outputs**:
- `.scratch/<feature-slug>/issues/` directory
- `.scratch/<feature-slug>/session-start-sha` file
- `.scratch/<feature-slug>/sprint-state.json` file
- `.scratch/<feature-slug>/sprint.env`, plus `.scratch/sprint.env` pointing at it
- `.scratch/<feature-slug>/traces/` (fresh; a previous traces dir is archived)

**Requirements**:
- Git repository with at least one commit
- `jq` command-line tool installed
- At least one issue file in `.scratch/*/issues/*.md` (if on default branch)

---

### `squash-commits.sh`

**Purpose**: Squash all commits from a sprint session into a single commit with formatted message.

**Usage**:
```bash
bash scripts/squash-commits.sh [--no-squash] [--platform claude|copilot|pi|codex] [completed_slug1 completed_slug2 ...]
```

**Arguments**:
- `--no-squash`: Skip squashing entirely (exit gracefully)
- `--platform <name>`: Set platform for Co-authored-by trailer (default: claude)
  - `claude`: Uses "Claude Code <claude@anthropic.com>"
  - `copilot`: Uses "GitHub Copilot <noreply@github.com>"
- Remaining args: list of completed issue slugs. Omit them — with no slugs the script reads `completed_slugs` from `sprint-state.json`, where `state.sh complete` records them.

**What it does**:
- Reads sprint state file to get base SHA
- Validates base SHA is ancestor of HEAD
- Extracts issue titles from done issue files
- Generates formatted commit message with bulleted list
- Performs soft reset to base SHA
- Creates single squashed commit with platform-appropriate Co-authored-by trailer
- Updates sprint state file with new HEAD SHA

**Example commit message**:
```
Implement 3 features

- Add user authentication endpoints
- Create password reset flow
- Implement session management

Co-authored-by: Claude Code <claude@anthropic.com>
```

**Requirements**:
- Git repository with commits to squash
- `.scratch/<feature-slug>/sprint-state.json` file
- `jq` command-line tool installed
- Completed issue files in `.scratch/*/issues/done/`

---

## Integration

These scripts are called by the orchestrator program (`orchestrator/lib/effects.mjs` wraps
them; `orchestrator/lib/loop.mjs` and `pipeline.mjs` decide when), not by a skill body. Every
platform's `skills/crew-afk/<platform>.SKILL.md` is a launcher whose only job is to run
`.coding-crew/crew-afk/main.mjs`. Render one to read it as the model will:

```bash
bash scripts/render-skill.sh crew-afk pi
```

The platform reaches the scripts as a flag the program passes (e.g. `--platform claude` vs
`--platform pi`), so there is one caller and one call order.

## Maintenance

When updating these scripts:

1. Keep all four platform variants compatible — a script interface change must land in every
   variant that calls it.
2. Update this README if interfaces change.
3. Test with both `--jira` flag present and absent.
4. Test with both `--no-squash` flag present and absent.
5. Verify platform-specific Co-authored-by trailers.
