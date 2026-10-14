---
name: review-pr
description: >
  One read-only subagent reviews a checked-out pull request against the spec in its body, for what
  breaks and for the repo's documented rules; you post its report as one review and mark a draft
  ready when the spec is met with no CRITICAL or HIGH finding. Trigger with /review-pr <pr-number>.
argument-hint: "<pr-number>"
allowed-tools: Bash, shell
---

# review-pr

A fresh subagent reviews; you check its work stayed read-only and post what it found. **You do not
review the PR yourself.**

The number the user gave is the PR number, `<n>`; `<repo>` is the repo's absolute top level.

1. **Check out.** `HEAD` must be the PR's head (`gh pr view <n> --json headRefOid,isDraft`) and the
   tree clean; otherwise tell the user to run `gh pr checkout <n>` (or commit/stash) and stop. Note
   `isDraft`, and remove any old `<repo>/.solve-feature/pr-<n>.review.json`.
2. **Review.** Run a **fresh, read-only subagent** — none of this conversation, the repo's working
   directory — with exactly this prompt: `Review PR #<n> following <skill-dir>/reviewer-prompt.md. Write
   your report to <repo>/.solve-feature/pr-<n>.review.json`. Give it tools to read files and run shell commands (it
   writes its report with one) and, where your host lets you, no tool that edits files. When
   `.coding-crew/config.json` sets `solveFeature.models.reviewer` and your host accepts that model
   name, run it on that model; otherwise on your own. Wait for it to finish.
3. **Check.** If `HEAD` moved or the tree is no longer clean, the reviewer changed it: say so, post
   nothing and stop. With no report, or one that is not JSON, say so and stop.
4. **Post.** Read the PR's earlier reviews and comments (`gh pr view <n> --comments`) and leave out
   any finding they already raise. Post one review with `gh pr review <n> --comment --body-file
   <file>`: a first line `review-pr: spec <met|unmet>, <k> new finding(s)`, then the `gaps` under
   `### Gaps`, then the findings by severity, each `` `<location>` — <issue> — Fix: <fix> ``, then
   the line `<!-- crew-finding: review-pr -->`.
5. **Ready.** Only when the PR is a draft, `prd` is `met` and no finding in the report is CRITICAL or
   HIGH: `gh pr ready <n>`.

Report `REVIEW: prd=<met|unmet> findings=<k> new=<j> ready=<yes|no|already>` (`already` when the PR
was not a draft).
