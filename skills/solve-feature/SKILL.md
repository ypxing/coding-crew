---
name: solve-feature
description: >
  Runs one feature's ready-for-agent issues unattended on one branch, each by a fresh coder subagent gated by
  the project's checks, in a draft PR that is reviewed at the end, has its findings fixed, and is marked ready
  when nothing needs a person. Works with a local or GitHub tracker. Use when a feature's issues are ready and
  should land as one reviewed PR. Trigger with /solve-feature <slug>. Optional: --branch <name>.
argument-hint: "<feature-slug> [--branch <name>]"
allowed-tools: Bash shell
---

# solve-feature

You drive the loop; a script guards every step. **You do not implement, check, review, fix, commit
or close anything yourself** — each issue's coder, the reviewer, the fixer and the PR's writer are fresh subagents,
and the script decides whether their work lands and when the PR is ready.

A bare word the user gave is the slug: pass it as is; `start` stops on a slug the tracker does not list. `<repo>` is the repo's absolute top level;
`<skill-dir>` is the directory you read this file from.

1. **Start.** `bash "<skill-dir>/scripts/solve-feature.sh" start <slug> [--branch <name>]`. It prints `branch=`,
   `coder-model=`, `reviewer-model=` and `pr=`; keep them.
2. **Per issue**, until `next` exits 3:
   1. `bash "<skill-dir>/scripts/solve-feature.sh" next <slug>` — prints the issue's ref. Exit 3: no ready issue is
     left, go to step 3.
   2. Run a **fresh subagent** — none of this conversation, full tool access, the repo's working
     directory — with exactly this prompt: `Use the solve-issue skill on <ref>; write your outcome and
     report to <repo>/.solve-feature/coder.report.md`. When `coder-model=`
     is non-empty and your host accepts that model name for a subagent, run it on that model;
     otherwise on your own. Wait for it to finish.
   3. `bash "<skill-dir>/scripts/solve-feature.sh" land <slug> <ref> <branch>`, with `start`'s `branch=` — always,
     whatever the subagent reported: `land` is what checks and records its result. It prints `pr=<n>`.
3. **Review, fix and describe**, on `<n>`, the last `pr=` printed (by `land`, else `start`). With none, `next`
   printed why nothing landed: report it and end.
   1. Run a **fresh, read-only subagent** — none of this conversation, the repo's working directory —
     with exactly this prompt: `Use the crew-review skill on branch <branch> against the spec in <repo>/.solve-feature/spec.md; write the report to <repo>/.solve-feature/pr-<n>.review.json`.
     Give it tools to read files and run shell commands (it writes its report with one) and, where your host lets
     you, no tool that edits files. When `reviewer-model=` is non-empty and your host accepts that model name, run
     it on that model; otherwise on your own. Wait for it to finish.
   2. Only when `jq '.findings // [] | length' .solve-feature/pr-<n>.review.json` prints more than 0:
     run a **fresh subagent** — none of this conversation, full tool access, the repo's working
     directory — with exactly this prompt: `Use the tdd skill to fix every
     finding in <repo>/.solve-feature/pr-<n>.review.json; list any you could not fix, one per line,
     in <repo>/.solve-feature/pr-<n>.unfixed.md, and leave that file absent if you fixed them all. This
     run is non-interactive: the report's findings are the approved plan; ask no questions`. Run it on `coder-model=` as for each issue's coder.
     Wait for it to finish.
   3. `bash "<skill-dir>/scripts/solve-feature.sh" fix <slug> <n> <branch>` — always, whatever the subagents
     reported. It gates the fixes with the checks, commits and pushes them, and records what needs a person.
     Report its last line, `FIX: findings=<k> needs-attention=<a> review-again=yes|no`. After the first review,
     `review-again=yes` means run 3.1–3.3 once more; after the second review, go on to 3.4 whatever it prints.
   4. Run a **fresh subagent** — none of this conversation, the repo's working directory — with exactly
     this prompt: `Use the write-pr skill on PR #<n>; its intent is the spec in <repo>/.solve-feature/spec.md
     and its checks passed (<repo>/.solve-feature/pr-<n>.checks.log). Write it to
     <repo>/.solve-feature/pr-<n>.summary.md`. Wait for it to finish.
   5. `bash "<skill-dir>/scripts/solve-feature.sh" describe <slug> <n>` — writes the PR's body and title, marks the
     draft ready when nothing needs a person, and prints the run's outcome, `ready pr=<n>` or
     `needs-attention pr=<n>`. Report it.

**Any other non-zero exit stops the run.** Relay the script's message as it printed it (a stop names
the step, the reason and, for the checks, its log; a `solve` stop, the coder's report) — and end; do
not retry, fix or close anything.
Once the cause is fixed, a re-run skips the issues already done and reuses the branch and the PR, which `start`
brings up to date with the default branch first. A `checks`
stop has already reopened its issue and pushed its work, so the re-run's coder starts from that work; a stop
after a push failed or a review was fixed names its own recovery.

Run it where an unattended agent may change the checkout — a worktree or a container, not the one
the user works in. Nothing takes a lock: never start a second run on a slug whose run is still going.

Every run ends with one line in `<repo>/.solve-feature/outcome` — `ready pr=<n>`, `needs-attention pr=<n>` or
`stopped: <what> failed: <reason>` — for a host to read; no file means the run never finished. `<what>` is the
subcommand that stopped (`start failed: …`, `next failed: nothing landed: …`), or the issue ref or `review` and
the step (`2 checks failed: …`, `review fix failed: …`).

| Setting                                         | Effect                                                         |
| ----------------------------------------------- | -------------------------------------------------------------- |
| `--branch <name>`                               | The branch the run uses, never the default branch (default: one named after the slug) |
| `.coding-crew/config.json` `solveFeature.models.coder` / `.reviewer` | The coder and fixer / reviewer subagent's model, when your host accepts the name (default: your own) |
