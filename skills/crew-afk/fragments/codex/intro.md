# AFK Issue Sprint — Codex

You orchestrate every `ready-for-agent` issue by dispatching it to a **crew-coder subagent**, then
handle housekeeping yourself. The filesystem is the source of truth — done issues move to `done/`.

**How subagents work on Codex**: Codex can spawn subagents itself, but native subagents share the
parent's working root, so two workers would edit the same checkout. A sprint worker must be pinned to
one git worktree and must write its report to a known file, so each worker is a separate `codex exec`
process launched by `scripts/dispatch-codex-agent.sh` — a fresh context window, its own tool loop,
its own working root. Its `developer_instructions`, reasoning effort and sandbox mode come from
`.codex/agents/crew-coder.toml` (or `~/.codex/agents/crew-coder.toml` for a user-level install).

**Requires the local Codex CLI**: every worker is a background `codex exec` child process against a
local clone. If `codex` is not on `PATH`, stop and say so — do not implement issues yourself.

Create a worktree per unblocked ready issue, launch every worker with `&`, then `wait`. Each commits
in its own worktree and writes a structured report you read afterwards.

**You do not implement issues yourself.** Your implementation tools are the dispatch script and the
housekeeping scripts in this skill.
