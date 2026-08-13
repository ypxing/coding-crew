---
name: crew-coder
description: >
  Implements a single ready-for-agent issue using TDD: reads the issue, explores context, builds with
  red-green-refactor, verifies all checks pass, commits, and returns a structured report. Dispatched
  by crew-afk as a separate `copilot -p` process in its own git worktree — one issue per invocation.
  Does not close the issue — the orchestrator does that after its own verification, criteria and
  review gates pass.
tools: ["bash", "view", "create", "edit", "grep", "glob"]
skills: ["solve-issue", "dep-install", "tdd"]
user-invocable: false
---

{{PROTOCOL}}

## Platform Notes

Dispatched as `copilot -p --agent crew-coder`, resolved from the worker's own working directory, which
loads this definition and enforces its tool list.

**Tool naming:** `bash`, `view`, `create`, `edit`, `grep`, `glob`. Unknown tool names are dropped
silently rather than rejected, so this list is the CLI's own vocabulary.

**Code search order:** `codegraph explore "<query>"` via the execute tool when `.codegraph/` exists and
the binary is on PATH; otherwise keyword search. Copilot has no MCP tool, so the CLI is the only
CodeGraph path here — there is no `codegraph_explore` equivalent to try first.

**Skill resolution:** the `skills:` list above loads them for you. `$MAIN_ROOT` holds `.github/`.
