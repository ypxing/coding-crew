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
- **`MAIN_ROOT`** — main checkout; where `.claude/`, `.scratch/`, and gitignored files live.

## Commit behavior flags

This skill accepts optional `--commit` or `--no-commit` flags to control whether changes are committed:

```bash
# Commit changes automatically (default)
/solve-issue .scratch/auth/issues/01-add-logout.md

# Explicitly commit changes
/solve-issue .scratch/auth/issues/01-add-logout.md --commit

# Stage changes but don't commit (for manual review)
/solve-issue .scratch/auth/issues/01-add-logout.md --no-commit
```

**Precedence** (highest to lowest):
1. CLI flags (`--commit` or `--no-commit`) override everything
2. Config file value at `docs/agents/sprint-config.md` (`auto_commit: yes/no`)
3. Default: `yes` (auto-commit enabled)

**With `--no-commit`:**
- Changes are staged with `git add` but not committed
- Issue is NOT marked done
- User reviews with `git diff --staged`, then commits manually
- Re-run the skill after manual commit to mark the issue done

**Examples:**

```bash
# Review before committing
/solve-issue .scratch/auth/issues/01-add-logout.md --no-commit
# ... skill stages changes ...
git diff --staged  # review
git commit -m "Add logout endpoint"
/solve-issue .scratch/auth/issues/01-add-logout.md  # mark done
```

## Steps

### 0. Feature Branch Setup

Parse optional `--jira` flag from invocation arguments (if present, format is `--jira TICKET-123`).

Check current branch:

```bash
CURRENT_BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD)
DEFAULT_BRANCH=$(git -C "$PROJECT_ROOT" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')

# Fallback to "main" if origin/HEAD is not set
if [ -z "$DEFAULT_BRANCH" ]; then
  DEFAULT_BRANCH="main"
fi

if [ "$CURRENT_BRANCH" = "$DEFAULT_BRANCH" ]; then
  # On default branch - need to create or switch to feature branch
  # Extract issue slug from filename: strip leading digits and .md extension
  ISSUE_SLUG=$(basename "$ISSUE_PATH" | sed 's/^[0-9]*-//' | sed 's/\.md$//')
  
  # Build branch name with optional JIRA prefix
  if [ -n "$JIRA_TICKET" ]; then
    SUGGESTED_BRANCH="feature/$JIRA_TICKET-$ISSUE_SLUG"
  else
    SUGGESTED_BRANCH="feature/$ISSUE_SLUG"
  fi
  
  # Check if branch exists: switch if yes, create if no
  if git -C "$PROJECT_ROOT" rev-parse --verify "$SUGGESTED_BRANCH" >/dev/null 2>&1; then
    git -C "$PROJECT_ROOT" checkout "$SUGGESTED_BRANCH"
  else
    git -C "$PROJECT_ROOT" checkout -b "$SUGGESTED_BRANCH"
  fi
fi
```

If already on a non-default branch, continue without making any changes.

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

Parse commit preference using three-level precedence:
1. Check for `--commit` or `--no-commit` flag in the skill invocation arguments
2. If no flag present, read `docs/agents/sprint-config.md` at `$MAIN_ROOT/docs/agents/sprint-config.md` for `auto_commit:` value (yes/no)
3. If no config file exists or value cannot be parsed, default to `yes`

Store the result for use in this step and Step 7.

Before committing, confirm:
- [ ] Tests were written before implementation (TDD red/green loop completed)
- [ ] `references/verification.md` was read
- [ ] Every check listed in `references/verification.md` passed (tests, type-check, lint, or equivalent for this stack)

If any check failed, do NOT stage or commit. Report status `partial` or `blocked`.

**Always stage modified files:**

Stage only the files you changed — never `git add .` or `git add -A`.

```bash
git add <file1> <file2> ...
```

If there are no changes to stage (working directory is clean), check if the issue was already implemented and committed. If so, proceed to Step 7 to mark done. If not, report accordingly.

**Conditionally commit:**

- If commit preference is `yes`: proceed with `git commit`
- If commit preference is `no`: stop after staging; skip commit and proceed to Step 7

Commit message format (when committing):
```
<issue title>

- <key decision or tradeoff — omit if none>
```

If the caller specifies a `Co-Authored-By:` git trailer, append it verbatim as the last line.

Do not push.

### 7. Mark done

**Only if work was committed** (commit preference from Step 6 was `yes`, or working directory was already clean because work was previously committed):

Read `docs/agents/issue-tracker.md` (at `$MAIN_ROOT/docs/agents/issue-tracker.md`) and follow its "mark the ticket done" instructions using the issue file path from Step 1.

If the file does not exist, use the default: run `sed -i '' "s/^Status:.*/Status: done/" "<issue-path>"` then `mkdir -p "$(dirname <issue-path>)/done" && mv "<issue-path>" "$(dirname <issue-path>)/done/"`.

**If work was NOT committed** (commit preference was `no`):

Skip this step entirely. Issue stays at current status and location. User can review staged changes, commit manually, then re-run this skill to mark the issue done.
