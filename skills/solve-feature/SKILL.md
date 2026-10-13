---
name: solve-feature
description: >
  Run one feature's ready-for-agent issues unattended on one branch, each by a fresh coder subagent and
  gated by the project's checks, in a draft PR that review-pr reviews at the end. Local or GitHub
  tracker. Trigger with /solve-feature <slug>. Optional: --branch <name>.
argument-hint: "<feature-slug> [--branch <name>]"
allowed-tools: Bash, shell
---

# solve-feature

You drive the loop; a script guards every step. **You do not implement, check, review, commit or
close anything yourself** — each issue's coder is a fresh subagent, and the script decides whether
its work lands.

Find the script once, then run each step as `bash <path> …` with the absolute path it printed:

```bash
LOOP="$(git rev-parse --show-toplevel)/.coding-crew/solve-feature/scripts/solve-feature.sh"
# a linked worktree may lack .coding-crew/: the main checkout's copy
[ -f "$LOOP" ] || LOOP="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")/.coding-crew/solve-feature/scripts/solve-feature.sh"
[ -f "$LOOP" ] || LOOP="$HOME/.coding-crew/solve-feature/scripts/solve-feature.sh"
echo "$LOOP"
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
3. **Review.** Use the review-pr skill on the last `pr=` printed (by `land`, else `start`). With none,
   report `nothing landed: no open PR to review` and end.

**Any other non-zero exit stops the run.** Relay the script's message as it printed it (a stop names
the step, the reason and, for the checks, its log) — after a `solve` stop, with the subagent's own
report — and end; do not retry, fix or close anything.
Once the cause is fixed, a re-run skips the issues already done and reuses the branch and the PR.

Run it where an unattended agent may change the checkout — a worktree or a container, not the one
the user works in. Nothing takes a lock: never start a second run on a slug whose run is still going.

| Setting                                         | Effect                                                         |
| ----------------------------------------------- | -------------------------------------------------------------- |
| `--branch <name>`                               | The branch to use when started on the default branch (default: one named after the slug) |
| `.coding-crew/config.json` `solveFeature.models.coder` / `.reviewer` | The coder / reviewer subagent's model, when your host accepts the name (default: your own) |
| `SOLVE_FEATURE_HOST`                            | The host name the PR's progress comment shows (default: `hostname`) |
