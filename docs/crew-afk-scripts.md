# AFK Sprint Scripts

Reference for the scripts in `skills/crew-afk/scripts/`, extracted from the afk-run skill files to
improve maintainability and reduce duplication.

This file lives in `docs/` and is **not** installed. It documents scripts an orchestrator only ever
invokes by name from the skill body, so shipping it into a consumer repo added ~2,000 words of
exploration bait to every install for no runtime benefit.

## Scripts

### `dispatch-agent.sh` (pi only)

**Purpose**: Run a crew agent as an isolated `pi -p` subprocess — pi has no built-in subagent tool, so this script is the pi equivalent of Claude's `Agent` tool / Copilot's `#runSubagent`.

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

**Markers written by scripts**: `SESSION` (session-init), `DISPATCH` (dispatch-agent / dispatch-codex-agent), `VERIFY` (verify-worktree), `MERGE` (merge-branches), `CLOSE` (close-issue), `PROMOTE` / `FLUSH` / `REVIEW result=not_run` (promote-findings), `CLEANUP` (cleanup-worktrees), `SQUASH` (squash-commits), `MODEL` / `ROUND` / `STATE` (state.sh), `EXIT` (crew-summary). The orchestrator writes only what it decides itself: `ACVERIFY`, and `DISPATCH` on Copilot.

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

These scripts are referenced by the skill body sources:

- `skills/crew-afk/SKILL.md` (Claude Code)
- `skills/crew-afk/dispatch.SKILL.md` + `skills/crew-afk/fragments/<platform>/` (pi, Codex, GitHub Copilot)

The dispatch platforms share one body; their differences are inlined from
`fragments/<platform>/<key>.md` at install time by `scripts/render-skill.sh`. Render one to read
it as the model will:

```bash
bash scripts/render-skill.sh crew-afk pi
```

All variants call the same scripts, differing only in platform-specific flags (e.g.
`--platform claude` vs `--platform pi`) and in how they dispatch workers.

## Maintenance

When updating these scripts:

1. Keep all four platform variants compatible — a script interface change must land in every
   variant that calls it.
2. Update this README if interfaces change.
3. Test with both `--jira` flag present and absent.
4. Test with both `--no-squash` flag present and absent.
5. Verify platform-specific Co-authored-by trailers.
