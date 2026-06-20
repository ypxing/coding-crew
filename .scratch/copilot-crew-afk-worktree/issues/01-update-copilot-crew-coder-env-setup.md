Status: ready-for-agent

## What to build

Update `agents/crew-coder/copilot.agent.md` so the coder accepts `MAIN_ROOT` and `Working directory`
from the caller's prompt instead of inferring `PROJECT_ROOT` from `$(pwd)`.

The coder must:
- Read `MAIN_ROOT` and `Working directory` from the prompt and export both
- Set `PROJECT_ROOT` to the value of `Working directory` and `cd` into it
- Verify it is running inside a worktree: `.git` at `$PROJECT_ROOT` must be a file (not a directory);
  if it is a directory or absent, report `blocked` immediately
- Update command logging to write to `$MAIN_ROOT/.scratch/commands.log` with a worker tag derived
  from the current branch name (`git rev-parse --abbrev-ref HEAD | sed 's|.*/||'`)

This aligns the Copilot crew-coder with the Claude crew-coder's `MAIN_ROOT`/`PROJECT_ROOT`
convention (see `agents/crew-coder/claude.agent.md` for reference).

## Acceptance criteria

- [ ] `copilot.agent.md` environment setup reads `MAIN_ROOT` and `Working directory` from prompt
- [ ] `PROJECT_ROOT` is set to `Working directory` value; coder `cd`s into it at startup
- [ ] Worktree verification block present: reports `blocked` if `.git` is a directory or absent
- [ ] Command log target is `$MAIN_ROOT/.scratch/commands.log` with `[$WORKER]` prefix
- [ ] No reference to bare `PROJECT_ROOT=$(pwd)` remains in the env setup section

## Blocked by

None - can start immediately
