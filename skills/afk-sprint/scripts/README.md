# AFK Sprint Scripts

This directory contains reusable shell scripts extracted from the afk-sprint skill files to improve maintainability and reduce duplication.

## Scripts

### `session-init.sh`

**Purpose**: Initialize a new afk-sprint session with feature branch setup and state tracking.

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

**Purpose**: Workflow script for running afk-sprint using the Workflow tool (Claude Code only). Renamed to `workflow.js` by `install.sh` during a Claude install.

**Usage**: Invoked via Workflow tool when user specifies "with workflow" in the afk-sprint invocation.

**Note**: This is a JavaScript workflow script, not a bash script. See the file itself for implementation details.

---

## Integration

These scripts are referenced by:
- `skills/afk-sprint/SKILL.md` (Claude Code version)
- `skills/afk-sprint/copilot.SKILL.md` (GitHub Copilot version)

Both platform versions use the same scripts with platform-specific flags (e.g., `--platform claude` vs `--platform copilot`).

## Maintenance

When updating these scripts:
1. Ensure both platform versions remain compatible
2. Update this README if interfaces change
3. Test with both `--jira` flag present and absent
4. Test with both `--no-squash` flag present and absent
5. Verify platform-specific Co-authored-by trailers
