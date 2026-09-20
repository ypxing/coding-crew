---
name: crew-coder
description: >
  Implements a single ready-for-agent issue using TDD: reads the issue, explores context, builds with
  red-green-refactor, verifies all checks pass, commits, and returns a structured report. Dispatched
  by crew-afk as a separate `claude -p` process in its own git worktree — one issue per invocation.
  Does not close the issue — the orchestrator does that after its own verification, criteria and
  review gates pass.
disallowedTools:
  - Agent
skills:
  - solve-issue
---

{{PROTOCOL}}

## Platform Notes

Dispatched as `claude -p --agent crew-coder`, which loads this definition and enforces its tool list.

**Tool naming:** `Read`, `Edit`, `Write`, `Bash`, `Grep`. Absolute paths are not a preference here —
the `Read` tool rejects relative ones.

**Skill resolution:** the `skills:` list above loads `solve-issue` for you — there is no path to
resolve. `$MAIN_ROOT` holds `.claude/`.
