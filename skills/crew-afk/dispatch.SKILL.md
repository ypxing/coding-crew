---
name: crew-afk
{{FRAGMENT:frontmatter}}
---

{{FRAGMENT:intro}}

**Issue tracker: local only.** Issues are markdown files under `.scratch/*/issues/open/*.md`. Never query `gh`, GitHub, or any remote tracker. If there are no local issues, print `NO MORE TASKS` and stop.

## Definitions

- **Ready**: `Status: ready-for-agent`. Every other status is skipped — including `deferred-findings`, which only **## Findings Flush** picks up.
- **Blocked**: a `## Blocked by` section lists a filename that is not present in `$(dirname "$ISSUE_PATH")/../done/`. No such section, or all listed files present → unblocked.
- **Slug**: the issue filename without leading digits or extension. Branch: `crew/$FEATURE_SLUG/$SLUG`.
- **Result status** a worker may report — use exactly one:
  - `complete` — all acceptance criteria met, all checks pass, work committed.
  - `partial` — real progress, committed with a `[WIP]` marker so the code survives. `## Progress` notes are context alongside that code, never a substitute for it.
  - `blocked` — needs human input: unresolved dependency, ambiguous spec, or 2 consecutive failed attempts at the same step. Never use `partial` to avoid admitting you are stuck.

Triage labels you will see in `Status:` lines: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `deferred-findings`, `wontfix`, `done`.

## Loop

### 0. Session init (once, before round 1)

If a path argument was given, derive the feature slug from it:

```bash
FEATURE_SLUG_FLAG=""
if [ -n "${1:-}" ] && [[ "$1" == .scratch/* ]]; then
  DERIVED_SLUG=$(echo "$1" | sed 's|^\.scratch/||' | sed 's|/.*||')
  [ -n "$DERIVED_SLUG" ] && FEATURE_SLUG_FLAG="--feature-slug $DERIVED_SLUG"
fi
```

`session-init.sh` parses `--jira`/`--feature-slug`, creates or switches to the feature branch, creates `.scratch/<feature-slug>/issues/open/`, archives the previous `traces/`, records the session-start SHA, initialises `sprint-state.json`, and writes `sprint.env`:

```bash
bash "<skill-dir>/scripts/session-init.sh" $FEATURE_SLUG_FLAG "$@"
source "$(git rev-parse --show-toplevel)/.scratch/sprint.env"
```

**Start every later bash block with that `source` line.** It exports `MAIN_ROOT`, `FEATURE_SLUG`,
`FEATURE_BRANCH`, `STATE_FILE`, `TRACE_LOG`, `DISPATCH_DIR` and `REVIEW_DIR`. Never re-derive the
feature slug — not from the branch name, and not by globbing `.scratch/*/sprint-state.json`, which
picks the alphabetically-first feature and silently points traces, resume state and the PRD lookup
at the wrong directory.

Trace lines are written by the scripts that perform each step (`SESSION`, `DISPATCH`, `VERIFY`,
`MERGE`, `CLOSE`, `PROMOTE`, `FLUSH`, `CLEANUP`, `SQUASH`, `EXIT`). You only trace what you decide
yourself, with `bash "<skill-dir>/scripts/trace.sh" <MARKER> "<key=value ...>"`.

{{FRAGMENT:model-resolution}}

```bash
bash "<skill-dir>/scripts/state.sh" model "$RESOLVED_MODEL"
```

### 1. List issues

```bash
bash "<skill-dir>/scripts/state.sh" round <N> --issues <count>
```

Round 1 on first entry; increment before every later iteration. List every `.md` under
`.scratch/*/issues/open/`, read each, and keep the ones that are ready and unblocked.

If none are left, run **## Findings Flush** first — it may promote parked fix issues and send you
back here. Only when it prints `FLUSH: none` do you continue to **## Wrap Up**.

### 2. Dispatch

**2a. Worktree per issue**

```bash
BRANCH="crew/$FEATURE_SLUG/$SLUG"
WORKTREE_PATH="$MAIN_ROOT/.scratch/worktrees/$BRANCH"
mkdir -p "$(dirname "$WORKTREE_PATH")"
git -C "$MAIN_ROOT" worktree add -b "$BRANCH" "$WORKTREE_PATH" HEAD
```

**2b. `.worktreeinclude` (if present)** — symlink each listed entry into the worktree, skipping blank and `#` lines:

```bash
if [ -f "$MAIN_ROOT/.worktreeinclude" ]; then
    while IFS= read -r entry; do
        [[ -z "$entry" || "$entry" == \#* ]] && continue
        mkdir -p "$(dirname "$WORKTREE_PATH/$entry")"
        ln -sf "$MAIN_ROOT/$entry" "$WORKTREE_PATH/$entry"
    done < "$MAIN_ROOT/.worktreeinclude"
fi
```

**2c. Resume notes.** These go into the worker's prompt below. If the issue has a `## Progress`
section, ask whether last round's branch survived:

```bash
bash "<skill-dir>/scripts/state.sh" resume --slug "$SLUG"
```

- `resume: <branch>` — append: *A previous worker made partial progress and committed it to branch `<branch>`. Resume on that existing branch — the code is preserved. Notes in ## Progress are context alongside the existing code, not a substitute for it.*
- `no prior branch` — append: *A previous worker made partial progress — notes are in ## Progress. Use them as context.*
- The issue has a `## Blocked` section — also append: *A previous worker was blocked — the explanation is in ## Blocked. Review it before starting to avoid repeating the same failure.*

{{FRAGMENT:dispatch}}

**2e. Collect reports.** Each worker runs in its own context window and reports:

```
## Issue: <slug>
Status: complete | partial | blocked

### Checks / ### Acceptance Criteria / ### Changes / ### Notes
```

**Schema pre-filter:** demote a `complete` to `partial` if any reported check is `fail`, or if the test category
reports `not_run` — a worker that ran no tests has verified nothing. `not_run` for
lint or typecheck only is a **coverage gap**, not a demotion (many repos legitimately have neither,
and demoting there would stall every sprint on a false positive) — record it so it cannot read as a
clean pass:

```bash
bash "<skill-dir>/scripts/state.sh" coverage-gap --slug "$SLUG" --categories "lint,typecheck"
```

This is the same policy `verify-worktree.sh` enforces, so the two gates cannot disagree. It is
report validation only — it does not replace the independent verification in step 3.

### 3. Housekeeping

**Pipeline order per branch: verify → AC verify → per-branch review → merge → close**

Each gate below is mechanical: it writes a receipt naming the exact commit it passed, and the next
step refuses to run without a current one. Working around a refusal is never correct — re-run the
gate.

**`Status: complete`**

1. **Verify** in the worker's worktree, before teardown (typecheck, then lint, then tests — see `references/verification.md`):

   ```bash
   bash "<skill-dir>/scripts/verify-worktree.sh" --dir "<working_directory from the worker report>"
   ```

   Non-zero exit — a check failed, or no test command was discoverable — demotes this result to
   `partial`: no review, no merge, no close. On exit 0 it writes the **verification receipt**;
   `merge-branches.sh` refuses any `crew/` branch whose receipt is missing or stale, so a branch
   that skipped this gate, or gained commits after passing it, cannot merge. A
   `Verification: coverage gap — not_run: ...` line does not block the merge; record it with
   `state.sh coverage-gap`.

   Then remove the worktree: `git -C "$MAIN_ROOT" worktree remove --force "$WORKTREE_PATH"`

{{FRAGMENT:ac-verify}}

   ```bash
   git -C "$MAIN_ROOT" diff $(git -C "$MAIN_ROOT" merge-base "$FEATURE_BRANCH" "$BRANCH").."$BRANCH"
   bash "<skill-dir>/scripts/trace.sh" ACVERIFY "branch=$BRANCH result=<all-met|unmet>"
   ```

   On `AC: all-met`, and only then, record the receipt that permits the close:

   ```bash
   bash "<skill-dir>/scripts/receipts.sh" write ac --branch "$BRANCH"
   ```

   `close-issue.sh` refuses to close an issue without a receipt for **that issue's own slug**, so
   this is a gate, not bookkeeping. Never write one for a branch other than the one just checked —
   closing an issue on a sibling's evidence is exactly the failure it prevents.

   `AC: unmet` — demote to `partial`: no review, no merge, no close.

{{FRAGMENT:review-dispatch}}

   Append the reviewer's block (starting `## Branch: <branch-name>`) to
   `$REVIEW_DIR/sprint-review-<TIMESTAMP>.md` — one timestamped file per round, created on the
   first branch and appended to for the rest. With no verified branches this round, print
   `Code review: skipped (no verified branches this round)` and create no file.

   **If the reviewer produces no report, record the gap — do not review the branch yourself.**
{{FRAGMENT:review-gap-detect}}
   An inline self-review writes no report file, so promotion has nothing to read, `remind` counts
   zero findings, and the sprint reports a branch nobody reviewed as clean. Record it instead:

   ```bash
   bash "<skill-dir>/scripts/promote-findings.sh" mark-not-run \
     --feature-slug "$FEATURE_SLUG" --branch "$BRANCH" --slug "$SLUG" \
     --report "$REVIEW_DIR/sprint-review-<TIMESTAMP>.md" \
     --reason "<the dispatch failed, timed out, or produced an empty report>"
   ```

   Then skip promotion for this branch and continue to the merge: review is advisory, so the branch
   still merges unreviewed — the sprint only has to say so rather than imply it was checked.

4. **Promote CRITICAL/HIGH findings** (policy: `references/findings-promotion.md`). Findings never
   block a merge, so they need a route back into the sprint. When this branch's review block holds
   at least one `[CRITICAL]` or `[HIGH]` finding:

   ```bash
   cd "$MAIN_ROOT"
   bash "<skill-dir>/scripts/promote-findings.sh" guard --issue "<issue-file-path>"
   ```

   `guard: skip — source-guarded` — leave the findings in the report and move on (this is the depth
   bound: a fix issue's own findings are never promoted again, so there is no Phase 3).
   `guard: promotable` — write one criteria file with **one `- [ ]` line per CRITICAL/HIGH
   finding**, each restated as a verifiable criterion including the `file:line` it cites, and park
   one fix issue for the whole branch:

   ```bash
   CRITERIA_FILE="$REVIEW_DIR/$SLUG.criteria.md"
   bash "<skill-dir>/scripts/promote-findings.sh" defer \
     --feature-slug "$FEATURE_SLUG" --branch "$BRANCH" --slug "$SLUG" \
     --title "Fix review findings: $SLUG" \
     --report "$REVIEW_DIR/sprint-review-<TIMESTAMP>.md" \
     --criteria-file "$CRITERIA_FILE"
   ```

   One fix issue per reviewed branch, never one per finding — findings from one branch cite one
   diff, so grouping them avoids sibling merge conflicts. The issue is written
   `Status: deferred-findings`, which step 1 does not select, so it never delays a round. Never
   promote MEDIUM or LOW; they stay in the report for a human via `/crew-address-findings`.

5. **Merge**, then remove the worktree. `merge-branches.sh` runs no checks — verification happened above:

   ```bash
   git -C "$MAIN_ROOT" checkout "$FEATURE_BRANCH"
   bash "<skill-dir>/scripts/merge-branches.sh" "$FEATURE_BRANCH" "$BRANCH"
   git -C "$MAIN_ROOT" worktree remove --force "$WORKTREE_PATH"
   ```

6. **Close — only if the merge reported `success`.** A branch it could not merge (conflict aborted,
   or receipt missing) exits non-zero; that issue stays open and its branch is retained so the next
   round resumes it. Closing before the merge would move the file to `done/`, where step 1 never
   lists it again, orphaning the unmerged branch:

   ```bash
   bash "<skill-dir>/scripts/close-issue.sh" "<issue-file-path>"
   bash "<skill-dir>/scripts/state.sh" complete --slug "$SLUG" --branch "$BRANCH"
   ```

   On a failed merge, record it as retained instead:
   `state.sh retain --slug "$SLUG" --branch "$BRANCH" --reason merge-failed`

**`Status: partial`** (including anything demoted above) — write or replace the issue's `## Progress`
section with what was done and what remains (replace it entirely; never add a second one), leave the
issue open, remove only the worktree, and record the retention. `state.sh retain` is what keeps the
branch ref alive: it feeds `cleanup-worktrees.sh --retain`, and it is where `state.sh resume` reads
the branch name next round.

```bash
git -C "$MAIN_ROOT" worktree remove --force "$WORKTREE_PATH"   # never: git branch -D "$BRANCH"
bash "<skill-dir>/scripts/state.sh" retain --slug "$SLUG" --branch "$BRANCH" \
  --reason "<partial | verification-failed | criteria-unmet — <criterion>>"
```

**`Status: blocked`** — leave the issue body untouched apart from the `## Blocked` section: append
`Round <N>: <what was tried and why it is stuck>` inside it, creating the heading only if absent
(never a second one). Then:

```bash
git -C "$MAIN_ROOT" worktree remove --force "$WORKTREE_PATH"
bash "<skill-dir>/scripts/state.sh" blocked --slug "$SLUG" --branch "$BRANCH" --reason "<why>"
```

### 4. Report

Print each worker's report verbatim. Do not reformat, summarise, or add text outside the worker's sections.

### 5. Repeat

Return to step 1 — newly unblocked issues may now be ready, and partial/blocked issues carry their
`## Progress` / `## Blocked` sections forward. Print the rollup for the round:

```bash
bash "<skill-dir>/scripts/crew-summary.sh" --no-reminder
```

**Stall detection**: if **two consecutive rounds** produce zero new completions (every result
`partial` or `blocked`), stop looping and go to **## Wrap Up**. One dry round is not a stall — retry
once first.

## Wrap Up

Every exit runs this section in order, whether the loop ran out of issues or stalled.

### Findings Flush

```bash
cd "$MAIN_ROOT"
bash "<skill-dir>/scripts/promote-findings.sh" flush --feature-slug "$FEATURE_SLUG"
```

- `FLUSH: promoted=<N>` — parked fix issues are now `ready-for-agent` (**Phase 2**). Reset the stall
  counter to 0 and **return to step 1**; the fixes run the identical pipeline, including their own
  review. Resetting stall matters: entering Phase 2 at the stall limit would abort it on the first
  `partial` round. Run no squash, coverage validation or cleanup on this pass.
- `FLUSH: none` — nothing was parked. Continue below and finish the sprint.

A stalled sprint still merged code that may carry a CRITICAL finding, so the flush runs regardless
of why the loop ended. It flips `Status:` on disk rather than tracking a phase in memory, so it is
idempotent and an interrupted sprint resumes with the fix issues looking like ordinary work.

### Squash Commits

Completed slugs are read from `sprint-state.json` (written by `state.sh complete`). Pass
`--no-squash` through if the user asked for it:

```bash
bash "<skill-dir>/scripts/squash-commits.sh" --platform {{PLATFORM}}
```

### Coverage Validation

```bash
bash "<skill-dir>/scripts/coverage-validation.sh"
```

Output containing `"skipped"` means no PRD — continue to cleanup. Otherwise the printed path is the
feature's `PRD.md`:

{{FRAGMENT:coverage-validation}}

```
Extract all requirements from:
<PRD.md content>

Categories to extract:
- Key User Stories
- Technical decisions
- Cross-cutting concerns (error handling, logging, security, performance, testing, architecture, validation, observability)
- Interface contracts
- Multi-issue flows

For each requirement, check:
1. Completed issues in .scratch/<feature-slug>/issues/done/ — match requirement to issue acceptance criteria
2. Merged code — heuristic validation (grep for relevant patterns, function names, config changes)

Classify each requirement as:
✓ covered - found in both issue criteria and code
⚠ partial - found in issue criteria OR code, but not both
✗ missing - no evidence in either

Report format:
✓ N covered / ⚠ N partial / ✗ N missing

### Details
✓ <requirement>: <brief evidence from issues/code>
⚠ <requirement>: <what's present and what's missing>
✗ <requirement>: <no evidence found>
```

That output becomes the **Coverage Report** section of the summary.

### Worktree Cleanup

One mechanical, idempotent step — never hand-roll `worktree remove` / `branch -D`, and never skip
it because a round ran long:

```bash
bash "<skill-dir>/scripts/cleanup-worktrees.sh" \
  --main-root "$MAIN_ROOT" --feature-slug "$FEATURE_SLUG" \
  --merged "$(bash "<skill-dir>/scripts/state.sh" get merged)" \
  --retain "$(bash "<skill-dir>/scripts/state.sh" get retained)"
```

It removes each merged branch's worktree before its ref (git refuses to delete a ref a worktree has
checked out), prunes stale worktree metadata, sweeps `crew/$FEATURE_SLUG/*` and `worktree-agent-*`
leftovers nobody passed in, and never touches a `--retain` branch. Anything it declines — a dirty
worktree, a swept branch with commits not in `HEAD` — is reported as `kept`, not as a failure. Run
it even when nothing merged; re-running is a clean no-op. Report its last line
(`CLEANUP: removed=N kept=M failed=K`) as-is: a non-zero exit means a ref survived, so never claim
a clean teardown over it.

### Summary

```bash
bash "<skill-dir>/scripts/crew-summary.sh"   # add --stalled if the loop stopped on the stall limit
```

It renders, from `sprint-state.json` and the review reports, and never from your recollection:

```
Rounds: <N>
Model:  <resolved model>
Merged  (<n>): <slugs> | none
Partial (<n>): <slugs> | none
Blocked (<n>): <slugs> | none
## Verification Failures / ## Coverage Gaps / ## Retained Branches / ## Promoted Findings
```

Then insert the **Coverage Report** (if one was produced) and the review report paths under
`## Code Review` — or `skipped (no verified branches this session)` if nothing was reviewed.

`crew-summary.sh` ends with the findings reminder, which is the **last thing printed**: either
`## Next Step` with a real count of the MEDIUM/LOW and fix-branch findings that promotion did not
cover, `No open review findings.`, or — never suppressed by either, and never counted as findings —
`## Unreviewed Branches` for every branch that merged without a completed review.

Finally print `NO MORE TASKS` and stop. The user can re-trigger the sprint after resolving blockers.
