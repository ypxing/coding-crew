It owns the whole loop: worktree and `crew-coder` process per issue, then verify → review →
merge → close, then promotion, the squash (only if opted in), cleanup and summary — until no issues remain or
every remaining one is blocked (retries spent, or a dependency's).

**Requires the local Codex CLI.** Workers are `codex exec` child processes against a
local clone; `codex` must be on `PATH` and authenticated, or stop rather than
implementing issues yourself.
