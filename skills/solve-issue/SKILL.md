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
  reporting `partial`. This includes a criterion that needs something the project's own commands
  do not provide — a service its tests need is unreachable and its start command fails, or a
  credential is missing, so the tests proving the criterion skip or cannot run. Report that, rather
  than standing the service up by hand: whatever you start is gone before anyone else re-runs the
  checks, so a pass that depended on it proves nothing.

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

Every fact the run needs before it reads code comes from one call — run it first:

```bash
bash "<skill-dir>/scripts/preflight.sh" --project-root "$PROJECT_ROOT" --main-root "$MAIN_ROOT" \
  --issue "$ISSUE_PATH"   # omit --issue when the caller handed the issue over inline
```

A `BLOCKED:` line (exit 1) — `BLOCKED: on default branch` (`DEFAULT_BRANCH`: `origin/HEAD`, else
`main`), or `BLOCKED: depends on <file>` for a `## Blocked by` file not yet in the sibling `done/` —
ends the run: report it verbatim and do not proceed to any other
step. Otherwise it prints `OK` and four values; each bash call is a fresh shell, so carry them as
literals for the rest of the run:

- `ISSUE_SLUG` — the commit prefix (Steps 4 and 6)
- `PRD` — the PRD path, or empty (Step 1.5)
- `ORCHESTRATED` — who closes the issue (Step 7)
- `DEP_SCRIPTS` — dep-install's scripts (Steps 2, 4 and 5)

A caller that dispatches into a prepared worktree has already put you on the right branch, so there
is no branch to create.

### 1. Understand the issue

Execute the `fetch` operation from `issue-tracker.md` using the path the caller provides. Do **not**
query GitHub (`gh`) or any remote issue tracker unless the caller explicitly says to. Extract the
acceptance criteria and the files likely to change (confirmed in Step 3).

### 1.5. Read the PRD

If `PRD` is non-empty, read it and keep it in memory for the rest of the run: it holds the
architecture decisions and constraints the issue assumes. `preflight.sh` resolved it from the
issue's `## Context Documents` (`- PRD: <path>`, against `$MAIN_ROOT`), falling back to
`$MAIN_ROOT/.scratch/<feature-slug>/PRD.md`. No PRD is normal — continue normally.

### 2. Dependencies — only when something is missing

If `DEP_SCRIPTS` is empty, stop and report `BLOCKED: dep-install skill not installed`. Otherwise
run this — even when your prompt already states `INSTALL_MODE=` or `DEPS=`; it is what turns them
into an action:

```bash
bash "$DEP_SCRIPTS/resolve-mode.sh" --project-root "$PROJECT_ROOT" --main-root "$MAIN_ROOT" \
  --deps "<the DEPS= value from your prompt, or empty>"
```

It prints `INSTALL_MODE` — the one verdict every later command uses; `git config --local
agent.install-mode` is its documented override — and an `ACTION`:

- `none` — the caller already installed into this directory. Continue to Step 3.
- `install` — docker mode: invoke the `dep-install` skill now. Never optional, never deferred to
  "if a command fails" — docker mode has no host-side fallback.
- `on-failure` — `INSTALL_MODE=host`. Do **not** install pre-emptively: a crew worktree usually
  inherits `node_modules`/`.venv` through `.worktreeinclude`, and many repos have no dependency
  step at all. Continue to Step 3.

Under every `ACTION`, a command that later fails for a missing dependency (module-not-found, import
error, test runner not found) means invoke `dep-install` then — its own retry rule. Do not probe
`node_modules`, `.venv` or `PATH` yourself instead: that question is the script's, and it answered.

### 3. Explore before coding

**Codebase orientation — do this first:**

1. Read `CLAUDE.md` (or `AGENTS.md` if that's what this repo uses) at `$PROJECT_ROOT` if it exists and is not already part of your context — it may describe architecture, conventions, and key entry points.
2. Grep for similar patterns to what you're about to implement — find existing utilities, helpers, or conventions you should follow or reuse.
3. Identify callers of the files you plan to change — understand how they're used before modifying them.

**Bug-fix issues:** if multiple callers share the broken behavior, fix it in the function they all
route through, not only at the call site the issue names — a guard added at one caller leaves every
sibling still broken.

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

**Run every project command through `run.sh`** — test runs, type checks, linting:

```bash
bash "$DEP_SCRIPTS/run.sh" --project-root "$PROJECT_ROOT" --main-root "$MAIN_ROOT" -- "<command>"
```

It runs the command where the INSTALL_MODE from Step 2 says: inside docker (both `-f` flags, this
worktree's git env, the right service) or on the host. Never hand-build a `docker compose` command.

STOP. Read and invoke the `tdd` skill before writing a single line of implementation. Do not proceed until the red/green loop is complete. Honor the style contract from Step 3.

**Commit after every GREEN, not only once at the end.** A dispatcher-imposed timeout can kill this
run mid-loop; only a branch that already has a commit on it is resumable next round — one with
everything still staged, uncommitted, is indistinguishable from a run that never started. Before
starting the next RED, checkpoint what just went green:

```bash
bash "<skill-dir>/scripts/commit-changes.sh" \
  --prefix "[$ISSUE_SLUG][WIP]" \
  --message "<behavior just made green>" \
  --files "<files touched this cycle>"
```

Commit message quality doesn't matter here — these checkpoints get squashed away with the rest of
the branch's history before merge. Getting one on disk before the next cycle does.

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

```bash
bash "<skill-dir>/scripts/run-checks.sh" --project-root "$PROJECT_ROOT" --main-root "$MAIN_ROOT" \
  --dep-scripts "$DEP_SCRIPTS"
```

It runs every check `.coding-crew/dev-commands.json` names — `typecheck`, `lint`, `test`, then
every other key with a command (coverage, integration) — each through `run.sh`, and reports each.
A `NOT RUN: no command found` is the cache's own answer that no local command exists: report it,
do not re-check CLAUDE.md/Makefile instead.

- `CHECKS: pass` — continue.
- `CHECKS: fail` — fix and re-run, per `references/verification.md`'s "Interpreting failures".
- `DISCOVER` — no cache yet. STOP. Read `references/verification.md` now and discover every check
  as it describes. Persist what you found, pass or fail (from the same directory you read this
  skill file from), then re-run `run-checks.sh` — it runs what you just wrote:

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

Run `commit-changes.sh` from the same directory you read this skill file from, with `ISSUE_SLUG`
from Step 0:

```bash
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

Who owns the close is a fact on disk, and `ORCHESTRATED` from Step 0 is it — the same one
`mark-done` checks: `CREW_ORCHESTRATED=1`, or a `$MAIN_ROOT/.scratch/*/.orchestrated` marker.

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
