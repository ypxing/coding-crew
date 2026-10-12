---
name: afk-feature
description: >
  Run one feature's ready-for-agent issues unattended, in order, on one branch: after each coder run
  the project's checks and a fresh read-only verifier gate it, and one comment on the feature's root
  issue shows progress. GitHub tracker only. Trigger with /afk-feature <slug>. Optional: --branch
  <name>, --budget <usd>, --open-pr.
argument-hint: "<feature-slug> [--branch <name>] [--budget <usd>] [--open-pr]"
allowed-tools: Bash, shell
---

# afk-feature

The loop is a script, not a prompt: launch it, let it run, report what it printed. **You do not
implement, check, review or close anything yourself.**

```bash
AFK="$(git rev-parse --show-toplevel)/.coding-crew/afk-feature/scripts/afk-feature.sh"
# a linked worktree may lack .coding-crew/: the main checkout's copy
[ -f "$AFK" ] || AFK="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")/.coding-crew/afk-feature/scripts/afk-feature.sh"
[ -f "$AFK" ] || AFK="$HOME/.coding-crew/afk-feature/scripts/afk-feature.sh"
bash "$AFK" "$@"
```

A run takes up to an hour per issue, so start it where it can outlive your turn: in the
background, or tell the user to run it in a terminal. A bare word the user gave is the slug: pass it
as is; the script exits 1 naming a slug the tracker has no feature for.

## What one run does

1. **Preconditions**, before touching anything: `claude`, `gh`, `jq`, `node`, `git` and `timeout` on
   `PATH`; the tracker CLI installed and set to `github`; a valid slug with a feature in the
   tracker; a clean working tree. Any miss exits 1 with one line naming it.
2. **Branch.** On the default branch it checks out `--branch` (default: one named after the slug),
   creating it from `origin/<default>` and pushing it when it exists neither locally nor on
   `origin`. On any other branch it uses that branch. It never resets or rebases a branch, so a
   re-run continues where the last one stopped.
3. **Per issue**, lowest number first among the feature's open `ready-for-agent` issues (the root
   excluded, and any whose `## Blocked by` names an issue that is neither closed nor
   `awaiting-merge`):
   - the coder: `claude -p "/solve-issue <n>"` with a 60-minute timeout and `--budget` (default 5 USD).
     solve-issue closes the issue itself (`mark-done`, which labels it `awaiting-merge`);
   - the checks: solve-issue's `run-checks.sh`, run by the script, not the coder;
   - the verifier: a separate `claude -p` with the shipped reviewer protocol, read-only tools, a
     20-minute timeout and 2 USD, judging `git diff <before>..HEAD` against the issue's criteria.
     Only an `all-met` verdict moves on.

   Any failure stops the run with exit 1 and the step's log path: a coder error, a branch change,
   a dirty tree or moved HEAD, a failing check, `DISCOVER` (run `/solve-issue` or `dep-install` once
   by hand first), a missing report, a verdict other than `all-met`, or an issue still ready after
   its coder ran. Fix the cause, then re-run: issues already done are skipped.
4. **Finish**, when no ready issue is left: push the branch, then print `gh pr create` with the
   feature's `Closes #<n>` lines as the body (the tracker's `closing-refs`), or with `--open-pr`
   create the PR when none exists and print its URL.

Logs are under `.afk-logs/` (`<n>.log`, `<n>.checks.log`, `<n>.verify.log`, `<n>.verify.json`,
`<n>.issue.md`, `prd.md`); the directory ignores itself.

**Progress** is one comment on the feature's root issue, marked `<!-- afk-progress -->`, edited in
place at every step: the host, a line per issue (`solve`, `checks`, `verify`: ✓, ✗ or ·), on a stop
the failing step and the last 20 lines of its log, and at the end the PR URL or command. A failed
comment write only warns.

## Flags and environment

| Name                | Effect                                                                                   |
| ------------------- | ---------------------------------------------------------------------------------------- |
| `--branch <name>`   | The branch to use when started on the default branch                                     |
| `--budget <usd>`    | The coder's `--max-budget-usd` per issue (default 5)                                     |
| `--open-pr`         | Create the PR at the end when none exists                                                |
| `AFK_SANDBOXED=1`   | Run both `claude` processes with `bypassPermissions`: only in a container or runner      |
| `AFK_HOST`          | The host name the progress comment shows (default: `hostname`)                           |

Without `AFK_SANDBOXED`, both run with `acceptEdits`, no permission prompts, and an allow-list:
`git`, `node`, `gh`, `bash`, and each check command in `.coding-crew/dev-commands.json`. A command
outside it is denied, and the coder fails. Models come from `.coding-crew/config.json`
`afk.models.claude.coder` and `.reviewer` (defaults `sonnet` and `opus`).

## Where to run it

- **A terminal**, from the repo: `bash .coding-crew/afk-feature/scripts/afk-feature.sh <slug>`.
- **A herdr or orca pane in a worktree**: a worktree per feature keeps your checkout free; start it
  from that worktree, on its branch or the default one.
- **An OpenRig seat**: the same command as the seat's command, from a clone.
- **A GitHub Actions step**: check out, install coding-crew and the `claude` CLI, then
  `AFK_SANDBOXED=1 bash .coding-crew/afk-feature/scripts/afk-feature.sh <slug> --open-pr`, with the
  API key as a secret and `contents`, `issues` and `pull-requests` write permissions.
- **A cloud Claude Code session**: launch, don't host. Start one of the above from it (a
  `gh workflow run` for an Actions workflow, say) rather than running the loop inside the session,
  whose time limit and restricted token would cut a feature short.
