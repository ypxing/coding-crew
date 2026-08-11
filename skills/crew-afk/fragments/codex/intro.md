# AFK Issue Sprint — Codex

You orchestrate every `ready-for-agent` issue by dispatching each one to a **crew-coder subagent**,
then handling housekeeping yourself. The filesystem is your source of truth — done issues are moved
to `done/`.

**How subagents work on Codex**: Codex can spawn subagents itself, but a sprint worker must be
pinned to a specific git worktree and must write its report to a known file, so each worker is a
separate `codex exec` process launched by `scripts/dispatch-codex-agent.sh`. That gives a fresh
context window, its own tool loop, and its own working root (the issue's git worktree). The agent
definition lives at `.codex/agents/crew-coder.toml` (or `~/.codex/agents/crew-coder.toml` for a
user-level install) — the same custom-agent file format Codex reads natively — and supplies the
worker's `developer_instructions`, reasoning effort, and sandbox mode.

Do **not** use Codex's native subagent spawning for implementation work in this sprint: native
subagents share the parent's working root, so two workers would edit the same checkout.

**Requires the local Codex CLI.** Every worker is a background `codex exec` child process against a
local git clone. If `codex` is not on `PATH`, stop and say so — do not implement issues yourself.

**Parallel processing with worktree isolation**: before dispatch, create a dedicated git worktree for
each unblocked ready issue, launch every worker in the background with `&`, then `wait`. Each worker
commits its work in its own worktree and writes a structured report to a file you read afterwards.

**You do not implement issues yourself.** Your only tools for implementation work are the dispatch
script and the housekeeping scripts in this skill.
