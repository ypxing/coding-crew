# orca support — spike analysis

Investigating whether [orca](https://www.onorca.dev/docs/cli/overview) can serve as an
alternate backend for the herdr integration in `orchestrator/lib/dispatch.mjs`, so crew-afk
could run without herdr installed.

## What orca is

A desktop "agent development environment" (macOS/Windows/Linux) that wraps and orchestrates
existing coding-agent CLIs (Claude, Codex, Gemini, Cursor, GLM) as subprocesses in terminals —
it is not a new agent runtime. It ships a GUI plus a scriptable CLI for driving worktrees,
terminals, and agent sessions.

Agent behavior is configured via Settings → Agents (launch-arg overrides), not a per-platform
protocol file — it just reads a repo's existing `.claude/`/`.codex/` dirs and `CLAUDE.md`/
`AGENTS.md`. So orca would be a new **herdr-equivalent backend** behind `herdrExec`, not a 5th
entry in `PLATFORMS`/`registry.json`.

## Where the seam already is

All herdr calls are isolated behind `herdrExec` and the handful of functions exported from
`orchestrator/lib/dispatch.mjs` (`ensureHerdrWorkspace`, `ensureHerdrLogTab`,
`notifyTriggeringPane`, `renameHerdrTriggeringTab`, ...). No other file needs to know which
backend is active — consistent with this repo's control-flow ownership rule for
`orchestrator/`.

Since `agent prompt`/`pane run` give no reliable signal against an unattended pane, crew-afk
stopped asking herdr to host or report on anything load-bearing:
`ensureHerdrLogTab` only ever runs one trivial, robust command (`tail -f
orchestrator.log`) in its pane, and the sprint's own process runs wherever it was invoked,
never relaunched into a herdr-hosted pane. This shrinks what an alternate backend needs to
support considerably — no exit-code readback, no sentinel-file/timeout machinery to replicate.

## Command mapping

| herdr                              | orca                                | Notes |
| ----------------------------------- | ------------------------------------ | ----- |
| `workspace create` / `close`       | `worktree create` / `rm`             | mechanical |
| `tab create --cwd ... --no-focus`  | `terminal create --worktree ...`     | mechanical |
| `pane run <paneId> tail -f <file>` | `terminal create --command "tail -f <file>"` | mechanical — the only command either backend ever has to run reliably, since nothing reads its outcome back |
| `agent prompt <paneId> <msg>`      | **no documented equivalent**         | see below |

## Real gaps, not just renames

1. **No orca equivalent to `agent prompt`.** The only text-injection primitive orca documents
   is `terminal send --text --enter` — the same keystroke-simulation approach herdr's own
   `send-text`/`send-keys` fallback uses, which is exactly as unreliable against an unattended
   (`--no-focus`, never-attached) pane as `agent prompt` is.
   Switching backends would likely relocate this reliability problem, not fix it — and since
   `notifyTriggeringPane` is already advisory-only (the log tab/file is the real fallback),
   this gap matters less than it used to.

2. Orca does have a separate, more structured orchestration layer
   (`orchestration run-create` → `task-create` → `worker-start`, with `worker_done` messages,
   heartbeats, and `orca orchestration ask`/`check --wait` for blocking coordinator questions,
   plus `@all`/`@idle`/`@codex` group broadcast). This is architecturally closer to
   dispatch→verify→review→merge than herdr's pane model, but it's a message-bus design, not a
   subprocess-exit-code one — adopting it would be a bigger rewrite than a drop-in backend
   swap, and is out of scope for matching herdr's now-much-smaller current surface.

## Recommendation

Given the surface left to replicate is now just "open a terminal that tails a file" plus a
best-effort push, this is low-priority: worth a small spike (create one orca terminal by
hand, confirm `terminal create --command` runs to completion visibly) whenever someone
actually needs orca support, not before.
