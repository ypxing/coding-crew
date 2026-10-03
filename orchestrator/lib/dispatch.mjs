/**
 * dispatch.mjs — four platforms, one contract.
 *
 * A dispatch is: run <agent> with <prompt> in <cwd>, capture its final message to
 * <outFile>, with a hard timeout. Every platform can do this headlessly:
 *
 *   pi       pi -p --mode json --append-system-prompt <protocol> …   (adapters/pi.mjs)
 *   codex    codex exec --cd … --json <protocol + prompt>             (adapters/codex.mjs)
 *   claude   claude -p <prompt> --append-system-prompt-file <protocol> …   (adapters/claude.mjs)
 *   copilot  copilot -p <protocol + prompt> -C … --output-format json        (adapters/copilot.mjs)
 *
 * No platform needs an agent file or a bash dispatcher: each adapter gets the role's protocol
 * rendered from orchestrator/roles/<role>.md (adapters/render.mjs) and role settings from
 * adapters/role-args.mjs.
 *
 * All four emit a JSON event stream. Recognised tool calls become `[TOOL]`/`[TOOL-ERROR]`
 * lines in the trace log while the worker runs; the raw stream is kept as
 * `<outFile>.events.jsonl`, and only the final assistant text goes into outFile (the one
 * thing report.mjs parses).
 *
 * Permissions are explicit per platform: an unattended sprint that stops on a
 * tool-permission prompt never finishes.
 */

import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { writeLog } from "./log.mjs";
import { preflightPaneHost, spawnDispatch } from "./pane-host/index.mjs";
import { ADAPTERS } from "./adapters/index.mjs";
import { ARGV_PROMPT_LIMIT_BYTES, EMPTY_RESULT_META, assertArgvPromptFits } from "./adapters/common.mjs";
import { renderRolePrompt, roleOfAgent } from "./adapters/render.mjs";

export { ARGV_PROMPT_LIMIT_BYTES, renderRolePrompt };

export const PLATFORMS = ["pi", "codex", "claude", "copilot"];

/**
 * Default parallelism per platform. Copilot's is conservative because what binds is the
 * account's request rate, which the CLI does not expose; raise with `--max-parallel`.
 */
export const DEFAULT_PARALLEL = Object.fromEntries(PLATFORMS.map((p) => [p, ADAPTERS[p].defaultParallel]));

/**
 * Build the argv for one dispatch.
 * @returns {{cmd: string, args: string[], cwd: string, env: object, capture: "stdout"|"file"}}
 */
export function buildDispatch(platform, spec) {
  const { agent, cwd, promptFile, outFile, model, mainRoot, logFile, scriptsDir, slug, reportPath, resumeSessionId, maxBudgetUsd } = spec;
  const shared = {
    cwd,
    env: {
    MAIN_ROOT: mainRoot,
    CREW_ORCHESTRATED: "1",
    // The coder defers the full suite to the verify gate; reviewer/triage never run checks.
    ...(agent === "crew-coder" ? { CREW_DEFER_FULL_CHECKS: "1" } : {}),
    },
  };

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
        ...(maxBudgetUsd ? ["--max-budget-usd", String(maxBudgetUsd)] : []),
      ],
      ...shared,
      cwd: mainRoot,
      capture: "file",
    };
  }

  const adapter = ADAPTERS[platform];
  if (!adapter) throw new Error(`unknown platform: ${platform}`);
  const role = roleOfAgent(agent);
  // Rendered here, before anything spawns: a missing protocol or fragment fails the dispatch.
  const protocol = role ? renderRolePrompt(role, platform, { mainRoot, rolesDir: spec.rolesDir }) : null;
  let prompt = readFileSync(promptFile, "utf8");
  let protocolFile = null;
  // claude takes the protocol as a system-prompt file, pi and codex place it themselves, copilot has
  // no system-prompt flag and gets it prepended.
  if (protocol && platform === "claude") {
    protocolFile = `${outFile}.protocol.md`;
    mkdirSync(dirname(protocolFile), { recursive: true });
    writeFileSync(protocolFile, protocol);
  } else if (protocol && platform === "copilot") {
    prompt = `${protocol}\n\n---\n\n${prompt}`;
  }
  // Every argv-borne string is capped; pi and codex carry the protocol in argv too.
  if (adapter.promptVia === "argv") assertArgvPromptFits(platform === "pi" || platform === "codex" ? `${protocol ?? ""}${prompt}` : prompt, adapter.cmd);
  const label = basename(promptFile, ".md").replace(/\.prompt$/, "");
  const args = adapter.argv({ cwd, mainRoot, model, role, promptFile, outFile, protocolFile, protocol: protocol ?? null, prompt, label: `${spec.agent}: ${label}` });
  // A fix round continuing the coder's own earlier session (pipeline.mjs decides when).
  if (resumeSessionId && adapter.resume) args.push(...adapter.resume(resumeSessionId));
  // afk.limits.<role>.usd: a backstop, checked after each turn, so it can overshoot one turn.
  if (maxBudgetUsd && adapter.budget) args.push(...adapter.budget(maxBudgetUsd));
  return {
    cmd: adapter.cmd,
    args,
    ...shared,
    env: { ...shared.env, ...(adapter.env ?? {}) },
    capture: "stdout",
    jsonEvents: platform,
  };
}

/**
 * One [TOOL]/[TOOL-ERROR] line per recognised event, null for anything else including an
 * unparseable line — observability never fails the dispatch. No timestamp or slug;
 * dispatch() adds both.
 */
export function formatJsonTraceLine(platform, agent, line) {
  const adapter = ADAPTERS[platform];
  if (!adapter) return null;
  let evt;
  try {
    evt = JSON.parse(line);
  } catch {
    return null;
  }
  return adapter.traceLine(evt, agent);
}

/**
 * onTrace heartbeat throttle: every Nth tool call or every INTERVAL_MS, whichever first, so
 * the live signal to the parent stays bounded over a long worker. The fake seam's
 * dispatch-time throttle applies to every platform.
 */
const HEARTBEAT_EVERY_N = 5;
const HEARTBEAT_INTERVAL_MS = 30_000;

/** The fake seam's own already-throttled [TOOL]/[TOOL-ERROR] line, forwarded on its stdout. */
const BASH_HEARTBEAT = /^\[(?:TOOL|TOOL-ERROR)\] /;

/**
 * The worker's final message from the raw event lines (the adapter knows the stream's shape).
 * Returns "" when nothing is found — an empty report is a handled state, and safer than leaking
 * raw JSONL.
 */
export function extractFinalText(platform, lines) {
  return ADAPTERS[platform]?.finalText(lines) ?? "";
}

/** Cost, error, session and timing from the stream, per the adapter; all-null where it has none (copilot). */
export function extractResultMeta(platform, lines) {
  return ADAPTERS[platform]?.resultMeta?.(lines) ?? EMPTY_RESULT_META;
}

/** The distinct tool names in claude's `permission_denials` (`tool_name`), comma-joined; `?` when unnamed. */
function deniedTools(denials) {
  const names = [...new Set(denials.map((d) => d?.tool_name ?? d?.tool ?? "?"))];
  return names.join(",");
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
  mkdirSync(dirname(spec.outFile), { recursive: true });
  const adapter = ADAPTERS[platform];
  let built;
  try {
    built = buildDispatch(platform, spec);
  } catch (e) {
    // Nothing was spawned: the failure is the answer, and no report is left to be misread.
    writeFileSync(spec.outFile, "");
    if (spec.logFile) writeLog(spec.logFile, `[DISPATCH-FAIL] agent=${spec.agent} slug=${spec.slug ?? "?"} code=1 before-spawn=true error=${JSON.stringify(e.message)}`);
    return { ...EMPTY_RESULT_META, code: 1, timedOut: false, dryRun: false, stderr: e.message, text: "", costUnknown: false };
  }

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
          // Tags after the marker, the position every other line keeps its fields in.
          const tags = `${spec.slug ? ` slug=${spec.slug}` : ""}${spec.round != null ? ` round=${spec.round}` : ""}`;
          writeLog(spec.logFile, trace.replace(/^(\[[A-Z-]+\])/, `$1${tags}`));
        }
        maybeHeartbeat(trace);
      }
      return;
    }
    // The fake seam writes spec.logFile itself; of its
    // stdout, only its already-throttled [TOOL] lines are heartbeats — the raw stream is not.
    if (onTrace && BASH_HEARTBEAT.test(line)) onTrace(line);
  };
  const onLine = (chunk) => {
    lineBuffer += String(chunk);
    const parts = lineBuffer.split("\n");
    lineBuffer = parts.pop();
    for (const line of parts) consumeLine(line);
  };

  // A CLI that writes its own final message to outFile (codex `-o`): start from none, so a stale
  // one from an earlier attempt is never read as this run's.
  const ownsOut = !!adapter?.lastMessageFile && !!built.jsonEvents && !process.env.CREW_FAKE_DISPATCH;
  if (ownsOut) writeFileSync(spec.outFile, "");

  const spawned = () =>
    spawnDispatch(effects, built.cmd, built.args, {
      cwd: built.cwd,
      env: built.env,
      timeoutMs,
      onLine,
      stem: spec.outFile,
      title: `${spec.slug ?? "crew-afk"} ${spec.agent}`,
      jsonEvents: built.jsonEvents,
      agent: spec.agent,
    });
  // A worker commits to its worktree's branch while it runs: a read-only guard elsewhere must not
  // blame that ref move on its own dispatch.
  const r = spec.cwd && spec.cwd !== spec.mainRoot && effects.inWorktree ? await effects.inWorktree(spec.cwd, spawned) : await spawned();
  consumeLine(lineBuffer);

  let meta = EMPTY_RESULT_META;
  if (built.jsonEvents && !r.dryRun) {
    keepPriorEvents(`${spec.outFile}.events.jsonl`);
    writeFileSync(`${spec.outFile}.events.jsonl`, lines.length ? `${lines.join("\n")}\n` : "");
    const own = ownsOut && existsSync(spec.outFile) ? readFileSync(spec.outFile, "utf8") : "";
    writeFileSync(spec.outFile, extractFinalText(built.jsonEvents, lines) || own);
    meta = extractResultMeta(built.jsonEvents, lines);
  } else if (built.capture === "stdout" && !r.dryRun) {
    writeFileSync(spec.outFile, r.stdout ?? "");
  }
  const text = existsSync(spec.outFile) ? readFileSync(spec.outFile, "utf8") : "";

  // A failure before anything is traced (a missing CLI → ENOENT/127, a killed
  // child) otherwise leaves its reason only in stderr. claude can also report isError while
  // still exiting 0 with text. Permission denials on an otherwise normal dispatch are not a
  // failure — the agent went on without that call — so they get their own label, naming the
  // tools denied, which a FAIL line with only a count left to guesswork.
  const failed = r.code !== 0 || r.timedOut || !text.trim() || meta.isError;
  const denials = meta.permissionDenials.length
    ? ` permissionDenials=${meta.permissionDenials.length} tools=${deniedTools(meta.permissionDenials)}`
    : "";
  if (spec.logFile && !r.dryRun && failed) {
    const stderrSnippet = (r.stderr ?? "").trim().slice(0, 500).replace(/\s+/g, " ");
    writeLog(
      spec.logFile,
      `[DISPATCH-FAIL] agent=${spec.agent} slug=${spec.slug ?? "?"} code=${r.code} timedOut=${!!r.timedOut} outEmpty=${!text.trim()} isError=${!!meta.isError}${denials} stderr=${JSON.stringify(stderrSnippet || "(none)")}`,
    );
  } else if (spec.logFile && !r.dryRun && denials) {
    writeLog(spec.logFile, `[DISPATCH-WARN] agent=${spec.agent} slug=${spec.slug ?? "?"} code=${r.code}${denials}`);
  }

  return {
    code: r.code,
    timedOut: !!r.timedOut,
    dryRun: !!r.dryRun,
    stderr: r.stderr ?? "",
    text,
    isError: meta.isError,
    subtype: meta.subtype,
    costUsd: meta.costUsd,
    durationMs: meta.durationMs,
    numTurns: meta.numTurns,
    permissionDenials: meta.permissionDenials,
    sessionId: meta.sessionId,
    contextTokens: meta.contextTokens,
    // A claude dispatch killed on timeout leaves no `result` event, even when it also left no
    // assistant event: either way its cost is unknown, not zero.
    costUnknown: meta.costUnknown || (built.jsonEvents === "claude" && !r.dryRun && !!r.timedOut && meta.costUsd == null),
    tokens: meta.tokens,
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
  { prompt, cwd, mainRoot, model, outFile, timeoutMs, fakeAgent = "prd-audit", maxBudgetUsd = null },
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
        ...(maxBudgetUsd ? ["--max-budget-usd", String(maxBudgetUsd)] : []),
      ];
      break;
    case "copilot":
      cmd = "copilot";
      args = ["-p", prompt, "-C", cwd, "--add-dir", mainRoot, "--allow-all-tools", "--no-color", "--silent", ...(model ? ["--model", model] : [])];
      break;
    default:
      throw new Error(`unknown platform: ${platform}`);
  }
  {
    try {
      assertArgvPromptFits(prompt, cmd);
    } catch (e) {
      if (outFile) {
        mkdirSync(dirname(outFile), { recursive: true });
        writeFileSync(outFile, "");
      }
      return { code: 1, timedOut: false, text: "", stderr: e.message, dryRun: false };
    }
  }
  const r = await effects.spawnWithTimeout(cmd, args, { cwd, env, timeoutMs });
  if (outFile && !r.dryRun) {
    mkdirSync(dirname(outFile), { recursive: true });
    writeFileSync(outFile, r.stdout ?? "");
  }
  return { code: r.code, timedOut: !!r.timedOut, text: r.stdout ?? "", dryRun: !!r.dryRun };
}

/**
 * Whether a `--help` text lists `flag`: as itself, or folded into a sibling's brackets
 * (`--append-system-prompt[-file]` lists `--append-system-prompt-file`).
 */
function helpLists(text, flag) {
  const forms = [flag];
  for (let i = flag.indexOf("-", 2); i > 2; i = flag.indexOf("-", i + 1)) forms.push(`${flag.slice(0, i)}[${flag.slice(i)}]`);
  const esc = (f) => f.replace(/[[\]]/g, "\\$&");
  return forms.some((f) => new RegExp(`(^|[^\\w-])${esc(f)}(?![\\w-])`).test(text));
}

/** Preflight: is this platform's CLI actually present? */
export function preflight(effects, platform, { paneHost = null, probeFlags = false } = {}) {
  if (process.env.CREW_FAKE_DISPATCH) return [];
  const cli = { pi: "pi", codex: "codex", claude: "claude", copilot: "copilot" }[platform];
  const which = effects.exec("sh", ["-c", `command -v ${cli}`], { mutating: false });
  const problems = [];
  if (which.code !== 0) problems.push(`${cli} CLI not found on PATH`);
  if (probeFlags && which.code === 0) {
    const adapter = ADAPTERS[platform];
    const help = effects.exec(cli, adapter.helpArgs ?? ["--help"], { mutating: false });
    const text = `${help.stdout ?? ""}\n${help.stderr ?? ""}`;
    const missing = (adapter.requiredFlags ?? []).filter((f) => !helpLists(text, f));
    for (const f of missing) problems.push(`${cli} \`${(adapter.helpArgs ?? ["--help"]).join(" ")}\` does not list ${f}, which the ${platform} adapter needs for a full-permission headless run`);
  }
  // Every platform is dispatched from the rendered protocol: no agent file to find.
  problems.push(...preflightPaneHost(effects, paneHost));
  return problems;
}
