---
name: solve-issue
description: >
  Implement a single issue end-to-end: read it, explore context, install deps, build with TDD,
  verify checks, and commit. Platform-agnostic — works in worktrees or branches.
argument-hint: "Path to issue file (e.g. .scratch/auth/issues/01-add-logout.md)"
---

# Solve Issue

Implement a single issue. One issue in, committed code out.

## Blocked output format

When stopping due to a blocker, always output:

```
BLOCKED: <reason>
<verbatim error or dependency name>
```

Do not attempt workarounds. Do not proceed.

## Inputs

The caller provides one of:

- A **file path** — read the issue from that path.
- **Issue content** inline — use it directly.

Two session-wide variables must be set before any step. If they are already set in the current session, use those values. Otherwise establish them now:

```bash
PROJECT_ROOT=$(pwd)

# If .git is a file we are inside a worktree — derive MAIN_ROOT from the common git dir.
# If .git is a directory we are at the main repo root — MAIN_ROOT equals PROJECT_ROOT.
if [ -f "$PROJECT_ROOT/.git" ]; then
  _common=$(git -C "$PROJECT_ROOT" rev-parse --git-common-dir)
  MAIN_ROOT=$(cd "$_common/.." && pwd)
else
  MAIN_ROOT="$PROJECT_ROOT"
fi
```

- **`PROJECT_ROOT`** — where code lives and all commands run.
- **`MAIN_ROOT`** — main checkout; where `.scratch/` and gitignored files live.

## Steps

### 0. Feature Branch Setup

**Note:** The `scripts/feature-branch-setup.sh` file is copied into this skill during installation from the central git-workflow scripts. It won't exist in the repo until `install.sh` runs.

Use the feature branch setup script. Parse optional `--jira` flag from invocation arguments (if present, format is `--jira TICKET-123`).

```bash
# feature-branch-setup.sh - copied during installation from git-workflow
# Source: scripts/skill-utils/git-workflow/feature-branch-setup.sh
#
# Purpose: Create or switch to a feature branch based on issue slug
# Usage: bash scripts/feature-branch-setup.sh <issue-path> [--jira TICKET-123]
#
# Arguments:
#   <issue-path>       - Path to the issue markdown file
#   --jira TICKET-123  - Optional JIRA ticket (format: [A-Z]+-[0-9]+, validated by script)
#
# Behavior:
#   - If on default branch: creates or switches to feature/<slug> or feature/<JIRA>-<slug>
#   - If already on non-default branch: no-op (stays on current branch)
#
# Security: JIRA ticket format validated with regex [A-Z]+-[0-9]+ - invalid formats rejected

bash scripts/feature-branch-setup.sh "$ISSUE_PATH" "$@"
```

### 0.1. Pre-flight

Run `git -C "$PROJECT_ROOT" status --short`. If there are modified or staged tracked files not owned by this issue, stop and report blocked: `BLOCKED: dirty worktree — stash or commit unrelated changes first`.

### 1. Understand the issue

**Finding the issue file:** Issues live as local markdown files in `.scratch/`. Read from the path
the caller provides. Do **not** query GitHub (`gh`) or any remote issue tracker unless the caller
explicitly says to.

Extract from the issue:

- Acceptance criteria
- Hypothesized files likely to change (confirmed in Step 2)
- Blocked-by dependencies — if any are unresolved, stop and report blocked.

### 2. Install dependencies

STOP. Read and invoke the `dep-install` skill. If the skill is not found, stop and report `BLOCKED: dep-install skill not installed`. Run install **once**; only re-run if you add a new package during implementation.

### 3. Explore before coding

For each hypothesized file from Step 1:

1. Read the source file.
2. Read the corresponding test file if one exists.
3. Note test style, naming conventions, and patterns — these become the style contract for Step 4.

Expand the file list if exploration reveals additional files. Do not guess. Confirm the current state before writing anything.

### 4. Implement with TDD

**Use the INSTALL_MODE established in Step 2 for all commands** — test runs, type checks, linting. If INSTALL_MODE=docker, every command runs inside docker, not on the host.

STOP. Read and invoke the `karpathy-guidelines` skill now, before writing any code.

STOP. Read and invoke the `tdd` skill before writing a single line of implementation. Do not proceed until the red/green loop is complete. Honor the style contract from Step 3.

### 5. Verify

**Use the same INSTALL_MODE from Step 2** — all check commands run inside docker or on the host, matching whatever was established then.

STOP. Read `references/verification.md` now. Run every check listed. Do not skip any.

Do not proceed to commit if any check fails or any acceptance criterion from Step 1 is unmet.

### 6. Commit

Before committing, confirm:

- [ ] Tests were written before implementation (TDD red/green loop completed)
- [ ] `references/verification.md` was read
- [ ] Every check listed in `references/verification.md` passed (tests, type-check, lint, or equivalent for this stack)

If any check failed, do NOT stage or commit. Report status `partial` or `blocked`.

**Check if work is already done:**

If there are no changes to stage (working directory is clean), check if the issue was already implemented and committed. If so, proceed to Step 7 to mark done. If not, report accordingly.

**Commit with shared script:**

Extract the issue slug and use the shared commit script:

```bash
ISSUE_SLUG=$(basename "$ISSUE_PATH" | sed 's/\.md$//')
ISSUE_TITLE="<extract title from issue file>"

# Collect all changed files
CHANGED_FILES="<space-separated list of files you modified>"

# Build commit message details (optional - omit if none)
DETAILS="- <key decision or tradeoff line 1>
- <key decision or tradeoff line 2>"

# commit-changes.sh - copied during installation from git-workflow
# Source: scripts/skill-utils/git-workflow/commit-changes.sh
#
# Purpose: Stage specific files and commit with standardized message format
# Usage: bash scripts/commit-changes.sh --message "msg" --files "file1 file2" [--coauthor "Name <email>"] [--prefix "[slug]"]
#
# Arguments:
#   --message   - Commit message body (required)
#   --files     - Space-separated list of files to stage (required)
#   --coauthor  - Optional Co-authored-by trailer
#   --prefix    - Optional prefix for commit message (e.g., "[01-auth]")
#
# Safety: Never uses git add -A or git add . - only stages explicitly listed files

# Commit with prefix and co-author if provided
if [ -n "$COAUTHOR_TRAILER" ]; then
  bash scripts/commit-changes.sh \
    --prefix "[$ISSUE_SLUG]" \
    --message "$ISSUE_TITLE${DETAILS:+

$DETAILS}" \
    --files "$CHANGED_FILES" \
    --coauthor "$COAUTHOR_TRAILER"
else
  bash scripts/commit-changes.sh \
    --prefix "[$ISSUE_SLUG]" \
    --message "$ISSUE_TITLE${DETAILS:+

$DETAILS}" \
    --files "$CHANGED_FILES"
fi
```

Example: `[01-auth-logout] Add user logout endpoint`

Do not push.

### 7. Mark done

Read `docs/agents/issue-tracker.md` (at `$MAIN_ROOT/docs/agents/issue-tracker.md`) and follow its "mark the ticket done" instructions using the issue file path from Step 1.

If the file does not exist, use the default: run `sed -i '' "s/^Status:.*/Status: done/" "<issue-path>"` then `mkdir -p "$(dirname <issue-path>)/done" && mv "<issue-path>" "$(dirname <issue-path>)/done/"`.
