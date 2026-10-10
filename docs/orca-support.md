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
else none. `run` prints `PANE-HOST: <host|none>` before any sprint output, for a human or
script that wants the resolved host; the launcher skills no longer read it. Nothing else in the
pipeline needs to know which backend is active — `effects.paneHost` is the one seam, consistent
with this repo's control-flow ownership rule for `orchestrator/`.

## What orca is

A desktop "agent development environment" (macOS/Windows/Linux) that wraps and orchestrates
existing coding-agent CLIs (Claude, Codex, Gemini, Cursor, GLM) as subprocesses in terminals —
it is not a new agent runtime. It ships a GUI plus a scriptable CLI for driving worktrees,
terminals, and agent sessions, and can also run headless (`orca serve`).

## Why so little was needed

Every coder/reviewer/triage dispatch is headless — neither backend is ever asked to report
on anything load-bearing. A pane host is asked to open one tab/terminal that runs
`tail -f orchestrator.log`, to open (or reuse) one interactive [watch agent](#the-watch-agent)
for the slug, and to push best-effort milestone and outcome messages into that agent. orca additionally hosts each dispatch in a terminal of its own (see
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
| ensure workspace + log tab         | `worktree open --path <_feature> --label <slug> --no-focus` (the sprint's feature worktree; `workspace create --cwd <mainRoot> …` with none), then `tab create --workspace <id> --cwd <mainRoot> --label <slug>-log --no-focus` + `pane run <pane> tail -f <log>` | `terminal create --worktree path:<mainRoot> --title <slug>-log --command "tail -f '<log>'" --json` (one call) |
| close log tab                      | `tab close <tabId>`                                          | `terminal close --terminal <handle> --json`                                |
| close workspace                    | `workspace close <id>` (no-op if reused)                     | no-op always — no workspace object exists                                  |
| rename triggering tab              | `tab rename <tabId> <slug>`                                  | `terminal rename --terminal <handle> --title <slug> --json`                |
| open watch agent                   | inside herdr: `tab create --workspace $HERDR_WORKSPACE_ID --cwd <mainRoot> --label <slug>-watch --no-focus`; outside: `workspace create --cwd <mainRoot> --label <slug>-watch --no-focus`; then `pane run <pane> "bash '<launch.sh>'"` | `terminal create --worktree path:<mainRoot> --title <slug>-watch --command "bash '<launch.sh>'" --json` |
| watch agent still live             | `pane list` has the pane with an `agent_status` other than `unknown` | `terminal show --terminal <handle> --json` has `agentIdentity`             |
| notify watch agent                 | `agent prompt <paneId> <msg> --wait --until working --timeout-ms 2000` | `terminal send --terminal <handle> --text <msg> --enter --json`  |
| open follow-up worker              | inside herdr: `tab create --workspace $HERDR_WORKSPACE_ID --cwd <_followup> --label <slug>-followup --no-focus`; outside: `workspace create --cwd <_followup> …`; then `pane run <pane> "bash '<launch.sh>'"` and `agent prompt <pane> <brief + task> --wait --until working` | `orchestration run-create --objective … --from <watch handle>`, `terminal create --worktree path:<_followup> --title <slug>-followup --command "bash '<launch.sh>'"`, then `orchestration worker-start --run <id> --worktree path:<_followup> --terminal <handle> --spec <brief + task>` |
| await follow-up response           | `agent wait <pane> --until done --until idle --until blocked`, then `agent read <pane> --source recent-unwrapped`: the last `QUESTION: …` / `DONE: …` line | poll `orchestration inbox`: the `worker_done` to `run:<id>`, else the latest unanswered `type: question` |
| reply to a follow-up question      | `agent prompt <pane> <answer> --wait --until working`        | `orchestration reply --id <msg> --body <answer> --run <id> --from <watch handle>` |
| reuse signal (ambient env)         | `HERDR_WORKSPACE_ID` / `HERDR_TAB_ID` / `HERDR_PANE_ID`       | `ORCA_WORKTREE_ID` (implicit — every create already lands there) / `ORCA_TAB_ID` / `ORCA_TERMINAL_HANDLE` |
| preflight readiness check          | `herdr status` (text: `status: running`)                     | `orca status --json` → `result.runtime.reachable`                          |

## The watch agent

Under orca or herdr, every sprint opens (or reuses) one long-lived interactive agent for its
slug, in the **main checkout** (`crew/<slug>/_feature` is removed on every ending). It is the
sprint's own `--platform` CLI in interactive mode on the coder's resolved model, briefed by
`orchestrator/roles/watcher.md` as its initial prompt (each adapter's `interactive()`; the
read-only `ROLE_POLICY.watcher` flags apply). It is for the human: every milestone push
and the final push go to it, and it answers questions from the trace log, the summary file and
the tracker. It never edits, merges, closes or dispatches.

- **Handle.** `.scratch/<slug>/watch.json` holds `{host, handle}` (an orca terminal handle, a
  herdr pane id). A run reuses it while the host still reports a live agent there (table above);
  a dead or missing one is replaced and the file rewritten. The title `<slug>-watch` is only a
  display name — an agent rewrites its own terminal title, so a lookup by title cannot work.
- **Env.** An agent a host starts gets the host's shell env, not crew-afk's (a live probe failed
  with "There's an issue with the selected model" until the launch carried
  `CLAUDE_CODE_USE_BEDROCK=1`). So the host is given `bash .scratch/<slug>/watch/launch.sh`,
  which sources the 0600 `env.sh` [worker terminals](#worker-terminals) use (`envScript`, deleted
  once sourced), `cd`s to the checkout and `exec`s the argv. The briefing is on the argv rather
  than sent as a first push, because orca reports a pi pane's `agentIdentity` only after its
  first prompt has run.
- **Never closed.** No ending closes it, a signal and a thrown error included: orca's handle is
  never tracked, so the terminal sweep skips it, and herdr's `<slug>-watch` workspace (outside
  herdr) is not the sprint workspace `closeWorkspace` closes.
- **Pushes are advisory.** No pushes ever go to `ORCA_TERMINAL_HANDLE` or `HERDR_PANE_ID`. A
  create that fails, or a platform CLI missing from `PATH`, logs `WARN`; each later push then logs
  `MILESTONE-PUSH-SKIPPED` (once at warn, then debug) and the run's exit code is what it would be
  with no host. A setup failure before the log tab has no watch agent. The final push names
  `.scratch/<slug>/traces/summary-<runId>.md` (everything the run printed to stdout, `:` in the run
  id replaced by `-`), or carries the failure's first line when the run never reached it.
- **herdr.** Pushes use `agent prompt --wait --until working --timeout 2000`; herdrdev/herdr#4537
  is still open upstream and a long-running agent was not reproduced, so a push stays advisory:
  the log tab, the summary file and the exit code carry the same information.
- **None.** `--dry-run`, `CREW_PANE_HOST=none` or no host open no watch agent and write no
  `watch.json`.

## Follow-ups

`crew-afk followup start <slug> "<task>" --platform <p>` (the watch agent runs it; `watcher.md`) opens a
**follow-up worker**: the sprint's platform CLI, interactive, in `<worktreeRoot>/crew/<slug>/_followup`
on the feature branch, briefed by `orchestrator/roles/followup.md` (`ROLE_POLICY.followup`: may edit,
no sub-agents, no default effort). It runs `/crew-address-findings`, `/address-pr-comments` or the task
it is given, commits, and answers over the host's own agent channel. `followup wait <id>` blocks for
the answer and prints one line, `DONE: …` or `QUESTION: …`; `followup reply <id> "<answer>"` answers a
question. With no pane host every subcommand exits 1.

- **Worktree.** Made with git (`ensureWorktree`'s `checkout` mode) and, under orca, adopted for display
  (`orca worktree set`). `start` refuses, naming why and creating nothing, while `lease.sh owner --slug`
  reports a holder (`tracker: github`), a live run's `.scratch/<slug>/.crew-afk.lock` names a running
  pid, or the slug's follow-up is still open. A later `crew-afk run` takes the branch back through
  `releaseBranch`: a clean `_followup` is removed, a dirty one is refused with "commit or discard
  them". `cleanup-worktrees.sh` does not touch it (it sweeps only `crew/<slug>/*` branches).
- **Record.** `.scratch/<slug>/followup.json` holds the id, host, run/terminal or pane handle, the
  pending question and the result. It is written only after the host has started the worker, so a
  failed call leaves nothing recorded (and `_followup` is removed again). It is open until `wait` has
  returned a final result; a worker that is gone needs the file deleted by hand.
- **orca.** The Run is created with `--from <watch handle>` (the Run's coordinator is the terminal that
  creates it), then the terminal, then `worker-start` with `--worktree` (without it orca refuses the
  terminal as belonging to the coordinator's worktree). `worker-start --agent` is not used: that agent
  would lack crew-afk's env. A worker question is `orchestration ask`, a `type: question` message to
  `run:<id>`; the response is its `worker_done`, which `orchestration inbox` lists and `check` does not.
- **herdr.** No message queue: a worker's question also ends its turn as `done`, so `followup.md` makes
  every turn end with one `QUESTION: …` or `DONE: …` line and `wait` returns the last such line it reads.
  A turn that ends with neither is an error showing the pane's tail.
- **Host calls** are each bounded (orca 10s, herdr's agent calls 60s to start); `wait` itself has no
  timeout. A failing or timed-out call exits non-zero with the host's own text.
- **Live.** Both transports passed one live cross-worktree round trip (question, answer, final result)
  on 2026-10-10; the `followup` command itself has not been run live yet.

## Worker terminals

With orca as the pane host, each coder/reviewer/triage dispatch runs in its own orca terminal,
titled `<slug> <agent>` and scoped to the dispatch's own worktree (the main checkout for a dispatch with none), so every worker is a tab you can
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
(`follow-output.mjs`), so a display failure can't reach the worker. It
shows stdout's JSON stream as `[TOOL]` lines, plus the assistant's text for an adapter that declares `liveText` (claude). The tab is a read-only view
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
  seen even when the prompt did land. `notifyWatchSession`'s orca path treats
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
  copilot pane detection is untested. If orca doesn't identify the watch agent's pane, the push
  is skipped rather than typed in blind.
- orca must be chosen, not detected by default: orca injects `ORCA_WORKTREE_ID`/`ORCA_TAB_ID`/
  `ORCA_TERMINAL_HANDLE` into its terminals, which `auto` uses, but no opt-in of its own.
- `terminal send` into a live claude pane takes ~8s to return (it watches for turn start),
  so the orca push gets a 20s timeout. With 5s it exited 124 after the message had already
  been delivered. Per-issue milestone pushes (coder finished, merged, partial, blocked) are
  queued rather than awaited, so that delay never holds an issue's pipeline. The queue sends
  one at a time, in order, and is drained before the end-of-run push.
- `ORCA_TAB_ID` is read by nothing: every create is already scoped by `--worktree`, and the
  rename goes by `ORCA_TERMINAL_HANDLE`; pushes go by the watch agent's recorded handle.
- `--worktree path:<mainRoot>`, not `active`: `active` isn't documented as cwd-relative and
  may resolve to whatever worktree orca's GUI has focused. `--command` is typed into the
  terminal's shell rather than passed as argv, so the log path is shell-quoted.
- Orca's own orchestration layer (`orchestration run-create`/`task-create`/`worker-start`,
  worker supervision, gates) is not used; see [Worker terminals](#worker-terminals) for why.
  Worker tabs are plain terminals to orca, not supervised workers.

## Worktrees the sprint creates

The sprint keeps its feature branch in `crew/<slug>/_feature` and each issue in its own worktree,
all made with native git — neither host creates one. After creating one, crew-afk names it to
the host, best-effort (a failure is logged and the run goes on):

- **orca:** `orca worktree set --worktree path:<worktree> --display-name <title> [--issue <n>]
  [--parent-worktree path:<_feature>]` for `_feature` and every issue worktree, and a worker
  terminal for a dispatch in an adopted worktree is created with `--worktree path:<that worktree>`
  (any other dispatch keeps `path:<mainRoot>`). Whether an adopted worktree shows in orca's sidebar
  is unverified: `orca worktree list` showed only the repo's main checkout.
- **herdr:** `_feature` only, as the sprint's workspace (`herdr worktree open --path <_feature>`);
  issue worktrees get no herdr call, since each herdr worktree is a whole workspace.
- **none:** nothing is called.
