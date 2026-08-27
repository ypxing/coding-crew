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
  const { agent, cwd, promptFile, outFile, model, mainRoot, logFile, scriptsDir } = spec;
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

function capJson(value) {
  try {
    return JSON.stringify(value ?? {}).slice(0, 200);
  } catch {
    return "{}";
  }
}

/**
 * One [TOOL]/[TOOL-ERROR] line per recognised event, or null for everything else
 * (message text deltas, session bookkeeping, a line that failed to parse) — the same
 * "observability must never fail the dispatch" rule dispatch-agent.sh's and
 * dispatch-codex-agent.sh's trace_event follow. Claude's shape is the standard Anthropic
 * Messages content-block schema (`assistant.message.content[]` carries `tool_use`/
 * `tool_result` blocks); copilot's is copilot-sdk's own generated session-events.d.ts
 * (`tool.execution_start`/`tool.execution_complete`).
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
          return `[TOOL] agent=${agent} tool=${block.name} args=${capJson(block.input)}`;
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
      return `[TOOL] agent=${agent} tool=${evt.data?.toolName ?? "?"} args=${capJson(evt.data?.arguments)}`;
    }
    if (evt.type === "tool.execution_complete" && evt.data?.success === false) {
      return `[TOOL-ERROR] agent=${agent} toolCallId=${evt.data?.toolCallId ?? "?"} error=${capJson(evt.data?.error?.message)}`;
    }
    return null;
  }
  return null;
}

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
 * Run one dispatch to completion. Always leaves a report file on disk (empty when the
 * child produced nothing), because "no report" is a state the pipeline must be able
 * to read rather than infer.
 */
export async function dispatch(effects, platform, spec, { timeoutMs } = {}) {
  const built = buildDispatch(platform, spec);
  mkdirSync(dirname(spec.outFile), { recursive: true });

  // claude's stream-json and copilot's json visibility: read the child's NDJSON one line
  // at a time as it arrives, the same way dispatch-agent.sh/dispatch-codex-agent.sh do for
  // pi/codex. A recognised tool call becomes a `[TOOL]`/`[TOOL-ERROR]` line in spec.logFile
  // *while the worker is still running*; every raw line is also kept, for post-hoc
  // debugging, next to outFile as `<outFile>.events.jsonl`. onLine is only wired when
  // jsonEvents is set, so this is a no-op for the CREW_FAKE_DISPATCH seam (which returns
  // before jsonEvents is ever assigned) and for any platform with no event stream.
  //
  // effects.spawnWithTimeout's onLine is misnamed: it hands back raw stdout chunks, not
  // lines — a long JSON line can arrive split across two chunks. lineBuffer holds the
  // trailing partial line between calls; only complete lines (newline-terminated) are
  // processed as they arrive, and any remainder left after the child closes is flushed
  // once, below, the same as a final chunk with an implicit trailing newline.
  const lines = [];
  let lineBuffer = "";
  const consumeLine = (line) => {
    if (!line.trim()) return;
    lines.push(line);
    const trace = formatJsonTraceLine(built.jsonEvents, spec.agent, line);
    if (trace && spec.logFile) appendLine(spec.logFile, trace);
  };
  const onLine = built.jsonEvents
    ? (chunk) => {
        lineBuffer += String(chunk);
        const parts = lineBuffer.split("\n");
        lineBuffer = parts.pop();
        for (const line of parts) consumeLine(line);
      }
    : undefined;

  const r = await effects.spawnWithTimeout(built.cmd, built.args, {
    cwd: built.cwd,
    env: built.env,
    timeoutMs,
    onLine,
  });
  if (built.jsonEvents) consumeLine(lineBuffer);

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
      `[DISPATCH-FAIL] agent=${spec.agent} code=${r.code} timedOut=${!!r.timedOut} outEmpty=${!text.trim()} stderr=${JSON.stringify(stderrSnippet || "(none)")}`,
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
export function preflight(effects, platform, mainRoot, agents) {
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
  return problems;
}
