/**
 * dispatch.mjs — four platforms, one contract.
 *
 * A dispatch is: run <agent> with <prompt> in <cwd>, capture its final message to
 * <outFile>, with a hard timeout. Every platform can do this headlessly:
 *
 *   pi       pi -p --mode json --append-system-prompt …   (via dispatch-agent.sh)
 *   codex    codex exec --cd … --json -o …                (via dispatch-codex-agent.sh)
 *   claude   claude -p --agent <name> --add-dir … --output-format stream-json --verbose
 *   copilot  copilot -p --agent <name> -C … --output-format json
 *
 * pi and codex keep their existing bash dispatchers, which already resolve the agent
 * definition and map its frontmatter onto CLI flags. claude and copilot resolve their
 * own agent by name (`--agent`).
 *
 * All four now run through a live event stream rather than a plain -p/text mode that
 * prints nothing until the whole turn is done: pi's --mode json, codex's --json, claude's
 * stream-json, and copilot's json output-format each emit one JSON object per event
 * (tool calls, in particular) as it happens. dispatch() and the two bash dispatchers read
 * that stream one line at a time and turn a recognised tool call into a `[TOOL]`/
 * `[TOOL-ERROR]` line in the sprint's trace log *while the worker is still running* — the
 * visibility a `tail -f` on that log did not have when a dispatch was a subprocess whose
 * only signal was silence, then its buffered final answer. The full raw stream is kept
 * next to outFile as `<outFile>.events.jsonl` for anyone who needs more than that one
 * line; only the final assistant text — the one thing report.mjs actually parses — goes
 * into outFile itself. See formatJsonTraceLine/extractFinalText below for claude/copilot,
 * and each bash dispatcher's own trace_event for pi/codex.
 *
 * For claude that name is the whole contract, verified against 2.1.221: `--agent` loads
 * the project-level `.claude/agents/<name>.md`, enforces its `tools:` list, and exits 1
 * with `--agent '<name>' not found` rather than silently falling back. So no agent body
 * is re-sent as a system prompt — an append would duplicate the definition Claude has
 * already loaded and, on any conflict, override it.
 *
 * Copilot 1.0.79 behaves the same way in `-p` mode — `No such agent: <name>, available: …`
 * on exit 1, and the definition's `tools:` list binds even under `--allow-all-tools` — with
 * one difference that matters here: **it resolves `.github/agents/` relative to its own
 * working directory and does not walk up.** A worker runs with the worktree as cwd, so only
 * a definition present in that checkout (tracked in `HEAD`) or under `~/.copilot/agents/`
 * resolves. `preflight()` checks exactly that, because the alternative is every worker
 * dying on `No such agent` after the sprint has already started.
 *
 * Permissions are explicit per platform: an unattended sprint that stops on a
 * tool-permission prompt is a sprint that never finishes.
 */

import { existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { homedir } from "node:os";
import { randomUUID } from "node:crypto";
import { appendLine } from "./effects.mjs";

export const PLATFORMS = ["pi", "codex", "claude", "copilot"];

/**
 * Default parallelism per platform. Copilot's plan tier (Free 2 … Enterprise 32) capped
 * *in-session* subagents; a worker is its own `copilot -p` session now, so what binds is
 * the account's request rate — which the CLI does not expose. Hence the conservative
 * default, raised with `--max-parallel`.
 */
export const DEFAULT_PARALLEL = { pi: 3, codex: 3, claude: 3, copilot: 2 };

function agentFileCandidates(platform, mainRoot, agent) {
  // $HOME first: os.homedir() reads USERPROFILE on Windows, not HOME, so a $HOME override
  // — bash's own portable way to redirect "home" — would be silently ignored there.
  const home = process.env.HOME || homedir();
  switch (platform) {
    case "pi":
      return [
        join(mainRoot, ".pi/agents", `${agent}.md`),
        join(home, ".pi/agent/agents", `${agent}.md`),
      ];
    case "codex":
      return [
        join(mainRoot, ".codex/agents", `${agent}.toml`),
        join(home, ".codex/agents", `${agent}.toml`),
      ];
    case "claude":
      return [
        join(mainRoot, ".claude/agents", `${agent}.md`),
        join(home, ".claude/agents", `${agent}.md`),
      ];
    case "copilot":
      return [
        join(mainRoot, ".github/agents", `${agent}.agent.md`),
        join(mainRoot, ".github/agents", `${agent}.md`),
        join(home, ".copilot/agents", `${agent}.agent.md`),
        join(home, ".copilot/agents", `${agent}.md`),
      ];
    default:
      return [];
  }
}

export function resolveAgentFile(platform, mainRoot, agent) {
  return agentFileCandidates(platform, mainRoot, agent).find((p) => existsSync(p)) ?? null;
}

/**
 * Build the argv for one dispatch.
 * @returns {{cmd: string, args: string[], cwd: string, env: object, capture: "stdout"|"file"}}
 */
export function buildDispatch(platform, spec) {
  const { agent, cwd, promptFile, outFile, model, mainRoot, logFile, scriptsDir, slug, reportPath } = spec;
  const shared = { cwd, env: { MAIN_ROOT: mainRoot, CREW_ORCHESTRATED: "1" } };

  // A test/CI seam: one script stands in for every model dispatch, so the whole state
  // machine (stall, Phase 2, conflicts, timeouts) is exercisable for zero tokens.
  // --report-path is passed through so fake-dispatch.sh can write the sidecar report.mjs
  // actually reads — the same file a real agent's own Write tool call would produce.
  if (process.env.CREW_FAKE_DISPATCH) {
    return {
      cmd: "bash",
      args: [
        process.env.CREW_FAKE_DISPATCH,
        "--agent", agent,
        "--dir", cwd,
        "--prompt-file", promptFile,
        "--out", outFile,
        ...(model ? ["--model", model] : []),
        ...(slug ? ["--slug", slug] : []),
        ...(reportPath ? ["--report-path", reportPath] : []),
      ],
      ...shared,
      cwd: mainRoot,
      capture: "file",
    };
  }

  if (platform === "pi" || platform === "codex") {
    const script = platform === "pi" ? "dispatch-agent.sh" : "dispatch-codex-agent.sh";
    const args = [
      join(scriptsDir, script),
      "--agent",
      agent,
      "--dir",
      cwd,
      "--prompt-file",
      promptFile,
      "--out",
      outFile,
    ];
    if (logFile) args.push("--log", logFile);
    if (model) args.push("--model", model);
    if (slug) args.push("--slug", slug);
    // The bash dispatchers cd into --dir themselves; run them from the main root so
    // their own git lookups resolve the main checkout.
    return { cmd: "bash", args, ...shared, cwd: mainRoot, capture: "file" };
  }

  const prompt = readFileSync(promptFile, "utf8");

  if (platform === "claude") {
    // bypassPermissions removes the *prompt*, not the allowlist: the agent definition's
    // `tools:` still applies, so the reviewer stays read-only and the coder still cannot
    // spawn agents. A narrower --allowedTools cannot be written in advance — a worker runs
    // the consuming project's own checks.
    //
    // --output-format stream-json --verbose (required together, or claude refuses to start:
    // "--output-format=stream-json requires --verbose") replaces plain -p text output. Text
    // mode prints nothing until the whole turn is done; stream-json emits one JSON object per
    // turn as it happens — an assistant message per turn (its `content` carries `tool_use`
    // blocks when the agent calls a tool), a user message carrying that tool's `tool_result`,
    // and a final `result` line with the agent's last answer in `.result`. dispatch() reads
    // that stream for the same visibility pi's --mode json and codex's --json give: a
    // `[TOOL]`/`[TOOL-ERROR]` line in --log as each tool call starts/fails, instead of
    // silence until the child exits or times out.
    const args = [
      "-p",
      "--permission-mode",
      "bypassPermissions",
      "--add-dir",
      mainRoot,
      "--agent",
      agent,
      "--output-format",
      "stream-json",
      "--verbose",
    ];
    if (model) args.push("--model", model);
    args.push(prompt);
    // Dispatched from inside a Claude Code session, this child would otherwise inherit
    // CLAUDE_CODE_SESSION_ID/CLAUDE_CODE_CHILD_SESSION from the parent process's own
    // environment and attach to the parent session's hook chain (e.g. a global
    // UserPromptSubmit hook), which can mutate or swallow the prompt before the agent
    // ever sees it. Clearing both severs that inheritance so the child always starts a
    // session of its own.
    return {
      cmd: "claude",
      args,
      ...shared,
      env: { ...shared.env, CLAUDE_CODE_SESSION_ID: "", CLAUDE_CODE_CHILD_SESSION: "" },
      capture: "stdout",
      jsonEvents: "claude",
    };
  }

  if (platform === "copilot") {
    // `--agent <name>` is the contract here too: probed against 1.0.79, the definition's
    // body governs the run and its `tools:` list binds even under --allow-all-tools, which
    // removes the confirmation prompt and nothing else. So no body is prepended — it would
    // duplicate what the CLI loads, and it cannot rescue a name the CLI refuses.
    //
    // --add-dir names the main checkout because the worker reads the issue file and writes
    // its <slug>.report.json under .scratch/ there, outside its worktree cwd.
    //
    // --output-format json (JSONL, one object per line — copilot-sdk's generated
    // session-events.d.ts is the schema) replaces --silent's plain text: a
    // `tool.execution_start` event per tool call (with `data.toolName`/`data.arguments`),
    // `tool.execution_complete` on success/failure, and `assistant.message` events whose
    // `data.content` is that turn's full text — the last one is the agent's final answer.
    // --silent only suppressed a stats footer in text mode and does nothing for json output;
    // dropped here for clarity, not because of a conflict.
    const args = [
      "-p",
      prompt,
      "--agent",
      agent,
      "-C",
      cwd,
      "--add-dir",
      mainRoot,
      "--allow-all-tools",
      "--no-color",
      "--output-format",
      "json",
    ];
    if (model) args.push("--model", model);
    return { cmd: "copilot", args, ...shared, capture: "stdout", jsonEvents: "copilot" };
  }

  throw new Error(`unknown platform: ${platform}`);
}

/**
 * A JSON preview that never silently swallows a truncation: a bare `.slice(0, max)` reads
 * as if the value just happened to be short, so a human (or a future grep) has no way to
 * tell "this is everything" from "this is cut off". Appending the byte count that got cut
 * makes the two cases distinguishable without needing to go find the original.
 */
function safePreview(value, max = 200) {
  let text;
  try {
    text = JSON.stringify(value ?? {});
  } catch {
    text = "{}";
  }
  return text.length > max ? `${text.slice(0, max)}…(+${text.length - max} chars)` : text;
}

/**
 * A one-line, human-readable stand-in for a tool call's raw args — `$ <command>` for a
 * shell call, a bare path for a read/write/edit — mirroring the style pi's own bundled
 * subagent extension uses for the same purpose (`examples/extensions/subagent/index.ts`'s
 * formatToolCall). Only the two argument shapes every platform's file/shell tools actually
 * use are recognised; anything else (an MCP call, a web fetch, a tool this doesn't know
 * about) falls through to a capped JSON preview rather than guessing.
 */
function summarizeArgs(args) {
  if (!args || typeof args !== "object") return null;
  if (typeof args.command === "string") return `$ ${args.command}`;
  const path = args.file_path ?? args.path;
  return typeof path === "string" ? path : null;
}

function formatArgs(args) {
  return summarizeArgs(args) ?? `args=${safePreview(args)}`;
}

/**
 * One [TOOL]/[TOOL-ERROR] line per recognised event, or null for everything else
 * (message text deltas, session bookkeeping, a line that failed to parse) — the same
 * "observability must never fail the dispatch" rule dispatch-agent.sh's and
 * dispatch-codex-agent.sh's trace_event follow. Claude's shape is the standard Anthropic
 * Messages content-block schema (`assistant.message.content[]` carries `tool_use`/
 * `tool_result` blocks); copilot's is copilot-sdk's own generated session-events.d.ts
 * (`tool.execution_start`/`tool.execution_complete`). The returned line carries no
 * timestamp or slug — dispatch() adds both when it lands the line in spec.logFile, the one
 * place that knows which dispatch this stream belongs to.
 */
export function formatJsonTraceLine(platform, agent, line) {
  let evt;
  try {
    evt = JSON.parse(line);
  } catch {
    return null;
  }
  if (platform === "claude") {
    if (evt.type === "assistant") {
      for (const block of evt.message?.content ?? []) {
        if (block.type === "tool_use") {
          return `[TOOL] agent=${agent} tool=${block.name} ${formatArgs(block.input)}`;
        }
      }
    }
    if (evt.type === "user") {
      for (const block of evt.message?.content ?? []) {
        if (block.type === "tool_result" && block.is_error) {
          return `[TOOL-ERROR] agent=${agent} tool_use_id=${block.tool_use_id ?? "?"}`;
        }
      }
    }
    return null;
  }
  if (platform === "copilot") {
    if (evt.type === "tool.execution_start") {
      return `[TOOL] agent=${agent} tool=${evt.data?.toolName ?? "?"} ${formatArgs(evt.data?.arguments)}`;
    }
    if (evt.type === "tool.execution_complete" && evt.data?.success === false) {
      return `[TOOL-ERROR] agent=${agent} toolCallId=${evt.data?.toolCallId ?? "?"} error=${safePreview(evt.data?.error?.message)}`;
    }
    return null;
  }
  return null;
}

/** [HH:MM:SSZ], matching the two bash dispatchers' `date -u +%H:%M:%SZ` exactly. */
function traceTimestamp() {
  return `${new Date().toISOString().slice(11, 19)}Z`;
}

/**
 * Throttle for the one live signal a long dispatch sends to the parent session: not every
 * tool call (unbounded over a 45-minute worker — gates × issues × rounds must stay the
 * bound, never tool calls × issues × rounds, see .scratch/crew-afk-visibility/plan.md),
 * but a heartbeat every Nth one or every INTERVAL_MS, whichever comes first. pi's and
 * codex's own bash dispatchers apply the identical rule before ever writing to their own
 * stdout (see dispatch-agent.sh/dispatch-codex-agent.sh's maybe_heartbeat) — this is
 * claude/copilot's equivalent, applied here since their tracing is already JS-side.
 */
const HEARTBEAT_EVERY_N = 5;
const HEARTBEAT_INTERVAL_MS = 30_000;

/** pi's/codex's own already-throttled [TOOL]/[TOOL-ERROR] line, forwarded on their stdout. */
const BASH_HEARTBEAT = /^\[(?:TOOL|TOOL-ERROR)\] /;

/**
 * The worker's final message, pulled back out of the raw event lines — report.mjs reads
 * outFile as that text, not the NDJSON envelope, the same contract pi's and codex's
 * dispatchers keep. Claude's terminal `result` line carries the final answer directly in
 * `.result`; copilot has no equivalent terminal event, so the last `assistant.message` —
 * the one after any tool calls — stands in for it, the same message copilot's own text
 * mode would have printed. Either extraction failing (a truncated stream, an unrecognised
 * shape) returns "": an empty report is already a handled state (report.mjs's "empty"
 * parsedFrom), and is safer than leaking raw JSONL into what the pipeline parses as text.
 */
export function extractFinalText(platform, lines) {
  if (platform === "claude") {
    for (let i = lines.length - 1; i >= 0; i--) {
      try {
        const evt = JSON.parse(lines[i]);
        if (evt.type === "result") return evt.result ?? "";
      } catch {
        /* skip an unparseable line */
      }
    }
    return "";
  }
  if (platform === "copilot") {
    for (let i = lines.length - 1; i >= 0; i--) {
      try {
        const evt = JSON.parse(lines[i]);
        if (evt.type === "assistant.message") return evt.data?.content ?? "";
      } catch {
        /* skip an unparseable line */
      }
    }
    return "";
  }
  return "";
}

const EMPTY_RESULT_META = { isError: null, costUsd: null, durationMs: null, numTurns: null, permissionDenials: [], sessionId: null };

/**
 * claude's terminal `result` event (verified live against 2.1.280) carries cost, error, and
 * timing fields that extractFinalText discards, keeping only `.result`. Scoped to claude
 * only: copilot's own terminal event has no confirmed equivalent (its documented event set —
 * see buildDispatch's copilot branch — has no "turn complete" shape at all), and pi/codex
 * don't run through this JS-side parsing path. Any platform/line-shape this doesn't recognise
 * returns the same all-null/empty shape, matching extractFinalText's own fail-open contract.
 */
export function extractResultMeta(platform, lines) {
  if (platform !== "claude") return EMPTY_RESULT_META;
  for (let i = lines.length - 1; i >= 0; i--) {
    try {
      const evt = JSON.parse(lines[i]);
      if (evt.type === "result") {
        return {
          isError: evt.is_error ?? null,
          costUsd: evt.total_cost_usd ?? null,
          durationMs: evt.duration_ms ?? null,
          numTurns: evt.num_turns ?? null,
          permissionDenials: evt.permission_denials ?? [],
          sessionId: evt.session_id ?? null,
        };
      }
    } catch {
      /* skip an unparseable line */
    }
  }
  return EMPTY_RESULT_META;
}

/**
 * herdr (https://herdr.dev) is ambient only: crew-afk's own process gets a dedicated pane
 * under HERDR_ENV=1 (see relaunchIntoDedicatedPane), but every coder/reviewer/triage
 * dispatch is always headless (`-p`/equivalent), whether or not HERDR_ENV is set. An earlier
 * version drove each dispatch as a long-lived interactive REPL in its own herdr pane
 * (`agent start`/`agent prompt --wait`, one tab per dispatch, pane reuse across retries) —
 * removed once headless `-p` was confirmed to run correctly with a herdr server active in
 * the background, since that REPL-per-worker machinery bought only live pane-watching and a
 * retry-continuity bonus that headless retries already work fine without.
 */

/**
 * effects.exec runs spawnSync — it blocks Node's single event loop for the child's whole
 * lifetime. Fine for the short bash scripts effects.exec is otherwise used for, but herdr's
 * own calls are not short: `agent prompt --wait` blocks until the pane goes idle/done, up to
 * the full worker timeout (45 min by default). The dispatch pool (loop.mjs) runs issues
 * concurrently by interleaving promises on that same single event loop — a blocked loop
 * blocks every other "concurrent" dispatch too, so a spawnSync herdrExec silently serialised
 * every herdr-enabled sprint no matter how high --max-parallel was set. spawnWithTimeout
 * uses async spawn instead, which yields the loop back between I/O events and lets the pool
 * actually run herdr dispatches side by side.
 */
async function herdrExec(effects, args, timeoutMs) {
  return effects.spawnWithTimeout("herdr", args, { cwd: effects.mainRoot, timeoutMs });
}

/**
 * herdr's own contract (`herdr --skill`): "CLI server errors are JSON on stderr with exit
 * status 1." Success responses are JSON on stdout. Tried in that order so a failed call's
 * `.error.code` (e.g. `agent_not_ready`) is actually reachable — the first live end-to-end
 * run against a real herdr server hit exactly this: `agent start`'s error landed on stderr
 * and a stdout-only parse silently swallowed the agent_not_ready code, so the trust-dialog
 * recovery branch below was never reached.
 */
function herdrJson(result) {
  for (const text of [result?.stdout, result?.stderr]) {
    if (!text) continue;
    try {
      return JSON.parse(text);
    } catch {
      /* try the next candidate */
    }
  }
  return null;
}

/**
 * A human watching herdr across several concurrent crew-afk runs sees one workspace per
 * run — the feature slug is what tells those apart at a glance; the hardcoded "crew-afk"
 * every run used to share told them apart not at all. Falls back to "crew-afk" for callers
 * that never resolved one (dry-run planning, tests), so the label is always non-empty.
 */
function herdrWorkspaceLabel(featureSlug) {
  return featureSlug || "crew-afk";
}

/**
 * The triggering pane's own tab still shows whatever it was called before crew-afk started
 * running in it (often the literal "crew-afk" the human typed to launch it) — herdr injects
 * that pane's tab as `HERDR_TAB_ID` alongside `HERDR_WORKSPACE_ID`, so this is the one chance
 * to relabel it to the sprint's feature slug the same way a freshly created workspace already
 * is (see herdrWorkspaceLabel). Skipped when no feature slug resolved: relabelling someone's
 * own tab to the "crew-afk" fallback would just clobber a title they chose with no gain.
 * Best-effort: a failed rename is cosmetic, not a reason to fail the run.
 */
async function renameHerdrTriggeringTab(effects, featureSlug) {
  if (!featureSlug) return;
  const tabId = process.env.HERDR_TAB_ID;
  if (!tabId) return;
  try {
    await herdrExec(effects, ["tab", "rename", tabId, featureSlug]);
  } catch {
    /* cosmetic — the sprint's own dispatch tabs are what matters */
  }
}

/**
 * The one herdr workspace for a whole crew-afk run, created by whichever dispatch gets here
 * first and reused by every dispatch after it — see the file-header comment for why. Cached
 * as a promise, not a plain field: the pool dispatches concurrently, and the promise is
 * assigned synchronously (before this function's first `await`), so a second call that
 * arrives before the first `workspace create` resolves still sees the cached promise instead
 * of racing its own `workspace create`. A rejection is cached too — every dispatch this run
 * then fails fast with the same error rather than each retrying the same broken call.
 *
 * When crew-afk itself is running inside a herdr-managed pane — a human started their own
 * claude/pi/codex/copilot session through herdr and is running crew-afk from inside it —
 * herdr has already injected that pane's workspace as `HERDR_WORKSPACE_ID` (see herdr's own
 * `--skill` guidance). Dispatches then add their tabs to that same workspace instead of
 * popping open a second, unrelated one: the human is already looking at the workspace that
 * triggered the sprint, so a new window would just be a second place to watch instead of the
 * one they have focused. Marked `_herdrWorkspaceReused` so closeHerdrWorkspace never closes
 * a workspace this run didn't create — that would yank the terminal out from under whoever
 * is still typing in it.
 *
 * `featureSlug` is only consulted by whichever call actually creates the workspace — every
 * dispatch this run passes the same sprint's values, so which one wins the race makes no
 * difference.
 */
function ensureHerdrWorkspace(effects, { featureSlug } = {}) {
  if (!effects._herdrWorkspace) {
    effects._herdrWorkspace = (async () => {
      const triggeringWorkspaceId = process.env.HERDR_WORKSPACE_ID;
      if (triggeringWorkspaceId) {
        effects._herdrWorkspaceReused = true;
        await renameHerdrTriggeringTab(effects, featureSlug);
        return triggeringWorkspaceId;
      }
      const label = herdrWorkspaceLabel(featureSlug);
      const create = await herdrExec(effects, ["workspace", "create", "--cwd", effects.mainRoot, "--label", label, "--no-focus"]);
      const workspaceId = herdrJson(create)?.result?.workspace?.workspace_id;
      if (create.code !== 0 || !workspaceId) {
        throw new Error(`herdr workspace create failed: ${(create.stderr || create.stdout || "").trim()}`);
      }
      return workspaceId;
    })();
  }
  return effects._herdrWorkspace;
}

/**
 * Closes the shared workspace ensureHerdrWorkspace created, once, at the end of the whole
 * crew-afk run (see main.mjs). A no-op when no herdr dispatch ever ran this run — nothing to
 * close — or when that workspace was the triggering pane's own, reused rather than created
 * (see ensureHerdrWorkspace): closing it would close the terminal crew-afk was launched
 * from. Otherwise swallows a failed close rather than throwing, since by this point the
 * run's own exit code is already decided and a stray workspace is a herdr-UI nuisance, not a
 * reason to report the run itself as failed.
 */
export async function closeHerdrWorkspace(effects) {
  if (!effects._herdrWorkspace || effects._herdrWorkspaceReused) return;
  try {
    const workspaceId = await effects._herdrWorkspace;
    await herdrExec(effects, ["workspace", "close", workspaceId]);
  } catch {
    /* already reported at the dispatch that first hit it, or nothing was ever created */
  }
}

/**
 * With HERDR_ENV=1, crew-afk is commonly launched as a backgrounded command inside the very
 * pane a human (or the agent driving it) is watching, then left to poll it — see main.mjs's
 * doc comment and ensureHerdrWorkspace's. That pane sits idle between polls, so pushing this
 * run's outcome straight into it, once, at the very end, lets the caller stop polling
 * altogether and just wait for the next turn instead. `$HERDR_PANE_ID` is the triggering
 * pane's own ID, which herdr injects into every process it starts (see herdr's own --skill:
 * agent commands take either a live agent name or "the pane ID currently hosting that
 * agent") — no lookup needed. Absent (not running inside herdr) or any failure (no agent
 * recognized in that pane, one already at a dialog, herdr unreachable) is a silent no-op:
 * the run's own outcome is already decided by the time this fires, and the printed summary
 * is still sitting in that pane's scrollback either way.
 *
 * Returns `{sent, reason?}` rather than void: `effects.log` — the only thing this used to
 * report through — is a dead sink for most callers (see main.mjs's own Effects
 * construction, buffered into an array nothing reads, mirrored to stderr only under
 * CREW_VERBOSE, never written to orchestrator.log), so a caller that does have a real
 * trace-log writer (see notifyMilestone in pipeline.mjs) needs this outcome handed back to
 * actually surface a skip or failure anywhere durable.
 */
export async function notifyTriggeringPane(effects, message) {
  const paneId = process.env.HERDR_PANE_ID;
  if (!paneId) {
    effects.log?.("NOTIFY-SKIP no HERDR_PANE_ID in env");
    return { sent: false, reason: "no HERDR_PANE_ID in env" };
  }
  try {
    const result = await herdrExec(effects, ["agent", "prompt", paneId, message]);
    // herdrExec/spawnWithTimeout resolves rather than rejects on a nonzero exit (see
    // effects.mjs) — the catch below only ever catches a thrown error (e.g. herdr not on
    // PATH), so a failed push (agent_not_ready, no agent in that pane, herdr unreachable)
    // must be checked here explicitly or it is never seen at all, not even in this
    // best-effort log line.
    if (result.code !== 0) {
      const reason = `herdr agent prompt exit=${result.code} ${(result.stderr || result.stdout || "").trim()}`;
      effects.log?.(`NOTIFY-FAIL ${reason}`);
      return { sent: false, reason };
    }
    return { sent: true };
  } catch (err) {
    /* best effort — see doc comment above */
    const reason = `herdr agent prompt threw: ${err.message}`;
    effects.log?.(`NOTIFY-FAIL ${reason}`);
    return { sent: false, reason };
  }
}

// How long the front door will wait for the relaunched instance to report its own
// completion before giving up — see relaunchIntoDedicatedPane's own doc comment for why
// there is no better signal than this ceiling: `pane run` starts a plain command
// fire-and-forget, with no way to read its later exit code back (no `pane wait`, no
// exit_code field anywhere in herdr's own responses). Deliberately generous: a real sprint
// can legitimately run for hours across many issues and rounds.
const DEFAULT_RELAUNCH_TIMEOUT_MS = 8 * 60 * 60 * 1000;
const RELAUNCH_POLL_MS = 3_000;

// Ambient env the front door itself may have that the dedicated pane has no reason to
// already know — a dev/test seam (CREW_FAKE_DISPATCH, CREW_SCRIPTS), or a debug flag
// (CREW_VERBOSE). Forwarded only when actually set on the front door's own env, never
// assumed present in the new pane — `pane run` is not confirmed to inject anything beyond
// what `tab create --env` names.
const RELAUNCH_ENV_PASSTHROUGH = ["HOME", "CREW_SCRIPTS", "CREW_VERBOSE", "CREW_FAKE_DISPATCH"];

/**
 * The dedicated run pane's own env, built explicitly rather than assumed inherited. Never
 * includes `HERDR_TAB_ID`: `renameHerdrTriggeringTab` only fires when it reads one from
 * `process.env`, and this pane is not "the triggering pane" — its own tab is already
 * labelled correctly at create time, so there is nothing for that rename logic to do here,
 * and omitting the var is what keeps it from trying. `HERDR_PANE_ID`, when forwarded, still
 * points at the *original* triggering pane (whatever the front door's own env named), not
 * this new one — so the relaunched instance's own end-of-run notifyTriggeringPane still
 * nudges the right pane.
 */
function relaunchEnvPairs({ workspaceId, triggeringPaneId, platform, sentinelPath, env }) {
  const pairs = {
    HERDR_ENV: "1",
    HERDR_WORKSPACE_ID: workspaceId,
    CREW_AFK_RELAUNCHED: "1",
    CREW_AFK_RELAUNCH_SENTINEL: sentinelPath,
    CREW_PLATFORM: platform,
  };
  if (triggeringPaneId) pairs.HERDR_PANE_ID = triggeringPaneId;
  for (const k of RELAUNCH_ENV_PASSTHROUGH) if (env[k] !== undefined) pairs[k] = env[k];
  return pairs;
}

function envFlags(pairs) {
  return Object.entries(pairs).flatMap(([k, v]) => ["--env", `${k}=${v}`]);
}

/**
 * Blocks until the relaunched instance's own finally block writes `sentinelPath` (its last
 * act — see main.mjs), or until `timeoutMs` elapses. There is no herdr primitive that can
 * tell us this any other way (see DEFAULT_RELAUNCH_TIMEOUT_MS above), so a sentinel file is
 * the whole mechanism: `{exitCode, at}`, written once, read once, then deleted here
 * regardless of outcome so `.scratch/.crew-afk-relaunch/` doesn't accumulate one file per run
 * forever.
 */
async function waitForRelaunchSentinel(sentinelPath, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (existsSync(sentinelPath)) {
      try {
        const parsed = JSON.parse(readFileSync(sentinelPath, "utf8"));
        return { exitCode: typeof parsed.exitCode === "number" ? parsed.exitCode : 1, timedOut: false };
      } catch {
        return { exitCode: 1, timedOut: false }; // partial/corrupt write — a real failure, not a hang
      } finally {
        try {
          unlinkSync(sentinelPath);
        } catch {
          /* hygiene only */
        }
      }
    }
    // Never sleeps past the deadline — a short relaunchTimeoutMs (a test, or a genuinely
    // fast-failing child) must not overshoot it by up to one full poll interval.
    await new Promise((r) => setTimeout(r, Math.max(0, Math.min(RELAUNCH_POLL_MS, deadline - Date.now()))));
  }
  return { exitCode: 1, timedOut: true };
}

/**
 * Gives crew-afk's own process a herdr pane of its own, distinct from the triggering pane and
 * from every coder/reviewer/triage dispatch tab, so a human can watch the sprint's own
 * round-by-round narration live without it competing with whatever else the triggering pane
 * is doing. Runs a *plain* command via `pane run`, not `agent start` — crew-afk's own process
 * is not a chat agent herdr should idle-detect or prompt.
 *
 * Returns `{exitCode, delegated, error?}`. `delegated` is true once responsibility for
 * nudging the triggering pane (see notifyTriggeringPane) has been handed off — either because
 * the relaunched instance itself got far enough to send its own nudge, or because this
 * function sent an equivalent one itself after giving up — so the caller's own end-of-run
 * nudge must fire only when `delegated` is false (the child never started at all).
 */
export async function relaunchIntoDedicatedPane(effects, { mainRoot, featureSlug, platform, argv, mainScript, relaunchTimeoutMs = DEFAULT_RELAUNCH_TIMEOUT_MS } = {}) {
  const sentinelPath = join(mainRoot, ".scratch", ".crew-afk-relaunch", `${randomUUID()}.json`);
  mkdirSync(dirname(sentinelPath), { recursive: true });

  let workspaceId;
  try {
    workspaceId = await ensureHerdrWorkspace(effects, { featureSlug });
  } catch (err) {
    return { exitCode: 1, delegated: false, error: `could not create/reuse a herdr workspace for the dedicated run pane: ${err.message}` };
  }

  const pairs = relaunchEnvPairs({
    workspaceId,
    triggeringPaneId: process.env.HERDR_PANE_ID,
    platform,
    sentinelPath,
    env: process.env,
  });
  const label = `${herdrWorkspaceLabel(featureSlug)}-run`;
  const create = await herdrExec(effects, ["tab", "create", "--workspace", workspaceId, "--cwd", mainRoot, "--label", label, ...envFlags(pairs), "--no-focus"]);
  const created = herdrJson(create)?.result;
  const paneId = created?.root_pane?.pane_id;
  const tabId = created?.tab?.tab_id;
  if (create.code !== 0 || !paneId) {
    return { exitCode: 1, delegated: false, error: `herdr tab create failed for the dedicated run pane: ${(create.stderr || create.stdout || "").trim()}` };
  }

  // No hardcoded "run" here: argv is process.argv.slice(2) from the front door, which
  // already carries its own "run" token whenever the caller passed one explicitly (every
  // platform launcher does) — and main.mjs's own parseArgs() defaults to "run" anyway when
  // the first token isn't one. Adding another "run" duplicated it into "run run ...",
  // which parseArgs then rejected as an unrecognized argument.
  const run = await herdrExec(effects, ["pane", "run", paneId, process.execPath, mainScript, ...argv]);
  if (run.code !== 0) {
    // herdr rejected the request outright — the node process never started, so there is no
    // sentinel to wait for and no pane worth leaving open.
    await closeHerdrPane(effects, tabId);
    return { exitCode: 1, delegated: false, error: `herdr pane run failed to start the dedicated run pane: ${(run.stderr || run.stdout || "").trim()}` };
  }

  const { exitCode, timedOut } = await waitForRelaunchSentinel(sentinelPath, relaunchTimeoutMs);
  if (timedOut) {
    await notifyTriggeringPane(
      effects,
      `crew-afk: gave up waiting on its own dedicated pane after ${Math.round(relaunchTimeoutMs / 3_600_000)}h with no completion report — check that pane directly, and .scratch/<feature-slug>/traces/orchestrator.log.`,
    );
  }
  await closeHerdrPane(effects, tabId);
  return { exitCode, delegated: true };
}

/**
 * Explicit close for a tab this file itself opened — currently only
 * relaunchIntoDedicatedPane's own dedicated run pane. A no-op when tabId is falsy, so a
 * caller that never opened one can call this unconditionally without checking first.
 */
export async function closeHerdrPane(effects, tabId) {
  if (!tabId) return;
  try {
    await herdrExec(effects, ["tab", "close", tabId]);
  } catch {
    /* the pane is a herdr-UI nuisance at worst, not a reason to fail the caller */
  }
}

/**
 * Run one dispatch to completion. Always leaves a report file on disk (empty when the
 * child produced nothing), because "no report" is a state the pipeline must be able
 * to read rather than infer.
 */
export async function dispatch(effects, platform, spec, { timeoutMs, onTrace } = {}) {
  const built = buildDispatch(platform, spec);
  mkdirSync(dirname(spec.outFile), { recursive: true });

  // claude's stream-json and copilot's json visibility: read the child's NDJSON one line
  // at a time as it arrives, the same way dispatch-agent.sh/dispatch-codex-agent.sh do for
  // pi/codex. A recognised tool call becomes a `[TOOL]`/`[TOOL-ERROR]` line in spec.logFile
  // *while the worker is still running*; every raw line is also kept, for post-hoc
  // debugging, next to outFile as `<outFile>.events.jsonl`.
  //
  // effects.spawnWithTimeout's onLine is misnamed: it hands back raw stdout chunks, not
  // lines — a long JSON line can arrive split across two chunks. lineBuffer holds the
  // trailing partial line between calls; only complete lines (newline-terminated) are
  // processed as they arrive, and any remainder left after the child closes is flushed
  // once, below, the same as a final chunk with an implicit trailing newline.
  const lines = [];
  let lineBuffer = "";
  let heartbeatCount = 0;
  // Seeded to "now", not 0: an elapsed-time check against the epoch is always >=
  // INTERVAL_MS on the very first call, which would fire a heartbeat on tool call #1
  // regardless of the count throttle.
  let lastHeartbeatAt = Date.now();
  const maybeHeartbeat = (trace) => {
    if (!onTrace) return;
    heartbeatCount += 1;
    const now = Date.now();
    if (heartbeatCount % HEARTBEAT_EVERY_N !== 0 && now - lastHeartbeatAt < HEARTBEAT_INTERVAL_MS) return;
    lastHeartbeatAt = now;
    onTrace(trace);
  };
  const consumeLine = (line) => {
    if (!line.trim()) return;
    if (built.jsonEvents) {
      lines.push(line);
      const trace = formatJsonTraceLine(built.jsonEvents, spec.agent, line);
      if (trace) {
        if (spec.logFile) {
          const slugTag = spec.slug ? ` slug=${spec.slug}` : "";
          const roundTag = spec.round != null ? ` round=${spec.round}` : "";
          appendLine(spec.logFile, `[${traceTimestamp()}]${slugTag}${roundTag} ${trace}`);
        }
        maybeHeartbeat(trace);
      }
      return;
    }
    // pi/codex (and the CREW_FAKE_DISPATCH test seam): the bash dispatcher already writes
    // full [TOOL]/[TOOL-ERROR] detail to spec.logFile itself, tagged and timestamped —
    // the only thing on its stdout meant for the live stream is its own already-throttled
    // copy of that same line (see dispatch-agent.sh/dispatch-codex-agent.sh's
    // maybe_heartbeat). Everything else on that stdout (the raw NDJSON stream, forwarded
    // there for a human running the script by hand) is not a heartbeat and is dropped
    // rather than mirrored.
    if (onTrace && BASH_HEARTBEAT.test(line)) onTrace(line);
  };
  const onLine = (chunk) => {
    lineBuffer += String(chunk);
    const parts = lineBuffer.split("\n");
    lineBuffer = parts.pop();
    for (const line of parts) consumeLine(line);
  };

  const r = await effects.spawnWithTimeout(built.cmd, built.args, {
    cwd: built.cwd,
    env: built.env,
    timeoutMs,
    onLine,
  });
  consumeLine(lineBuffer);

  let meta = EMPTY_RESULT_META;
  if (built.jsonEvents && !r.dryRun) {
    writeFileSync(`${spec.outFile}.events.jsonl`, lines.length ? `${lines.join("\n")}\n` : "");
    // report.mjs reads outFile as the worker's final message text, not the event stream.
    writeFileSync(spec.outFile, extractFinalText(built.jsonEvents, lines));
    meta = extractResultMeta(built.jsonEvents, lines);
  } else if (built.capture === "stdout" && !r.dryRun) {
    writeFileSync(spec.outFile, r.stdout ?? "");
  }
  const text = existsSync(spec.outFile) ? readFileSync(spec.outFile, "utf8") : "";

  // The dispatch scripts (dispatch-agent.sh/dispatch-codex-agent.sh) trace their own
  // [DISPATCH]/[DISPATCH-END] lines from *inside* the script — so a failure before the
  // script gets that far (an early `die()` guard, or the child process never starting at
  // all: ENOENT, a killed process, fork/resource exhaustion) leaves zero trace anywhere,
  // and the one place the reason lived — this child's stderr — was read into `r.stderr`
  // and then never looked at again by any caller. Log it here, once, so a repeat isn't a
  // mystery a second time. Never throws and never blocks a dispatch on its own account.
  //
  // Also fires on meta.isError/permissionDenials even when code===0 and text is non-empty:
  // claude can flag a turn `is_error: true` or record a permission denial while still
  // exiting 0 and writing something — a case that otherwise left no trace anywhere.
  if (spec.logFile && !r.dryRun && (r.code !== 0 || r.timedOut || !text.trim() || meta.isError || meta.permissionDenials.length)) {
    const stderrSnippet = (r.stderr ?? "").trim().slice(0, 500).replace(/\s+/g, " ");
    const metaTag = meta.isError || meta.permissionDenials.length
      ? ` isError=${!!meta.isError} permissionDenials=${meta.permissionDenials.length}`
      : "";
    appendLine(
      spec.logFile,
      `[DISPATCH-FAIL] agent=${spec.agent} slug=${spec.slug ?? "?"} code=${r.code} timedOut=${!!r.timedOut} outEmpty=${!text.trim()}${metaTag} stderr=${JSON.stringify(stderrSnippet || "(none)")}`,
    );
  }

  return {
    code: r.code,
    timedOut: !!r.timedOut,
    dryRun: !!r.dryRun,
    stderr: r.stderr ?? "",
    text,
    isError: meta.isError,
    costUsd: meta.costUsd,
    durationMs: meta.durationMs,
    numTurns: meta.numTurns,
    permissionDenials: meta.permissionDenials,
    sessionId: meta.sessionId,
  };
}

/**
 * An agent-less dispatch: one reasoning pass with no agent definition. Used for the
 * opt-in coverage validation, whose prompt is printed by coverage-validation.sh, and for
 * one-time command discovery (see commands.mjs) — so the prompt only exists in a context
 * window when the step that built it actually runs.
 *
 * Deliberately does not strip tool access: a `noTools` option restricting command
 * discovery's dispatch once existed here (pi's `--no-tools --no-context-files`, claude's
 * `--tools ""`), but claude's `--tools` flag is variadic — with no `--model` between it and
 * the prompt (the default, unless a sprint passes `--model`), `--tools ""` swallowed the
 * prompt itself as part of its own argument list, so claude saw no prompt at all and exited
 * 1 with "Input must be provided either through stdin or as a prompt argument", surfaced as
 * "Command discovery: model dispatch did not complete (exit 1)". Every caller of this
 * function gets the same read/bash/edit/write toolset an interactive session would.
 *
 * claude's auto-memory *is* disabled here (CLAUDE_CODE_DISABLE_AUTO_MEMORY=1), unlike its
 * tool access above: every dispatchPlain call is a one-shot, stateless reasoning pass —
 * command discovery re-derives its answer from a source hash every run, coverage validation
 * likewise takes the current diff as input — so there is nothing for either to usefully
 * remember between runs. Worse, auto-memory's project directory is shared across every
 * worktree in the repo, and this dispatch gets full write-tool access before any worktree
 * exists; a "learned" note written here would leak into every future interactive session
 * and worker's context with no reviewer ever having signed off on it.
 */
export async function dispatchPlain(
  effects,
  platform,
  { prompt, cwd, mainRoot, model, outFile, timeoutMs, fakeAgent = "coverage-validation" },
) {
  const env = {
    MAIN_ROOT: mainRoot,
    CREW_ORCHESTRATED: "1",
    ...(platform === "claude"
      ? {
          CLAUDE_CODE_DISABLE_AUTO_MEMORY: "1",
          // See buildDispatch's claude branch: without these cleared, a claude -p run
          // launched from inside a Claude Code session inherits the parent's session
          // id and attaches to its hook chain instead of starting its own session.
          CLAUDE_CODE_SESSION_ID: "",
          CLAUDE_CODE_CHILD_SESSION: "",
        }
      : {}),
  };

  // The same test/CI seam buildDispatch has: an agent-less dispatch is still a model
  // call, so any step that makes one must be exercisable for zero tokens or it is the one
  // step no test ever runs. fakeAgent tells fake-dispatch.sh which canned response to play
  // — coverage validation and command discovery are both agent-less, but need different
  // answers.
  if (process.env.CREW_FAKE_DISPATCH) {
    const out = outFile ?? join(cwd, "plain-dispatch.out");
    const r = await effects.spawnWithTimeout(
      "bash",
      [process.env.CREW_FAKE_DISPATCH, "--agent", fakeAgent, "--dir", cwd, "--out", out],
      { cwd: mainRoot, env, timeoutMs },
    );
    const text = existsSync(out) ? readFileSync(out, "utf8") : "";
    return { code: r.code, timedOut: !!r.timedOut, text, dryRun: !!r.dryRun };
  }

  let cmd;
  let args;
  switch (platform) {
    case "pi":
      cmd = "pi";
      args = ["-p", ...(model ? ["--model", model] : []), prompt];
      break;
    case "codex":
      cmd = "codex";
      args = ["exec", "--cd", cwd, ...(model ? ["--model", model] : []), prompt];
      break;
    case "claude":
      cmd = "claude";
      // Prompt must not be the argv token right after --add-dir's value: --add-dir is
      // variadic (`<directories...>`) and, with no --model in between (the default,
      // unless a sprint passes --model), claude's own parser would consume the prompt as
      // a second directory instead of the -p positional argument — claude then sees no
      // prompt at all and exits 1 with "Input must be provided either through stdin or as
      // a prompt argument". Placed immediately after -p instead, exactly like copilot's
      // argv below, so no later flag's arity can ever swallow it.
      args = [
        "-p",
        prompt,
        "--permission-mode",
        "bypassPermissions",
        "--add-dir",
        mainRoot,
        ...(model ? ["--model", model] : []),
      ];
      break;
    case "copilot":
      cmd = "copilot";
      args = ["-p", prompt, "-C", cwd, "--add-dir", mainRoot, "--allow-all-tools", "--no-color", "--silent", ...(model ? ["--model", model] : [])];
      break;
    default:
      throw new Error(`unknown platform: ${platform}`);
  }
  const r = await effects.spawnWithTimeout(cmd, args, { cwd, env, timeoutMs });
  if (outFile && !r.dryRun) {
    mkdirSync(dirname(outFile), { recursive: true });
    writeFileSync(outFile, r.stdout ?? "");
  }
  return { code: r.code, timedOut: !!r.timedOut, text: r.stdout ?? "", dryRun: !!r.dryRun };
}

/**
 * Copilot resolves `--agent` from the worker's own cwd and does not walk up, so the only
 * definitions a worker in a worktree can see are the ones that checkout has (i.e. tracked
 * in `HEAD`) and the user-level ones. A definition sitting untracked in the main root is
 * installed and invisible — the failure is `No such agent` on every worker, after the
 * sprint has started.
 */
function copilotWorktreeVisible(effects, mainRoot, agent) {
  // See agentFileCandidates' comment above on $HOME vs os.homedir() on Windows.
  const home = process.env.HOME || homedir();
  for (const p of [
    join(home, ".copilot/agents", `${agent}.agent.md`),
    join(home, ".copilot/agents", `${agent}.md`),
  ]) {
    if (existsSync(p)) return true;
  }
  for (const rel of [`.github/agents/${agent}.agent.md`, `.github/agents/${agent}.md`]) {
    if (effects.gitRead(["cat-file", "-e", `HEAD:${rel}`]).code === 0) return true;
  }
  return false;
}

/** Preflight: is this platform's CLI and agent definition actually present? */
export function preflight(effects, platform, mainRoot, agents, { herdr = false } = {}) {
  if (process.env.CREW_FAKE_DISPATCH) return [];
  const cli = { pi: "pi", codex: "codex", claude: "claude", copilot: "copilot" }[platform];
  const which = effects.exec("sh", ["-c", `command -v ${cli}`], { mutating: false });
  const problems = [];
  if (which.code !== 0) problems.push(`${cli} CLI not found on PATH`);
  for (const a of agents) {
    if (!resolveAgentFile(platform, mainRoot, a)) {
      problems.push(`${a} agent definition not installed for ${platform} — run: ./install.sh ${platform} --skill crew-afk`);
      continue;
    }
    if (platform === "copilot" && !copilotWorktreeVisible(effects, mainRoot, a)) {
      problems.push(
        `${a} agent definition is not visible from a worktree — copilot resolves --agent from the worker's cwd. ` +
          `Commit .github/agents/${a}.agent.md, or install it user-level: TARGET_REPO=$HOME ./install.sh copilot --skill crew-afk`,
      );
    }
  }
  if (herdr) problems.push(...preflightHerdr(effects));
  return problems;
}

/**
 * HERDR_ENV=1 applies to whichever --platform the sprint runs, so this check fails the
 * sprint at startup with one clear message, rather than crew-afk's own dedicated run pane
 * (relaunchIntoDedicatedPane) discovering mid-run that herdr's CLI or server isn't there.
 */
function preflightHerdr(effects) {
  const which = effects.exec("sh", ["-c", "command -v herdr"], { mutating: false });
  if (which.code !== 0) return ["HERDR_ENV=1 but the herdr CLI was not found on PATH"];
  const status = effects.exec("herdr", ["status"], { mutating: false });
  if (status.code !== 0 || !/status:\s*running/.test(status.stdout || "")) {
    return ["HERDR_ENV=1 but the herdr server is not running — start it with: herdr server"];
  }
  return [];
}
