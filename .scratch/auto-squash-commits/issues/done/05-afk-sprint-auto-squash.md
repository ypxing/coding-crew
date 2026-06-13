Status: done

## Parent

None - part of auto-squash-commits feature (PRD at `.scratch/auto-squash-commits/PRD.md`)

## What to build

Add Step 4.5 to afk-sprint (both Claude and Copilot versions) that squashes all completed issue commits into one clean commit after sprint completes. Parse commits by `[issue-slug]` prefix, generate squashed message with issue list, update state file with new base SHA. Support `--no-squash` flag to opt-out.

This delivers the core "one commit per sprint" behavior.

## Acceptance criteria

- [x] New Step 4.5 added between Step 4 (Merge housekeeping) and Exit in both afk-sprint versions
- [x] Parses `--no-squash` flag - if present, skips squashing entirely
- [x] Reads base SHA from sprint-state.json for current branch
- [x] If no base SHA found: warns and skips squashing
- [x] Collects list of completed issue slugs from sprint session (tracked in Step 2-3)
- [x] Generates squashed commit message: "Implement N features" with bulleted issue list
- [x] Performs squash using `git reset --soft <base_sha>` + `git commit`
- [x] Includes platform-appropriate Co-authored-by trailer in squashed commit
- [x] On success: updates state file with new HEAD SHA as base_sha
- [x] On failure: reports error with manual fix command, exits without updating state
- [x] Handles edge case: only completed issues squashed (partial/blocked commits preserved)
- [ ] Tested with 1, 3, and 5 issue sprints - requires actual sprint execution for integration testing

## Blocked by

- 03-solve-issue-commit-format.md (establishes `[issue-slug]` commit format)
- 04-afk-sprint-state-tracking.md (provides base SHA tracking)
