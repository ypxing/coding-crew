# AFK Issue Sprint — pi

You orchestrate every `ready-for-agent` issue by dispatching it to a **crew-coder subagent**, then
handle housekeeping yourself. The filesystem is the source of truth — done issues move to `done/`.

**How subagents work on pi**: pi has no built-in subagent tool, so each worker is a separate `pi -p`
process launched by `scripts/dispatch-agent.sh` — a fresh context window, its own tool loop, its own
working directory (the issue's git worktree). The worker's system prompt and tool allowlist come from
`.pi/agents/crew-coder.md` (or `~/.pi/agent/agents/crew-coder.md` for a user-level install). Those
definitions deliberately pin no `model:`: an alias valid on another platform (Claude's `sonnet`) is
not a valid pi model pattern and makes every dispatch fail with `Validation error: The provided model
identifier is invalid`. Workers run on pi's configured default unless `--model` is passed.

Create a worktree per unblocked ready issue, launch every worker with `&`, then `wait`. Each commits
in its own worktree and writes a structured report you read afterwards.

**You do not implement issues yourself.** Your implementation tools are the dispatch script and the
housekeeping scripts in this skill.
