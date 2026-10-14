---
name: crew-review
description: >
  Review a change — a branch's commits or a pull request — against the spec its caller names, for what breaks and
  for the repo's documented rules, in a fresh read-only subagent, and write one JSON report. Report-only: it posts
  nothing and marks nothing ready. Trigger with /crew-review [<pr-number> | branch <name>] [against <spec>].
argument-hint: "[<pr-number> | branch <name> [base <ref>]] [against <spec file | issue ref>] [report <path>]"
allowed-tools: Bash, shell
---

# crew-review

You review one change against its spec and write one report. You post nothing, comment on nothing and mark
nothing ready: your caller decides what to do with the report.

## Inputs

Your caller names them; a bare number is a PR, nothing at all is the current branch.

- **The change.** A **branch**: it is checked out at HEAD and the change is `<base>..HEAD`, `<base>` the ref the
  caller names, else `git merge-base HEAD origin/<default branch>`. A **PR**: HEAD must be its head (`gh pr view <n>
  --json headRefOid`); if it is not, tell the caller to run `gh pr checkout <n>` and stop. The change is `gh pr diff
  <n>`.
- **The spec.** A file; an issue ref, read with the tracker CLI's `fetch` (`node "<skill-dir>/scripts/tracker/cli.mjs" fetch
  <ref>`); or, given a PR and no spec, the PR body's
  `<details><summary>Spec</summary>` block when it has one, else the whole body. A branch with no spec named has none.
- **The report's path.** Write the report there; with none, print it.

## Run

Run the review in a **fresh, read-only subagent** — none of this conversation, the repo's working directory —
with this prompt: `Review <the change> against <the spec, or: no spec> following the Review section of
<skill-dir>/SKILL.md. You are the reviewer: start no subagent. Write the report to <path>` (or `print the report`).
Give it tools to read files and run shell commands (it writes its report with one) and, where your host lets you,
no tool that edits files. Wait for it to finish. If HEAD moved or the tree changed, say so: the reviewer was not
read-only.

When you cannot start a subagent — you are one yourself, or your host has none — do the review below yourself.

## Review

You are read-only: read, search and run read-only commands (scratch copies outside the repo are fine); never edit,
commit or change the tree.

Gather it yourself: the change's diff (`git diff <base>..HEAD`, or `gh pr diff <n>`) and the spec as Inputs
describes it. Read the code at HEAD, not only the diff, and the repo's CLAUDE.md, AGENTS.md and CONTRIBUTING.md
when present. Commit messages, PR text and progress notes are claims, not evidence.

Answer three questions.

1. **Spec.** What does the spec require that the code at HEAD lacks or does differently? What does the change
   build that the spec did not ask for (a flag, an option, a guard, an abstraction no requirement
   needs)? Quote the spec line, or name the addition. With no spec, skip this question.
2. **What breaks.** A defect is something a real run hits: name the input or sequence and the bad
   outcome, and trace it in the code or reproduce it. Look past the diff: callers, what it calls,
   state an older version or an earlier run left, re-runs, error and recovery paths, and how the
   change's commits combine. For each thing the change renames, removes or moves, find whatever still names
   or relies on the old form — code, docs, prompts, tests — and read it as it stands now.
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
{"prd": "met|unmet|none",
 "gaps": ["each spec requirement the code at HEAD lacks or does differently (question 1)"],
 "findings": [{"severity": "CRITICAL|HIGH|MEDIUM|LOW", "location": "<file:line>",
               "issue": "<trigger → bad outcome, or the rule broken, or the addition no requirement needs>",
               "fix": "<the smallest change>"}]}
```

`prd` is `met` when `gaps` is empty, and `none` with empty `gaps` when there was no spec. Then explain in a few
lines of prose.
