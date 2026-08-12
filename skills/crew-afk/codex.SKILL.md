---
name: crew-afk
description: >
  Implements all ready-for-agent issues in the current repo by dispatching each one to a crew-coder
  subagent (a separate `codex exec` process in an isolated git worktree), then housekeeping the
  result. Loops until no issues remain or all are stalled. Reviews every branch before it merges.
  Use when asked to run an AFK sprint or implement all open issues.
  Optional: --model <alias|inherit> to override the coder's default model; --coverage for a PRD
  coverage report; --promote critical-high to promote HIGH review findings as well as CRITICAL.
---

# AFK Issue Sprint — Codex

The sprint is a program, not a prompt. You launch it, stream its output, and report what
it printed. **You do not orchestrate, implement, review, merge or close anything yourself.**

```bash
node "$(git rev-parse --show-toplevel)/.coding-crew/crew-afk/main.mjs" run --platform codex "$@"
```

Pass the user's arguments straight through: `--model <alias|inherit>`, `--coverage`,
`--promote critical-high`, `--max-parallel N`, `--worker-timeout <minutes>`,
`--max-rounds N`, `--no-squash`, `--jira TICKET-123`, or a `.scratch/<feature-slug>/…`
path. Unrecognised arguments are forwarded to session setup, so never rewrite them.

It owns the whole loop: session init, issue selection, a worktree and a `crew-coder`
process per ready issue, then per branch `verify → review (acceptance criteria +
findings) → merge → close`, then findings promotion, squash, cleanup and the summary. It
loops until no issues remain or two rounds complete nothing.

**Requires the local Codex CLI.** Every worker is a separate `codex exec` child process
against a local clone, so `codex` must be on `PATH` and already authenticated. If it is
not, say so and stop — do not implement issues yourself.

## Your part

1. Run the command above, with `--dry-run` first **only** if the user asked what it would do.
2. Stream stdout as it arrives. The summary it prints is the report — do not rewrite,
   summarise, or re-derive it from the state file.
3. Report the exit code's meaning and stop: `0` finished, `2` stalled (blockers need a
   human), `3` no ready issues, `1` setup problem — print its stderr verbatim and stop.

## Failure handling

- `node: command not found` → tell the user the orchestrator needs Node ≥ 20, and stop.
- `cannot find crew-afk's scripts/ dir` → the skill is half-installed; re-run
  `./install.sh codex --skill crew-afk`.
- Missing `crew-coder` / `crew-code-reviewer` definitions → the same re-install fixes it;
  `node .coding-crew/crew-afk/main.mjs doctor --platform codex` names what is absent.
- Any other non-zero exit → print its output and stop. Never finish the sprint by hand:
  a merge or close performed outside the pipeline skips the receipt gates that keep an
  unverified branch out of the feature branch.
