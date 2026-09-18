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

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { homedir } from "node:os";
import { createHash } from "node:crypto";
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
  const home = homedir();
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

/** Strip YAML frontmatter, returning { frontmatter, body }. */
export function splitFrontmatter(text) {
  if (!text.startsWith("---")) return { frontmatter: {}, body: text };
  const end = text.indexOf("\n---", 3);
  if (end === -1) return { frontmatter: {}, body: text };
  const head = text.slice(4, end);
  const body = text.slice(end + 4).replace(/^\n/, "");
  const frontmatter = {};
  for (const m of head.matchAll(/^([\w-]+):\s*(.*)$/gm)) frontmatter[m[1]] = m[2].trim();
  return { frontmatter, body };
}

/**
 * Build the argv for one dispatch.
 * @returns {{cmd: string, args: string[], cwd: string, env: object, capture: "stdout"|"file"}}
 */
export function buildDispatch(platform, spec) {
  const { agent, cwd, promptFile, outFile, model, mainRoot, logFile, scriptsDir, slug } = spec;
  const shared = { cwd, env: { MAIN_ROOT: mainRoot, CREW_ORCHESTRATED: "1" } };

  // A test/CI seam: one script stands in for every model dispatch, so the whole state
  // machine (stall, Phase 2, conflicts, timeouts) is exercisable for zero tokens.
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

/**
 * herdr (https://herdr.dev) drives coding agents as long-lived interactive REPLs inside
 * panes it manages — idle/working/blocked/done/unknown, not a one-shot batch run — so this
 * is a second dispatch path, not a flag on buildDispatch's claude branch. Verified live
 * against herdr 0.8.2: `agent start` never creates a pane, only occupies one that already
 * exists — dispatchViaHerdr gets one via `tab create --workspace <the sprint's one shared
 * workspace> --cwd <the issue's worktree>`, one tab per dispatch, closed when it's done. Every
 * coder/reviewer/triage dispatch for the whole crew-afk run shares that one workspace
 * (created lazily by the first dispatch, see ensureHerdrWorkspace) instead of each opening
 * its own — a human watching herdr sees one steady window gaining and losing tabs as work
 * starts and finishes, not a new window flashing open and closed per dispatch. A fresh
 * worktree trips claude's and copilot's one-time trust dialog in interactive mode (unlike
 * their own `-p` mode, which always skips it) — but that trust is keyed off the repository,
 * not the literal cwd, so it fires once per repo, on whichever dispatch happens to hit it
 * first, not once per worktree; the detect-and-answer block in dispatchViaHerdr handles that
 * single occurrence, per platform (see HERDR_DIALOGS). `agent read` returns *rendered*
 * terminal text, not the clean `.result` field stream-json gives extractFinalText.
 *
 * All four platforms now go through this path when spec.herdr is set: herdr's own `--kind`
 * already lists pi/claude/codex/copilot as supported kinds (`herdr agent start --help`), and
 * its idle/working/blocked/done detection is generic per kind — nothing here is claude-only
 * by herdr's own design, only by how much of each platform's interactive quirks had been
 * verified live. claude and copilot were verified live against herdr 0.8.2 with real
 * transcripts (trust dialog text, reply framing — see HERDR_DIALOGS and extractHerdrReply).
 * pi was verified live too, but needs no dialog table entry: it's launched with --approve,
 * which skips its trust prompt outright rather than answering it, the same way claude's
 * bypassPermissions and copilot's --allow-all-tools remove a prompt instead of clicking
 * through it. codex could not be verified live in the environment this was built in (no
 * ChatGPT/API-key credentials to get past its sign-in screen) — its argv is built from
 * documented flags only, and extractHerdrReply falls back to the same generic text-window
 * heuristic pi uses. An unrecognised block still fails loud rather than guessing a keystroke
 * (see HERDR_DIALOGS) — codex hitting an unhandled first-run dialog fails clearly instead of
 * silently misbehaving; the fix, once someone runs it for real, is a new HERDR_DIALOGS entry.
 */
const HERDR_DIALOGS = {
  claude: { match: "is this a project you created or one you trust", keys: ["down", "enter"] },
  copilot: { match: "do you trust the files in this folder", keys: ["enter"] },
};

/**
 * effects.exec runs spawnSync — it blocks Node's single event loop for the child's whole
 * lifetime. Fine for the short bash scripts effects.exec is otherwise used for, but herdr's
 * own calls are not short: `agent prompt --wait` blocks until the pane goes idle/done, up to
 * the full worker timeout (45 min by default). mapPool (loop.mjs) dispatches issues
 * concurrently by interleaving promises on that same single event loop — a blocked loop
 * blocks every other "concurrent" dispatch too, so a spawnSync herdrExec silently serialised
 * every herdr-enabled sprint no matter how high --max-parallel was set. spawnWithTimeout
 * uses async spawn instead, which yields the loop back between I/O events and lets the pool
 * actually run herdr dispatches side by side.
 */
async function herdrExec(effects, args, timeoutMs) {
  return effects.spawnWithTimeout("herdr", args, { cwd: effects.mainRoot, timeoutMs });
}

// How long to wait before re-reading a pane whose `agent prompt --wait` already reported
// idle/done but whose rendered screen came back with no extractable reply — see the retry
// loop in dispatchViaHerdr, below. Backs off linearly (250ms, 500ms, 750ms, 1000ms) across
// HERDR_READ_MAX_ATTEMPTS total reads — herdr exposes no signal for "the render buffer has
// caught up", so this only covers flush lag, not a genuinely empty or unparsable reply.
const HERDR_READ_RETRY_DELAY_MS = 250;
const HERDR_READ_MAX_ATTEMPTS = 5;

// Bounds the one `pane wait-output` pre-check below — generous relative to typical TUI
// flush latency, small relative to the dispatch's own timeout. A pane that never renders the
// anchor (blocked, or a platform whose rendering doesn't match herdrReplyReadyPattern) just
// falls through to the fixed-delay backoff loop instead of waiting here.
const HERDR_WAIT_OUTPUT_TIMEOUT_MS = 10_000;

// `agent prompt --wait --timeout <bound>` is told to self-report a stall at exactly `bound`,
// but the JS-side spawnWithTimeout kill used to fire at that same instant — a race where our
// own SIGKILL could win and erase herdr's chance to ever print the agent_prompt_stalled/timeout
// JSON envelope its exit is diagnosed from, leaving a DISPATCH-FAIL log with an empty stderr and
// a falsely-false timedOut. Giving the JS-side kill a grace period past herdr's own --timeout
// lets herdr detect and report the stall first; the JS-side timer stays only as a backstop for
// a herdr CLI that hangs without ever honouring its own --timeout at all.
const HERDR_CLI_KILL_GRACE_MS = 2 * 60 * 1000;

// Bounds the one-off `herdr status` health check a DISPATCH-FAIL takes when `agent prompt`
// failed with literally no stdout/stderr to explain why — small, since this is a diagnostic
// side-call on an already-failed dispatch, not something worth waiting on at length.
const HERDR_STATUS_CHECK_TIMEOUT_MS = 10_000;

/**
 * herdr's `agent start` rejects any name that isn't `^[a-z][a-z0-9_-]{0,31}$` — issue slugs
 * are usually already that shape, but come from a markdown filename (issueSlug()), so nothing
 * stops one running long or carrying an uppercase letter. Sanitising here, once, at the herdr
 * boundary keeps issueSlug() itself free of a constraint that's herdr's, not the tracker's.
 */
export function herdrAgentName(raw) {
  const lowered = (raw || "").toLowerCase().replace(/[^a-z0-9_-]/g, "-");
  const startsValid = /^[a-z]/.test(lowered) ? lowered : `a-${lowered.replace(/^-+/, "")}`;
  const trimmed = startsValid.slice(0, 32).replace(/-+$/, "");
  return trimmed || "a";
}

/**
 * Coder, reviewer and triage dispatches for one issue all pass the same spec.slug — without
 * a role tag here, herdrAgentName(spec.slug) alone collapses all three onto the identical
 * pane name, so a reviewer or triage dispatch would reuse the coder's herdr pane (and, were
 * two of them ever dispatched concurrently for the same issue, race for it) instead of each
 * getting its own claude instance. Each role gets a short, fixed tag so the three are never
 * the same name for the same issue.
 */
const HERDR_ROLE_TAGS = {
  "crew-coder": "coder",
  "crew-code-reviewer": "review",
  "crew-triage": "triage",
};

function herdrRoleTag(agent) {
  return HERDR_ROLE_TAGS[agent] ?? (herdrAgentName(agent).slice(0, 8) || "agent");
}

/**
 * herdrAgentName truncates a label to 32 chars with nothing to disambiguate what got cut —
 * two different issues (two different coders dispatched concurrently by mapPool, or two
 * different reviewers/triages) whose slugs happen to share the same truncated prefix would
 * otherwise land on the identical herdr name and race for the same pane. A 6-hex-char hash
 * of the *untruncated* raw label, appended after truncation, makes that collision astronomically
 * unlikely without needing every dispatch to see every other slug in the round.
 */
function herdrUniqueSuffix(raw) {
  return createHash("sha1").update(raw || "").digest("hex").slice(0, 6);
}

/**
 * herdrAgentName(label) with a role tag appended, so a human scanning `herdr agent list`
 * can tell coder/review/triage apart at a glance — e.g. `implement-user-auth-coder`. Most
 * issue slugs fit alongside their tag well within herdr's 32-char cap, so the common case
 * stays fully readable with no decoration beyond the tag. Only when the label is long enough
 * that fitting it in would truncate two different labels down to the same prefix (or the same
 * label's own truncation would drop the disambiguating tail) does a 6-hex-char hash of the
 * *untruncated* label get appended — trading readability for collision-safety only when
 * truncation actually makes it necessary.
 *
 * issueNumber, when given (the issue file's own `NN-` prefix — see tracker.mjs's
 * issueNumber()), is prepended so panes for the same feature sort and scan by issue, the same
 * way the issue tracker's own files do — e.g. `i42-implement-user-auth-coder`. Led with `i`
 * because herdr's name regex requires a leading letter, so a bare digit can't start the name.
 *
 * round, when given, is inserted the same way (`r3-`) — a kept-open failed pane (see
 * CREW_HERDR_KEEP_PANE's new default in dispatchViaHerdr) still holds its herdr agent name
 * until something closes it, so the *next* round's fresh dispatch for the same issue+role
 * needs a name distinct from that still-live one to avoid `agent_name_taken`. Omitted only
 * by a caller reusing a specific already-open pane (spec.herdrReuse carries that pane's own
 * name forward instead of asking this function to recompute it — see dispatchViaHerdr).
 */
export function herdrDispatchName(label, agent, issueNumber, round) {
  const tag = herdrRoleTag(agent);
  const prefix = issueNumber ? `i${issueNumber}-` : "";
  const roundTag = round ? `r${round}-` : "";
  const full = herdrAgentName(label);
  const budgetNoHash = Math.max(1, 32 - prefix.length - roundTag.length - tag.length - 1);
  if (full.length <= budgetNoHash) return `${prefix}${roundTag}${full}-${tag}`;

  const suffix = herdrUniqueSuffix(label);
  const budget = Math.max(1, 32 - prefix.length - roundTag.length - tag.length - suffix.length - 2);
  const base = full.slice(0, budget).replace(/-+$/, "") || "a";
  return `${prefix}${roundTag}${base}-${tag}-${suffix}`;
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
 * `agent prompt --wait`'s own contract admits it "does not track turns": if the pane was
 * already working when this dispatch's prompt landed, --wait can settle on that *earlier*
 * turn's idle/done transition instead of this one's. The `agent read --source
 * recent-unwrapped` that follows then rejects with agent_not_idle — recent-unwrapped needs
 * the pane idle to scroll its alt-screen buffer — putting a JSON error envelope on stdout
 * instead of rendered text (the one case where `agent read` doesn't return raw pane text; see
 * herdrJson's doc comment). extractHerdrReply finds no echoed prompt in that JSON and returns
 * "", indistinguishable from a pane that genuinely rendered nothing. Naming the one error code
 * that means "still working, not blank" lets the retry loop below wait out the actual
 * remaining work instead of burning the short flush-lag backoff meant for a different failure
 * mode and reporting a false empty reply.
 */
function herdrReadNotIdle(readResult) {
  return herdrJson(readResult)?.error?.code === "agent_not_idle";
}

// Polling interval while waiting out a live agent_not_idle — coarser than the flush-lag
// backoff (HERDR_READ_RETRY_DELAY_MS) since this is waiting on actual agent work, not a
// terminal render catching up.
const HERDR_NOT_IDLE_POLL_MS = 2_000;

/**
 * Polls `agent get` until agent_status settles to idle, done, or blocked, or the deadline
 * passes. blocked is a stopping condition too, not something to wait out: unlike idle/done
 * it doesn't arrive from work finishing, so a pane that lands there stays there until a
 * human (or a keystroke this file already knows to send — see the trust-dialog handling
 * above) answers it. Polling past that would just spend the rest of the deadline for no
 * reason. Returns the settled status string, or null if the deadline passed first.
 */
async function waitForHerdrIdle(effects, name, deadline) {
  while (Date.now() < deadline) {
    const get = await herdrExec(effects, ["agent", "get", name]);
    if (get.code !== 0) return null;
    const status = herdrJson(get)?.result?.agent?.agent_status;
    if (status === "idle" || status === "done" || status === "blocked") return status;
    await new Promise((r) => setTimeout(r, HERDR_NOT_IDLE_POLL_MS));
  }
  return null;
}

/**
 * Sidecar-first completion signal for a herdr dispatch: a file on disk beats scraping the
 * pane's rendered text, since it isn't subject to render lag, echo/marker glyph drift, or
 * ANSI noise the way extractHerdrReply is — it's the same `<slug>.report.json` sidecar
 * pipeline.mjs already reads for the headless path, just checked here before falling back
 * to the pane-read chain. Still has to guard against `--wait`'s own "does not track turns"
 * gap (see waitForHerdrIdle's doc comment): a fast idle/done settle can still land while the
 * agent is minutes from actually writing the file, so this polls agent_status the same way,
 * testing for the file each pass rather than for text. Returns "found" once the file exists,
 * "blocked" on a mid-turn dialog, or "absent" once the pane genuinely settles idle/done (or
 * the deadline passes) with no file — the caller falls back to the pane-scrape chain only in
 * that last case, since the file might never come (an older agent build, a crash, a
 * final-message-only reply the prompt's own fallback wording explicitly allows for).
 */
async function waitForSidecarReport(effects, reportPath, name, deadline) {
  while (Date.now() < deadline) {
    if (existsSync(reportPath)) return "found";
    const get = await herdrExec(effects, ["agent", "get", name]);
    if (get.code !== 0) return "absent";
    const status = herdrJson(get)?.result?.agent?.agent_status;
    if (status === "blocked") return "blocked";
    if (status === "idle" || status === "done") {
      // The file write and this status settle can race by a beat — one last direct check
      // before giving up on the sidecar rather than falling back on that alone.
      return existsSync(reportPath) ? "found" : "absent";
    }
    await new Promise((r) => setTimeout(r, HERDR_NOT_IDLE_POLL_MS));
  }
  return existsSync(reportPath) ? "found" : "absent";
}

/**
 * Every `agent read` call in the retry loop below goes through here rather than calling
 * herdrExec directly, so the agent_not_idle recovery only has to be written once. On that
 * error code, waits for the pane to actually settle (bounded by this dispatch's own
 * deadline, not another fixed retry budget) and reads again — the second read's stdout is
 * returned as-is even if it's still an error envelope (deadline exceeded), since that's a
 * real failure the caller's existing empty-reply handling already reports correctly.
 */
async function herdrReadSettled(effects, name, deadline) {
  let result = await herdrExec(effects, ["agent", "read", name, "--source", "recent-unwrapped", "--lines", "400"]);
  if (herdrReadNotIdle(result)) {
    await waitForHerdrIdle(effects, name, deadline);
    result = await herdrExec(effects, ["agent", "read", name, "--source", "recent-unwrapped", "--lines", "400"]);
  }
  return result.stdout || "";
}

/**
 * Pull the assistant's reply out of `agent read`'s rendered pane text. There is no
 * structured field here (unlike extractFinalText's clean `.result`), so this is a
 * text-window heuristic — the reply sits between the echoed prompt and some trailing
 * status marker, but exactly what marks each is per-platform TUI rendering, not a herdr
 * contract. Two shapes, verified against real transcripts:
 *
 *   - claude/copilot echo the prompt on a line starting with `❯` (copilot appends a
 *     right-aligned timestamp on the same line, hence startsWith rather than an exact
 *     match) and settle behind a status line: claude's `✻ Worked for …`, copilot's
 *     bottom input box (a `─{5,}` rule, immediately after a status bar ending in the
 *     credit-usage text "AIC used").
 *   - pi echoes the literal prompt with no marker glyph at all, and settles behind its
 *     own `─{5,}` rule pair before the cwd/branch status line.
 *
 * codex has no verified transcript (no credentials to get one when this was built) —
 * it falls back to pi's glyph-less shape as the closest documented approximation, not a
 * confirmed one; revise this branch once someone runs it against a real session.
 */
function herdrIsEchoLine(line, promptFirstLine, platform) {
  if (platform === "claude") return line.startsWith("❯") && line.slice(1).trim() === promptFirstLine;
  if (platform === "copilot") return line.startsWith("❯") && line.slice(1).trim().startsWith(promptFirstLine);
  return line === promptFirstLine; // pi, and codex's unverified fallback
}

/**
 * Diagnostic-only sibling of extractHerdrReply's own echo detection, shared via
 * herdrIsEchoLine rather than duplicated: reports whether the echoed prompt appears
 * *anywhere* in a captured render, regardless of whether a trailing end marker was ever
 * found after it. Feeds the outEmpty DISPATCH-FAIL log so a genuinely missing echo (the
 * read's --lines window too small, or the pane on an alternate screen per herdr's own
 * `--skill` caveat) is distinguishable from an echo that's present but whose end-marker
 * pattern didn't match this platform's actual rendering — two different bugs that would
 * otherwise both just read as "empty reply".
 */
function herdrEchoFound(rendered, promptText, platform) {
  const promptFirstLine = (promptText || "").split("\n", 1)[0].trim();
  return (rendered || "").split("\n").some((l) => herdrIsEchoLine(l.trim(), promptFirstLine, platform));
}

export function extractHerdrReply(rendered, promptText, platform = "claude") {
  const lines = (rendered || "").split("\n");
  const promptFirstLine = (promptText || "").split("\n", 1)[0].trim();
  const echoIndex = lines.findLastIndex((l) => herdrIsEchoLine(l.trim(), promptFirstLine, platform));
  if (echoIndex === -1) return "";
  const rest = lines.slice(echoIndex + 1);
  const isEnd = (l) => {
    if (/^─{5,}/.test(l.trim())) return true;
    if (platform === "claude") return /^\s*✻\s/.test(l);
    if (platform === "copilot") return /AIC used/.test(l);
    return false;
  };
  const endIndex = rest.findIndex(isEnd);
  const body = endIndex === -1 ? rest : rest.slice(0, endIndex);
  return body
    .map((l) => l.replace(/^\s*[●○!✗]\s?/, ""))
    .filter((l) => l.trim().length > 0)
    .join("\n")
    .trim();
}

function escapeHerdrRegex(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/**
 * Same trailing status markers extractHerdrReply's isEnd() looks for, expressed as a Rust
 * regex fragment for `herdr pane wait-output` — a separate, parallel definition rather than
 * a shared one, so this doesn't reshape isEnd()'s already-verified-against-real-transcripts
 * matching. Update both if a platform's rendering ever changes.
 */
function herdrEndMarkerPattern(platform) {
  const rule = "─{5,}";
  if (platform === "claude") return `(${rule}|✻\\s)`;
  if (platform === "copilot") return `(${rule}|AIC used)`;
  return rule; // pi, and codex's unverified fallback
}

/**
 * Anchors on this dispatch's own echoed prompt, not just any trailing status marker, so
 * `pane wait-output` can't lock onto a stale echo+marker pair a prior turn left in the same
 * pane — see the reusingPane guard at its one call site, in dispatchViaHerdr.
 */
function herdrReplyReadyPattern(promptText, platform) {
  const promptFirstLine = (promptText || "").split("\n", 1)[0].trim();
  const escaped = escapeHerdrRegex(promptFirstLine);
  const echo = platform === "pi" || platform === "codex" ? escaped : `❯\\s*${escaped}`;
  return `${echo}[\\s\\S]*?${herdrEndMarkerPattern(platform)}`;
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
 * A second tab in the shared workspace, alongside the workspace itself, that just tails the
 * sprint's own trace log — the same file every dispatch's [DISPATCH-FAIL] line already lands
 * in (see dispatch()'s onTrace/logFile handling). Without it, watching a sprint live means
 * either tailing that file from a separate terminal or reading a dispatch's own pane, which
 * only ever shows that one worker's turn, not the orchestrator's round-by-round narration.
 * Best-effort: a broken log tab is cosmetic, not a reason to fail every dispatch this run —
 * unlike the dispatch's own tab, nothing downstream reads this one back.
 */
async function ensureHerdrLogTab(effects, workspaceId, label, logFile) {
  try {
    const create = await herdrExec(effects, [
      "tab",
      "create",
      "--workspace",
      workspaceId,
      "--cwd",
      effects.mainRoot,
      "--label",
      `${label}-log`,
      "--no-focus",
    ]);
    const paneId = herdrJson(create)?.result?.root_pane?.pane_id;
    if (create.code !== 0 || !paneId) return;
    await herdrExec(effects, ["pane", "run", paneId, "tail", "-f", logFile]);
  } catch {
    /* the sprint's own dispatch tabs are what matters; a broken log tab is cosmetic */
  }
}

/**
 * The triggering pane's own tab still shows whatever it was called before crew-afk started
 * running in it (often the literal "crew-afk" the human typed to launch it) — herdr injects
 * that pane's tab as `HERDR_TAB_ID` alongside `HERDR_WORKSPACE_ID`, so this is the one chance
 * to relabel it to the sprint's feature slug the same way a freshly created workspace already
 * is (see herdrWorkspaceLabel). Skipped when no feature slug resolved: relabelling someone's
 * own tab to the "crew-afk" fallback would just clobber a title they chose with no gain. Best
 * effort like ensureHerdrLogTab — a failed rename is cosmetic, not a reason to fail the run.
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
 * as a promise, not a plain field: mapPool dispatches concurrently, and the promise is
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
 * `featureSlug`/`logFile` are only consulted by whichever call actually creates the
 * workspace — every dispatch this run passes the same sprint's values, so which one wins
 * the race makes no difference.
 */
function ensureHerdrWorkspace(effects, { featureSlug, logFile } = {}) {
  if (!effects._herdrWorkspace) {
    effects._herdrWorkspace = (async () => {
      const triggeringWorkspaceId = process.env.HERDR_WORKSPACE_ID;
      if (triggeringWorkspaceId) {
        effects._herdrWorkspaceReused = true;
        await renameHerdrTriggeringTab(effects, featureSlug);
        if (logFile) await ensureHerdrLogTab(effects, triggeringWorkspaceId, herdrWorkspaceLabel(featureSlug), logFile);
        return triggeringWorkspaceId;
      }
      const label = herdrWorkspaceLabel(featureSlug);
      const create = await herdrExec(effects, ["workspace", "create", "--cwd", effects.mainRoot, "--label", label, "--no-focus"]);
      const workspaceId = herdrJson(create)?.result?.workspace?.workspace_id;
      if (create.code !== 0 || !workspaceId) {
        throw new Error(`herdr workspace create failed: ${(create.stderr || create.stdout || "").trim()}`);
      }
      if (logFile) await ensureHerdrLogTab(effects, workspaceId, label, logFile);
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
 */
export async function notifyTriggeringPane(effects, message) {
  const paneId = process.env.HERDR_PANE_ID;
  if (!paneId) return;
  try {
    await herdrExec(effects, ["agent", "prompt", paneId, message]);
  } catch {
    /* best effort — see doc comment above */
  }
}

/** A scalar TOML value: `key = "value"` — the same shape dispatch-codex-agent.sh's toml_scalar reads. */
function tomlScalar(text, key) {
  const m = text.match(new RegExp(`^[ \\t]*${key}[ \\t]*=[ \\t]*(.+)$`, "m"));
  if (!m) return "";
  return m[1]
    .trim()
    .replace(/^["']/, "")
    .replace(/["'][ \t]*$/, "");
}

/** A multi-line literal TOML value: `key = '''\n...\n'''` — dispatch-codex-agent.sh's toml_multiline. */
function tomlMultiline(text, key) {
  const m = text.match(new RegExp(`^[ \\t]*${key}[ \\t]*=[ \\t]*'''[ \\t]*\\n([\\s\\S]*?)\\n[ \\t]*'''`, "m"));
  return m ? m[1] : "";
}

/**
 * dispatch-agent.sh's/dispatch-codex-agent.sh's own `--model inherit means pass nothing`
 * rule: an explicit override wins, an empty one falls back to the agent file's own model,
 * and a literal "inherit" (only possible calling dispatchViaHerdr directly, outside
 * main.mjs's own normalisation) is treated the same as empty.
 */
function effectiveHerdrModel(model, agentModel) {
  if (model && model !== "inherit") return model;
  if (!model) return agentModel || "";
  return "";
}

/**
 * The AGENT_ARG argv for `herdr agent start <name> --kind <platform> --pane <id> -- <...>`,
 * and the literal text later submitted via `agent prompt` — herdr's interactive equivalent
 * of buildDispatch's headless argv, with the -p/prompt/output-format machinery stripped:
 * the prompt is submitted once the pane is ready, not at launch.
 *
 * claude and copilot resolve `--agent <name>` themselves (see buildDispatch's own header
 * comment), so no agent-file parsing happens here for them — same flags, minus -p/prompt/
 * output-format. pi and codex have no such CLI concept: dispatch-agent.sh's and
 * dispatch-codex-agent.sh's own agent-file resolution (frontmatter tools/model,
 * developer_instructions) is reproduced here so a herdr-driven pi/codex session gets the
 * same tools/model/instructions a batch dispatch would. codex has no --append-system-prompt
 * equivalent (see dispatch-codex-agent.sh's own comment on this), so its instructions are
 * prepended to the task and submitted together as one prompt, exactly like COMBINED there.
 */
export function buildHerdrInvocation(effects, platform, spec) {
  if (platform === "claude") {
    const args = ["--permission-mode", "bypassPermissions", "--add-dir", spec.mainRoot, "--agent", spec.agent];
    if (spec.model) args.push("--model", spec.model);
    return { args, prompt: readFileSync(spec.promptFile, "utf8") };
  }

  if (platform === "copilot") {
    const args = ["--agent", spec.agent, "-C", spec.cwd, "--add-dir", spec.mainRoot, "--allow-all-tools", "--no-color"];
    if (spec.model) args.push("--model", spec.model);
    return { args, prompt: readFileSync(spec.promptFile, "utf8") };
  }

  if (platform === "pi") {
    const agentFile = resolveAgentFile("pi", spec.mainRoot, spec.agent);
    if (!agentFile) throw new Error(`pi agent definition not found for '${spec.agent}' (looked in .pi/agents and ~/.pi/agent/agents)`);
    const { frontmatter, body } = splitFrontmatter(readFileSync(agentFile, "utf8"));
    const model = effectiveHerdrModel(spec.model, frontmatter.model);
    // --approve trusts this run's project-local files outright, the same role
    // bypassPermissions/--allow-all-tools play for claude/copilot: removing the prompt
    // entirely rather than needing HERDR_DIALOGS to answer one.
    const args = ["--approve"];
    if (model) args.push("--model", model);
    if (frontmatter.tools) args.push("--tools", frontmatter.tools.replace(/[[\]"]/g, "").replace(/\s/g, ""));
    args.push("--append-system-prompt", body);
    return { args, prompt: readFileSync(spec.promptFile, "utf8") };
  }

  if (platform === "codex") {
    const agentFile = resolveAgentFile("codex", spec.mainRoot, spec.agent);
    if (!agentFile) throw new Error(`codex agent definition not found for '${spec.agent}' (looked in .codex/agents and ~/.codex/agents)`);
    const toml = readFileSync(agentFile, "utf8");
    const instructions = tomlMultiline(toml, "developer_instructions");
    if (!instructions.trim()) throw new Error(`agent definition has empty developer_instructions: ${agentFile}`);
    const sandbox = tomlScalar(toml, "sandbox_mode") || process.env.CREW_CODEX_SANDBOX || "workspace-write";
    const model = effectiveHerdrModel(spec.model, tomlScalar(toml, "model"));
    const effort = tomlScalar(toml, "model_reasoning_effort");
    const args = ["-C", spec.cwd, "-a", "never", "-s", sandbox];
    if (sandbox === "workspace-write") {
      // Workers install deps and fetch packages; a sandboxed workspace blocks network by
      // default, which would fail every dep-install step.
      args.push("-c", "sandbox_workspace_write.network_access=true");
      // Same fix as dispatch-codex-agent.sh's: a linked worktree's index lives in the main
      // repo's git dir, which the sandbox otherwise keeps read-only even with --add-dir.
      const gitCommonDirRaw = effects.gitRead(["rev-parse", "--git-common-dir"], { cwd: spec.cwd }).stdout.trim();
      const gitCommonDir = !gitCommonDirRaw
        ? ""
        : gitCommonDirRaw.startsWith("/")
          ? gitCommonDirRaw
          : join(spec.cwd, gitCommonDirRaw);
      if (gitCommonDir) args.push("-c", `sandbox_workspace_write.writable_roots=["${gitCommonDir}"]`);
    }
    if (spec.mainRoot !== spec.cwd) args.push("--add-dir", spec.mainRoot);
    if (model) args.push("--model", model);
    if (effort) args.push("-c", `model_reasoning_effort="${effort}"`);
    const task = readFileSync(spec.promptFile, "utf8");
    return { args, prompt: `${instructions}\n\n---\n\n# Task\n\n${task}` };
  }

  throw new Error(`unknown platform: ${platform}`);
}

/**
 * The herdr equivalent of dispatch(): same {code, timedOut, dryRun, stderr, text} contract,
 * same [DISPATCH-FAIL] logging, same always-leaves-a-report-file behaviour — pipeline.mjs
 * and report.mjs need no changes to call this instead. See the doc comment above for why
 * this is a separate function rather than a buildDispatch branch.
 */
export async function dispatchViaHerdr(effects, platform, spec, { timeoutMs } = {}) {
  mkdirSync(dirname(spec.outFile), { recursive: true });
  if (effects.dryRun) return { code: 0, timedOut: false, dryRun: true, stderr: "", text: "" };

  const bound = timeoutMs || 45 * 60 * 1000;
  const dispatchDeadline = Date.now() + bound;
  const label = spec.slug || spec.agent;
  // spec.herdrReuse ({tabId, paneId, name}) names a pane a prior dispatch left open (see
  // spec.herdrPersistPane below) — set only by a caller that tracked those ids itself
  // (pipeline.mjs's herdr-reuse bookkeeping), never derived here. Its own `name` rides along
  // rather than being recomputed from this call's (possibly later) spec.round: the pane is
  // still registered in herdr under whatever name it was `agent start`-ed with originally,
  // and this round's own round number has nothing to do with that. Reusing it skips
  // workspace/tab-create/agent-start entirely and goes straight to `agent prompt`, so the
  // coder's own session (files already read, decisions already made) carries into the retry
  // instead of starting cold. Never verified live against a real herdr server —
  // reusedPromptFailed below falls back to a fresh dispatch rather than trusting that
  // unverified path to fail loud.
  const name = spec.herdrReuse?.name ?? herdrDispatchName(label, spec.agent, spec.issueNumber, spec.round);
  let tabId = spec.herdrReuse?.tabId ?? null;
  let paneId = spec.herdrReuse?.paneId ?? null;
  const reusingPane = !!spec.herdrReuse;

  // Default on: a failed dispatch's tab stays open instead of closing here, so `herdr agent
  // read <name>` (or the herdr UI) can show what the pane actually rendered — otherwise the
  // transcript is gone the instant a DISPATCH-FAIL is logged, which is exactly when you'd
  // want to see it. This used to be debug-only (opt-in via CREW_HERDR_KEEP_PANE=1) because a
  // kept pane holds its herdr agent name, and a same-named retry would fail with
  // agent_name_taken — spec.round folded into `name` above is what makes that safe to default
  // on: the next round's fresh dispatch for this same issue+role gets a distinct name, never
  // the one the kept-open failed pane still holds. Set CREW_HERDR_KEEP_PANE=0 to opt back out
  // (e.g. to avoid panes piling up in unattended CI).
  const keepPaneOnFail = process.env.CREW_HERDR_KEEP_PANE !== "0";
  // spec.herdrPersistPane (set only for a herdr coder dispatch — see pipeline.mjs) defers
  // closing a *successful* dispatch's tab to the caller: verify-worktree.sh runs after this
  // returns, so at this point nobody yet knows whether the pane will be worth reusing.
  // herdrTabId/herdrPaneId ride on the return value either way so the caller can close it
  // itself once it does know.
  const persistPane = !!spec.herdrPersistPane;

  const finish = async (code, stderr, text, timedOut = false) => {
    const failed = code !== 0 || !((text ?? "").trim());
    const keepOpen = failed ? keepPaneOnFail : persistPane;
    if (tabId && !keepOpen) {
      await herdrExec(effects, ["tab", "close", tabId]);
    }
    writeFileSync(spec.outFile, text ?? "");
    if (spec.logFile && failed) {
      const kept = failed && keepPaneOnFail ? ` kept-pane=${name} pane=${paneId ?? "?"}` : "";
      appendLine(
        spec.logFile,
        `[DISPATCH-FAIL] agent=${spec.agent} herdr=1 code=${code} timedOut=${!!timedOut} outEmpty=${!((text ?? "").trim())}${kept} slug=${spec.slug ?? "?"} ${(stderr || "").trim().slice(0, 400)}`,
      );
    }
    return {
      code,
      timedOut: !!timedOut,
      dryRun: false,
      stderr: stderr ?? "",
      text: text ?? "",
      herdrTabId: tabId && keepOpen ? tabId : null,
      herdrPaneId: paneId && keepOpen ? paneId : null,
      herdrName: tabId && keepOpen ? name : null,
      // This dispatch's own attempt failed to communicate (a transport/CLI error, a timeout,
      // a rejected/blocked pane) or produced nothing usable — not whether some *later* step
      // (verify, review) went on to fail. A caller that keeps this herdrTabId open past this
      // call (pipeline.mjs's own cleanup) reads this to tell "kept because it might still be
      // reused" apart from "kept so a human can see why it failed" — the latter must never be
      // closed as a side effect of demoting the issue, or the one thing worth inspecting is
      // gone the instant the demotion runs.
      herdrFailed: failed,
    };
  };

  let invocation;
  try {
    invocation = buildHerdrInvocation(effects, platform, spec);
  } catch (err) {
    return await finish(1, err.message, "");
  }

  if (!reusingPane) {
    let workspaceId;
    try {
      workspaceId = await ensureHerdrWorkspace(effects, { featureSlug: spec.featureSlug, logFile: spec.logFile });
    } catch (err) {
      return await finish(1, err.message, "");
    }

    // One tab per dispatch, in the sprint's one shared workspace, closed in finish() (unless
    // persistPane keeps it for a caller-tracked retry) — the workspace itself outlives every
    // individual dispatch and is closed once, at the end of the whole run (see
    // closeHerdrWorkspace, called from main.mjs). CLAUDE_CODE_SESSION_ID/
    // CLAUDE_CODE_CHILD_SESSION clearing is claude-only (see buildDispatch's claude branch for
    // why): pi/codex/copilot have no equivalent parent-session inheritance documented here.
    const create = await herdrExec(effects, [
      "tab",
      "create",
      "--workspace",
      workspaceId,
      "--cwd",
      spec.cwd,
      "--label",
      label,
      ...(platform === "claude" ? ["--env", "CLAUDE_CODE_SESSION_ID=", "--env", "CLAUDE_CODE_CHILD_SESSION="] : []),
      "--env",
      `MAIN_ROOT=${spec.mainRoot}`,
      "--env",
      "CREW_ORCHESTRATED=1",
      "--no-focus",
    ]);
    const created = herdrJson(create)?.result;
    paneId = created?.root_pane?.pane_id;
    if (create.code !== 0 || !paneId) {
      return await finish(create.code || 1, `herdr tab create failed: ${(create.stderr || create.stdout || "").trim()}`, "");
    }
    tabId = created?.tab?.tab_id;

    // A one-time trust/consent dialog some platforms' interactive mode shows on a fresh repo,
    // keyed off the repository, not the literal cwd (confirmed live for claude: trusting
    // mainRoot once, then starting claude in a git worktree of that same repo, skipped the
    // dialog entirely). So this only actually answers it on whichever dispatch happens to hit
    // an untrusted repo first — every dispatch after that, in this sprint or a later one,
    // starts ready immediately and skips straight past this block. Never a blind keypress: an
    // unrecognised blocked reason is a real failure (see herdr's own --skill guidance), and a
    // platform with no HERDR_DIALOGS entry (pi never needs one — see buildHerdrInvocation's
    // --approve; codex has none verified yet) fails the same way an unmatched dialog text does.
    const start = await herdrExec(effects, ["agent", "start", name, "--kind", platform, "--pane", paneId, "--", ...invocation.args], bound);
    if (start.code !== 0) {
      if (herdrJson(start)?.error?.code !== "agent_not_ready") {
        return await finish(start.code || 1, `herdr agent start failed: ${(start.stderr || start.stdout || "").trim()}`, "", start.timedOut);
      }
      // Unlike every other herdr subcommand used here, `agent read`/`pane read` print raw
      // rendered text on stdout, never a JSON envelope — confirmed live, and the reason
      // herdrJson() must not be used on this call.
      const blockedText = (await herdrExec(effects, ["agent", "read", name, "--source", "recent-unwrapped", "--lines", "40"])).stdout || "";
      const dialog = HERDR_DIALOGS[platform];
      if (!dialog || !blockedText.toLowerCase().includes(dialog.match)) {
        return await finish(1, `herdr agent start blocked on an unrecognised dialog: ${blockedText.trim().slice(0, 300)}`, "");
      }
      await herdrExec(effects, ["agent", "send-keys", name, ...dialog.keys]);
      const deadline = Date.now() + Math.min(bound, 30_000);
      let ready = false;
      while (Date.now() < deadline) {
        const get = await herdrExec(effects, ["agent", "get", name]);
        if (get.code !== 0) break;
        if (herdrJson(get)?.result?.agent?.interactive_ready) {
          ready = true;
          break;
        }
        // A live run against a real server hammered it with a spawnSync call every tick
        // here before this existed — hundreds of polls in the ~2s claude actually took to
        // settle after `send-keys`. 300ms keeps the poll responsive without doing that again.
        await new Promise((r) => setTimeout(r, 300));
      }
      if (!ready) return await finish(1, "herdr agent never became ready after answering the trust dialog", "");
    }
  }

  // --until idle --until done, not the default (idle/done/blocked/unknown all match): herdr's
  // own docs recommend this pairing for automation, "to differentiate between truly finished
  // work and intermediate idle states" — and without it, a pane sitting at any blocking dialog
  // this file doesn't already know to answer would settle the wait and read back as a mundane
  // empty reply, indistinguishable from a worker that produced nothing. Excluding "blocked"
  // means such a pane now runs out the clock on --timeout instead, a real, loggable failure.
  const promptResult = await herdrExec(
    effects,
    ["agent", "prompt", name, invocation.prompt, "--wait", "--until", "idle", "--until", "done", "--timeout", String(bound)],
    bound + HERDR_CLI_KILL_GRACE_MS,
  );

  // The reused pane may no longer exist (herdr restarted, a human closed it by hand) — this
  // is the only place that finds out, since reusingPane skipped every earlier check that
  // would otherwise have caught it. Retried exactly once, as a normal fresh dispatch, rather
  // than failing the whole round over an optimisation that didn't pan out.
  if (reusingPane && promptResult.code !== 0 && herdrJson(promptResult)?.error?.code === "agent_not_found") {
    tabId = null;
    paneId = null;
    return await dispatchViaHerdr(effects, platform, { ...spec, herdrReuse: null }, { timeoutMs });
  }

  // spec.reportPath (the same <slug>.report.json sidecar the headless path and
  // pipeline.mjs's post-dispatch parse both already prefer over prose) is checked before
  // any pane read is attempted: when the agent wrote it, that file is the reliable result,
  // and every retry/backoff/echo-matching step below exists only to reconstruct the same
  // information out of a terminal render — so skip straight to success and leave the pane
  // scrape chain as a fallback for the one case it still earns its keep: the agent settled
  // without ever writing the file.
  if (spec.reportPath && promptResult.code === 0) {
    const sidecarState = await waitForSidecarReport(effects, spec.reportPath, name, dispatchDeadline);
    if (sidecarState === "blocked") {
      const tail = await herdrReadSettled(effects, name, dispatchDeadline);
      return await finish(1, `herdr pane blocked mid-turn: ${tail.trim().slice(-400)}`, "");
    }
    if (sidecarState === "found") {
      // Wrapped in a fenced json block, not handed back bare: outFile's text is not only
      // pipeline.mjs's own input (which re-reads the sidecar file itself anyway, same as
      // the headless path) but also, for review, the raw block appended verbatim to the
      // round's aggregate report file — parseReviewAggregate (and crew-summary.sh/
      // promote-findings.sh through it) only ever looks for a fenced json block with a
      // `verdict` field in that text, never at a sidecar. A bare placeholder here would
      // silently drop this branch's verdict from that aggregate.
      let sidecarText = "";
      try {
        sidecarText = readFileSync(spec.reportPath, "utf8").trim();
      } catch {
        sidecarText = "";
      }
      const wrapped = sidecarText ? "```json\n" + sidecarText + "\n```" : `(structured result written to ${spec.reportPath})`;
      return await finish(0, "", wrapped);
    }
    // "absent": the pane settled idle/done with no sidecar file — fall through to the
    // pane-scrape chain below on the chance the reply landed in prose only.
  }

  let rendered = await herdrReadSettled(effects, name, dispatchDeadline);
  let text = extractHerdrReply(rendered, invocation.prompt, platform);
  let attempt = 1;

  // herdr's own idle/done detector already said this pane settled successfully — an empty
  // extractHerdrReply() here means a later `agent read` call caught the pane's rendering
  // before it caught up (buffered terminal flush lag), not that the dispatch failed. Rather
  // than guess with a fixed delay, actively wait for this dispatch's own echoed prompt and
  // its trailing status marker to actually appear in the exact snapshot `agent read` uses
  // next — once matched, the full reply is provably present, not just probably. Skipped on a
  // reused pane: its buffer already carries a prior turn's echo+marker (see
  // herdrReplyReadyPattern's doc comment).
  if (promptResult.code === 0 && !text.trim() && !reusingPane) {
    await herdrExec(effects, [
      "pane",
      "wait-output",
      paneId,
      "--regex",
      herdrReplyReadyPattern(invocation.prompt, platform),
      "--source",
      "recent-unwrapped",
      "--lines",
      "400",
      "--timeout",
      String(HERDR_WAIT_OUTPUT_TIMEOUT_MS),
    ]);
    attempt++;
    rendered = await herdrReadSettled(effects, name, dispatchDeadline);
    text = extractHerdrReply(rendered, invocation.prompt, platform);
  }

  // Fallback for whatever the wait-output step above didn't cover — a reused pane, or an
  // echo/marker pattern that doesn't match this platform's actual rendering. Same fixed-delay
  // backoff as before, just resuming from whichever attempt the step above already spent.
  while (promptResult.code === 0 && !text.trim() && attempt < HERDR_READ_MAX_ATTEMPTS) {
    attempt++;
    await new Promise((r) => setTimeout(r, HERDR_READ_RETRY_DELAY_MS * (attempt - 1)));
    rendered = await herdrReadSettled(effects, name, dispatchDeadline);
    text = extractHerdrReply(rendered, invocation.prompt, platform);
  }

  // Every retry above assumed the reply was already there, just not rendered yet — the same
  // assumption herdrReadSettled makes when a *read* comes back agent_not_idle. But a read can
  // also come back with no error at all and still catch nothing but the pane's live status
  // footer: --wait's own "does not track turns" gap means the coder can still be minutes into
  // active tool calls when it settled early, long past wait-output's 10s timeout and this
  // fixed backoff's few seconds. Ask `agent get` directly rather than assume: a busy status
  // means text is absent because the turn is still running, not because it produced nothing,
  // so wait it out (bounded by this dispatch's own deadline) and read again — repeating for as
  // long as the pane keeps reporting busy, so a genuinely long-running turn is never cut off
  // early. Once status itself reports idle/done with text still empty, that's a real empty
  // reply, not a race, and the loop below stops. A status of blocked fails immediately
  // instead of polling: a dialog appearing sometime after --wait's stale match already
  // settled the prompt call needs an answer, not more waiting, and nothing here would make
  // it resolve on its own before the deadline — see waitForHerdrIdle's doc comment.
  // lastKnownStatus rides into the outEmpty message below purely for diagnosis: it says
  // whether the pane was genuinely idle/done (a real empty reply) or this loop simply ran
  // out of deadline while still busy, without guessing from the rendered tail alone.
  let lastKnownStatus = null;
  while (promptResult.code === 0 && !text.trim() && Date.now() < dispatchDeadline) {
    const get = await herdrExec(effects, ["agent", "get", name]);
    const status = herdrJson(get)?.result?.agent?.agent_status;
    lastKnownStatus = status ?? lastKnownStatus;
    if (get.code !== 0 || status === "idle" || status === "done") break;
    if (status === "blocked") {
      rendered = await herdrReadSettled(effects, name, dispatchDeadline);
      return await finish(1, `herdr pane blocked mid-turn: ${rendered.trim().slice(-400)}`, "");
    }
    const settled = await waitForHerdrIdle(effects, name, dispatchDeadline);
    lastKnownStatus = settled ?? lastKnownStatus;
    if (settled === "blocked") {
      rendered = await herdrReadSettled(effects, name, dispatchDeadline);
      return await finish(1, `herdr pane blocked mid-turn: ${rendered.trim().slice(-400)}`, "");
    }
    rendered = await herdrReadSettled(effects, name, dispatchDeadline);
    text = extractHerdrReply(rendered, invocation.prompt, platform);
  }

  if (promptResult.code !== 0) {
    const errorCode = herdrJson(promptResult)?.error?.code;
    // promptResult.timedOut is spawnWithTimeout's own signal that *our* SIGKILL fired
    // (effects.mjs) — checked in addition to herdr's self-reported error code because that
    // JS-side kill has a grace period past herdr's own --timeout (HERDR_CLI_KILL_GRACE_MS)
    // specifically so herdr gets to report a stall first, but if herdr never does (hung
    // client, dead server) our kill is still the reason this call ended and should still log
    // as a timeout rather than a silent, code-less failure.
    const timedOut = promptResult.timedOut || errorCode === "agent_prompt_stalled" || errorCode === "timeout";
    // agent_blocked: herdr rejects the submission outright, before sending any input, when
    // the pane was already blocked — extractHerdrReply finds nothing (the prompt was never
    // echoed), so without this the failure reads as an empty reply with no clue why. Read
    // the rendered pane directly into the failure message instead of just the CLI's own
    // stderr, which never contains the dialog text itself.
    if (errorCode === "agent_blocked") {
      return await finish(promptResult.code, `herdr agent prompt rejected — agent already blocked: ${rendered.trim().slice(-400)}`, text, timedOut);
    }
    const rawError = (promptResult.stderr || promptResult.stdout || "").trim();
    const message = rawError ? `herdr agent prompt failed: ${rawError}` : await describeHerdrUnavailability(effects);
    return await finish(promptResult.code, message, text, timedOut);
  }
  // Every retry above (the anchored wait-output check, then the fixed-delay backoff) is
  // built on one assumption: the reply is there, just not rendered yet. If text is still
  // empty here, that assumption already failed once — worth knowing whether the pane was
  // genuinely blank (real flush lag outlasting every retry) or had content extractHerdrReply
  // just couldn't match (an echo/marker pattern out of sync with this platform's actual
  // rendering — a different bug, and one this snippet is the only way to ever notice).
  if (!text.trim()) {
    const tail = rendered.trim().slice(-400);
    const statusNote = lastKnownStatus ? ` last agent_status=${lastKnownStatus}` : "";
    // lines/echoFound distinguish a capture the --lines window missed entirely (echoFound=no
    // — see herdrEchoFound's doc comment) from one that has the echo but didn't match the
    // trailing end-marker pattern (echoFound=yes) — the tail alone can't tell them apart,
    // since it's always just the pane's last 400 rendered characters either way.
    const lineCount = rendered ? rendered.split("\n").length : 0;
    const echoFound = herdrEchoFound(rendered, invocation.prompt, platform) ? "yes" : "no";
    return await finish(
      0,
      `herdr pane read empty after every retry${statusNote} lines=${lineCount} echoFound=${echoFound} — tail: ${tail || "(pane rendered nothing)"}`,
      text,
    );
  }
  return await finish(0, "", text);
}

/**
 * Explicit close for a pane a caller kept open via spec.herdrPersistPane (see
 * dispatchViaHerdr's finish()) — the herdr-reuse bookkeeping in pipeline.mjs calls this once
 * it knows the pane will not be reused again (verify passed, or the one retry is spent).
 * A no-op when tabId is falsy, so a caller that never persisted a pane can call this
 * unconditionally without checking first.
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
  if (spec.herdr && !process.env.CREW_FAKE_DISPATCH) {
    return await dispatchViaHerdr(effects, platform, spec, { timeoutMs });
  }
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
          appendLine(spec.logFile, `[${traceTimestamp()}]${slugTag} ${trace}`);
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

  if (built.jsonEvents && !r.dryRun) {
    writeFileSync(`${spec.outFile}.events.jsonl`, lines.length ? `${lines.join("\n")}\n` : "");
    // report.mjs reads outFile as the worker's final message text, not the event stream.
    writeFileSync(spec.outFile, extractFinalText(built.jsonEvents, lines));
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
  if (spec.logFile && !r.dryRun && (r.code !== 0 || r.timedOut || !text.trim())) {
    const stderrSnippet = (r.stderr ?? "").trim().slice(0, 500).replace(/\s+/g, " ");
    appendLine(
      spec.logFile,
      `[DISPATCH-FAIL] agent=${spec.agent} slug=${spec.slug ?? "?"} code=${r.code} timedOut=${!!r.timedOut} outEmpty=${!text.trim()} stderr=${JSON.stringify(stderrSnippet || "(none)")}`,
    );
  }

  return {
    code: r.code,
    timedOut: !!r.timedOut,
    dryRun: !!r.dryRun,
    stderr: r.stderr ?? "",
    text,
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
  const home = homedir();
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
 * HERDR_ENV=1 applies to whichever --platform the sprint runs (see
 * dispatchViaHerdr's doc comment — herdr's own --kind already covers all four), so this
 * check fails the sprint at startup with one clear message, rather than every dispatch
 * discovering mid-round that herdr's CLI or server isn't there.
 */
/**
 * Only called from dispatchViaHerdr's generic `agent prompt` failure branch, and only when
 * that failure came with no stdout/stderr at all to explain it — preflightHerdr already
 * proved the server was up once, at sprint start, but that says nothing about whether it's
 * still up minutes or hours later when one particular dispatch's prompt call dies silently.
 * Without this, "the herdr server crashed/restarted mid-sprint" and "herdr rejected this one
 * call for a reason it just didn't print" log identically — an empty DISPATCH-FAIL line with
 * no way to tell which retrying would fix.
 */
async function describeHerdrUnavailability(effects) {
  const status = await herdrExec(effects, ["status"], HERDR_STATUS_CHECK_TIMEOUT_MS);
  if (status.timedOut) {
    return "herdr agent prompt failed with no output, and `herdr status` itself timed out — the herdr server looks unresponsive";
  }
  if (status.code !== 0 || !/status:\s*running/.test(status.stdout || "")) {
    const detail = (status.stderr || status.stdout || "").trim().slice(0, 200);
    return `herdr agent prompt failed with no output, and \`herdr status\` no longer reports running — the herdr server may have crashed or restarted mid-sprint${detail ? `: ${detail}` : ""}`;
  }
  return "herdr agent prompt failed with no output, though the herdr server still reports running — likely a transport or session-specific issue with this one pane, not a dead server";
}

function preflightHerdr(effects) {
  const which = effects.exec("sh", ["-c", "command -v herdr"], { mutating: false });
  if (which.code !== 0) return ["HERDR_ENV=1 but the herdr CLI was not found on PATH"];
  const status = effects.exec("herdr", ["status"], { mutating: false });
  if (status.code !== 0 || !/status:\s*running/.test(status.stdout || "")) {
    return ["HERDR_ENV=1 but the herdr server is not running — start it with: herdr server"];
  }
  return [];
}
