Status: done

## Parent

None - part of auto-squash-commits feature (PRD at `.scratch/auto-squash-commits/PRD.md`)

## What to build

Add Step 0 branch safety check to `address-pr-comments` and `address-code-review` skills. Detect if on default branch (main/master) and block execution with clear error message directing user to switch to their PR branch first.

These skills work on existing PR branches, so accidental execution on main should be prevented.

## Acceptance criteria

- [x] New Step 0 added before existing Step 1 in `skills/address-pr-comments/SKILL.md`
- [x] New Step 0 added before existing Step 1 in `skills/address-code-review/SKILL.md`
- [x] Detects default branch using same logic as solve-issue (symbolic-ref with fallback)
- [x] If on default branch: prints error message and exits with status 1
- [x] Error message: "ERROR: Cannot run on default branch ($DEFAULT_BRANCH). Switch to your PR branch first: git checkout <branch-name>"
- [x] If on non-default branch: continues to existing Step 1
- [x] No feature branch creation (assumes user is already on PR branch)
- [x] Tested on both main and feature branches

## Blocked by

None - can start immediately (independent slice)
