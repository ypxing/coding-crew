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
 * pi and codex run through bash dispatchers that resolve the agent definition and map its
 * frontmatter onto CLI flags; claude and copilot resolve their own agent by name.
 *
 * All four emit a JSON event stream. Recognised tool calls become `[TOOL]`/`[TOOL-ERROR]`
 * lines in the trace log while the worker runs; the raw stream is kept as
 * `<outFile>.events.jsonl`, and only the final assistant text goes into outFile (the one
 * thing report.mjs parses).
 *
 * claude (2.1.221) and copilot (1.0.79): `--agent` loads the definition, binds its `tools:`
 * list, and exits 1 on an unknown name — so no body is re-sent. Copilot resolves
 * `.github/agents/` from its cwd without walking up, so a worker in a worktree only sees
 * definitions tracked in HEAD or under `~/.copilot/agents/`; preflight() checks that.
 *
 * Permissions are explicit per platform: an unattended sprint that stops on a
 * tool-permission prompt never finishes.
 */

import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { homedir } from "node:os";
import { appendLine } from "./effects.mjs";
import { preflightPaneHost, spawnDispatch } from "./pane-host/index.mjs";

export const PLATFORMS = ["pi", "codex", "claude", "copilot"];

/**
 * Default parallelism per platform. Copilot's is conservative because what binds is the
 * account's request rate, which the CLI does not expose; raise with `--max-parallel`.
 */
export const DEFAULT_PARALLEL = { pi: 3, codex: 3, claude: 3, copilot: 2 };

function agentFileCandidates(platform, mainRoot, agent) {
  // $HOME first: os.homedir() ignores a $HOME override on Windows (reads USERPROFILE).
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
  const { agent, cwd, promptFile, outFile, model, mainRoot, logFile, scriptsDir, slug, reportPath, resumeSessionId } = spec;
  const shared = { cwd, env: { MAIN_ROOT: mainRoot, CREW_ORCHESTRATED: "1" } };

  // Test/CI seam: one script stands in for every model dispatch, so the whole state
  // machine runs for zero tokens. --report-path lets it write the sidecar report.mjs reads.
  if (process.env.CREW_FAKE_DISPATCH) {
    return {
      cmd: "bash",
      args: [
        process.env.CREW_FAKE_DISPATCH,
        "--agent", agent,
        "--runtime", platform,
        "--dir", cwd,
        "--prompt-file", promptFile,
        "--out", outFile,
        ...(model ? ["--model", model] : []),
        ...(slug ? ["--slug", slug] : []),
        ...(reportPath ? ["--report-path", reportPath] : []),
        ...(resumeSessionId ? ["--resume", resumeSessionId] : []),
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
    // bypassPermissions removes the *prompt*, not the allowlist: the definition's `tools:`
    // still applies. A narrower --allowedTools can't be written in advance — a worker runs
    // the consuming project's own checks.
    //
    // stream-json requires --verbose, or claude refuses to start. Its final `result` line
    // carries the agent's last answer in `.result`.
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
    // A fix round continuing the coder's own earlier session (pipeline.mjs decides when).
    if (resumeSessionId) args.push("--resume", resumeSessionId);
    args.push(prompt);
    // Cleared so a child launched from inside a Claude Code session starts its own session
    // instead of attaching to the parent's hook chain, which can mutate or swallow the prompt.
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
    // --allow-all-tools removes the confirmation prompt only; the definition's `tools:`
    // still binds. --add-dir: the worker reads the issue and writes its report under
    // .scratch/ in the main checkout, outside its worktree cwd. The json schema is
    // copilot-sdk's session-events.d.ts.
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

/** A capped JSON preview that says how much it cut, so truncation is never mistaken for the whole value. */
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
 * `$ <command>` for a shell call, a bare path for a file tool; null for any other shape,
 * which formatArgs renders as a capped JSON preview instead.
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
 * One [TOOL]/[TOOL-ERROR] line per recognised event, null for anything else including an
 * unparseable line — observability never fails the dispatch. No timestamp or slug;
 * dispatch() adds both.
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
    // A run that dies on an API error (auth, quota) says so only here.
    if (evt.type === "result" && evt.is_error) return `[AGENT-ERROR] agent=${agent} error=${safePreview(evt.result)}`;
    return null;
  }
  if (platform === "copilot") {
    if (evt.type === "tool.execution_start") {
      return `[TOOL] agent=${agent} tool=${evt.data?.toolName ?? "?"} ${formatArgs(evt.data?.arguments)}`;
    }
    if (evt.type === "tool.execution_complete" && evt.data?.success === false) {
      return `[TOOL-ERROR] agent=${agent} toolCallId=${evt.data?.toolCallId ?? "?"} error=${safePreview(evt.data?.error?.message)}`;
    }
    if (evt.type === "session.error") {
      return `[AGENT-ERROR] agent=${agent} type=${evt.data?.errorType ?? "?"} error=${safePreview(evt.data?.message)}`;
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
 * onTrace heartbeat throttle: every Nth tool call or every INTERVAL_MS, whichever first, so
 * the live signal to the parent stays bounded over a long worker. The bash dispatchers'
 * maybe_heartbeat applies the same rule for pi/codex.
 */
const HEARTBEAT_EVERY_N = 5;
const HEARTBEAT_INTERVAL_MS = 30_000;

/** pi's/codex's own already-throttled [TOOL]/[TOOL-ERROR] line, forwarded on their stdout. */
const BASH_HEARTBEAT = /^\[(?:TOOL|TOOL-ERROR)\] /;

/**
 * The worker's final message from the raw event lines: claude's terminal `result.result`,
 * or copilot's last `assistant.message` (it has no terminal event). Returns "" when nothing
 * is found — an empty report is a handled state, and safer than leaking raw JSONL.
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

const EMPTY_RESULT_META = {
  isError: null,
  costUsd: null,
  durationMs: null,
  numTurns: null,
  permissionDenials: [],
  sessionId: null,
  contextTokens: null,
};

/**
 * Cost, error and timing from claude's terminal `result` event (2.1.280). Claude only:
 * copilot has no equivalent event. Anything unrecognised returns the all-null shape.
 * `contextTokens` is the last assistant turn's prompt size — what a resumed session would
 * start from — not the session's cumulative usage.
 */
export function extractResultMeta(platform, lines) {
  if (platform !== "claude") return EMPTY_RESULT_META;
  let contextTokens = null;
  for (let i = lines.length - 1; i >= 0; i--) {
    try {
      const evt = JSON.parse(lines[i]);
      const u = evt.type === "assistant" ? evt.message?.usage : null;
      if (u && contextTokens == null) {
        contextTokens = (u.input_tokens ?? 0) + (u.cache_read_input_tokens ?? 0) + (u.cache_creation_input_tokens ?? 0);
      }
    } catch {
      /* skip an unparseable line */
    }
  }
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
          contextTokens,
        };
      }
    } catch {
      /* skip an unparseable line */
    }
  }
  return EMPTY_RESULT_META;
}

/**
 * Move an earlier dispatch's event stream at `file` aside, to the first free
 * `<stem>.events.<n>.jsonl`, so every attempt's stream (and its cost) outlives the retry
 * that reuses the path. The latest stays at `file`.
 */
function keepPriorEvents(file) {
  if (!existsSync(file)) return;
  const stem = file.replace(/\.events\.jsonl$/, "");
  let n = 1;
  while (existsSync(`${stem}.events.${n}.jsonl`)) n++;
  try {
    renameSync(file, `${stem}.events.${n}.jsonl`);
  } catch {
    /* overwritten below instead — the stream is debugging output, not state */
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

  // spawnWithTimeout's onLine hands back raw chunks, not lines — a long JSON line can span
  // two. lineBuffer holds the trailing partial line; the remainder is flushed after close.
  const lines = [];
  let lineBuffer = "";
  let heartbeatCount = 0;
  // Seeded to now, not 0, or the first tool call would always pass the interval check.
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
    // pi/codex (and the fake seam): the bash dispatcher writes spec.logFile itself; of its
    // stdout, only its already-throttled [TOOL] lines are heartbeats — the raw stream is not.
    if (onTrace && BASH_HEARTBEAT.test(line)) onTrace(line);
  };
  const onLine = (chunk) => {
    lineBuffer += String(chunk);
    const parts = lineBuffer.split("\n");
    lineBuffer = parts.pop();
    for (const line of parts) consumeLine(line);
  };

  const r = await spawnDispatch(effects, built.cmd, built.args, {
    cwd: built.cwd,
    env: built.env,
    timeoutMs,
    onLine,
    stem: spec.outFile,
    title: `${spec.slug ?? "crew-afk"} ${spec.agent}`,
    jsonEvents: built.jsonEvents,
    agent: spec.agent,
  });
  consumeLine(lineBuffer);

  let meta = EMPTY_RESULT_META;
  if (built.jsonEvents && !r.dryRun) {
    keepPriorEvents(`${spec.outFile}.events.jsonl`);
    writeFileSync(`${spec.outFile}.events.jsonl`, lines.length ? `${lines.join("\n")}\n` : "");
    writeFileSync(spec.outFile, extractFinalText(built.jsonEvents, lines));
    meta = extractResultMeta(built.jsonEvents, lines);
  } else if (built.capture === "stdout" && !r.dryRun) {
    writeFileSync(spec.outFile, r.stdout ?? "");
  }
  const text = existsSync(spec.outFile) ? readFileSync(spec.outFile, "utf8") : "";

  // A failure before a bash dispatcher traces anything (an early die(), ENOENT, a killed
  // child) otherwise leaves its reason only in stderr. Also fires on isError/permission
  // denials, which claude can report while still exiting 0 with text.
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
    contextTokens: meta.contextTokens,
  };
}

/**
 * An agent-less dispatch: one reasoning pass with no agent definition, for the PRD audit
 * (loop.mjs) and one-time command discovery (commands.mjs).
 *
 * Tool access is not restricted: claude's `--tools` is variadic and swallows the prompt
 * when no flag separates them.
 *
 * claude's auto-memory is disabled: each call is stateless, and the memory directory is
 * shared across every worktree, so a note written here would leak into every later session
 * unreviewed.
 */
export async function dispatchPlain(
  effects,
  platform,
  { prompt, cwd, mainRoot, model, outFile, timeoutMs, fakeAgent = "prd-audit" },
) {
  const env = {
    MAIN_ROOT: mainRoot,
    CREW_ORCHESTRATED: "1",
    ...(platform === "claude"
      ? {
          CLAUDE_CODE_DISABLE_AUTO_MEMORY: "1",
          // See buildDispatch's claude branch.
          CLAUDE_CODE_SESSION_ID: "",
          CLAUDE_CODE_CHILD_SESSION: "",
        }
      : {}),
  };

  // Same test/CI seam as buildDispatch. fakeAgent picks fake-dispatch.sh's canned answer.
  if (process.env.CREW_FAKE_DISPATCH) {
    const out = outFile ?? join(cwd, "plain-dispatch.out");
    const r = await effects.spawnWithTimeout(
      "bash",
      [
        process.env.CREW_FAKE_DISPATCH,
        "--agent", fakeAgent,
        "--runtime", platform,
        ...(model ? ["--model", model] : []),
        "--dir", cwd,
        "--out", out,
      ],
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
      // Prompt right after -p: --add-dir is variadic and would swallow a prompt following it.
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
 * Whether a worker in a worktree can see this copilot definition: tracked in HEAD, or
 * user-level. An untracked one in the main root is invisible (see the file header).
 */
function copilotWorktreeVisible(effects, mainRoot, agent) {
  // $HOME first — see agentFileCandidates.
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
export function preflight(effects, platform, mainRoot, agents, { paneHost = null } = {}) {
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
  problems.push(...preflightPaneHost(effects, paneHost));
  return problems;
}
