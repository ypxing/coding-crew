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
or close anything yourself** — each issue's coder, a conflicting merge's resolver, the reviewer, the fixer and the PR's writer are fresh subagents,
and the script decides whether their work lands and when the PR is ready.

A bare word the user gave is the slug: pass it as is; `start` stops on a slug the tracker does not list. `<repo>` is the repo's absolute top level;
`<skill-dir>` is the directory you read this file from.

1. **Start.** `bash "<skill-dir>/scripts/solve-feature.sh" start <slug> [--branch <name>]`. It prints `branch=`,
   `coder-model=`, `reviewer-model=` and `pr=`; keep them.
2. **Per issue**, until `next` exits 3:
   1. `bash "<skill-dir>/scripts/solve-feature.sh" next <slug>` — prints the issue's ref. Exit 3: no ready issue is
     left, go to step 3; it prints `reviewer-model=` again, for step 3.
   2. Run a **fresh subagent** — none of this conversation, full tool access, the repo's working
     directory — with exactly this prompt: `Use the solve-issue skill on <ref>; write your outcome and
     report to <repo>/.coding-crew/solve-feature/coder.report.md, and anything a person must do or decide to
     <repo>/.coding-crew/solve-feature/coder.notes.md, leaving that file absent when there is none`. When `coder-model=`
     is non-empty, run it on the model in your own list that matches that name (a family, with an optional
     version): a version you do not offer → the closest model of the same family; a family you do not offer → your
     own model. When it is empty, on your own. Wait for it to finish.
   3. `bash "<skill-dir>/scripts/solve-feature.sh" land <slug> <ref> <branch>`, with `start`'s `branch=` — always,
     whatever the subagent reported: `land` is what checks and records its result. It prints `pr=<n>`, and adds the coder's notes to the PR body's notes section.
3. **Review, fix and describe**, on `<n>`, the last `pr=` printed (by `land`, else `start`). With none, `next`
   printed why nothing landed: report it and end.
   Before 3.1, once (a second review round does not sync): `bash "<skill-dir>/scripts/solve-feature.sh" sync <slug> <branch>`.
   It merges the default branch in, gating and pushing that merge. Exit 4: the merge conflicts, left in progress,
   and it prints `conflicts=<files>`. Then run a **fresh subagent** — none of this conversation, full tool access,
   the repo's working directory, on `coder-model=` as for each issue's coder — with exactly this prompt: `Finish the
   merge in progress in <repo>, resolving the conflicts in <files> so that both sides' intent is kept, reading
   <repo>/.coding-crew/solve-feature/spec.md and the commits being merged in (git log HEAD..MERGE_HEAD); commit with
   git commit --no-edit. This run is non-interactive; ask no questions`. Wait for it to finish, then run `sync`
   again, once: any non-zero exit of that run, 4 included, stops the run like any other.
   1. Run a **fresh subagent** — none of this conversation, full tool access, the repo's working directory —
     with exactly this prompt: `Use the crew-review skill on branch <branch> against the spec in <repo>/.coding-crew/solve-feature/spec.md; write the report to <repo>/.coding-crew/solve-feature/pr-<n>.review.json`.
     When `reviewer-model=` (as `next` last printed it) is non-empty, run it on the model in your own list that
     matches that name, as for `coder-model=`, naming that model in the call; when it is empty, on your own. Wait for it to finish.
   2. `bash "<skill-dir>/scripts/solve-feature.sh" reviewed <slug> <n> <branch>` — always: it discards what the
     reviewer changed in the tree, flags it for the PR, and prints `findings=<k>` last. Only when it prints `findings=` greater than 0:
     run a **fresh subagent** — none of this conversation, full tool access, the repo's working
     directory — with exactly this prompt: `Judge each finding in <repo>/.coding-crew/solve-feature/pr-<n>.review.json
     against the code and the spec in <repo>/.coding-crew/solve-feature/spec.md before acting on it: its fix is a
     reviewer's suggestion, and a tool, API or platform fact a fix rests on is checked, never taken from memory. Run
     every project command through run.sh in the coding-crew-lib skill (coding-crew-lib/scripts/checks/run.sh
     --project-root <repo> -- "<command>"), as the solve-issue skill's Step 4 says: it runs where the project's
     dependencies are installed. Use the tdd skill to fix each real defect with the fix that adds no trigger, flag,
     permission, input or path the spec does not name. List each finding you did not fix, one per line with why — it
     is wrong, or only changing a spec decision fixes it (quote the decision) — in <repo>/.coding-crew/solve-feature/pr-<n>.unfixed.md, and leave that
     file absent if you fixed them all. Anything else a person must do or decide goes in
     <repo>/.coding-crew/solve-feature/pr-<n>.notes.md, left absent when there is none. This run is non-interactive; ask no questions`. Run it on `coder-model=` as for each issue's coder.
     Wait for it to finish.
   3. `bash "<skill-dir>/scripts/solve-feature.sh" fix <slug> <n> <branch>` — always, whatever the subagents
     reported. It gates the fixes with the checks, commits and pushes them, adds the fixer's notes to the PR body's notes section,
     and records what needs a person.
     Report its last line, `FIX: findings=<k> needs-attention=<a> review-again=yes|no`. After the first review,
     `review-again=yes` means run 3.1–3.3 once more; after the second review, go on to 3.4 whatever it prints.
     A non-zero exit of `fix` stops the run like any other: do not start a subagent or fix the checks yourself.
   4. Run a **fresh subagent** — none of this conversation, the repo's working directory — with exactly
     this prompt: `Use the write-pr skill on PR #<n>; its intent is the spec in <repo>/.coding-crew/solve-feature/spec.md
     and its checks passed (<repo>/.coding-crew/solve-feature/pr-<n>.checks.log). Write it to
     <repo>/.coding-crew/solve-feature/pr-<n>.summary.md`. Wait for it to finish.
   5. `bash "<skill-dir>/scripts/solve-feature.sh" describe <slug> <n>` — writes the PR's body and title, marks the
     draft ready when nothing needs a person, and prints the run's outcome, `ready pr=<n>` or
     `needs-attention pr=<n>`. Report it.

**Any other non-zero exit stops the run.** Relay the script's message as it printed it (a stop names
the step, the reason and, for the checks, its log; a `solve` stop, the coder's report) — and end; do
not retry, fix or close anything: a stop's recovery steps are for a person, never for you to carry out.
Once the cause is fixed, a re-run skips the issues already done and reuses the branch and the PR, which `start`
brings up to date with the default branch first.

Run it where an unattended agent may change the checkout — a worktree or a container, not the one
the user works in. Nothing takes a lock: never start a second run on a slug whose run is still going.

| Setting                                         | Effect                                                         |
| ----------------------------------------------- | -------------------------------------------------------------- |
| `--branch <name>`                               | The branch the run uses, never the default branch (default: one named after the slug) |
| `solveFeature.models.coder` / `.reviewer`       | The coder and fixer / reviewer model name; `CREW_CODER_MODEL` / `CREW_REVIEWER_MODEL` override it, and `start` prints the one it resolved |
