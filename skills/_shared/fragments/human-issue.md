**A `ready-for-human` issue opens with a `## For a human` block**, placed right after `## What to build`. A person reads it cold, so write plain language that needs neither the PRD nor the codebase. It has exactly five `###` parts, in this order:

1. `### Why a person` — why no agent can do this (a permission, a credential, a judgement call, a failing `## Requires` command and its output).
2. `### What changes` — what is true today and what will be true after, in concrete names and values.
3. `### Steps` — numbered. Each step says what to do, then a `Check:` line (how to see it worked) and an `Undo:` line (how to reverse it). Write `n/a — <why>` when a step has no check or no undo. Put commands and file contents in fenced blocks.
4. `### If skipped or done wrong` — what breaks, in the reader's terms.
5. `### Done when` — the observable end state.

Write acceptance criteria unticked (`- [ ]`): the person ticks each one as they finish it, so a box ticked at publish says "done" before anything was done.

**Kind A — the whole task is a person's.** Drop `## Implements`, `## Interfaces` and the "Read this document before implementing" line; no agent will read this issue. End `### Steps` with a fixed last step, "Mark it done", that runs `node .coding-crew/tracker/cli.mjs mark-done <n>` from the repo root when the `cli.mjs` you located under Tracker Configuration is inside this repo or its main checkout, else `node ~/.coding-crew/tracker/cli.mjs mark-done <n>` (local tracker: the issue file path instead of `<n>`) — never the absolute path you located, which does not exist on the reader's machine — with `Check:` the command exits 0 and prints no `REFUSED` line, and `Undo:` follow "Reopen an issue" in the tracker doc `.coding-crew/tracker/docs/<kind>.md` — `~/.coding-crew/tracker/docs/<kind>.md` when the `mark-done` command above is the `~/.coding-crew` one — with `<kind>` the `tracker=` value `node .coding-crew/tracker/cli.mjs config` prints (the same path, `~/.coding-crew/…` when that is the one). Name neither the tracker nor its labels or files in the step.

**Kind B — agent work blocked on a person.** Keep the agent brief (`## What to build`, `## Implements`, acceptance criteria, …) below the block, and make the last step of `### Steps` relabel the issue `ready-for-agent`, so crew-afk picks it up.

Trimmed example (Kind A):

````markdown
Status: ready-for-human

## What to build

Make the `main` branch ruleset require green test checks before a pull request merges.

## For a human

### Why a person

Only a repository admin can edit rulesets, and the change is made on GitHub itself. An agent has no admin token and must not have one.

### What changes

Today the ruleset has no `required_status_checks` rule, so a PR can merge while its tests are red. After this change it has one, listing the four test jobs.

### Steps

1. Save the current ruleset. Check: the file is not empty. Undo: n/a — this step only reads.

   ```bash
   gh api repos/OWNER/REPO/rulesets/ID > ruleset.backup.json
   ```

2. Apply the edited ruleset. Check: the command prints JSON with no `message` error. Undo: send `ruleset.backup.json` back with the same command.

   ```bash
   gh api -X PUT repos/OWNER/REPO/rulesets/ID --input ruleset.json
   ```

3. Mark it done, once every acceptance criterion below is ticked. Check: the command exits 0 and prints no `REFUSED` line. Undo: follow "Reopen an issue" in `.coding-crew/tracker/docs/<kind>.md`, `<kind>` being the `tracker=` value `node .coding-crew/tracker/cli.mjs config` prints.

   ```bash
   node .coding-crew/tracker/cli.mjs mark-done 42
   ```

### If skipped or done wrong

If skipped, a PR can merge with red tests. If `ruleset.json` leaves out an existing rule, that rule is silently removed.

### Done when

Reading the ruleset back lists `required_status_checks`, and a PR with a failing check cannot be merged.

## Acceptance criteria

- [ ] The ruleset has a `required_status_checks` rule
````
