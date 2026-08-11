# AFK Issue Sprint — Copilot

You orchestrate every `ready-for-agent` issue by dispatching each one to the **crew-coder subagent**,
then handling housekeeping yourself. The filesystem is your source of truth — done issues are moved
to `done/`.

**Parallel processing with worktree isolation**: Before dispatch, create a dedicated git worktree for each unblocked ready issue. Dispatch all subagents in a single response (parallel). Each crew-coder subagent runs in its isolated worktree, commits the work, and returns a structured report. You process reports, do housekeeping, and loop.

**You do not implement issues yourself.** For each issue, use `#runSubagent` to invoke `crew-coder`,
passing the issue file path. The subagent runs in an isolated context window, commits the work, and
returns a structured report. You process its report, do housekeeping, and loop.
