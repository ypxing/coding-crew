# orca support

[orca](https://www.onorca.dev/docs/cli/overview) is a second, interchangeable backend for
the ambient pane-host integration in `orchestrator/lib/pane-host/` — the same narration
role herdr (https://herdr.dev) already played. `ORCA_ENV=1` selects it, `HERDR_ENV=1` selects
herdr, neither selects neither (today's default, unchanged); the two are mutually exclusive
(`main.mjs` fails fast if both are set). Nothing else in the pipeline needs to know which
backend is active — `effects.paneHost` is the one seam, consistent with this repo's
control-flow ownership rule for `orchestrator/`.

## What orca is

A desktop "agent development environment" (macOS/Windows/Linux) that wraps and orchestrates
existing coding-agent CLIs (Claude, Codex, Gemini, Cursor, GLM) as subprocesses in terminals —
it is not a new agent runtime. It ships a GUI plus a scriptable CLI for driving worktrees,
terminals, and agent sessions, and can also run headless (`orca serve`).

## Why so little was needed

Every coder/reviewer/triage dispatch is a direct, headless `child_process` spawn — neither
backend is ever asked to host or report on anything load-bearing. The only things a pane
host is ever asked to do are: open one tab/terminal that runs `tail -f orchestrator.log`, and
push a best-effort outcome message into the pane that triggered the run. That shrunk surface
is why orca support didn't need `worktree create`, `repo add`, or any env injection scheme —
confirmed with a live spike against a running orca runtime (not just the CLI reference doc):

- **No new worktree needed.** `orca worktree current`, run from an existing git checkout's
  root, resolves straight to that checkout's existing Orca-managed worktree — no `repo add`/
  `worktree create` required. Orca's own CLI help says the same thing directly: *"Use
  [`terminal create`], not `worktree create`, for a fresh agent in the current checkout."*
- **No separate workspace object.** Unlike herdr (workspace container → tabs within it),
  orca's model is flat: a worktree already is the container, a terminal is the pane. Every
  `terminal create --worktree path:<mainRoot>` naturally lands in the right place with nothing extra
  to create, reuse, or close.
- **Ambient env vars exist.** Dumping `env` inside a created terminal showed
  `ORCA_WORKTREE_ID`, `ORCA_TAB_ID`, `ORCA_TERMINAL_HANDLE` — direct equivalents of herdr's
  `HERDR_WORKSPACE_ID`/`HERDR_TAB_ID`/`HERDR_PANE_ID`, letting a run launched from inside an
  orca terminal detect and rename/notify it.
- **`terminal rename` exists**, contrary to an earlier doc-only read of the CLI reference.
- **`terminal send` self-reports delivery confidence.** Sending into a plain shell terminal
  returned `accepted: true` but `prompt.observation: "unsupported"`, with an explicit warning
  that delivery couldn't be confirmed — orca never claims a confirmation it doesn't have, so
  there's no need for a herdr-style `--wait --until working` workaround (added in commit
  `31b0110` specifically because herdr's `agent prompt` used to report false success against
  an unattended pane — `herdrdev/herdr#4537`).

## Command mapping (as implemented)

| operation                         | herdr                                                        | orca                                                                        |
| ---------------------------------- | ------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| ensure workspace + log tab         | `workspace create --cwd <mainRoot> --label <slug> --no-focus`, then `tab create --workspace <id> --cwd <mainRoot> --label <slug>-log --no-focus` + `pane run <pane> tail -f <log>` | `terminal create --worktree path:<mainRoot> --title <slug>-log --command "tail -f '<log>'" --json` (one call) |
| close log tab                      | `tab close <tabId>`                                          | `terminal close --terminal <handle> --json`                                |
| close workspace                    | `workspace close <id>` (no-op if reused)                     | no-op always — no workspace object exists                                  |
| rename triggering tab              | `tab rename <tabId> <slug>`                                  | `terminal rename --terminal <handle> --title <slug> --json`                |
| notify triggering pane             | `agent prompt <paneId> <msg> --wait --until working --timeout-ms 2000` | `terminal send --terminal <handle> --text <msg> --enter --json`  |
| reuse signal (ambient env)         | `HERDR_WORKSPACE_ID` / `HERDR_TAB_ID` / `HERDR_PANE_ID`       | `ORCA_WORKTREE_ID` (implicit — every create already lands there) / `ORCA_TAB_ID` / `ORCA_TERMINAL_HANDLE` |
| preflight readiness check          | `herdr status` (text: `status: running`)                     | `orca status --json` → `result.runtime.reachable`                          |

## Known limitations

- `terminal send`'s delivery confidence is provider-dependent: a plain shell terminal (what
  the log tab runs) reports `observation: "unsupported"`; a live claude pane reports
  `provider: "claude"`, `observation: "supported"`, but can still warn that no turn start was
  seen even when the prompt did land. `notifyTriggeringPane`'s orca path treats
  `accepted: true` as success either way, matching the advisory nature this push has always
  had under herdr too.
- `terminal send` types into any terminal, agent or plain shell alike (herdr's `agent prompt`
  only ever reaches an agent), and in a shell the message plus Enter runs as a command
  (`syntax error near unexpected token`). So the push first runs `terminal show` and only
  sends if it reports `agentIdentity`. That field is set for a claude pane, stays set while
  the agent is mid-tool-call, and is absent for a plain shell. No identity, or a failed
  `show`, means no send.
- Verified live in real orca panes: a shell with a foreground run and a shell with stdin
  redirected (`< /dev/null`) both skip, with nothing typed. A Claude session running it
  through its Bash tool sends, and the message arrives as a prompt. Detection of pi, codex
  and copilot panes is untested (those CLIs weren't available). If orca doesn't identify
  one, the push is skipped rather than typed in blind — which is why the pi/codex/copilot
  skills keep polling under `ORCA_ENV=1` instead of waiting for it.
- `ORCA_ENV=1` must be set by hand: orca injects `ORCA_WORKTREE_ID`/`ORCA_TAB_ID`/
  `ORCA_TERMINAL_HANDLE` into its terminals, but not `ORCA_ENV` itself.
- `terminal send` into a live claude pane takes ~8s to return (it watches for turn start),
  so the orca push gets a 20s timeout. With 5s it exited 124 after the message had already
  been delivered.
- `--worktree path:<mainRoot>`, not `active`: `active` isn't documented as cwd-relative and
  may resolve to whatever worktree orca's GUI has focused. `--command` is typed into the
  terminal's shell rather than passed as argv, so the log path is shell-quoted.
- Orca's own richer orchestration layer (`orchestration run-create`/`task-create`/
  `worker-start`, worker supervision, gates) is untouched by this integration — it's a
  message-bus design, architecturally closer to dispatch→verify→review→merge than herdr's
  pane model, but adopting it would be a bigger rewrite than matching herdr's now-much-smaller
  surface. Out of scope unless crew-afk's own dispatch model changes.
