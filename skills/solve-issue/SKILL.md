---
name: solve-issue
description: >
  Implement a single issue end-to-end: read it, explore context, install deps, build with TDD,
  verify checks, and commit. Platform-agnostic — works in worktrees or branches.
argument-hint: "Path to issue file (e.g. .scratch/auth/issues/01-add-logout.md)"
---

# Solve Issue

Implement a single issue. One issue in, committed code out.

## Outcome

Every run ends as exactly one of these. Report it in whatever form your caller asked for — these are
the words, not the wire format:

- **`complete`** — every acceptance criterion is met, every check passes, and the work is committed.
- **`partial`** — meaningful progress, but a check fails or a criterion is unmet. Commit the work with
  a `[WIP]` marker so the branch preserves it, and say what remains. A later round resumes here.
- **`blocked`** — cannot proceed without human input or an environment fix. Not a way to avoid
  reporting `partial`.

When you stop on a blocker, always output:

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

`PROJECT_ROOT` (where code lives and all commands run) and `MAIN_ROOT` (the main checkout, where
`.scratch/` and gitignored files live) are **inherited from the caller** — use the values already
established and do not re-derive them.

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

A caller that dispatches into a prepared worktree has already put you on the right branch, so this
guard is the whole of step 0 — there is no branch to create.

### 1. Understand the issue

Execute the `fetch` operation from `issue-tracker.md` using the path the caller provides. Do **not**
query GitHub (`gh`) or any remote issue tracker unless the caller explicitly says to. Extract the
acceptance criteria and the files likely to change (confirmed in Step 3).

**Blocked-by check:** if `## Blocked by` names a file that is not present in the sibling `done/`
directory (`$(dirname "$ISSUE_PATH")/../done/<dep-filename>`), stop immediately with
`BLOCKED: depends on <dep-filename> which is not yet done`. "None", or every listed file present →
proceed. A caller that filters blocked issues before dispatch never reaches this, so it only fires on
a direct invocation.

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

### 2. Dependencies — only when something is missing

Do **not** install pre-emptively: a crew worktree usually inherits `node_modules`/`.venv` through
`.worktreeinclude`, and many repos have no dependency step at all.

Invoke the `dep-install` skill in exactly two cases — up front if the project is in docker mode, and
later if any command fails for a missing dependency (module-not-found, import error, test runner not
found). Otherwise `INSTALL_MODE=host`, and you continue straight to Step 3. If the skill is not
found, stop and report `BLOCKED: dep-install skill not installed`.

Docker mode is: `$MAIN_ROOT/docker-compose.override.yml` exists, or `detect-mode.sh` says so — run
the real script rather than re-deriving its verdict, since it also reads a Makefile `install`/`deps`
target for a docker command, not just an explicit `agent.install-mode`:

```bash
if [ -f "$MAIN_ROOT/docker-compose.override.yml" ]; then
  echo USE_DOCKER
else
  for d in "$PROJECT_ROOT/.coding-crew" "$PROJECT_ROOT"/.*/skills "$PROJECT_ROOT/skills"; do
    [ -f "$d/dep-install/scripts/detect-mode.sh" ] && DETECT="$d/dep-install/scripts/detect-mode.sh" && break
  done
  [ -n "$DETECT" ] && bash "$DETECT" --project-root "$PROJECT_ROOT" || echo USE_HOST
fi
```

`USE_DOCKER` → invoke `dep-install` now. `USE_HOST` (including when `detect-mode.sh` cannot be
found) → `INSTALL_MODE=host`, continue to Step 3, and let the later module-not-found trigger recover
if that guess was wrong.

### 3. Explore before coding

**Codebase orientation — do this first:**

1. Read `CLAUDE.md` (or `AGENTS.md` if that's what this repo uses) at `$PROJECT_ROOT` if it exists and is not already part of your context — it may describe architecture, conventions, and key entry points.
2. Grep for similar patterns to what you're about to implement — find existing utilities, helpers, or conventions you should follow or reuse.
3. Identify callers of the files you plan to change — understand how they're used before modifying them.

**Then for each hypothesized file from Step 1:**

1. Read the source file.
2. Read the corresponding test file if one exists.
3. Note test style, naming conventions, and patterns — these become the style contract for Step 4.

Expand the file list if exploration reveals additional files. Do not guess. Confirm the current state before writing anything.

**Batch these calls.** Each exploration tool call re-bills your entire accumulated context, so five
small calls cost far more in aggregate than one or two larger ones covering the same ground. Combine
multiple grep patterns into a single call (`grep -rn -E 'patternA|patternB'` instead of two separate
greps), and read several files in one turn where your tool allows it, rather than one call per
bullet above.

### 4. Implement with TDD

**Use the INSTALL_MODE from Step 2 for all commands** — test runs, type checks, linting. If it is
`docker`, every command runs inside docker, not on the host.

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

**Use the same INSTALL_MODE from Step 2** — every check command runs inside docker or on the host,
matching what was established then.

**Cache fast path** — command discovery is a property of the repo, not of this issue:

```bash
CACHE="$MAIN_ROOT/.coding-crew/dev-commands.json"
if [ -f "$CACHE" ] && grep -q '"test"' "$CACHE"; then echo USE_CACHE; else echo DISCOVER; fi
```

`USE_CACHE` → read `test`/`lint`/`typecheck` straight from `$CACHE`. An empty/`null` value is
that discovery's own answer of "no local command" — report `NOT RUN: no command found`, do not
re-check CLAUDE.md/Makefile instead. Skip straight to running the three, in order.

`DISCOVER` → STOP. Read `references/verification.md` now and discover every check as it
describes. Run every check listed. Do not skip any. Then, pass or fail, persist what you found
(from the same directory you read this skill file from):

```bash
cat > /tmp/discovered-commands.json <<'JSON'
{"test": "<command or null>", "lint": "<command or null>", "typecheck": "<command or null>"}
JSON
bash "<skill-dir>/scripts/write-commands-cache.sh" --response-file /tmp/discovered-commands.json
```

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

### 6.5. Reminder: dev-commands.json

`.coding-crew/dev-commands.json` is committed and human-editable, but nothing here auto-commits
it — Step 5's `DISCOVER` fallback can be the first thing to ever create it in a repo where no
sprint has run yet, and a bootstrap write left uncommitted is easy to lose to a stray
`git clean` before anything notices it. Stateless — re-check `git status` every run, no
"already warned" flag file:

```bash
if [ -n "$(git -C "$MAIN_ROOT" status --porcelain -- .coding-crew/dev-commands.json 2>/dev/null)" ]; then
  echo "Reminder: .coding-crew/dev-commands.json has uncommitted changes at MAIN_ROOT — review and commit it."
fi
```

Clean or absent → print nothing.

### 7. Mark done

Who owns the close is a fact on disk — the same one `mark-done` checks:

```bash
ORCHESTRATED=$( { [ "${CREW_ORCHESTRATED:-}" = 1 ] || ls "$MAIN_ROOT"/.scratch/*/.orchestrated; } >/dev/null 2>&1 && echo 1 || echo 0 )
```

**`1` — write nothing to the issue file, in this step or the next:** no tick, no `mark-done`, no
`Status:` rewrite, no move, no added section. Report every criterion and its state in your structured
result and stop; the owner ticks the boxes and closes the issue after its own gates pass on your branch.

**`0` — the close is yours.** Check off (`- [x]`) every criterion the code satisfies under
`## Acceptance criteria` — and under `## Cross-cutting Requirements` if present. Then Execute the `mark-done` operation from `issue-tracker.md` with the issue path. Never hand-roll `mv` or `sed`; a refusal is an expected outcome, not something to force past.

### 8. Unmet criteria

Orchestrated (Step 7): report status `partial` with the unmet criteria, and stop.

Otherwise add a `## Unmet criteria` section explaining what is missing and why (descoped, blocked,
split out). Then, on a **non-interactive run** (a headless/`-p` invocation; `CREW_ORCHESTRATED` already
took the branch above), report status `partial` with the unmet criteria listed, and stop — a question
nobody can answer stalls the run. Only on an interactive run, ask the user how to proceed.
