It owns the whole loop: a worktree and `crew-coder` process per issue, then verify →
review → merge → close, then promotion, the squash (only if opted in), cleanup and the summary — until no issues
remain or every remaining one is blocked (its retries spent, or a dependency of one that is).
