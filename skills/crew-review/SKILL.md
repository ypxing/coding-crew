---
name: crew-review
description: >
  Reviews a change — a branch's commits or a pull request — against the spec its caller names, for what breaks
  and for the repo's documented rules, in a fresh subagent that can run what it reviews, and writes one JSON report. Report-only:
  it posts nothing and marks nothing ready. Use when a branch or PR needs a review against its spec before it
  is merged or marked ready. Trigger with /crew-review [<pr-number> | branch <name>] [against <spec>].
argument-hint: "[<pr-number> | branch <name> [base <ref>]] [against <spec file | issue ref>] [report <path>]"
allowed-tools: Bash shell
---

# crew-review

You review one change against its spec and write one report. You post nothing, comment on nothing and mark
nothing ready: your caller decides what to do with the report.

## Inputs

Your caller names them; a bare number is a PR, nothing at all is the current branch.

- **The change.** A **branch**: it must be checked out at HEAD (`git branch --show-current`); if it is not, tell
  the caller to check it out and stop. The change is `<base>..HEAD`, `<base>` the ref the
  caller names, else `git merge-base HEAD origin/<default branch>`. A **PR**: HEAD must be its head (`gh pr view <n>
  --json headRefOid`); if it is not, tell the caller to run `gh pr checkout <n>` and stop. The change is `gh pr diff
  <n>`.
- **The spec.** A file; an issue ref, read with the tracker CLI's `fetch` (`node "<skill-dir>/scripts/tracker/cli.mjs" fetch
  <ref>`, `<skill-dir>` being the directory you read this file from); or, given a PR and no spec, the PR body's
  `<details><summary>Spec</summary>` block when it has one, else the whole body. A branch with no spec named has none.
- **The report's path.** Write the report there; with none, print it.

## Run

Run the review in a **fresh subagent** — none of this conversation, the repo's working directory — with this
prompt: `Review <the change> against <the spec, or: no spec> following the Review section of
<skill-dir>/SKILL.md. You are the reviewer: answer its three questions yourself. Write the report to <path>`
(or `print the report`). Give it tools to read files, run any shell command and write scratch files outside the repo (it writes its
report with one). On Claude Code that is a general-purpose agent: Explore and Plan cannot write. Wait for it to finish.
If HEAD moved or the tree changed, say so: the reviewer did not leave the repo as it found it.

When you cannot start a subagent — you are one yourself, or your host has none — do the review below yourself.

## Review

Leave the repo as you found it: never edit, commit or change its tree. Run what helps — the tests, the scripts under
review, experiments — in a scratch copy outside the repo when they would write to it. Start helper subagents when
they help, each with a brief naming what to run or check and what to return (the command and its output, or the
trace). A helper gets the tools you have and none of your conclusions; you judge what it returns and write every
finding yourself.

Gather it yourself: the change's diff (`git diff <base>..HEAD`, or `gh pr diff <n>`) and the spec as Inputs
describes it. Read the code at HEAD, not only the diff, and the repo's CLAUDE.md, AGENTS.md and CONTRIBUTING.md
when present. Commit messages, PR text and progress notes are claims, not evidence.

Answer three questions.

1. **Spec.** What does the spec require that the code at HEAD lacks or does differently? What does the change
   build that the spec did not ask for (a flag, an option, a guard, an abstraction no requirement
   needs)? Quote the spec line, or name the addition. With no spec, skip this question.
2. **What breaks.** A defect is something a real run hits: name the input or sequence and the bad
   outcome. Reproduce it where that is cheap, else trace it in the code. Look past the diff: callers, what it calls,
   state an older version or an earlier run left, re-runs, error and recovery paths, and how the
   change's commits combine. For each thing the change renames, removes or moves, find whatever still names
   or relies on the old form — code, docs, prompts, tests — and read it as it stands now. A spec decision can be
   wrong: when following it causes a defect, report the defect and quote the decision. For each new or changed
   test, check it fails when the behaviour it covers breaks; one that cannot is a finding naming the test.
3. **Standards.** Where does the diff break a rule the repo documents? Name the file and the rule.
   Only a documented rule counts; tooling-enforced rules, naming and taste do not.

Do not report input the project's own components never produce, a guard for a case no path
reaches, or a preference. Suggest the smallest fix; where removing code fixes it, say that rather
than adding a guard. One finding per defect, listing every place it occurs. No findings is a valid
answer.

Severity: CRITICAL loses data, leaks a secret or breaks the main path; HIGH is wrong behaviour a
user hits; MEDIUM is a broken error or recovery path, or a broken documented rule; LOW is a wrong
doc or message.

As your last action, write the report as JSON to the path you were given, or print it when you were given none:

```json
{"spec": "met|unmet|none",
 "gaps": ["each spec requirement the code at HEAD lacks or does differently (question 1)"],
 "findings": [{"severity": "CRITICAL|HIGH|MEDIUM|LOW", "location": "<file:line>",
               "issue": "<trigger → bad outcome, or the rule broken, or the addition no requirement needs>",
               "fix": "<the smallest change>"}]}
```

`spec` is `met` when `gaps` is empty, and `none` with empty `gaps` when there was no spec. Then explain in a few
lines of prose.
