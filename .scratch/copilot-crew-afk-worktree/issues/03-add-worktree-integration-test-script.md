Status: ready-for-agent

## What to build

Add `skills/crew-afk/references/test-worktree.sh` — a bash integration test script that verifies
the worktree lifecycle added in issue 02. Follow the pattern of the existing
`skills/crew-afk/references/test-session-init.sh`.

The script must set up a temporary git repo, simulate a crew-afk sprint round (create worktree,
symlink `.worktreeinclude` entries, remove worktree, prune), and assert:

1. Worktree is created at the expected path during a round
2. `.worktreeinclude` entries are symlinked into the worktree when the file exists
3. `.worktreeinclude` is skipped gracefully when absent
4. Worktree is removed after the round completes
5. `.scratch/worktrees/` is empty (or absent) after `git worktree prune`
6. Branch `crew/<feature-slug>/<issue-slug>` exists after worktree creation and is removed after cleanup

Each assertion prints `PASS` or `FAIL: <reason>` and the script exits non-zero if any assertion
fails.

## Acceptance criteria

- [ ] Script exists at `skills/crew-afk/references/test-worktree.sh`
- [ ] Script is executable (`chmod +x`)
- [ ] All 6 assertions above are present and tested
- [ ] Script cleans up its temp repo on exit (trap on EXIT)
- [ ] Script exits 0 when all assertions pass, non-zero otherwise
- [ ] Running the script produces clear PASS/FAIL output per assertion

## Blocked by

- 02-add-worktree-lifecycle-to-copilot-crew-afk.md
