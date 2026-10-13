---
name: review-pr
description: >
  One read-only agent reviews a checked-out pull request against the spec in its body, posts one
  review on it and marks a draft ready when the spec is met with no CRITICAL or HIGH finding. Runnable
  by hand, by solve-feature and by a workflow. Trigger with /review-pr <pr-number>. Optional: --agent
  claude|copilot.
argument-hint: "<pr-number> [--agent claude|copilot]"
allowed-tools: Bash, shell
---

# review-pr

The review is a script, not a prompt: launch it, let it run, report what it printed. **You do not
review the PR yourself, and you never post, edit or mark anything on it.**

```bash
REVIEW="$(git rev-parse --show-toplevel)/.coding-crew/review-pr/scripts/review-pr.sh"
# a linked worktree may lack .coding-crew/: the main checkout's copy
[ -f "$REVIEW" ] || REVIEW="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")/.coding-crew/review-pr/scripts/review-pr.sh"
[ -f "$REVIEW" ] || REVIEW="$HOME/.coding-crew/review-pr/scripts/review-pr.sh"
bash "$REVIEW" "$@"
```

A run takes up to 30 minutes, so start it where it can outlive your turn, or tell the user to run it
in a terminal. The number the user gave is the PR number: pass it as is.

## Precondition: the PR is checked out

The script reads `gh pr view <n>` and refuses, exit 1, unless `git rev-parse HEAD` is the PR's head
commit — the reviewer reads callers in the tree, and the script asserts afterwards that the tree is
unchanged. Tell the user to run `gh pr checkout <n>` first. It also needs the agent's CLI, `gh`,
`jq`, `git` and `timeout` on `PATH`.

## What one run does

1. Saves the PR's spec and diff under `.solve-feature/` (`pr-<n>.spec.md`, `pr-<n>.diff`; the
   directory ignores itself). The spec is the body's `<details><summary>Spec</summary>` block when
   the body has one (solve-feature writes it), else the whole body.
2. Runs one fresh read-only agent — `claude` by default, `--agent copilot` or
   `SOLVE_FEATURE_AGENT=copilot` for the Copilot CLI — with a 30-minute timeout (4 USD on claude),
   asking two questions: does the PR deliver what the spec asks for, and is it bug free in the new
   code and its integration. Its log is `pr-<n>.review.log`, its report `pr-<n>.review.json`. The
   model is `.coding-crew/config.json` `afk.models.<agent>.reviewer` (claude default `opus`).
3. Posts **one review** (`COMMENT`): the body opens `review-pr: prd <met|unmet>, <k> finding(s)`,
   lists the gaps, and holds the findings not on the diff's right-hand side under a heading per
   severity; a finding at a `path:line` the diff shows is an inline comment. Each finding carries a
   hidden `crew-finding:` marker, so a re-run posts only what is new (and still posts the one-line
   body when nothing is).
4. Runs `gh pr ready <n>` only when the report says the spec is met, no finding is CRITICAL or HIGH
   and the PR was a draft. Otherwise the PR is left as it is.

Last stdout line: `REVIEW: prd=<met|unmet> findings=<k> (<i> inline) ready=<yes|no|already>`
(`already` when the PR was not a draft). Exit 1 with nothing posted on a precondition miss, a
reviewer that changed HEAD or the tree, a missing or unreadable report (the line names
`pr-<n>.review.log`), or a failed post.

`scripts/agent.sh` beside the script owns the agent argv, the coder prompt and the model lookup for
both this skill and solve-feature. The copilot coder prompt (`Use the solve-issue skill on <ref>.`)
is to be verified at the first real copilot run; if the CLI does not invoke the skill that way, the
copilot arm of `agent_coder_prompt` is the one line to change.
