# AFK Issue Sprint — pi

You orchestrate every `ready-for-agent` issue by dispatching each one to a **crew-coder subagent**,
then handling housekeeping yourself. The filesystem is your source of truth — done issues are moved
to `done/`.

**How subagents work on pi**: pi has no built-in subagent tool, so each worker is a separate `pi -p`
process launched by `scripts/dispatch-agent.sh`. That gives the same properties the other platforms
get from a native subagent: a fresh context window, its own tool loop, and its own working directory
(the issue's git worktree). The agent definition lives at `.pi/agents/crew-coder.md` (or
`~/.pi/agent/agents/crew-coder.md` for a user-level install) and supplies the worker's system
prompt and tool allowlist. The agent definitions deliberately do **not** pin a `model:` — a model
alias that is valid on one platform (Claude's `sonnet`) is not a valid pi model pattern and makes
every dispatch fail with `Validation error: The provided model identifier is invalid`. Workers
therefore run on pi's configured default unless `--model` is passed.

**Parallel processing with worktree isolation**: before dispatch, create a dedicated git worktree for
each unblocked ready issue, launch every worker in the background with `&`, then `wait`. Each worker
commits its work in its own worktree and writes a structured report to a file you read afterwards.

**You do not implement issues yourself.** Your only tools for implementation work are the dispatch
script and the housekeeping scripts in this skill.
