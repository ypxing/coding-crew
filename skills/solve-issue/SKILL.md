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

Tracker operations named below (`fetch`, `mark-done`) are defined in
`$(git rev-parse --show-toplevel)/.coding-crew/docs/issue-tracker.md`. If that file is missing, invoke
the `configure-tracker` skill once to create it.

Two session-wide variables must be set before any step. Use the values already established by the caller (crew-coder sets these at startup). Both are inherited by this skill — do not re-derive them.

- **`PROJECT_ROOT`** — where code lives and all commands run.
- **`MAIN_ROOT`** — main checkout; where `.scratch/` and gitignored files live.

## Steps

### 0. Branch guard

You must not be on the default branch. Check, and stop immediately if you are — do not proceed to any
other step:

```bash
CURRENT_BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD)
DEFAULT_BRANCH=$(git -C "$PROJECT_ROOT" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
[ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH="main"

if [ "$CURRENT_BRANCH" = "$DEFAULT_BRANCH" ]; then
  echo "BLOCKED: on default branch ($DEFAULT_BRANCH) — create or switch to a feature branch first"
  exit 1
fi
```

A crew worker is already on `crew/<feature>/<slug>` in its own worktree, so this guard is the whole
of step 0 — there is no branch to create.

### 1. Understand the issue

Execute the `fetch` operation from `issue-tracker.md` using the path the caller provides. Do **not**
query GitHub (`gh`) or any remote issue tracker unless the caller explicitly says to. Extract the
acceptance criteria and the files likely to change (confirmed in Step 3).

**Blocked-by check:** if `## Blocked by` names a file that is not present in the sibling `done/`
directory (`$(dirname "$ISSUE_PATH")/../done/<dep-filename>`), stop immediately with
`BLOCKED: depends on <dep-filename> which is not yet done`. "None", or every listed file present →
proceed. An orchestrator filters blocked issues before dispatch, so this only fires on a direct
invocation.

### 1.5. Read the PRD

The PRD holds the architecture decisions and constraints the issue assumes. Read the first of these
that exists and keep it in memory for the rest of the run:

1. the path in the issue's `## Context Documents` section (a `- PRD: <path>` line), resolved against `$MAIN_ROOT`;
2. `$MAIN_ROOT/.scratch/<feature-slug>/PRD.md`, where `<feature-slug>` is the segment after `.scratch/` in the issue path.

```bash
PRD_REL=$(grep -A3 '## Context Documents' "$ISSUE_PATH" | sed -n 's/.*PRD: *`\(.*\)`.*/\1/p')
FEATURE_SLUG=$(echo "$ISSUE_PATH" | sed 's|.*\.scratch/||' | sed 's|/.*||')
PRD="${PRD_REL:+$MAIN_ROOT/$PRD_REL}"
[ -n "$PRD" ] && [ -f "$PRD" ] || PRD="$MAIN_ROOT/.scratch/$FEATURE_SLUG/PRD.md"
[ -f "$PRD" ] && echo "$PRD" || echo "no PRD"
```

No PRD is normal — continue normally.

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

If any check in Step 5 failed, do NOT stage or commit — report status `partial` or `blocked` instead.

If the working directory is already clean, the issue may already be implemented and committed:
check, and if so proceed to Step 7.

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

Check off (`- [x]`) every criterion the code satisfies under `## Acceptance criteria` — and under
`## Cross-cutting Requirements` if present. Then Execute the `mark-done` operation from
`issue-tracker.md` with the issue path. Never hand-roll `mv` or `sed`.

The operation refuses (exit 3) when an orchestrator owns the close and (exit 4) when a criterion is
still unchecked. Both are expected outcomes: report the outcome, leave the file in `issues/open/`,
and stop.

### 8. Unmet criteria

Add a `## Unmet criteria` section to the issue explaining what is missing and why (descoped, blocked,
split out). Then, on a **non-interactive run** (`CREW_ORCHESTRATED=1`, a headless/`-p` invocation, or
your instructions name an orchestrator as your caller) report status `partial` with the unmet criteria
listed, and stop — a question nobody can answer stalls the run. Only on an interactive run, ask the
user how to proceed.
