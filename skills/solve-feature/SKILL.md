---
name: solve-feature
description: >
  Runs one feature's ready-for-agent issues unattended on one branch, each by a fresh coder subagent gated by
  the project's checks, in a draft PR that is reviewed at the end, has its findings fixed, and is marked ready
  when nothing needs a person. Works with a local or GitHub tracker. Use when a feature's issues are ready and
  should land as one reviewed PR. Trigger with /solve-feature <slug>, or /solve-feature --spec <file> --issue <n> to
  build one spec file as the feature issue-<n>. Optional: --branch <name>, --review-since <sha>.
argument-hint: "<feature-slug> | --spec <file> --issue <n> [--branch <name>] [--review-since <sha>]"
allowed-tools: Bash shell
---

# solve-feature

You drive the loop; a script guards every step. **You do not implement, check, review, fix, commit
or close anything yourself** — each issue's coder, a conflicting merge's resolver, the reviewer, the fixer and the PR's writer are fresh subagents,
and the script decides whether their work lands and when the PR is ready.

A bare word the user gave is the slug: pass it as is; `start` stops on a slug the tracker does not list. `<repo>` is the repo's absolute top level;
`<skill-dir>` is the directory you read this file from.

1. **Start.** `bash "<skill-dir>/scripts/solve-feature.sh" start <slug> [--branch <name>] [--review-since <sha>]`, passing on the flags the user gave;
   given `--spec <file> --issue <n>`, pass those in place of `<slug>`. It prints `branch=`,
   `coder-model=`, `reviewer-model=` and `pr=`; keep them. With `--spec` it prints `slug=` first: that value is `<slug>` in every step below.
2. **Per issue**, until no ready issue is left:
   1. Once, before the first issue: `bash "<skill-dir>/scripts/solve-feature.sh" next <slug>` — prints the issue's ref.
     Exit 3: no ready issue is left, go to step 3; with a PR open it prints `red-files=`, `reviewer-model=` and
     `review-base=` for step 3, having merged the default branch in (exit 4: step 3's conflict).
   2. Run a **fresh subagent** — none of this conversation, full tool access, the repo's working
     directory — with exactly this prompt: `Use the solve-issue skill on <ref>; write your outcome and
     report to <repo>/.coding-crew/solve-feature/coder.report.md, and anything a person must do or decide before
     this branch merges to <repo>/.coding-crew/solve-feature/coder.notes.md (not what the run settles on its own, such
     as the tracker defaulting to local, [WIP] checkpoint commits or an untracked dev commands file, nor optional follow-ups), keeping what that file already holds, leaving it absent when there is none;
     your red-evidence file is <ref, / → _>.red.md in <repo>/.coding-crew/solve-feature`. When `coder-model=`
     is non-empty, run it on the model in your own list that matches that name (a family, with an optional
     version): a version you do not offer → the closest model of the same family; a family you do not offer → your
     own model. When it is empty, on your own. Wait for it to finish.
   3. `bash "<skill-dir>/scripts/solve-feature.sh" land <slug> <ref> <branch>`, with `start`'s `branch=` — always,
     whatever the subagent reported: `land` is what checks and records its result. It prints `pr=<n>`, then `next=<ref>`: the next issue, back to 2.2 with it. When none is left it prints instead what `next`'s exit 3 does, then `next-exit=3`, and exits 0: go to step 3. Exit 4 is step 3's conflict. It records the coder's notes in the run's notes file.
3. **Review, fix and describe**, on `<n>`, the last `pr=` printed (by `land`, else `start`). With none, `next`
   printed why nothing landed: report it and end. `pr=local` means `solveFeature.publish` is `false`: there is no
   PR, `<n>` is `local` throughout, and the body is kept in `<repo>/.coding-crew/solve-feature/local-pr-<branch, / → _>.md`.
   The exit 3 of `next` (or `land`'s `next-exit=3`) merged the default branch in, gating and pushing that merge, and
   printed `review-base=`; keep it for both review rounds. Exit 4 of `next` or `land`: the merge conflicts, left in progress,
   and it printed `conflicts=<files>`. Then run a **fresh subagent** — none of this conversation, full tool access,
   the repo's working directory, on `coder-model=` as for each issue's coder — with exactly this prompt: `Finish the
   merge in progress in <repo>, resolving the conflicts in <files> so that both sides' intent is kept, reading
   <repo>/.coding-crew/solve-feature/spec.md and the commits being merged in (git log HEAD..MERGE_HEAD); commit with
   git commit --no-edit. This run is non-interactive; ask no questions`. Wait for it to finish, then run `bash "<skill-dir>/scripts/solve-feature.sh" sync <slug> <branch>`,
   once, keeping its `review-base=`: any non-zero exit of that run, 4 included, stops the run like any other.
   1. Run a **fresh subagent** — none of this conversation, full tool access, the repo's working directory —
     with exactly this prompt: `Use the crew-review skill on branch <branch> against the spec in <repo>/.coding-crew/solve-feature/spec.md; write the report to <repo>/.coding-crew/solve-feature/pr-<n>.review.json; the tests named in <red files> are the coders' new tests`,
     `<red files>` being the last `red-files=` value `next` or `land` printed; when that is empty, the `; the tests named…` clause is left out.
     When `review-base=` is non-empty, `<sha>` its value, the prompt reads `…on branch <branch> base <sha> against the spec…`
     and `; Findings cover <sha>..HEAD; judge spec, gaps and criteria on the code at HEAD: the commits before <sha> were already reviewed` is appended.
     When `<repo>/.coding-crew/solve-feature/pr-<n>.coder-notes.json` exists, `; the notes the change's author left for a person are in <repo>/.coding-crew/solve-feature/pr-<n>.coder-notes.json` is appended last:
     `fix` marks each note the review settles, so it no longer holds the draft.
     When `reviewer-model=` (as `next` or `land` last printed it) is non-empty, run it on the model in your own list that
     matches that name, as for `coder-model=`, naming that model in the call; when it is empty, on your own. Wait for it to finish.
   2. `bash "<skill-dir>/scripts/solve-feature.sh" reviewed <slug> <n> <branch>` — always: it discards what the
     reviewer changed in the tree, flags it for the PR, and prints `findings=<k>` last; `fixer-note=<path>` before it when a fixer note stands (an earlier round's, or a stopped run's). Only when it prints `findings=` greater than 0:
     run a **fresh subagent** — none of this conversation, full tool access, the repo's working
     directory — with exactly this prompt: `Judge each finding in <repo>/.coding-crew/solve-feature/pr-<n>.review.json
     against the code and the spec in <repo>/.coding-crew/solve-feature/spec.md before acting on it: its fix is a
     reviewer's suggestion, and a tool, API or platform fact a fix rests on is checked, never taken from memory. Run
     a project check by its key through run-checks.sh in the coding-crew-lib skill (coding-crew-lib/scripts/checks/run-checks.sh
     --project-root <repo>), never by retyping its command line, and every other project command through run.sh
     (coding-crew-lib/scripts/checks/run.sh --project-root <repo> -- "<command>"), as the solve-issue skill's Step 4
     says: they run where the project's dependencies are installed. Use the tdd skill to fix each real defect with the fix that adds no trigger, flag,
     permission, input or path the spec does not name. List each finding you did not fix, with why — it is wrong, or
     only changing a spec decision fixes it (quote the decision) — in <repo>/.coding-crew/solve-feature/pr-<n>.unfixed.json as a
     JSON list, [{"finding": <its 0-based index in the report's findings>, "why": "<why>"}], and leave that file absent if you fixed them all. Anything else a person must do or decide goes in
     <repo>/.coding-crew/solve-feature/pr-<n>.notes.md, left absent when there is none. This run is non-interactive; ask no questions`;
     when `reviewed` printed `fixer-note=<path>`, `; an earlier fixer's note for a person is in <path>: keep, edit or drop this note, writing what still applies to pr-<n>.notes.md` is inserted before `. This run is non-interactive`. Run it on `coder-model=` as for each issue's coder.
     Wait for it to finish.
   3. `bash "<skill-dir>/scripts/solve-feature.sh" fix <slug> <n> <branch>` — always, whatever the subagents
     reported. It records the fixer's note in place of the previous round's, gates the fixes with the checks, commits and pushes them,
     and records what needs a person.
     Report its last line, `FIX: findings=<k> needs-attention=<a> review-again=yes|no`. After the first review,
     `review-again=yes` means run 3.1–3.3 once more; after the second review, go on to 3.4 whatever it prints.
     A non-zero exit of `fix` stops the run like any other: do not start a subagent or fix the checks yourself.
   4. Run a **fresh subagent** — none of this conversation, the repo's working directory — with exactly
     this prompt: `Use the write-pr skill on PR #<n>; its intent is the spec in <repo>/.coding-crew/solve-feature/spec.md
     and its checks passed (<repo>/.coding-crew/solve-feature/pr-<n>.checks.log). Write it to
     <repo>/.coding-crew/solve-feature/pr-<n>.summary.md, leaving out its **Tested:** line: the script writes that line from the checks.
     Also write the same title and summary to <repo>/.coding-crew/solve-feature/pr-<n>.summary.json as
     {"title": "<the title>", "why": "<the Why text>", "changes": ["<one What changes bullet>", …], "risk": "<the Risk line>"}`; when `<n>` is `local`, the same prompt with `Use the
     write-pr skill on branch <branch>` in place of `Use the write-pr skill on PR #<n>`. Run it on `coder-model=` as for each issue's coder. Wait for it to finish.
   5. `bash "<skill-dir>/scripts/solve-feature.sh" describe <slug> <n>` — writes the PR's body (its `**Tested:**` line included) and title, marks the
     draft ready when nothing needs a person, and prints the run's outcome, `ready pr=<n>` or
     `needs-attention pr=<n>`. Report it. When `<n>` is `local` it writes the local body file instead (its first
     line the title) and prints `ready branch=<b>` or `needs-attention branch=<b>`: report it with that file's path,
     for the person to push the branch and open the PR from.

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
| `--review-since <sha>`                          | Scopes the review's findings to the commits since `<sha>` (a follow-up run's), while spec and gaps are judged on the whole code; used only when `<sha>` holds the default branch and is in the branch after `sync`'s merge, else the whole branch is reviewed. Not a commit: `start` stops |
| `solveFeature.models.coder` / `.reviewer`       | The coder and fixer / reviewer model name; `CREW_CODER_MODEL` / `CREW_REVIEWER_MODEL` override it, and `start` prints the one it resolved |
| `solveFeature.publish`                          | `false` keeps the run on this machine: no `git push` and no `gh pr` call, the body in the local file of step 3. Read from the user-level `~/.coding-crew/config.json` only, never the project's, so an Actions run always pushes |

`--spec <file> --issue <n>`, `CREW_PUBLISH`, `CREW_TRACKER` and `CREW_COMMANDS_FILE`, the settings of a host that embeds this skill, and the `result.json` fields such a host may rely on: coding-crew's guide, "Embedding solve-feature".
