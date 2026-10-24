---
name: crew-afk
description: >
  Starts one feature's /solve-feature run unattended in that feature's own worktree and returns at
  once, launched with your own agent CLI's command: locally as a detached headless session capped at
  1 hour, or as an interactive session in an orca terminal or a herdr pane. Reports how each run ended. Use when a feature's issues are ready
  and it should be built without anyone watching. Trigger with /crew-afk <feature> [--to local|orca|herdr] [--branch <name>],
  or /crew-afk status [<feature>].
argument-hint: "<feature> [--to local|orca|herdr] [--branch <name>] | status [<feature>]"
allowed-tools: Bash
---

# crew-afk

You start runs and say how they ended. **You do not run /solve-feature yourself, and you implement,
review, fix or close nothing**: each run is its own top-level session in its own worktree.

<!-- fragment:missing-library -->
**Shared scripts.** The scripts this skill runs live in the `coding-crew-lib` skill, installed beside it at
`<skill-dir>/../coding-crew-lib` (`<skill-dir>` being the directory you read this file from). Before the first
command that runs one, check that directory exists. If it does not, stop and tell the user to install it at this
skill's scope, `npx skills add ypxing/coding-crew -s coding-crew-lib` (adding `-g` when this skill is installed at
user level), or to re-run coding-crew's `install.sh`.
<!-- /fragment:missing-library -->

<!-- fragment:tracker-configuration -->
## Tracker Configuration

Every tracker op runs through the tracker CLI, `TRACKER=<skill-dir>/../coding-crew-lib/scripts/tracker/cli.mjs` (`<skill-dir>` being the
directory you read this file from), as `node "$TRACKER" <op> …`; nothing else reads or writes the tracker. Before the
first op run `node "$TRACKER" config` (prints `tracker=<kind>` and `configured=yes|no`). On `configured=no` on an
interactive run, invoke the `configure-tracker` skill, then continue; on a non-interactive run (a headless/`-p`
invocation or a subagent) never ask: proceed as `local`. The tracker's refs, statuses and labels are in
`<skill-dir>/../coding-crew-lib/scripts/tracker/docs/<kind>.md`.

Exit codes, every op: 0 ok; 3 not found; on 1 (the op failed) or 2 (a usage error or an invalid ref), report the
stderr verbatim, fix its cause (an input, auth, the network) and re-run the op, never performing it with the tracker's
own tool. `publish-issues` adds 4 and 5, which the skill that publishes handles.
<!-- /fragment:tracker-configuration -->

## Start a run

1. **Resolve the feature.** List what exists:

   ```bash
   node "$TRACKER" features   # <slug>, open|closed, count of issues that can start now — one line per feature
   ```

   Match the user's word against those slugs: exactly, then as a likely typo, then by issue content
   (`d="$(mktemp -d)" && node "$TRACKER" known --feature-slug <slug> --out "$d" && echo "$d"` for a
   candidate writes its issues as files in the directory it prints). One match: use it and
   say what you inferred. Several: ask which. None: start nothing, and point the user at
   `crew-grill`, `crew-brainstorm` or `to-issues` to plan the feature first. Never guess: a wrong
   slug spends a run on the wrong work. One call starts one feature; for several, run this once each.
2. **Dispatch**, with `--to` only when the user named a destination (default `local`), and `--branch`
   only when the user named a branch (default: solve-feature's, named after the slug). After `--`, pass
   the command that starts a session of your own agent CLI in the run's worktree, with permission
   prompts off, that runs the solve-feature skill on `<slug>` (plus ` --branch <name>` when given): by
   the prompt `Use the solve-feature skill on <slug>`, or by your CLI's own form for invoking a skill by
   name. Write it as separate arguments; the script runs it as given, in the worktree. What that command
   must be depends on the destination:

   - `local`: a non-interactive run that needs no terminal and exits when the session ends. If your
     CLI can print the session's result with its cost as a JSON line last, ask it to: `status` and
     `wait` read the cost from that line.
   - `orca` or `herdr`: an interactive session, which a person watches in that terminal.

   ```bash
   bash "<skill-dir>/scripts/crew-afk.sh" dispatch <slug> [--to local|orca|herdr] [--branch <name>] -- <command…>
   ```

   Relay what it prints: the run goes on without you, so do not wait for it in the foreground, read its
   log or check on it. On a non-zero exit, relay the message as printed. A dispatch on a slug whose run is
   still going stops, whatever destination either run uses: its message names the run's pid, pane or terminal.
3. **Watch the end**, after a dispatch that exited 0, if you can run a command in the background and be told when
   it exits: run it that way and relay its lines when it does. It prints what `status` prints, once the run has
   ended. Otherwise skip this step: `/crew-afk status` works as today.

   ```bash
   bash "<skill-dir>/scripts/crew-afk.sh" wait <slug>
   ```

## Status

```bash
bash "<skill-dir>/scripts/crew-afk.sh" status [<slug>]
```

Relay its lines as printed.
