Status: done

## Parent

PRD: `.scratch/no-commit-feature/PRD.md`

## What to build

Add a `Committed: yes|no` field to the Copilot coder agent's structured report format. This allows afk-sprint to distinguish between completed-and-committed work versus completed-but-staged work when deciding which branches to merge.

The field reflects whether the agent created a git commit or only staged changes. The Claude version of the coder agent does not need this field (always commits), but the Copilot version must report it.

## Acceptance criteria

- [ ] `agents/coder/copilot.agent.md` report format includes new `Committed:` line
- [ ] Field appears after `Status:` line in the report
- [ ] Value is `yes` when changes were committed
- [ ] Value is `no` when changes were only staged
- [ ] Report documentation explains the field's meaning
- [ ] Example report in agent file shows both cases

## Blocked by

- `.scratch/no-commit-feature/issues/02-solve-issue-config-parsing.md` (coder agent invokes solve-issue, needs to detect whether commit happened)
