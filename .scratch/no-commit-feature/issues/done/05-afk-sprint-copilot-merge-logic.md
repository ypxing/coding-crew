Status: done

## Parent

PRD: `.scratch/no-commit-feature/PRD.md`

## What to build

Add `--commit` and `--no-commit` flag support to the Copilot version of `afk-sprint`. This is the orchestrator-level integration that ties everything together.

Parse flags/config at session start, pass the commit preference to each coder subagent, conditionally skip the merge step when `--no-commit` is used, and provide a summary listing all worktrees with staged changes.

On a second run (after user manually commits some worktrees), detect which branches have commits, merge only those, mark their issues done, and leave uncommitted worktrees intact for further work.

The Claude version of afk-sprint is unchanged—it always commits regardless of flags.

## Acceptance criteria

- [ ] Session init parses flags and config using correct precedence
- [ ] Coder subagent prompts include `Auto-commit: yes|no` based on parsed preference
- [ ] When `--no-commit`: Step 4 skips merge entirely, worktrees stay intact
- [ ] When `--no-commit`: Exit prints worktree summary with paths, file counts, next steps
- [ ] When `--commit` (default): current behavior preserved (merge and mark done)
- [ ] Second run detects committed branches and merges only those
- [ ] Partial commits supported: merge committed, leave uncommitted worktrees for user
- [ ] Claude platform warning added if needed (though Claude version doesn't use this code)

## Blocked by

- `.scratch/no-commit-feature/issues/02-solve-issue-config-parsing.md` (afk-sprint invokes solve-issue, needs it to support flags first)
