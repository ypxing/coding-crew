---
name: solve-feature
description: >
  Run one feature's ready-for-agent issues unattended on one branch, each gated by the project's
  checks, in a draft PR that review-pr reviews at the end. Local or GitHub tracker. Trigger with
  /solve-feature <slug>. Optional: --branch <name>, --budget <usd>, --agent claude|copilot|pi|codex.
argument-hint: "<feature-slug> [--branch <name>] [--budget <usd>] [--agent claude|copilot|pi|codex]"
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

The coder runs with every permission granted, so suggest a worktree or container over the checkout
the user works in. The script takes no lock: never start a second run on a slug whose run is still
going.

Every stop exits 1 with one line naming the cause and, for a failed step, its log. Relay it; once
the cause is fixed, a re-run skips the issues already done and reuses the PR. A finished run prints
review-pr's `REVIEW:` line and the PR URL last.

| Flag / env            | Effect                                                                   |
| --------------------- | ------------------------------------------------------------------------ |
| `--branch <name>`     | The branch to use when started on the default branch (default: one named after the slug) |
| `--budget <usd>`      | The coder's budget per issue (default 10; claude only)                   |
| `--agent <agent>`     | `claude`, `copilot`, `pi` or `codex` (default `SOLVE_FEATURE_AGENT`, then `claude`) |
| `SOLVE_FEATURE_AGENT` | The `--agent` default                                                    |
| `SOLVE_FEATURE_HOST`  | The host name the PR's progress comment shows (default: `hostname`)      |

The coder's model is `.coding-crew/config.json` `afk.models.<agent>.coder` (claude defaults to
`sonnet`; the others use their CLI's default).
