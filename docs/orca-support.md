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
`orchestrator/lib/dispatch.mjs` (`ensureHerdrWorkspace`, `relaunchIntoDedicatedPane`,
`notifyTriggeringPane`, `renameHerdrTriggeringTab`, `relaunchEnvPairs`, ...). No other file
needs to know which backend is active — consistent with this repo's control-flow ownership
rule for `orchestrator/`.

## Command mapping

| herdr                          | orca                                    | Notes |
| ------------------------------ | ---------------------------------------- | ----- |
| `workspace create` / `close`   | `worktree create` / `rm`                 | mechanical |
| `tab create --env ... --no-focus` | `terminal create --worktree ...`      | mechanical |
| `pane run <paneId> <cmd>`      | `terminal create --command`              | mechanical; `terminal wait --for tui-idle` might replace the sentinel-file poll in `waitForRelaunchSentinel`/`DEFAULT_RELAUNCH_TIMEOUT_MS` — **must verify it reflects the command's actual exit code**, not just terminal idleness, before relying on it |
| `agent prompt <paneId> <msg>`  | **no documented equivalent**             | see below |

## Real gaps, not just renames

1. **No orca equivalent to `agent prompt`.** The only text-injection primitive orca documents
   is `terminal send --text --enter` — the same keystroke-simulation approach herdr's own
   `send-text`/`send-keys` fallback uses, and issue #4537 shows that fallback is exactly as
   unreliable against an unattended (`--no-focus`, never-attached) pane as `agent prompt` is.
   Switching backends would likely relocate this reliability problem, not fix it.

2. **Env injection into created terminals is unconfirmed.** `relaunchEnvPairs`
   (`dispatch.mjs:617`) depends on `HERDR_PANE_ID`/`HERDR_WORKSPACE_ID` being available to the
   new pane's process. Orca's docs don't show whether `terminal create` injects an equivalent
   env var pointing back at the pane/terminal that created it.

3. Orca does have a separate, more structured orchestration layer
   (`orchestration run-create` → `task-create` → `worker-start`, with `worker_done` messages,
   heartbeats, and `orca orchestration ask`/`check --wait` for blocking coordinator questions,
   plus `@all`/`@idle`/`@codex` group broadcast). This is architecturally closer to
   dispatch→verify→review→merge than herdr's pane model, but it's a message-bus design, not a
   subprocess-exit-code one — adopting it would be a bigger rewrite than a drop-in backend
   swap, and is out of scope for matching herdr's current surface 1:1.

## Recommendation

Treat as a spike before writing any backend-selection code:

- Create one orca terminal by hand and inspect its env for a pane/terminal-id equivalent.
- Confirm whether `terminal wait --for tui-idle` reports the launched command's real exit
  code or just UI idleness.
- Decide whether `terminal send --text --enter` is worth wiring up for `notifyTriggeringPane`
  given it shares the same reliability failure mode as herdr's fallback that #4537 is about —
  i.e. whether it's worth doing at all before that class of bug is fixed somewhere.
