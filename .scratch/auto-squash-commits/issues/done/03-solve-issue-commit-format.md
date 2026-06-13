Status: done

## Parent

None - part of auto-squash-commits feature (PRD at `.scratch/auto-squash-commits/PRD.md`)

## What to build

Update `solve-issue` Step 6 to format commit messages with `[issue-slug]` prefix. Remove all `--commit`/`--no-commit` flag logic and always commit after staging. Simplify Step 7 to always mark done after commit (remove conditional logic).

This enables commit parsing for selective squashing and simplifies the commit workflow.

## Acceptance criteria

- [ ] Step 6 commit message format changed to `[<issue-slug>] <issue title>`
- [ ] Issue slug extracted from filename (e.g., `01-auth-logout.md` → `01-auth-logout`)
- [ ] All references to `--commit` and `--no-commit` flags removed from skill file
- [ ] Config file reading logic removed (lines 48-87 in current version)
- [ ] Step 6 always commits (no conditional commit logic)
- [ ] Step 7 always marks done after commit (remove conditional "only if committed" logic)
- [ ] Co-authored-by trailer still included in commits
- [ ] Tested with various issue filenames to verify slug extraction

## Blocked by

None - can start immediately (independent of branch setup)
