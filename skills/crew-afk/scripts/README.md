# AFK Sprint Scripts

This directory contains reusable shell scripts extracted from the afk-run skill files to improve maintainability and reduce duplication.

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

**Outputs**:
- `.scratch/<feature-slug>/issues/` directory
- `.scratch/.session-start-sha` file
- `.scratch/<feature-slug>/sprint-state.json` file
- `.scratch/commands.log` (fresh)

**Requirements**:
- Git repository with at least one commit
- `jq` command-line tool installed
- At least one issue file in `.scratch/*/issues/*.md` (if on default branch)

---

### `squash-commits.sh`

**Purpose**: Squash all commits from a sprint session into a single commit with formatted message.

**Usage**:
```bash
bash scripts/squash-commits.sh [--no-squash] [--platform claude|copilot] [completed_slug1 completed_slug2 ...]
```

**Arguments**:
- `--no-squash`: Skip squashing entirely (exit gracefully)
- `--platform <name>`: Set platform for Co-authored-by trailer (default: claude)
  - `claude`: Uses "Claude Code <claude@anthropic.com>"
  - `copilot`: Uses "GitHub Copilot <noreply@github.com>"
- Remaining args: List of completed issue slugs (used to build commit message)

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

### `claude.workflow.js`

**Purpose**: Workflow script for running afk-run using the Workflow tool (Claude Code only). Renamed to `workflow.js` by `install.sh` during a Claude install.

**Usage**: Invoked via Workflow tool when user specifies "with workflow" in the afk-run invocation.

**Note**: This is a JavaScript workflow script, not a bash script. See the file itself for implementation details.

---

## Integration

These scripts are referenced by:
- `skills/afk/SKILL.md` (Claude Code version)
- `skills/afk/copilot.SKILL.md` (GitHub Copilot version)

Both platform versions use the same scripts with platform-specific flags (e.g., `--platform claude` vs `--platform copilot`).

## Maintenance

When updating these scripts:
1. Ensure both platform versions remain compatible
2. Update this README if interfaces change
3. Test with both `--jira` flag present and absent
4. Test with both `--no-squash` flag present and absent
5. Verify platform-specific Co-authored-by trailers
