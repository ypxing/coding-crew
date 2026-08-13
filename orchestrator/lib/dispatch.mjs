/**
 * dispatch.mjs — four platforms, one contract.
 *
 * A dispatch is: run <agent> with <prompt> in <cwd>, capture its final message to
 * <outFile>, with a hard timeout. Every platform can do this headlessly:
 *
 *   pi       pi -p --append-system-prompt …           (via dispatch-agent.sh)
 *   codex    codex exec --cd … -o …                   (via dispatch-codex-agent.sh)
 *   claude   claude -p --agent <name> --add-dir …
 *   copilot  copilot -p --agent <name> -C … --silent
 *
 * pi and codex keep their existing bash dispatchers, which already resolve the agent
 * definition and map its frontmatter onto CLI flags. claude and copilot resolve their
 * own agent by name (`--agent`).
 *
 * For claude that name is the whole contract, verified against 2.1.221: `--agent` loads
 * the project-level `.claude/agents/<name>.md`, enforces its `tools:` list, and exits 1
 * with `--agent '<name>' not found` rather than silently falling back. So no agent body
 * is re-sent as a system prompt — an append would duplicate the definition Claude has
 * already loaded and, on any conflict, override it. copilot still prepends the body to
 * the prompt, because that CLI has no system-prompt flag at all.
 *
 * Permissions are explicit per platform: an unattended sprint that stops on a
 * tool-permission prompt is a sprint that never finishes.
 */

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { homedir } from "node:os";

export const PLATFORMS = ["pi", "codex", "claude", "copilot"];

/** Default parallelism per platform. Copilot's real cap is the user's plan tier. */
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
    const args = [
      "-p",
      "--permission-mode",
      "bypassPermissions",
      "--add-dir",
      mainRoot,
      "--agent",
      agent,
    ];
    if (model) args.push("--model", model);
    args.push(prompt);
    return { cmd: "claude", args, ...shared, capture: "stdout" };
  }

  if (platform === "copilot") {
    // Copilot has no system-prompt flag, so an unresolvable named agent is covered by
    // prepending the definition body to the prompt (what codex's dispatcher does).
    let text = prompt;
    const agentFile = resolveAgentFile(platform, mainRoot, agent);
    if (agentFile) {
      const { body } = splitFrontmatter(readFileSync(agentFile, "utf8"));
      text = `${body}\n\n---\n\n${prompt}`;
    }
    const args = ["-p", text, "--agent", agent, "-C", cwd, "--allow-all-tools", "--no-color", "--silent"];
    if (model) args.push("--model", model);
    return { cmd: "copilot", args, ...shared, capture: "stdout" };
  }

  throw new Error(`unknown platform: ${platform}`);
}

/**
 * Run one dispatch to completion. Always leaves a report file on disk (empty when the
 * child produced nothing), because "no report" is a state the pipeline must be able
 * to read rather than infer.
 */
export async function dispatch(effects, platform, spec, { timeoutMs } = {}) {
  const built = buildDispatch(platform, spec);
  mkdirSync(dirname(spec.outFile), { recursive: true });
  const r = await effects.spawnWithTimeout(built.cmd, built.args, {
    cwd: built.cwd,
    env: built.env,
    timeoutMs,
  });
  if (built.capture === "stdout" && !r.dryRun) writeFileSync(spec.outFile, r.stdout ?? "");
  const text = existsSync(spec.outFile) ? readFileSync(spec.outFile, "utf8") : "";
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
 * opt-in coverage validation, whose prompt is printed by coverage-validation.sh — so
 * the prompt only exists in a context window when the step actually runs.
 */
export async function dispatchPlain(effects, platform, { prompt, cwd, mainRoot, model, outFile, timeoutMs }) {
  const env = { MAIN_ROOT: mainRoot, CREW_ORCHESTRATED: "1" };

  // The same test/CI seam buildDispatch has: an agent-less dispatch is still a model
  // call, so the wrap-up that makes it (coverage validation) must be exercisable for
  // zero tokens or it is the one step no test ever runs.
  if (process.env.CREW_FAKE_DISPATCH) {
    const out = outFile ?? join(cwd, "plain-dispatch.out");
    const r = await effects.spawnWithTimeout(
      "bash",
      [process.env.CREW_FAKE_DISPATCH, "--agent", "coverage-validation", "--dir", cwd, "--out", out],
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
      args = ["-p", "--permission-mode", "bypassPermissions", "--add-dir", mainRoot, ...(model ? ["--model", model] : []), prompt];
      break;
    case "copilot":
      cmd = "copilot";
      args = ["-p", prompt, "-C", cwd, "--allow-all-tools", "--no-color", "--silent", ...(model ? ["--model", model] : [])];
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
    }
  }
  return problems;
}
