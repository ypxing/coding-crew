# PRD: Optional Commit Mode for Agent Skills

## Problem Statement

Users of the agent skills (`solve-issue`, `afk-sprint`, `address-pr-comments`, `address-code-review`) want to review implemented changes before committing them. Currently, these skills automatically commit all changes upon successful completion, leaving no opportunity for human review before the commit is made.

This is problematic for:
- Teams that require manual review of agent-generated code before committing
- Users who want to test changes locally before creating a commit
- Workflows where commit messages need manual refinement
- Cases where only some of the agent's changes should be committed

## Solution

Add optional `--commit` and `--no-commit` flags to all four skills, with a project-level configuration file to set defaults. When `--no-commit` is used, skills stage changes (`git add`) but skip the commit step, leaving changes ready for manual review and commit.

The solution maintains backward compatibility (default is auto-commit) and respects platform constraints (Claude Code requires commits for worktree isolation, so this feature is Copilot-only).

## Key User Stories

1. As a **Copilot CLI user**, I want to run `/afk-sprint --no-commit` so that I can review all implemented issues before committing any of them.

2. As a **project maintainer**, I want to set `auto_commit: no` in `docs/agents/sprint-config.md` so that my team always reviews changes before committing without remembering to pass flags.

3. As a **developer addressing PR comments**, I want to run `/address-pr-comments --no-commit` so that I can review the agent's fixes before committing them to the PR branch.

4. As a **developer using Claude Code**, I want the tool to warn me (but still work) when I accidentally use `--no-commit`, since Claude's worktree isolation requires commits.

5. As a **user who approved some changes**, I want to commit selected worktrees and run `/afk-sprint` again so that only committed branches get merged while uncommitted ones remain for further work.

## Decisions

### Configuration System

**New file**: `docs/agents/sprint-config.md` (installed via registry for both platforms)

```markdown
# Sprint Configuration

## Commit behavior
auto_commit: yes

Note: Claude Code always commits due to worktree isolation. 
This setting only affects GitHub Copilot CLI.
```

**Precedence** (highest to lowest):
1. CLI flags (`--commit` or `--no-commit`)
2. Config file value (`auto_commit: yes/no`)
3. Hardcoded default: `yes`

**Registry changes**: Add to `registry.json`:
```json
"docs": {
  "sprint-config.md": {
    "description": "Sprint-level configuration for commit behavior and other defaults.",
    "install": "docs/agents/sprint-config.md"
  }
}
```

### Platform-Specific Behavior

**GitHub Copilot** (branch-based):
- Fully supports `--commit` / `--no-commit` flags
- Reads config file to determine default behavior
- All four skills respect the setting

**Claude Code** (worktree isolation):
- Always commits regardless of flags/config
- Worktree isolation requires commits for dependency visibility between parallel issues
- If `--no-commit` flag is used: print warning and continue with commit
- Warning: `"Warning: --no-commit is not supported on Claude Code (worktree isolation requires commits). Proceeding with auto-commit."`

### Modified Skills

#### 1. `skills/solve-issue/SKILL.md`

**Step 6 (Commit)** becomes conditional:

```markdown
### 6. Commit

Parse commit preference:
1. Check for `--commit` or `--no-commit` in invocation
2. If no flag, read `docs/agents/sprint-config.md` for `auto_commit` value
3. If no config, default to `yes`

Before committing, confirm:
- [ ] Tests were written before implementation (TDD red/green loop completed)
- [ ] `references/verification.md` was read
- [ ] Every check listed passed

If any check failed, do NOT stage or commit. Report status `partial` or `blocked`.

**Always stage** modified files:
```bash
git add <file1> <file2> ...
```

**Conditionally commit**:
- If commit preference is `yes`: proceed with `git commit`
- If commit preference is `no`: stop after staging

Commit message format (when committing):
```
<issue title>

- <key decision or tradeoff — omit if none>
```

If the caller specifies a `Co-Authored-By:` git trailer, append it verbatim as the last line.

Do not push.
```

**Step 7 (Mark done)** becomes conditional:

```markdown
### 7. Mark done

**Only if work was committed** (commit preference was `yes`):

Read `docs/agents/issue-tracker.md` and follow its "mark the ticket done" instructions.

If the file does not exist, use the default: run `sed -i '' "s/^Status:.*/Status: done/" "<issue-path>"` then `mkdir -p "$(dirname <issue-path>)/done" && mv "<issue-path>" "$(dirname <issue-path>)/done/"`.

**If work was NOT committed** (commit preference was `no`):

Skip this step entirely. Issue stays at current status and location.

**Re-running after manual commit**:

If re-invoked without changes in working directory (user already committed), detect this case, verify checks pass, and mark done.
```

#### 2. `skills/afk-sprint/SKILL.md` (Claude version - no changes)

Claude version remains unchanged. Always commits. Ignores config file and flags.

#### 3. `skills/afk-sprint/copilot.SKILL.md`

**After session init** (parse config):

```markdown
## Parse commit preference

1. Check for `--commit` or `--no-commit` in invocation arguments
2. If no flag, read `docs/agents/sprint-config.md` for `auto_commit` value (yes/no)
3. If no config file exists, default to `yes`
4. Store result as `SHOULD_COMMIT` (true/false) for this session
```

**Step 2 (Sprint)** - when invoking coder subagents:

```markdown
When calling subagent, include in prompt:

Auto-commit: <yes|no based on SHOULD_COMMIT>

The coder subagent will read this and pass it to solve-issue.
```

**Step 4 (Merge)** becomes conditional:

```markdown
### Step 4 — Merge

**If SHOULD_COMMIT is true** (current behavior):
- Merge all complete branches with `git merge --no-ff <branch>`
- Track success/failure per branch

**If SHOULD_COMMIT is false** (new behavior):
- Skip merge entirely
- All worktrees remain intact
- Do NOT mark any issues done
- Proceed to housekeeping to update partial/blocked issues only
```

**Exit** - modify summary output:

```markdown
## Exit

**If SHOULD_COMMIT was true**:
- Print current summary (branches merged, code review report, etc.)

**If SHOULD_COMMIT was false**:
- Print worktree summary:

```
Sprint complete: <N> issues implemented, awaiting review

Worktrees with staged changes:
  - <issue-slug>: <worktree-path> (<file-count> files)
  ...

Next steps:
1. Review: cd <worktree-path> && git diff --staged
2. Commit approved changes: cd <worktree-path> && git commit -m "your message"
3. Merge and close: /afk-sprint (detects committed branches, merges and marks done)
```

**Second run detection** (when SHOULD_COMMIT is true):
- Before spawning new coder agents, check tracked worktrees for committed work
- Identify branches with new commits (compare with main branch)
- Merge committed branches first
- Mark those issues done
- Then proceed with normal sprint loop for remaining ready issues
```

#### 4. `skills/address-pr-comments/SKILL.md`

**Step 5 (Commit)** becomes conditional:

```markdown
## Step 5 — Commit

Parse commit preference:
1. Check for `--commit` or `--no-commit` in invocation
2. If no flag, read `docs/agents/sprint-config.md` for `auto_commit` value
3. If no config, default to `yes`

**Always stage** files touched during Step 4:
```bash
git add <file1> <file2> ...
```

**Conditionally commit**:
- If commit preference is `yes`: create commit
- If commit preference is `no`: stop after staging

Commit message format (when committing):
```
address PR review comments

<bullet list: one line per actionable comment — what changed and why>

Co-Authored-By: Claude <noreply@anthropic.com>
```

Do not push — leave that to the user.
```

#### 5. `skills/address-code-review/SKILL.md`

**Step 5 (Commit)** becomes conditional:

```markdown
## Step 5 — Commit

Parse commit preference:
1. Check for `--commit` or `--no-commit` in invocation
2. If no flag, read `docs/agents/sprint-config.md` for `auto_commit` value
3. If no config, default to `yes`

**Always stage** files touched during Step 4:
```bash
git add <file1> <file2> ...
```

**Conditionally commit**:
- If commit preference is `yes`: create commit and proceed to Step 5b
- If commit preference is `no`: stop after staging, skip Step 5b (do NOT archive report)

Commit message format (when committing):
```
address code review findings

<bullet list: one line per actionable finding — what changed and why>

Co-Authored-By: Claude <noreply@anthropic.com>
```

If the commit fails, stop and report the error to the user — do **not** archive the report until the commit succeeds.
```

**Step 5b (Archive)** - only runs if commit happened:

```markdown
## Step 5b — Archive the report (only after a successful commit)

**Only if commit preference was `yes` AND commit succeeded**:

Move report to done subdirectory:
```bash
mkdir -p .scratch/reviews/done
mv <report-path> .scratch/reviews/done/
```

**If commit preference was `no`**:

Skip archival. Report stays in place. User can re-run after manual commit to archive.
```

### Coder Agent Output Changes

**Copilot `agents/coder/copilot.agent.md`** - add field to report format:

```markdown
## Report

Return **exactly** this format and nothing else:

```
## Issue: <slug>
Status: complete | partial | blocked
Committed: yes | no

### Checks
...
```

New field:
- `Committed: yes` if changes were committed
- `Committed: no` if changes were only staged
```

**Claude `agents/coder/claude.agent.md`** - no changes needed (always `committed: true`)

### Config File Reading Logic

Each skill that supports the flags implements this precedence check:

```bash
# Parse commit preference
SHOULD_COMMIT="yes"  # default

# 1. Check for flags in invocation
if [[ "$*" == *"--no-commit"* ]]; then
  SHOULD_COMMIT="no"
elif [[ "$*" == *"--commit"* ]]; then
  SHOULD_COMMIT="yes"
# 2. Check config file
elif [ -f "docs/agents/sprint-config.md" ]; then
  CONFIG_VALUE=$(grep "^auto_commit:" docs/agents/sprint-config.md | awk '{print $2}')
  if [ "$CONFIG_VALUE" = "no" ]; then
    SHOULD_COMMIT="no"
  fi
fi
# 3. Default remains "yes" from initial assignment

# Platform check (Claude only - add warning)
if [[ "$PLATFORM" == "claude" ]] && [[ "$SHOULD_COMMIT" == "no" ]]; then
  echo "Warning: --no-commit is not supported on Claude Code (worktree isolation requires commits). Proceeding with auto-commit."
  SHOULD_COMMIT="yes"
fi
```

### Key File Paths

- `docs/agents/sprint-config.md` - new config file
- `skills/solve-issue/SKILL.md` - modify Step 6 and Step 7
- `skills/afk-sprint/copilot.SKILL.md` - modify Step 4 and Exit
- `skills/address-pr-comments/SKILL.md` - modify Step 5
- `skills/address-code-review/SKILL.md` - modify Step 5 and Step 5b
- `agents/coder/copilot.agent.md` - add `Committed:` field to report
- `registry.json` - add sprint-config.md to docs section

## Out of Scope

- **Push automation** — Skills never push to remote. User always pushes manually.
- **Partial staging** — If checks fail, nothing is staged (all-or-nothing per skill run).
- **Interactive commit message editing** — Commit messages use fixed templates. User can amend after manual review.
- **Branch cleanup automation for uncommitted work** — User manually deletes uncommitted worktrees/branches they reject.
- **Claude Code support** — Feature is Copilot-only due to architectural constraints.
- **Squashing TDD commits** — Implementation already makes no intermediate commits; single commit at end (when enabled).
- **Config file validation** — Invalid values in sprint-config.md fall back to default (`yes`).
- **Per-issue commit preference** — Preference is set at skill invocation level, not per-issue in the issue file.
