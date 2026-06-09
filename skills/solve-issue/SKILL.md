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

Two session-wide variables must be set before any step. If the caller (e.g. `coder`) already set them, use those values. Otherwise establish them now:

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

## Steps

### 0. Pre-flight

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

Read the `dep-install` skill and follow it — do not attempt to detect the install mode yourself. Run install **once**; only re-run if you add a new package during implementation.

### 3. Explore before coding

For each hypothesized file from Step 1:
1. Read the source file.
2. Read the corresponding test file if one exists.
3. Note test style, naming conventions, and patterns — these become the style contract for Step 4.

Expand the file list if exploration reveals additional files. Do not guess. Confirm the current state before writing anything.

### 4. Implement with TDD

**Use the INSTALL_MODE established in Step 2 for all commands** — test runs, type checks, linting. If INSTALL_MODE=docker, every command runs inside docker, not on the host.

Follow the `tdd` skill: plan → tracer bullet → incremental red/green loop → refactor. Honor the style contract from Step 3.

Apply the `karpathy-guidelines` skill throughout — surgical changes, simplicity, goal-driven execution.

### 5. Verify

**Use the same INSTALL_MODE from Step 2** — all check commands run inside docker or on the host, matching whatever was established then.

Run all project checks and confirm every acceptance criterion is met.
See [references/verification.md](references/verification.md) for how to discover and run checks.

Do not proceed to commit if any check fails or any criterion is unmet.

### 6. Commit

If there are no staged changes after implementation, verify the issue was already done and report accordingly — do not error.

Stage only the files you changed — never `git add .` or `git add -A`.

Commit message format:
```
<issue title>

- <key decision or tradeoff — omit if none>
```

If the caller specifies a `Co-Authored-By:` git trailer, append it verbatim as the last line.

Do not push.

### 7. Mark done

Read `docs/agents/issue-tracker.md` (at `$MAIN_ROOT/docs/agents/issue-tracker.md`) and follow its "mark the ticket done" instructions using the issue file path from Step 1.

If the file does not exist, use the default: run `sed -i '' "s/^Status:.*/Status: done/" "<issue-path>"` then `mkdir -p "$(dirname <issue-path>)/done" && mv "<issue-path>" "$(dirname <issue-path>)/done/"`.
