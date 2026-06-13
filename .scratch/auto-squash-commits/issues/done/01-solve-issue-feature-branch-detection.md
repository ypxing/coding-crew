Status: done

## Parent

None - part of auto-squash-commits feature (PRD at `.scratch/auto-squash-commits/PRD.md`)

## What to build

Add feature branch detection and creation to `solve-issue` skill as a new Step 0. Before any work starts, check if on default branch (main/master). If yes, create or switch to a feature branch using the issue slug. Support optional `--jira` flag to prefix branch name with ticket number.

This prevents accidental commits to the default branch and establishes the foundation for clean feature branch workflow.

## Acceptance criteria

- [ ] New Step 0 added before existing Step 1 in `skills/solve-issue/SKILL.md`
- [ ] Detects default branch using `git symbolic-ref refs/remotes/origin/HEAD` with fallback to "main"
- [ ] Extracts issue slug from issue filename (strips leading digits and `.md` extension)
- [ ] Parses optional `--jira TICKET-123` flag from invocation arguments
- [ ] Creates branch name as `feature/<issue-slug>` or `feature/<JIRA-123>-<issue-slug>` if JIRA provided
- [ ] Checks if branch exists: if yes, switches to it; if no, creates it
- [ ] If already on non-default branch, continues without changes
- [ ] Tested with various branch states (on main, on existing feature branch, on new feature branch)

## Blocked by

None - can start immediately
