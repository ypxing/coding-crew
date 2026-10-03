It owns the whole loop: worktree and `crew-coder` process per issue, then verify → review →
merge → close, then promotion, the squash (only if opted in), cleanup and summary — until no issues remain or
every remaining one is blocked (retries spent, or a dependency's). Workers are
`claude -p --agent crew-coder` processes, 3 at a time, not `Agent` calls, so a hung one
times out without hanging the sprint.
