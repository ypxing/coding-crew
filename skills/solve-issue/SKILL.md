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

**Mandatory branch guard (always run first):**

Check the current branch and enforce you are **not** on the default branch:

```bash
CURRENT_BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD)
DEFAULT_BRANCH=$(git -C "$PROJECT_ROOT" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
[ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH="main"

if [ "$CURRENT_BRANCH" = "$DEFAULT_BRANCH" ]; then
  echo "BLOCKED: on default branch ($DEFAULT_BRANCH) — create or switch to a feature branch first"
  exit 1
fi
```

If blocked, stop immediately. Do not proceed to any other step.

**If issue file path is provided:**

Use the feature branch setup script from the same directory you read this skill file from:

```bash
bash "<skill-dir>/scripts/feature-branch-setup.sh" "$ISSUE_PATH" "$@"
```

If no issue file path is provided (inline content), the branch guard above is sufficient — proceed to Step 0.1.

### 0.1. Pre-flight

Run `git -C "$PROJECT_ROOT" status --short`. If there are modified or staged tracked files not owned by this issue, stop and report blocked: `BLOCKED: dirty worktree — stash or commit unrelated changes first`.

### 1. Understand the issue

**Finding the issue file:** Issues live as local markdown files in `.scratch/`. Read from the path
the caller provides. Do **not** query GitHub (`gh`) or any remote issue tracker unless the caller
explicitly says to.

Extract from the issue:

- Acceptance criteria
- Hypothesized files likely to change (confirmed in Step 3)
- Blocked-by dependencies

**Blocked-by check:** Read the `## Blocked by` section. For each listed dependency:

1. Resolve the dependency's filename relative to the current issue's directory (e.g. `03-foo.md` → sibling file or `done/03-foo.md`).
2. Check if it has been moved to `done/`: `ls "$(dirname "$ISSUE_PATH")/done/<dep-filename>" 2>/dev/null`.
3. If the file is **not** in `done/`, stop immediately:

```
BLOCKED: depends on <dep-filename> which is not yet done
```

Only continue if every listed dependency is confirmed in `done/`. If the section says "None", proceed.

### 2. Install dependencies

STOP. Read and invoke the `dep-install` skill. If the skill is not found, stop and report `BLOCKED: dep-install skill not installed`. Run install **once**; only re-run if you add a new package during implementation.

### 3. Explore before coding

**Codebase orientation — do this first:**

1. Read `CLAUDE.md` (at `$PROJECT_ROOT/CLAUDE.md`) if it exists — it may describe architecture, conventions, and key entry points.
2. Grep for similar patterns to what you're about to implement — find existing utilities, helpers, or conventions you should follow or reuse.
3. Identify callers of the files you plan to change — understand how they're used before modifying them.

**Then for each hypothesized file from Step 1:**

1. Read the source file.
2. Read the corresponding test file if one exists.
3. Note test style, naming conventions, and patterns — these become the style contract for Step 4.

Expand the file list if exploration reveals additional files. Do not guess. Confirm the current state before writing anything.

### 4. Implement with TDD

**Use the INSTALL_MODE established in Step 2 for all commands** — test runs, type checks, linting. If INSTALL_MODE=docker, every command runs inside docker, not on the host.

STOP. Read and invoke the `karpathy-guidelines` skill now, before writing any code.

STOP. Read and invoke the `tdd` skill before writing a single line of implementation. Do not proceed until the red/green loop is complete. Honor the style contract from Step 3.

### 4.5. Update documentation

After implementation, check whether the change affects anything user-facing. Ask:

- Does this add, remove, or change a public API, CLI flag, config option, or install step?
- Does this change behavior that users or consuming projects depend on?
- Does this add or remove an agent, skill, or script?
- Does this change architecture that `CLAUDE.md` or `docs/` describes?

If **none** of the above apply (e.g. pure refactor, internal test fix, private helper), skip this step.

If **any** apply, update the relevant documents before committing:

- `README.md` — user-facing install instructions, usage examples, skills table
- `CLAUDE.md` — architecture, agent/skill descriptions, conventions
- `docs/` — guides, ADRs, or other docs that describe the changed behavior
- Inline code comments only if the WHY is non-obvious

Do not add documentation for things that are already self-evident from the code. Do not touch doc sections unrelated to this change.

### 5. Verify

**Use the same INSTALL_MODE from Step 2** — all check commands run inside docker or on the host, matching whatever was established then.

STOP. Read `references/verification.md` now. Run every check listed. Do not skip any.

Do not proceed to commit if any check fails or any acceptance criterion from Step 1 is unmet.

### 6. Commit

Before committing, confirm:

- [ ] Tests were written before implementation (TDD red/green loop completed)
- [ ] `references/verification.md` was read
- [ ] Every check listed in `references/verification.md` passed (tests, type-check, lint, or equivalent for this stack)
- [ ] Relevant documentation was updated (Step 4.5) or explicitly determined not needed

If any check failed, do NOT stage or commit. Report status `partial` or `blocked`.

**Check if work is already done:**

If there are no changes to stage (working directory is clean), check if the issue was already implemented and committed. If so, proceed to Step 7 to mark done. If not, report accordingly.

**Commit with shared script:**

Extract the issue slug and run `commit-changes.sh` from the same directory you read this skill file from:

```bash
ISSUE_SLUG=$(basename "$ISSUE_PATH" | sed 's/\.md$//')
ISSUE_TITLE="<extract title from issue file>"
CHANGED_FILES="<space-separated list of files you modified>"
DETAILS="- <key decision or tradeoff line 1>
- <key decision or tradeoff line 2>"

if [ -n "$COAUTHOR_TRAILER" ]; then
  bash "<skill-dir>/scripts/commit-changes.sh" \
    --prefix "[$ISSUE_SLUG]" \
    --message "$ISSUE_TITLE${DETAILS:+

$DETAILS}" \
    --files "$CHANGED_FILES" \
    --coauthor "$COAUTHOR_TRAILER"
else
  bash "<skill-dir>/scripts/commit-changes.sh" \
    --prefix "[$ISSUE_SLUG]" \
    --message "$ISSUE_TITLE${DETAILS:+

$DETAILS}" \
    --files "$CHANGED_FILES"
fi
```

Example: `[01-auth-logout] Add user logout endpoint`

Do not push.

### 7. Mark done

Before moving, verify all acceptance criteria in the issue file are satisfied:

1. Check each `- [ ]` criterion against the implemented code.
2. If all are met, check them off (`- [x]`) and move the file to done:
   ```bash
   sed -i'' "s/^Status:.*/Status: done/" "<issue-path>"
   mkdir -p "$(dirname <issue-path>)/done" && mv "<issue-path>" "$(dirname <issue-path>)/done/"
   ```
3. If any are unmet, do NOT move the file. Instead, add a `## Unmet criteria` section explaining what's missing and why (descoped, blocked, moved to a new issue), and ask the user how to proceed.
