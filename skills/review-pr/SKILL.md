---
name: review-pr
description: >
  One read-only subagent reviews a checked-out pull request against the spec in its body; a script
  posts one review on it and marks a draft ready when the spec is met with no CRITICAL or HIGH finding.
  Runnable by hand, by solve-feature and by a workflow. Trigger with /review-pr <pr-number>.
argument-hint: "<pr-number>"
allowed-tools: Bash, shell
---

# review-pr

A fresh subagent reviews; a script guards it and posts. **You do not review the PR yourself, and you
never post, edit or mark anything on it.**

Find the script once, then run each step as `bash <path> …` with the absolute path it printed:

```bash
REVIEW="$(git rev-parse --show-toplevel)/.coding-crew/review-pr/scripts/review-pr.sh"
# a linked worktree may lack .coding-crew/: the main checkout's copy
[ -f "$REVIEW" ] || REVIEW="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")/.coding-crew/review-pr/scripts/review-pr.sh"
[ -f "$REVIEW" ] || REVIEW="$HOME/.coding-crew/review-pr/scripts/review-pr.sh"
echo "$REVIEW"
```

The number the user gave is the PR number: pass it as is.

1. `bash <path> prepare <n>` — needs the PR checked out (`HEAD` is its head commit; otherwise tell
   the user to run `gh pr checkout <n>`) and a clean tree. It saves the PR's spec and diff under
   `.solve-feature/` (which ignores itself) and prints `prompt=<file>` and `reviewer-model=`.
2. Run a **fresh, read-only subagent** — none of this conversation, the repo's working directory —
   whose prompt is the content of the `prompt=` file, verbatim. Give it tools to read files and run
   shell commands (it writes its report with one) and, where your host lets you, no tool that edits
   files. When `reviewer-model=` is non-empty and your host accepts that model name for a subagent,
   run it on that model; otherwise on your own. Wait for it to finish.
3. `bash <path> post <n>` — refuses, exit 1 with nothing posted, when `HEAD` moved or the tree is no
   longer clean (the reviewer changed it), or the report is missing or unreadable. Otherwise it
   posts **one review** (`COMMENT`) — findings on the diff's lines inline, the rest and the spec's
   gaps in the body, each with a hidden `crew-finding:` marker so a re-run posts only what is new —
   and runs `gh pr ready <n>` only when the report says the spec is met, no finding is CRITICAL or
   HIGH and the PR was a draft.

Report `post`'s last line, `REVIEW: prd=<met|unmet> findings=<k> (<i> inline) ready=<yes|no|already>`
(`already` when the PR was not a draft). On any non-zero exit relay the script's message and stop.
