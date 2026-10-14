---
name: crew-afk
description: >
  Starts one feature's /solve-feature run unattended in that feature's own worktree and returns at
  once: locally as a detached headless agent capped at $10 and 1 hour, or as an interactive agent in
  an orca terminal or a herdr pane. Reports how each run ended. Use when a feature's issues are ready
  and it should be built without anyone watching. Trigger with /crew-afk <feature> [--to local|orca|herdr],
  or /crew-afk status [<feature>].
argument-hint: "<feature> [--to local|orca|herdr] | status [<feature>]"
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
2. **Name your own platform** as `--agent`: `claude` (Claude Code), `copilot` (GitHub Copilot CLI),
   `codex` (Codex CLI) or `pi`. It is the CLI the run starts, so it must be the one you are.
3. **Dispatch**, with `--to` only when the user named a destination (default `local`):

   ```bash
   bash "<skill-dir>/scripts/crew-afk.sh" dispatch <slug> --agent <platform> [--to local|orca|herdr]
   ```

   It prints `worktree=`; a local run adds `log=` and `pid=`, and claude adds `session=`. Relay them
   and stop: the run goes on without you, so do not wait for it, read its log or check on it. Exit 1
   (a run for the slug still going, a missing `orca`/`herdr` CLI) or 2 (a bad argument): relay the
   message as printed.

## Status

```bash
bash "<skill-dir>/scripts/crew-afk.sh" status [<slug>]
```

Relay its lines as printed: one per feature run, its outcome (`ready pr=<n>`, `needs-attention pr=<n>`
or `stopped: …`), `running`, or why there is none, with how to resume or continue.
