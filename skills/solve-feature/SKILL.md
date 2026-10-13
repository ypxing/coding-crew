---
name: solve-feature
description: >
  Run one feature's ready-for-agent issues unattended, in order, on one branch: after each coder run
  the project's checks gate it and the tracker's own close confirms it; the first landed issue opens
  a draft PR carrying the spec, progress is one comment on that PR, and review-pr reviews it at the
  end. Local or GitHub tracker. Trigger with /solve-feature <slug>. Optional: --branch <name>,
  --budget <usd>, --agent claude|copilot.
argument-hint: "<feature-slug> [--branch <name>] [--budget <usd>] [--agent claude|copilot]"
allowed-tools: Bash, shell
---

# solve-feature

The loop is a script, not a prompt: launch it, let it run, report what it printed. **You do not
implement, check, review or close anything yourself.**

```bash
LOOP="$(git rev-parse --show-toplevel)/.coding-crew/solve-feature/scripts/solve-feature.sh"
# a linked worktree may lack .coding-crew/: the main checkout's copy
[ -f "$LOOP" ] || LOOP="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")/.coding-crew/solve-feature/scripts/solve-feature.sh"
[ -f "$LOOP" ] || LOOP="$HOME/.coding-crew/solve-feature/scripts/solve-feature.sh"
bash "$LOOP" "$@"
```

A run takes up to an hour per issue, so start it where it can outlive your turn: in the
background, or tell the user to run it in a terminal. A bare word the user gave is the slug: pass it
as is; the script exits 1 naming a slug the tracker has no feature for.

## What one run does

1. **Preconditions**, before touching anything: the coding agent's CLI (`claude` or `copilot`, per
   `--agent`), `gh`, `jq`, `node`, `git` and `timeout` on `PATH` (macOS ships no `timeout`: `brew
   install coreutils`, then put its `gnubin` on `PATH` or link `gtimeout` as `timeout`); the
   tracker CLI installed (local or GitHub); a valid slug; a clean working tree; a committed
   `.coding-crew/dev-commands.json` (run `/solve-issue` or `dep-install` once by hand first). Any
   miss exits 1 with one line naming it.
2. **Branch and prepare.** On the default branch it checks out `--branch` (default: one named after
   the slug), creating it from `origin/<default>` and pushing it when it exists neither locally nor
   on `origin`. On any other branch it uses that branch. It never resets or rebases a branch, so a
   re-run continues where the last one stopped. Then dep-install's `resolve-mode.sh` picks host or
   docker and the matching install script runs once, headlessly; a failed install only warns (the
   coder's own solve-issue retries a missing dependency), its output in `.solve-feature/prepare.log`.
3. **Per issue**, in the order the tracker's `next` gives — the lowest `ready-for-agent` issue not
   labelled `blocked` whose every `## Blocked by` entry is done, the root included:
   - the coder: `claude -p "/solve-issue <ref>"` or `copilot -p "Use the solve-issue skill on
     <ref>."`, with a 60-minute timeout and (claude) `--budget` (default 5 USD). solve-issue closes
     the issue itself (`mark-done`); an issue `next` still returns after the coder exits stops the
     run there (`coder ran but did not close <ref>`);
   - the checks: solve-issue's `run-checks.sh`, run by the script, not the coder;
   - the landing: push the branch, then open a draft PR titled after the PRD (or, without one, the
     first landed issue), or rewrite the block of the branch's open PR.

   Any failure stops the run with exit 1 and the step's log path: a coder error, a branch change,
   a dirty tree, an unclosed issue, a failing check or `DISCOVER`. Fix the cause, then re-run:
   issues already done are skipped, the PR is reused.
4. **Finish**, when no ready issue is left: run `review-pr` on the branch's open PR — also one an
   earlier run or a human opened — echo its `REVIEW:` line, print the PR URL last and exit with
   review-pr's code. No open PR (nothing ever landed) exits 0 saying so.

**The PR body** holds the spec between `<!-- solve-feature:begin -->` and `<!-- solve-feature:end -->`:
a collapsed `Spec` block with the feature's PRD and, per landed issue, `### <ref> — <title>` and its
acceptance criteria; on GitHub the `Closes #<n>` lines; the slug. A spec over GitHub's 65,536-character
body limit is cut inside the block with a note. Text outside the block is yours and kept; the draft
state is review-pr's to flip. review-pr reads the block as the spec; address-pr-comments recognises
a solve-feature PR by it.

Logs are under `.solve-feature/` (`<ref>.log`, `<ref>.checks.log`, `<ref>.issue.md`,
`<ref>.pr-body.md`, `prd.md`, `prepare.log`; a local ref's `/` becomes `_`); the directory ignores
itself.

**Progress** is one comment on the PR, marked `<!-- solve-feature-progress -->`, edited in place at
every step: the host, a line per issue (`solve`, `checks`: ✓, ✗ or ·), on a stop the failing step and
the last 20 lines of its log (of a `claude` log its result text, of a `copilot` log its last
assistant message), and at the end the `REVIEW:` line and the URL. Until the PR exists the rows go to
stdout. A failed comment write only warns.

## Flags and environment

| Name                           | Effect                                                                        |
| ------------------------------ | ----------------------------------------------------------------------------- |
| `--branch <name>`              | The branch to use when started on the default branch                          |
| `--budget <usd>`               | The coder's `--max-budget-usd` per issue (default 5; claude only)             |
| `--agent claude\|copilot`      | The coding agent (default `SOLVE_FEATURE_AGENT`, then `claude`)               |
| `SOLVE_FEATURE_AGENT`          | The `--agent` default                                                         |
| `SOLVE_FEATURE_HOST`           | The host name the progress comment shows (default: `hostname`)                |

The coder runs unattended with every permission granted (`claude`: `--permission-mode
bypassPermissions`; `copilot`: `--allow-all-tools`), as crew-afk's does: nobody can answer a prompt,
and an allow-list, `auto` mode and Claude Code's sandbox all refuse solve-issue's own commands. The
coder can therefore run anything your user can, so give it a worktree, container or runner rather than
the checkout you work in. review-pr's agent is read-only. Models come from `.coding-crew/config.json`
`afk.models.<agent>.coder` (claude defaults to `sonnet`; copilot passes `--model` only when set).

**One run per feature at a time.** The script takes no lock: two runs on the same slug both pick
the same lowest ready issue and both push to the same branch. Start a second host only after the
first has stopped.

## Where to run it

The loop is the same command everywhere; the hosts are recipes shipped as files under
`.coding-crew/solve-feature/hosts/` (also under the platform's `skills/solve-feature/hosts/`), not
code in the loop.

- **A terminal**, from the repo: `bash .coding-crew/solve-feature/scripts/solve-feature.sh <slug>`.
- **A herdr or orca pane in a worktree**: a worktree per feature keeps your checkout free; run the
  same command from that worktree, on its branch or the default one.
- **A cloud Claude Code session**: launch, don't host. Start one of the hosts below from it (`gh
  workflow run solve-feature -f slug=<slug>`, or label the root issue) rather than running the loop
  inside the session, whose time limit and restricted token would cut a feature short.
- **GitHub Actions, on the Copilot CLI** (no API key; billed to GitHub Copilot): copy
  `.coding-crew/solve-feature/hosts/github-actions.yml` to `.github/workflows/` (install.sh never
  writes there) and commit it, then label the feature's root issue `solve-feature`, or run the
  workflow by hand with the slug. With the workflow's own `github.token` the CLI bills under the
  organisation policy "Allow use of Copilot CLI billed to the organization"; billing a person
  through a `COPILOT_GITHUB_TOKEN` secret is sketched in the file as unverified. review-pr runs in
  the same job, because a PR the workflow's token opens triggers no other workflow; the concurrency
  group makes a re-label wait for the run in flight.
- **Docker**: build `.coding-crew/solve-feature/hosts/Dockerfile` (claude and copilot CLIs,
  `gh`, docker CLI, coding-crew user-level for every platform), run it with the clone mounted at
  `/work`, `ANTHROPIC_API_KEY` or `GH_TOKEN` in the environment and `--agent` as wanted; mount the
  docker socket when the project's checks run in compose. The run line is the file's header.
- **OpenRig and other cloud agents**: future recipes, the same command from a clone; the loop does
  not change for them.
