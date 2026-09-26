# orca support

[orca](https://www.onorca.dev/docs/cli/overview) is a second, interchangeable backend for
the ambient pane-host integration in `orchestrator/lib/pane-host/` — the same narration
role herdr (https://herdr.dev) already played. The pane host is one setting, resolved by
`resolvePaneHost` (`lib/crew-config.mjs`), first match wins:

1. `--pane-host orca|herdr|auto|none`
2. `CREW_PANE_HOST=orca|herdr|auto|none`
3. the legacy `ORCA_ENV=1`, then `HERDR_ENV=1` (both set: orca, with a notice)
4. `afk.paneHost` in `~/.coding-crew/config.json` — per-machine, so the repo's config.json
   is rejected for it
5. none

`auto` picks orca when `ORCA_TERMINAL_HANDLE` is set, else herdr when `HERDR_PANE_ID` is,
else none. `run` prints `PANE-HOST: <host|none>` before any sprint output, which is what the
launcher skills read. Nothing else in the pipeline needs to know which
backend is active — `effects.paneHost` is the one seam, consistent with this repo's
control-flow ownership rule for `orchestrator/`.

## What orca is

A desktop "agent development environment" (macOS/Windows/Linux) that wraps and orchestrates
existing coding-agent CLIs (Claude, Codex, Gemini, Cursor, GLM) as subprocesses in terminals —
it is not a new agent runtime. It ships a GUI plus a scriptable CLI for driving worktrees,
terminals, and agent sessions, and can also run headless (`orca serve`).

## Why so little was needed

Every coder/reviewer/triage dispatch is headless — neither backend is ever asked to report
on anything load-bearing. A pane host is asked to open one tab/terminal that runs
`tail -f orchestrator.log`, and to push a best-effort outcome message into the pane that
triggered the run. orca additionally hosts each dispatch in a terminal of its own (see
[Worker terminals](#worker-terminals)), but only as a place to run it. That shrunk surface
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

## Worker terminals

With orca as the pane host, each coder/reviewer/triage dispatch runs in its own orca terminal,
titled `<slug> <agent>` and scoped to the main checkout, so every worker is a tab you can
watch. Without it, dispatch is the plain headless spawn, unchanged. herdr keeps the plain
spawn too: its per-worker panes (`dispatchViaHerdr`) were removed for driving an
interactive REPL and scraping it, and this design does neither.

The worker is the same headless argv (`claude -p … --output-format stream-json`, etc.).
orca never reports on it — `--command` is typed into a login shell that outlives the
command, so `terminal wait --for exit` never fires and no exit code comes back (checked
live). `orchestrator/lib/pane-host/worker-terminal.mjs` writes a `run.sh` that records the
child's pid and exit code under `<outFile>.term/`, and polls those:

| on disk                                  | result                                      |
| ---------------------------------------- | ------------------------------------------- |
| `rc` written                             | that exit code                              |
| past the dispatch timeout                | SIGKILL the pid, 124 (as the headless path) |
| pid gone, no `rc` after 5s               | 1 — the terminal was closed under it        |
| no `pid` within 30s                      | 127 — the shell never ran `run.sh`          |
| `terminal create` fails                  | the headless spawn instead                  |

stdout goes straight to a file that crew-afk tails, so traces, heartbeats and report
parsing are the headless path's. What the tab shows comes from a separate follower
(`follow-output.mjs`), so a display failure can't reach the worker. For claude and copilot
it shows stdout's JSON stream as `[TOOL]` lines, plus claude's assistant text. For pi and
codex it shows stderr as-is: their bash dispatchers put raw events on stdout, and their
`[TOOL]` lines and the CLI's own errors on stderr. Either way the tab is a read-only view
of the headless run, not the agent's interactive UI. The worker gets exactly crew-afk's env,
through a 0600 `env.sh` that `run.sh` deletes once sourced. It also unsets whatever the
terminal's shell set that crew-afk doesn't have, such as a `GH_TOKEN` from a shell profile.
The terminal's own geometry and `ORCA_TERMINAL_HANDLE`/`ORCA_TAB_ID`/`ORCA_WORKTREE_ID` are
left alone. The terminal is
closed when the dispatch ends; `<outFile>.term/` is removed on success and kept on failure.

orca opens terminals only in a repo it has registered, and a repo on an SSH host can
only be registered from the desktop app. Preflight checks the checkout with
`orca worktree show --worktree path:<mainRoot>` (`selector_not_found`, exit 1, when orca
doesn't know it) and stops the sprint, rather than letting every dispatch fall back to
headless.

The pid checks assume the terminal runs on crew-afk's own host — true when crew-afk is
launched from an orca terminal in that checkout, including over orca's SSH relay, where
both sit on the SSH host.

orca's own worker supervision (`orchestration worker-start`) is not used: it signals
completion by the agent sending `worker_done` itself, and it binds a provider, not a named
agent definition.

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
  through its Bash tool sends, and the message arrives as a prompt. So do interactive pi
  and codex panes, each launching a sprint through its crew-afk skill. pi reports
  `agentIdentity` only once its first prompt has fired orca's status extension
  (`~/.pi/agent/extensions/orca-agent-status.ts`), which a skill invocation already is.
  copilot pane detection is untested. All four skills stop polling on `PANE-HOST: orca`. If
  orca doesn't identify a pane, the push is skipped rather than typed in blind.
- orca must be chosen, not detected by default: orca injects `ORCA_WORKTREE_ID`/`ORCA_TAB_ID`/
  `ORCA_TERMINAL_HANDLE` into its terminals, which `auto` uses, but no opt-in of its own.
- `terminal send` into a live claude pane takes ~8s to return (it watches for turn start),
  so the orca push gets a 20s timeout. With 5s it exited 124 after the message had already
  been delivered. Per-issue milestone pushes (coder finished, merged, partial, blocked) are
  queued rather than awaited, so that delay never holds an issue's pipeline. The queue sends
  one at a time, in order, and is drained before the end-of-run push.
- `ORCA_TAB_ID` is read by nothing: every create is already scoped by `--worktree`, and the
  rename and push go by `ORCA_TERMINAL_HANDLE`.
- `--worktree path:<mainRoot>`, not `active`: `active` isn't documented as cwd-relative and
  may resolve to whatever worktree orca's GUI has focused. `--command` is typed into the
  terminal's shell rather than passed as argv, so the log path is shell-quoted.
- Orca's own orchestration layer (`orchestration run-create`/`task-create`/`worker-start`,
  worker supervision, gates) is not used; see [Worker terminals](#worker-terminals) for why.
  Worker tabs are plain terminals to orca, not supervised workers.
