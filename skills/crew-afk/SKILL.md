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

<!-- fragment:tracker-configuration -->
## Tracker Configuration

Every tracker operation in this skill is an op of the tracker CLI — nothing else reads or writes
the tracker. Before the first one, check for Node:

```bash
node --version
```

If that fails, stop and tell the user: "the tracker CLI needs Node — install Node, then re-run this
skill." The CLI is `<skill-dir>/scripts/tracker/cli.mjs`, `<skill-dir>` being the directory you read
this file from. Wherever this skill runs an op as `node "$TRACKER" <op> …`, run it with that path:

```bash
node "<skill-dir>/scripts/tracker/cli.mjs" <op> …
```

Before the first op, ask the CLI which tracker it talks to:

```bash
node "$TRACKER" config   # prints tracker=<kind> and configured=yes|no
```

On `configured=no`, no tracker was ever chosen for this repo. On an interactive run, invoke the
`configure-tracker` skill now to choose one, then continue. On a non-interactive run
(a headless/`-p` invocation or a subagent) never ask: proceed as `local`, which
is what the CLI already uses. How the tracker works — its refs, statuses and labels — is in
`<skill-dir>/scripts/tracker/docs/<kind>.md`.

Exit codes, every op: 0 ok; 1 the op failed — stderr carries the tracker's own error, verbatim;
2 a usage error or an invalid ref; 3 not found (`publish-issues` adds 4 and 5, described where it
runs). On 1 or 2, report the stderr to the user and
fix its cause (an input, auth, the network), then re-run the op —
never perform the operation with the tracker's own tool instead.
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
   log or check on it. On a non-zero exit, relay the message as printed. Only a local run is refused while it
   is still going: a second dispatch to orca or herdr starts a second agent beside the first.
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
