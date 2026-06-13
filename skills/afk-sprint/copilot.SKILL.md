---
name: afk-sprint
description: >
  Implements all ready-for-agent issues in the current repo by delegating each one to the coder
  subagent, then housekeeping the result. Loops until no issues remain or all are stalled. Runs a
  code-reviewer pass on exit. Use when asked to run an AFK sprint or implement all open issues.
allowed-tools: shell
---

# AFK Issue Sprint — Copilot

You orchestrate every `ready-for-agent` issue by dispatching each one to the **coder subagent**,
then handling housekeeping yourself. The filesystem is your source of truth — done issues are moved
to `done/`.

**Sequential processing**: Issues are processed one at a time on the current branch. Each coder subagent runs, returns its report, then you process the next issue. No parallel execution or worktree isolation.

**You do not implement issues yourself.** For each issue, use `#runSubagent` to invoke `coder`,
passing the issue file path. The subagent runs in an isolated context window, commits the work, and
returns a structured report. You process its report, do housekeeping, and loop.

**Issue tracker: local only.** Issues live in `.scratch/*/issues/*.md`. Never query `gh`, GitHub, or any remote issue tracker. If no local issues are found, print `NO MORE TASKS` and stop.

## Definitions

- **Ready issue**: `Status: ready-for-agent` — fully specified, no human input needed.
- **Skipped issue**: any other status — skip entirely.
- **Blocked issue**: its `## Blocked by` section names an issue not yet in `done/`.
- **Unblocked issue**: no `## Blocked by` section, or all listed dependencies are in `done/`.

## Issue Tracker

If `docs/agents/issue-tracker.md` exists, read it first — the project may override the defaults
below. If `docs/agents/triage-labels.md` exists, read it for custom label strings. Otherwise use
these defaults:

<!-- SYNC: the defaults below mirror docs/agents/issue-tracker.md and docs/agents/triage-labels.md.
     Update both files together whenever these defaults change. -->

### Default conventions

- Issues live as markdown files under `.scratch/<feature-slug>/issues/<NN>-<slug>.md`
- Triage state is a `Status:` line near the top of each issue
- To **list open issues**: find all `.md` files under `.scratch/*/issues/` that are NOT in a
  `done/` subdirectory — this yields file paths only; content is fetched separately
- To **fetch an issue**: read the file at its path
- To **mark done**: first update the Status line, then move the file:
  ```bash
  sed -i'' "s/^Status:.*/Status: done/" "<path>"
  mkdir -p "$(dirname <path>)/done" && mv "<path>" "$(dirname <path>)/done/"
  ```

### Default triage labels

| Label             | Meaning                              |
| ----------------- | ------------------------------------ |
| `needs-triage`    | Maintainer needs to evaluate         |
| `needs-info`      | Waiting on reporter                  |
| `ready-for-agent` | Fully specified, ready for AFK agent |
| `ready-for-human` | Requires human implementation        |
| `wontfix`         | Will not be actioned                 |

### Default "Blocked by" format

An issue is blocked when its body contains a section like:

```
## Blocked by
- 01-add-schema.md
- 02-create-table.md
```

Filenames are resolved relative to the issue's own directory. An issue is blocked only if at least
one listed file is NOT present in the `done/` subdirectory alongside it.

## Status Definitions

Use exactly one of these in every issue report:

- **`complete`** — all acceptance criteria met, all checks pass, work is committed.
- **`partial`** — meaningful progress was made but work is NOT committed; write notes to
  `## Progress` so a fresh round can re-implement from scratch using that context. Use when you ran
  out of context mid-implementation — not when something is broken or unclear. Do not commit
  partial work.
- **`blocked`** — you cannot proceed without human input: a dependency is unresolved, the spec is
  ambiguous, or you hit 2 consecutive failed attempts at the same step. Do not use `partial` to
  avoid admitting you are stuck.

## Command logging

At the very start, before listing issues, clear the log from any previous session:

```bash
truncate -s 0 .scratch/commands.log 2>/dev/null || true
```

Then, before **every** shell command you run, log the exact command — verbatim, every flag and
argument, re-runnable as-is — to `.scratch/commands.log`:

```bash
echo "<exact command here>" >> .scratch/commands.log
<exact command here>
```

Prose summaries like `"run unit tests"` are wrong. The log line must be the literal command.

## Loop

### 0. Session init (run once before round 1)

### Feature Branch Setup

Run the session initialization script. It handles:
- Parsing optional `--jira TICKET-123` flag
- Feature branch creation/switching
- Session tracking setup
- Git repository validation
- jq dependency check
- Sprint state file initialization

```bash
bash "<skill-dir>/scripts/session-init.sh" "$@"
```

The script will:
- Create or switch to a feature branch (deriving slug from first issue if on main/default branch)
- Initialize `.scratch/<feature-slug>/issues/` directory structure
- Save session-start SHA for code review
- Create sprint state file to track base SHA per branch

### 1. List issues

**Initialize a round counter on first entry: `round = 1`. Increment by 1 at the top of every
subsequent iteration before doing anything else.**

Read `docs/agents/issue-tracker.md` if it exists (issue tracker overrides). List all open issue
paths (paths only), then read each file. Classify each as unblocked or blocked. Skip anything not
`ready-for-agent`.

If there are no unblocked ready issues, print `NO MORE TASKS` and stop.

### 2. Dispatch issue to coder subagent

Pick the first unblocked `ready-for-agent` issue.

Invoke the `coder` subagent via `#runSubagent`:

```
#runSubagent coder
Implement this issue: <absolute path to issue file>
```

The subagent has an isolated context window — it reads the issue, runs TDD, verifies checks,
commits, and returns a structured report in this format:

```
## Issue: <slug>
Status: complete | partial | blocked

### Checks
...

### Acceptance Criteria
...

### Changes
...

### Notes
...
```

Wait for the subagent to return its report, then proceed to step 3.

### 3. Issue housekeeping

**`Status: complete`** — update the Status line first, then move the file. The status update
must happen before the move so the listing agent won't re-pick the issue if the move is slow:

```bash
sed -i'' "s/^Status:.*/Status: done/" "<issue-path>"
mkdir -p "$(dirname <issue-path>)/done" && mv "<issue-path>" "$(dirname <issue-path>)/done/"
```

If `docs/agents/issue-tracker.md` exists, use its convention instead.

**`Status: partial`** — write or replace the `## Progress` section in the issue file with notes on
what was done and what remains. If a `## Progress` section already exists, replace it entirely —
do not append a second one. Leave the issue open for the next round.

**`Status: blocked`** — leave the issue file's existing content untouched. Add to the `## Blocked`
section using the round counter:

- If no `## Blocked` section exists, append one:
  ```
  ## Blocked
  Round <N>: <explanation of what was tried and why it is stuck>
  ```
- If a `## Blocked` section already exists, append a new line inside it:
  ```
  Round <N>: <explanation of what was tried and why it is stuck>
  ```
  Do not create a second `## Blocked` heading.

### 4. Report

Print the coder subagent's report verbatim. Do not reformat, summarize, or add text outside the
subagent's sections.

### 5. Repeat

Go back to step 1. Re-list issues — newly unblocked issues may now be ready. Partial and blocked
issues carry their updated `## Progress` / `## Blocked` sections forward (step 2 handles both).

After all issues in a round are reported, print a rollup line:

```
### Sprint: <N complete> / <N partial> / <N blocked> / <N remaining>
```

**Stall detection**: if **two consecutive rounds** both produce **zero new completions** (every result is `partial` or `blocked`), do not loop again. A single dry round does not stall — retry once first. Instead:

1. Print the rollup.
2. Print `NO MORE TASKS`.
3. **Run code review** (see below) — this is mandatory, not optional.
4. Stop.

**Normal exit** (no more unblocked issues): after printing the final rollup and `NO MORE TASKS`,
also run code review before stopping.

The user can re-trigger the sprint after resolving blockers.

## Squash Commits (before code review)

Run the squash commits script. Track completed issue slugs throughout the sprint by maintaining a list of all slugs marked as done in step 3. Pass `--no-squash` if the user specified it, `--platform copilot`, and the list of completed slugs:

```bash
# completed_slugs array should be populated in step 3 when issues are marked done
bash "<skill-dir>/scripts/squash-commits.sh" --platform copilot "${completed_slugs[@]}"
```

If `--no-squash` flag was specified, pass it to the script:

```bash
bash "<skill-dir>/scripts/squash-commits.sh" --no-squash --platform copilot "${completed_slugs[@]}"
```

The script will:
- Parse the `--no-squash` flag and skip if present
- Read sprint state file to get base SHA
- Skip if no completed issues or no commits to squash
- Generate squashed commit message from completed issue titles
- Perform soft reset and create single commit
- Update state file with new HEAD SHA

## Code Review (mandatory on exit)

**This step is required every time the loop exits — whether all issues completed or the sprint
stalled. Do not skip it.**

When the loop exits, check whether any commits were made:

```bash
SESSION_START=$(cat .scratch/.session-start-sha 2>/dev/null || echo "")
if [[ -z "$SESSION_START" ]]; then
  echo "Session start SHA not found — skipping code review"
  exit 0
fi
git log "$SESSION_START"..HEAD --oneline
```

If there are commits, invoke the `code-reviewer` agent (`@code-reviewer` in Copilot, or
`.github/agents/code-reviewer.agent.md`). Pass it:
- The session-start SHA
- A request to review all commits from `<session-start-sha>..HEAD`

Its findings are **advisory** — nothing is re-queued or blocked.

If there are no commits, print `Code review: skipped (no commits this session)` and stop.
