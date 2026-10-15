---
name: crew-afk
description: >
  Starts one feature's /solve-feature run unattended in that feature's own worktree and returns at
  once: locally as a detached headless agent capped at 1 hour, or as an interactive agent in
  an orca terminal or a herdr pane. Reports how each run ended. Use when a feature's issues are ready
  and it should be built without anyone watching. Trigger with /crew-afk <feature> [--to local|orca|herdr] [--branch <name>],
  or /crew-afk status [<feature>].
argument-hint: "<feature> [--to local|orca|herdr] [--branch <name>] | status [<feature>]"
allowed-tools: Bash
---

# crew-afk

You start runs and say how they ended. **You do not run /solve-feature yourself, and you implement,
review, fix or close nothing**: each run is its own top-level session in its own worktree.

{{FRAGMENT:tracker-configuration}}

## Start a run

1. **Resolve the feature.** List what exists:

   ```bash
   node "$TRACKER" features   # <slug>, open|closed, count of issues that can start now — one line per feature
   ```

   Match the user's word against those slugs: exactly, then as a likely typo, then by issue content
   (`node "$TRACKER" known --feature-slug <slug> --out <dir>` for a candidate). One match: use it and
   say what you inferred. Several: ask which. None: start nothing, and point the user at
   `crew-grill`, `crew-brainstorm` or `to-issues` to plan the feature first. Never guess: a wrong
   slug spends a run on the wrong work. One call starts one feature; for several, run this once each.
2. **Dispatch**, with `--to` only when the user named a destination (default `local`), and `--branch`
   only when the user named a branch (default: solve-feature's, named after the slug). The run uses
   the same agent CLI you are:

   ```bash
   bash "<skill-dir>/scripts/crew-afk.sh" dispatch <slug> [--to local|orca|herdr] [--branch <name>]
   ```

   Relay what it prints and stop: the run goes on without you, so do not wait for it, read its log or
   check on it. On a non-zero exit, relay the message as printed. Only a local run is refused while it
   is still going: a second dispatch to orca or herdr starts a second agent beside the first.

## Status

```bash
bash "<skill-dir>/scripts/crew-afk.sh" status [<slug>]
```

Relay its lines as printed.
