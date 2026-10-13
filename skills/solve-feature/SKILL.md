---
name: solve-feature
description: >
  Run one feature's ready-for-agent issues unattended on one branch, each by a fresh coder subagent and
  gated by the project's checks, in a draft PR that is reviewed at the end, its findings fixed and
  marked ready when nothing needs a person. Local or GitHub tracker. Trigger with /solve-feature <slug>. Optional: --branch <name>.
argument-hint: "<feature-slug> [--branch <name>]"
allowed-tools: Bash, shell
---

# solve-feature

You drive the loop; a script guards every step. **You do not implement, check, review, fix, commit
or close anything yourself** — each issue's coder, the reviewer and the fixer are fresh subagents,
and the script decides whether their work lands.

Find the scripts once, then run each step as `bash <path> …` (or `bash <review> …`) with the
absolute paths they printed:

```bash
LOOP="$(git rev-parse --show-toplevel)/.coding-crew/solve-feature/scripts/solve-feature.sh"
# a linked worktree may lack .coding-crew/: the main checkout's copy
[ -f "$LOOP" ] || LOOP="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")/.coding-crew/solve-feature/scripts/solve-feature.sh"
[ -f "$LOOP" ] || LOOP="$HOME/.coding-crew/solve-feature/scripts/solve-feature.sh"
echo "$LOOP"
echo "${LOOP%/solve-feature/scripts/solve-feature.sh}/review-pr/scripts/review-pr.sh"   # <review>
```

A bare word the user gave is the slug: pass it as is.

1. **Start.** `bash <path> start <slug> [--branch <name>]`. It prints `branch=`, `coder-model=`,
   `reviewer-model=` and `pr=`; keep them.
2. **Per issue**, until `next` exits 3:
   1. `bash <path> next <slug>` — prints the issue's ref. Exit 3: no ready issue is left, go to step 3.
   2. Run a **fresh subagent** — none of this conversation, full tool access, the repo's working
     directory — with exactly this prompt: `Use the solve-issue skill on <ref>`. When `coder-model=`
     is non-empty and your host accepts that model name for a subagent, run it on that model;
     otherwise on your own. Wait for it to finish.
   3. `bash <path> land <slug> <ref> <branch>`, with `start`'s `branch=` — always, whatever the
     subagent reported: `land` is what checks and records its result. It prints `pr=<n>`.
3. **Review and fix**, on `<n>`, the last `pr=` printed (by `land`, else `start`). With none, report
   `nothing landed: no open PR to review` and end.
   1. `bash <review> prepare <n>` — prints `prompt=<file>` and `reviewer-model=`.
   2. Run a **fresh, read-only subagent** — none of this conversation, the repo's working directory —
     whose prompt is the content of the `prompt=` file, verbatim. Give it tools to read files and run
     shell commands (it writes its report with one) and, where your host lets you, no tool that edits
     files. When `reviewer-model=` is non-empty and your host accepts that model name, run it on that
     model; otherwise on your own. Wait for it to finish.
   3. Only when `jq '.findings // [] | length' .solve-feature/pr-<n>.review.json` prints more than 0:
     run a **fresh subagent** — none of this conversation, full tool access, the repo's working
     directory — with exactly this prompt, `<repo>` the repo's absolute top level: `Use the tdd skill to fix every
     finding in <repo>/.solve-feature/pr-<n>.review.json; list any you could not fix, one per line,
     in <repo>/.solve-feature/pr-<n>.unfixed.md, and leave that file absent if you fixed them all`. Run it on `coder-model=` as for each issue's coder.
     Wait for it to finish.
   4. `bash <path> fix <slug> <n> <branch>` — always, whatever the subagents reported. It gates the
     fixes with the checks, commits and pushes them, records the review on the PR's progress comment
     and marks the draft ready when nothing needs a person. Report its last line,
     `FIX: findings=<k> fixed=<f> needs-attention=<a> ready=<yes|no|already>`.

**Any other non-zero exit stops the run.** Relay the script's message as it printed it (a stop names
the step, the reason and, for the checks, its log) — after a `solve` stop, with the subagent's own
report — and end; do not retry, fix or close anything.
Once the cause is fixed, a re-run skips the issues already done and reuses the branch and the PR; a
`fix` stop names its own recovery.

Run it where an unattended agent may change the checkout — a worktree or a container, not the one
the user works in. Nothing takes a lock: never start a second run on a slug whose run is still going.

| Setting                                         | Effect                                                         |
| ----------------------------------------------- | -------------------------------------------------------------- |
| `--branch <name>`                               | The branch to use when started on the default branch (default: one named after the slug) |
| `.coding-crew/config.json` `solveFeature.models.coder` / `.reviewer` | The coder and fixer / reviewer subagent's model, when your host accepts the name (default: your own) |
| `SOLVE_FEATURE_HOST`                            | The host name the PR's progress comment shows (default: `hostname`) |
