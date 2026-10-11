/**
 * dispatch.mjs — run one role's agent headlessly on any platform: <prompt> in <cwd>, final message
 * to <outFile>, hard timeout. The raw event stream is kept as `<outFile>.events.jsonl`. Permissions
 * are explicit per platform: an unattended sprint that stops on a permission prompt never finishes.
 */

import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { writeLog } from "./log.mjs";
import { preflightPaneHost, spawnDispatch } from "./pane-host/index.mjs";
import { ADAPTERS } from "./adapters/index.mjs";
import { ARGV_PROMPT_LIMIT_BYTES, EMPTY_RESULT_META, assertArgvFits } from "./adapters/common.mjs";
import { pathWithShim } from "./install-dir.mjs";
import { ROLE_POLICY, renderRolePrompt, roleOfAgent } from "./adapters/render.mjs";
import { formatJsonTraceLine } from "./adapters/trace.mjs";

export { ARGV_PROMPT_LIMIT_BYTES, renderRolePrompt };

export function buildDispatch(platform, spec) {
  const { agent, cwd, promptFile, outFile, model, mainRoot, slug, reportPath, resumeSessionId, maxBudgetUsd } = spec; // spec.effort: afk.effort over ROLE_POLICY; spec.protocolPart: renderRolePrompt's `part`
  const shared = {
    cwd,
    env: {
    MAIN_ROOT: mainRoot,
    CREW_ORCHESTRATED: "1",
    // The docker shim first: a bare `docker compose run` the agent types loads its worktree's override.
    ...(process.env.CREW_INSTALL_DIR ? { PATH: pathWithShim(process.env.CREW_INSTALL_DIR, process.env.PATH) } : {}),
    // The coder defers the full suite to the verify gate and runs only the tests it changed.
    ...(agent === "crew-coder" ? { CREW_DEFER_FULL_CHECKS: "1", ...(spec.baseRef ? { CREW_BASE_REF: spec.baseRef } : {}) } : {}),
    },
  };

  const role = roleOfAgent(agent);
  // Rendered here, before anything spawns: a missing protocol or fragment fails the dispatch.
  const protocol = role ? renderRolePrompt(role, platform, { mainRoot, rolesDir: spec.rolesDir, part: spec.protocolPart }) : null;
  // Every protocol is on disk as well as in hand: the adapter places whichever its CLI takes.
  let protocolFile = null;
  if (protocol) {
    protocolFile = `${outFile}.protocol.md`;
    mkdirSync(dirname(protocolFile), { recursive: true });
    writeFileSync(protocolFile, protocol);
  }

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
  const prompt = readFileSync(promptFile, "utf8");
  const label = basename(promptFile, ".md").replace(/\.prompt$/, "");
  const { args, input } = adapter.build({
    cwd,
    mainRoot,
    model,
    policy: role ? { ...ROLE_POLICY[role], ...(spec.effort ? { effort: spec.effort } : {}) } : null,
    protocol,
    protocolFile,
    prompt,
    outFile,
    label: `${spec.agent}: ${label}`,
  });
  // A CLI that reads its prompt on stdin carries no size limit; every argv string is capped.
  assertArgvFits(args, adapter.cmd);
  if (resumeSessionId && adapter.resume) args.push(...adapter.resume(resumeSessionId));
  // afk.limits.<role>.usd: a backstop, checked after each turn, so it can overshoot one turn.
  if (maxBudgetUsd && adapter.budget) args.push(...adapter.budget(maxBudgetUsd));
  return {
    cmd: adapter.cmd,
    args,
    input,
    ...shared,
    env: { ...shared.env, ...(adapter.env ?? {}) },
    capture: "stdout",
    jsonEvents: platform,
  };
}

// Heartbeat throttle: every Nth tool call or every INTERVAL_MS, whichever first.
const HEARTBEAT_EVERY_N = 5;
const HEARTBEAT_INTERVAL_MS = 30_000;

/** The fake seam's own already-throttled [TOOL]/[TOOL-ERROR] line, forwarded on its stdout. */
const BASH_HEARTBEAT = /^\[(?:TOOL|TOOL-ERROR)\] /;

/** "" when nothing is found: an empty report is a handled state, safer than leaking raw JSONL. */
export function extractFinalText(platform, lines) {
  return ADAPTERS[platform]?.finalText(lines) ?? "";
}

/** Cost, error, session and timing from the stream, per the adapter; all-null where it has none (copilot). */
export function extractResultMeta(platform, lines) {
  return ADAPTERS[platform]?.resultMeta?.(lines) ?? EMPTY_RESULT_META;
}

function deniedTools(denials) {
  const names = [...new Set(denials.map((d) => d?.tool_name ?? d?.tool ?? "?"))];
  return names.join(",");
}

/** Keep an earlier attempt's event stream (and its cost) at the first free `<stem>.events.<n>.jsonl`. */
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

/** Always leaves a report file (empty when nothing came back): "no report" must be read, not inferred. */
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

  // onLine hands back raw chunks: lineBuffer holds a trailing partial line until close.
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
    // The fake seam writes spec.logFile itself; only its already-throttled [TOOL] lines are heartbeats.
    if (onTrace && BASH_HEARTBEAT.test(line)) onTrace(line);
  };
  const onLine = (chunk) => {
    lineBuffer += String(chunk);
    const parts = lineBuffer.split("\n");
    lineBuffer = parts.pop();
    for (const line of parts) consumeLine(line);
  };

  const spawned = () =>
    spawnDispatch(effects, built.cmd, built.args, {
      cwd: built.cwd,
      env: built.env,
      input: built.input,
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
    writeFileSync(spec.outFile, extractFinalText(built.jsonEvents, lines));
    meta = extractResultMeta(built.jsonEvents, lines);
  } else if (built.capture === "stdout" && !r.dryRun) {
    writeFileSync(spec.outFile, r.stdout ?? "");
  }
  const text = existsSync(spec.outFile) ? readFileSync(spec.outFile, "utf8") : "";

  // claude can report isError while exiting 0 with text. Permission denials alone are not a
  // failure (the agent went on without that call), so they get a WARN naming the tools.
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
    // A CLI that reports cost in a final event (claude's `result`) leaves none when killed on
    // timeout, even with no assistant event: either way its cost is unknown, not zero.
    costUnknown: meta.costUnknown || (!!adapter?.reportsCost && !!built.jsonEvents && !r.dryRun && !!r.timedOut && meta.costUsd == null),
    tokens: meta.tokens,
  };
}

/** A role with no protocol (commandFinder, prWriter); `fakeAgent` names it to CREW_FAKE_DISPATCH and the trace. */
export async function dispatchPlain(
  effects,
  platform,
  { prompt, cwd, mainRoot, model, outFile, timeoutMs, fakeAgent = "plain", maxBudgetUsd = null, logFile },
) {
  mkdirSync(dirname(outFile), { recursive: true });
  const promptFile = `${outFile}.prompt.md`;
  writeFileSync(promptFile, prompt);
  return dispatch(effects, platform, { agent: fakeAgent, cwd, mainRoot, model, promptFile, outFile, maxBudgetUsd, logFile }, { timeoutMs });
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

export function preflight(effects, platform, { paneHost = null, probeFlags = false } = {}) {
  if (process.env.CREW_FAKE_DISPATCH) return [];
  const adapter = ADAPTERS[platform];
  const cli = adapter.cmd;
  const which = effects.exec("sh", ["-c", `command -v ${cli}`], { mutating: false });
  const problems = [];
  if (which.code !== 0) problems.push(`${cli} CLI not found on PATH`);
  if (probeFlags && which.code === 0) {
    const help = effects.exec(cli, adapter.helpArgs ?? ["--help"], { mutating: false });
    const text = `${help.stdout ?? ""}\n${help.stderr ?? ""}`;
    const missing = (adapter.requiredFlags ?? []).filter((f) => !helpLists(text, f));
    for (const f of missing) problems.push(`${cli} \`${(adapter.helpArgs ?? ["--help"]).join(" ")}\` does not list ${f}, which the ${platform} adapter needs for a full-permission headless run`);
  }
  problems.push(...preflightPaneHost(effects, paneHost));
  return problems;
}
