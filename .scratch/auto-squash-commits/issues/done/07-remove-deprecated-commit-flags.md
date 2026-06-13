Status: done

## Parent

None - part of auto-squash-commits feature (PRD at `.scratch/auto-squash-commits/PRD.md`)

## What to build

Clean up deprecated `--commit`/`--no-commit` flag system across all skills and documentation. Remove sprint-config.md from registry, remove any lingering references to old commit behavior config, update documentation to reflect new always-commit-then-squash model.

This completes the transition to the new workflow by removing obsolete code paths.

## Acceptance criteria

- [x] All remaining references to `--commit` and `--no-commit` flags removed from skill files (grep to verify)
- [x] sprint-config.md entry removed from `registry.json` docs section
- [x] If `docs/agents/sprint-config.md` template exists, verify it's no longer installed
- [x] Any comments or documentation mentioning "auto_commit config" removed or updated
- [x] Verify afk-sprint/copilot.SKILL.md has no lingering config parsing code
- [x] README or docs updated if they reference old commit behavior
- [x] Grepped entire skills/ directory for "no-commit", "auto_commit", "sprint-config" to ensure cleanup complete

## Blocked by

- 03-solve-issue-commit-format.md (removes flags from solve-issue)
- 05-afk-sprint-auto-squash.md (confirms new behavior works)
