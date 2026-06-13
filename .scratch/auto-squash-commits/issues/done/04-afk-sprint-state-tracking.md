Status: done

## Parent

None - part of auto-squash-commits feature (PRD at `.scratch/auto-squash-commits/PRD.md`)

## What to build

Implement sprint state tracking in `.scratch/<feature-slug>/sprint-state.json` for both Claude and Copilot afk-sprint versions. Record base SHA at sprint start, persist per-branch state, provide helper functions to read/write state.

This enables multi-sprint support by tracking where each sprint session started.

## Acceptance criteria

- [ ] State file structure implemented with branches keyed by branch name
- [ ] Each branch entry contains `base_sha` and `created_at` fields
- [ ] At Session Init: record current HEAD SHA as base_sha for current branch
- [ ] State file path: `.scratch/<feature-slug>/sprint-state.json`
- [ ] Feature-slug derived from branch name (strip `feature/` and JIRA prefix)
- [ ] If state file doesn't exist: create it with initial branch entry
- [ ] If state file exists: read existing state, add/update current branch entry
- [ ] Handles missing state file gracefully (creates on first use)
- [ ] Implemented in both `skills/afk-sprint/SKILL.md` and `skills/afk-sprint/copilot.SKILL.md`
- [ ] Uses `jq` for JSON manipulation

## Blocked by

- 02-afk-sprint-feature-branch-setup.md (establishes feature-slug derivation logic)
