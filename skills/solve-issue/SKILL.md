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

- **`complete`** — every acceptance criterion is met, every check passes, and the work is committed
  (or there was none: Step 3's already met).
- **`partial`** — meaningful progress, but a check fails or a criterion is unmet. Commit the work with
  a `[WIP]` marker so the branch preserves it, and say what remains. A later round resumes here.
- **`blocked`** — cannot proceed without human input or an environment fix. Not a way to avoid
  reporting `partial`. A failure that names something **no file in this repo can provide** — a
  credential, a license, a daemon, a registry, an external service — is `blocked`: run the
  project's documented command for it **once**, keep that command, its exit code and its verbatim
  output as the evidence, and stop. Do not start services by hand, search for tokens, or edit
  compose files or the Makefile to get around it: whatever you start is gone before anyone re-runs
  the checks, so a pass that depended on it proves nothing. Setup *inside* the repo that the issue
  asks for (helpers, wiring, config) is still coding, and in scope.

When you stop on a blocker, always output:

```
BLOCKED: <reason>
$ <command> (exit <N>)
<verbatim output, or the dependency name>
```

Do not attempt workarounds.

## Inputs

The caller provides a **file path** or tracker ref to read the issue from, or the issue content inline.

`PROJECT_ROOT` (where code lives and all commands run) and `MAIN_ROOT` (the main checkout, where
`.scratch/` and gitignored files live) are **inherited from the caller** — use the values already
established and do not re-derive them.

{{FRAGMENT:tracker-configuration}}

This skill uses two ops: `fetch` (Step 1) and `mark-done` (Step 7). `<issue-ref>` below is the issue
the caller named — a path, or the tracker's issue number.

## Steps

### 0. Branch guard

Every fact the run needs before it reads code comes from one call — run it first:

```bash
bash "<skill-dir>/scripts/preflight.sh" --project-root "$PROJECT_ROOT" --main-root "$MAIN_ROOT" \
  --issue "$ISSUE_PATH"   # omit --issue when the caller handed the issue over inline
```

A `BLOCKED:` line (exit 1) ends the run: report it verbatim and do not proceed. It is
`BLOCKED: on default branch` (`DEFAULT_BRANCH`: `origin/HEAD`, else `main`), `BLOCKED: depends on
<file>` for a `## Blocked by` file not yet in the sibling `done/`, or `BLOCKED: requires: <cmd>` for
a failing `## Requires` command. Otherwise it prints `OK` and four values; each bash call is a fresh
shell, so carry them as literals for the rest of the run:

- `ISSUE_SLUG` — the commit prefix (Steps 4 and 6)
- `PRD` — the PRD path, or empty (Step 1.5)
- `ORCHESTRATED` — who closes the issue (Step 7)
- `DEP_SCRIPTS` — dep-install's scripts (Steps 2, 4 and 5)

### 1. Understand the issue

Read the issue the caller names with `node "$TRACKER" fetch <issue-ref>` (inline content needs no
fetch). Read no other issue from the tracker unless the caller explicitly says to. Extract the
acceptance criteria and the files likely to change (confirmed in Step 3).

### 1.5. Read the PRD

If `PRD` is non-empty, read it and keep it for the rest of the run: it holds the architecture
decisions and constraints the issue assumes. No PRD is normal.

### 2. Dependencies — only when something is missing

If `DEP_SCRIPTS` is empty, stop and report `BLOCKED: dep-install skill not installed`. Otherwise
run this — even when your prompt already states `INSTALL_MODE=` or `DEPS=`; it is what turns them
into an action:

```bash
bash "$DEP_SCRIPTS/resolve-mode.sh" --project-root "$PROJECT_ROOT" --main-root "$MAIN_ROOT" \
  --deps "<the DEPS= value from your prompt, or empty>"
```

It prints `INSTALL_MODE` — the verdict every later command uses (`git config --local
agent.install-mode` overrides it) — and an `ACTION`:

- `none` — dependencies are already installed here. Continue to Step 3.
- `install` — docker mode: invoke the `dep-install` skill now. Never optional or deferred — docker
  mode has no host-side fallback.
- `on-failure` — `INSTALL_MODE=host`. Do **not** install pre-emptively: a worktree usually inherits
  `node_modules`/`.venv` through `.worktreeinclude`, and many repos have no dependency step.

Under every `ACTION`, a command that later fails for a missing dependency (module-not-found, import
error, test runner not found) means invoke `dep-install` then. Do not probe `node_modules`, `.venv`
or `PATH` yourself: the script answered that.

### 3. Explore before coding

1. Read `CLAUDE.md` (or `AGENTS.md`) at `$PROJECT_ROOT` if it exists and is not already in your context.
2. Grep for similar patterns — existing utilities, helpers and conventions to reuse.
3. Identify callers of the files you plan to change.
4. For each file from Step 1, read it and its test file; their test style, naming and patterns are
   the style contract for Step 4. Expand the list if exploration reveals more files. Do not guess.

**Bug-fix issues:** if multiple callers share the broken behavior, fix it in the function they all
route through, not only at the call site the issue names.

**Premise check — last, before Step 4.** For each acceptance criterion and each file, symbol or
behavior the issue names, find the `file:line` that confirms or contradicts it. Then, per finding:

- **Drift, same intent** (a renamed file, a moved function): build against what exists; record
  `<issue's name> → <file:line>` in Step 6's `DETAILS`.
- **Already met** — the code satisfies a criterion before this branch touches it (a bug already
  fixed is this case; `[$ISSUE_SLUG]` commits on this branch are a resumed run, not this): write no
  code for it. Pin it with a test if none exists — for a bug, the regression test; when the
  criterion is docs or prompt text, none (tdd's exemption: a grep pins wording) — and report it
  met with its `file:line`. Every criterion already met and tested leaves nothing to commit: that
  is still `complete`.
- **Wrong assumption** — the issue's picture of the code is wrong in a way reading cannot recover:
  a named thing has no counterpart, the described bug's code path does not exist, or a criterion
  conflicts with the PRD, an ADR or another criterion. Report `blocked` before writing code, with
  the search as evidence — `BLOCKED: premise: <issue assumes> — <code/PRD shows>`. A guess would be
  reviewed against the same wrong criteria, and merged.

Not for what more reading would settle, or a design you merely prefer.

**Batch these calls.** Each tool call re-bills your whole context: combine grep patterns into one
call (`grep -rn -E 'patternA|patternB'`) and read several files per turn.

### 4. Implement with TDD

**Run every project command through `run.sh`** — test runs, type checks, linting, and any ad-hoc
command, a one-off `docker compose` one included. It runs the command where `INSTALL_MODE` says:
inside docker (with this worktree's compose override) or on the host. Never hand-build a `docker
compose` command.

```bash
bash "$DEP_SCRIPTS/run.sh" --project-root "$PROJECT_ROOT" --main-root "$MAIN_ROOT" -- "<command>"
```

Run commands in the foreground and wait for them — never in the background. Between edits run only
what your change touches (one test file, not the suite); before committing, the tests your change
affects. Other workers share this machine: temp files go under `$PROJECT_ROOT`, never a shared path
such as `/tmp/<name>`; never kill a process you did not start.

STOP. Read and invoke the `tdd` skill before writing a single line of implementation. Do not proceed until the red/green loop is complete. Honor the style contract from Step 3.

**Comments.** A comment states a non-obvious *why* in 1–3 lines. History, PR and issue numbers,
and incident counts go in the commit message or PR body, never in code; neither does a comment that
restates the code.

A bug-fix test that passes on its first run, through the path the issue names, means the bug is
already fixed: keep it as the regression test (Step 3's already met).

A test of code the issue does not ask you to change that fails on its assertion (`tdd`'s "Testing
code that already exists") is Step 3's wrong assumption, found late: report `blocked` with the test
and its output as the evidence — `BLOCKED: premise: <criterion> — <observed output>`. Commits
already made stay.

**Commit after every GREEN**, before the next RED. A timeout can kill this run mid-loop, and only a
branch with a commit on it is resumable; uncommitted work looks like a run that never started.
Message quality doesn't matter — checkpoints are squashed before merge:

```bash
bash "<skill-dir>/scripts/commit-changes.sh" \
  --prefix "[$ISSUE_SLUG][WIP]" \
  --message "<behavior just made green>" \
  --files "<files touched this cycle>"
```

### 4.5. Update documentation

If the change adds, removes or changes a public API, CLI flag, config option, install step, agent,
skill or script, behavior consumers depend on, or architecture `CLAUDE.md` or `docs/` describes,
update `README.md`, `CLAUDE.md` or `docs/` to match before committing. Otherwise (a pure refactor,
an internal test fix, a private helper) skip this step. Do not document what the code already shows,
or touch unrelated doc sections.

### 5. Verify

This is the one full-suite run:

```bash
bash "<skill-dir>/scripts/run-checks.sh" --project-root "$PROJECT_ROOT" --main-root "$MAIN_ROOT" \
  --dep-scripts "$DEP_SCRIPTS"
```

It runs every `.coding-crew/dev-commands.json` check — `typecheck`, `lint`, `test`, then every other
key with a command (coverage, integration) — each through `run.sh`, and reports each. `NOT RUN: no
command found` means no local command exists: report it, do not re-check CLAUDE.md/Makefile.
`<key>: deferred` means the verify gate runs it: report `deferred`.

**Under `CREW_DEFER_FULL_CHECKS=1`** the full suite is the verify gate's: never run the
`dev-commands.json` `test` command (or any whole-suite glob) yourself. Pass `--targeted` to
`run-checks.sh`: it runs only the test files changed on the branch against its merge-base and
reports `test: pass (targeted)` / `test: fail (targeted, exit N)`, or `test: deferred` when no
changed test file is one the test command's suite selects (report `deferred`).

- `CHECKS: pass` — continue.
- `CHECKS: fail` — fix and re-run, per `references/verification.md`'s "Interpreting failures".
  Except `<key>: modified files:` — the check rewrote files this change didn't touch, which a
  human commits — and a failure naming what no repo file can provide (§ Outcome): report
  `blocked` with that output.
- `DISCOVER` — no cache yet. STOP. Read `references/verification.md` now and discover every check
  as it describes, persist what you found, pass or fail, then re-run `run-checks.sh`:

  ```bash
  cat > "$PROJECT_ROOT/.discovered-commands.json" <<'JSON'
  {"test": "<command or null>", "lint": "<command or null>", "typecheck": "<command or null>"}
  JSON
  bash "<skill-dir>/scripts/write-commands-cache.sh" --response-file "$PROJECT_ROOT/.discovered-commands.json"
  rm -f "$PROJECT_ROOT/.discovered-commands.json"
  ```

Do not proceed to commit if any check fails or any acceptance criterion from Step 1 is unmet.

### 6. Commit

If any check in Step 5 failed, do NOT stage or commit — report `partial` or `blocked` instead. If
the working directory is already clean, check whether the issue is already implemented and
committed; if so, go to Step 7.

Run `commit-changes.sh` from the same directory you read this skill file from:

```bash
DETAILS="- <key decision or tradeoff line 1>
- <key decision or tradeoff line 2>"
bash "<skill-dir>/scripts/commit-changes.sh" \
  --prefix "[$ISSUE_SLUG]" \
  --message "<issue title>${DETAILS:+

$DETAILS}" \
  --files "<space-separated list of files you modified>" \
  ${COAUTHOR_TRAILER:+--coauthor "$COAUTHOR_TRAILER"}
```

Example: `[01-auth-logout] Add user logout endpoint`. Do not push.

### 6.5. Reminder: dev-commands.json

Nothing here commits a `.coding-crew/dev-commands.json` that Step 5's `DISCOVER` created:

```bash
if [ -n "$(git -C "$MAIN_ROOT" status --porcelain -- .coding-crew/dev-commands.json 2>/dev/null)" ]; then
  echo "Reminder: .coding-crew/dev-commands.json has uncommitted changes at MAIN_ROOT — review and commit it."
fi
```

### 7. Mark done

`ORCHESTRATED` from Step 0 says who owns the close — the same fact `mark-done` checks:
`CREW_ORCHESTRATED=1`, or a `$MAIN_ROOT/.scratch/*/.orchestrated` marker.

**`1` — write nothing to the issue file, in this step or the next:** no tick, no `mark-done`, no
`Status:` rewrite, no move, no added section. Report every criterion and its state and stop; the
owner ticks the boxes and closes the issue once its own gates pass on your branch.

**`0` — the close is yours.** Verify every criterion under `## Acceptance criteria` — and under
`## Cross-cutting Requirements` if present — against the code. Once each one holds, run `node
"$TRACKER" tick <issue-ref>` (it checks every `- [ ]` off, on any tracker: a GitHub issue's body
has no file to edit), then `node "$TRACKER" mark-done <issue-ref>`. Never hand-roll `mv`, `sed`,
`gh issue edit` or a label edit. Exit 3 means another owner holds the close (report and stop);
exit 4 that a criterion is still unchecked, or the section missing (Step 8). A criterion that does
not hold is never ticked: Step 8 is for that, with nothing ticked.

### 8. Unmet criteria

Orchestrated (Step 7): report status `partial` with the unmet criteria, and stop.

Otherwise record a `## Unmet criteria` section saying what is missing and why (descoped, blocked,
split out): write it to a file and run `node "$TRACKER" write-section <issue-ref> --heading
"Unmet criteria" --body-file <file>` (into the issue file on a local tracker, as a comment on a
GitHub issue). On a **non-interactive run** (a headless/`-p` invocation or a subagent;
`CREW_ORCHESTRATED` took the branch above), report `partial` listing them and stop — nobody can
answer a question. Only on an interactive run, ask the user how to proceed.
