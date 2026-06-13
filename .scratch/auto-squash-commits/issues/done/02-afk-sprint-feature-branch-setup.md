Status: done

## Parent

None - part of auto-squash-commits feature (PRD at `.scratch/auto-squash-commits/PRD.md`)

## What to build

Add feature branch detection and creation to `afk-sprint` Session Init step in both Claude and Copilot versions. Parse `--jira` flag, detect default branch, create/switch to feature branch using first issue's slug. Auto-create `.scratch/<feature-slug>/` directory structure if needed.

This ensures sprint work happens on feature branches, not on main.

## Acceptance criteria

- [ ] Session Init enhanced in `skills/afk-sprint/SKILL.md` (Claude version)
- [ ] Session Init enhanced in `skills/afk-sprint/copilot.SKILL.md` (Copilot version)
- [ ] Parses `--jira TICKET-123` flag from invocation
- [ ] Fetches first ready issue to extract slug for branch naming
- [ ] Detects default branch (main/master/from git config)
- [ ] If on default branch: creates `feature/<first-issue-slug>` or `feature/<JIRA-123>-<first-issue-slug>`
- [ ] If branch exists: switches to it; if not: creates it
- [ ] Derives feature-slug from branch name (strips `feature/` and JIRA prefix)
- [ ] Auto-creates `.scratch/<feature-slug>/issues/` directory structure
- [ ] If already on feature branch: continues without changes

## Blocked by

- 01-solve-issue-feature-branch-detection.md (establishes branch naming conventions)
