#!/usr/bin/env node
/**
 * crew-afk — the AFK issue sprint, as a program.
 *
 * Usage:
 *   crew-afk run    [options]   run the sprint to completion
 *   crew-afk plan   [options]   print what a sprint would do, change nothing
 *   crew-afk status             print the current sprint's state
 *   crew-afk doctor [options]   check this platform can dispatch at all
 *
 * Options:
 *   --platform <pi|codex|claude|copilot>   default: $CREW_PLATFORM, else pi
 *   --model <alias|inherit>                worker + reviewer model
 *   --feature-slug <slug>                  or derived from the first issue's dir
 *   --coverage                             opt into the PRD coverage report
 *   --promote <critical|critical-high>      findings promotion threshold
 *   --max-parallel <n>                     concurrent workers (platform default)
 *   --worker-timeout <minutes>             default 45 — a hung worker cannot hang the sprint
 *   --max-rounds <n>                       hard cap on rounds
 *   --no-deps                              skip both ensure-deps.sh call sites
 *   --no-squash                            skip the end-of-sprint squash
 *
 * Exit codes: 0 clean · 2 stalled · 3 nothing to do · 1 setup error
 */

import { existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

import { Effects, appendLine } from "./lib/effects.mjs";
import { Sprint } from "./lib/sprint.mjs";
import { DEFAULT_PARALLEL, PLATFORMS, preflight } from "./lib/dispatch.mjs";
import { makeRoundReviewFile, runSprint } from "./lib/loop.mjs";
import { selectDispatchable } from "./lib/tracker.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));

function parseArgs(argv) {
  const o = {
    command: "run",
    platform: process.env.CREW_PLATFORM || "pi",
    model: null,
    featureSlug: null,
    coverage: false,
    promote: null,
    parallel: null,
    workerTimeoutMs: 45 * 60 * 1000,
    reviewTimeoutMs: 20 * 60 * 1000,
    maxRounds: null,
    deps: true,
    noSquash: false,
    dryRun: false,
    passthrough: [],
  };
  const args = [...argv];
  if (args[0] && !args[0].startsWith("-")) o.command = args.shift();
  while (args.length) {
    const a = args.shift();
    switch (a) {
      case "--platform": o.platform = args.shift(); break;
      case "--model": o.model = args.shift(); break;
      case "--feature-slug": o.featureSlug = args.shift(); break;
      case "--coverage": o.coverage = true; break;
      case "--promote": o.promote = args.shift(); break;
      case "--max-parallel": o.parallel = Number(args.shift()); break;
      case "--worker-timeout": o.workerTimeoutMs = Number(args.shift()) * 60 * 1000; break;
      case "--review-timeout": o.reviewTimeoutMs = Number(args.shift()) * 60 * 1000; break;
      case "--max-rounds": o.maxRounds = Number(args.shift()); break;
      case "--no-deps": o.deps = false; break;
      case "--no-squash": o.noSquash = true; break;
      case "--dry-run": o.dryRun = true; break;
      case "--jira": o.passthrough.push("--jira", args.shift()); break;
      case "-h": case "--help": o.command = "help"; break;
      default:
        if (a.startsWith(".scratch/")) {
          // A path argument names the sprint: derive the slug from it, exactly once.
          o.featureSlug ??= a.replace(/^\.scratch\//, "").split("/")[0] || null;
        } else {
          o.passthrough.push(a);
        }
    }
  }
  if (o.command === "plan") o.dryRun = true;
  o.model = o.model === "inherit" ? null : o.model;
  o.parallel ??= DEFAULT_PARALLEL[o.platform] ?? 2;
  return o;
}

function gitRoot() {
  const r = spawnSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8" });
  if (r.status !== 0) {
    console.error("crew-afk: not inside a git repository.");
    process.exit(1);
  }
  return r.stdout.trim();
}

function resolveScriptsDir(mainRoot) {
  // Installed layout first, then this repo's source tree (development).
  const candidates = [
    process.env.CREW_SCRIPTS,
    join(mainRoot, ".coding-crew/crew-afk/scripts"),
    join(mainRoot, ".pi/skills/crew-afk/scripts"),
    join(mainRoot, ".claude/skills/crew-afk/scripts"),
    join(mainRoot, ".agents/skills/crew-afk/scripts"),
    join(mainRoot, ".github/skills/crew-afk/scripts"),
    join(HERE, "../skills/crew-afk/scripts"),
  ].filter(Boolean);
  for (const c of candidates) if (existsSync(join(c, "state.sh"))) return resolve(c);
  console.error(
    "crew-afk: cannot find crew-afk's scripts/ dir. Set CREW_SCRIPTS or install the skill.",
  );
  process.exit(1);
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.command === "help") {
    console.log(
      "crew-afk run|plan|status|doctor [--platform pi|codex|claude|copilot] [--model X]\n" +
        "  [--feature-slug S] [--coverage] [--promote critical|critical-high]\n" +
        "  [--max-parallel N] [--worker-timeout MIN] [--max-rounds N] [--no-deps] [--no-squash]",
    );
    return 0;
  }
  if (!PLATFORMS.includes(options.platform)) {
    console.error(`crew-afk: unknown --platform ${options.platform} (expected ${PLATFORMS.join(", ")})`);
    return 1;
  }

  const mainRoot = gitRoot();
  const scriptsDir = resolveScriptsDir(mainRoot);
  const logLines = [];
  const effects = new Effects({
    scriptsDir,
    mainRoot,
    dryRun: options.dryRun,
    log: (line) => {
      logLines.push(line);
      if (process.env.CREW_VERBOSE) console.error(line);
    },
  });

  if (options.command === "doctor") {
    const problems = preflight(effects, options.platform, mainRoot, ["crew-coder", "crew-code-reviewer"]);
    console.log(problems.length ? problems.map((p) => `PROBLEM: ${p}`).join("\n") : `OK: ${options.platform} can dispatch.`);
    return problems.length ? 1 : 0;
  }

  if (options.command === "status") {
    const sprint = Sprint.attach(effects);
    if (!sprint) {
      console.log("No sprint initialised (.scratch/sprint.env absent).");
      return 3;
    }
    console.log(JSON.stringify({ env: sprint.env, state: sprint.readState() }, null, 2));
    return 0;
  }

  // --- plan: read-only, zero tokens ----------------------------------------
  if (options.command === "plan") {
    const issues = selectDispatchable(mainRoot);
    const problems = preflight(effects, options.platform, mainRoot, ["crew-coder", "crew-code-reviewer"]);
    console.log(`platform:  ${options.platform}`);
    console.log(`model:     ${options.model ?? "platform default"}`);
    console.log(`parallel:  ${options.parallel}`);
    console.log(`scripts:   ${scriptsDir}`);
    console.log(`preflight: ${problems.length ? problems.join("; ") : "ok"}`);
    console.log(`dispatchable now (${issues.length}):`);
    for (const i of issues) console.log(`  - ${i.slug}  [${i.status}]  ${i.path}`);
    const skipped = selectDispatchable(mainRoot, { status: "deferred-findings" });
    if (skipped.length) console.log(`parked fix issues (${skipped.length}): ${skipped.map((i) => i.slug).join(", ")}`);
    console.log("\npipeline per branch: deps → dispatch → verify → review (AC + findings) → merge → close");
    console.log(`deps:      ${options.deps ? "ensure-deps.sh, once per sprint and once per worktree" : "disabled (--no-deps)"}`);
    return issues.length ? 0 : 3;
  }

  // --- run -----------------------------------------------------------------
  const problems = preflight(effects, options.platform, mainRoot, ["crew-coder", "crew-code-reviewer"]);
  if (problems.length) {
    console.error(problems.map((p) => `crew-afk: ${p}`).join("\n"));
    return 1;
  }

  const sprint = Sprint.init(effects, {
    featureSlug: options.featureSlug,
    coverage: options.coverage,
    promote: options.promote,
    passthrough: options.passthrough,
    deps: options.deps,
    log: (line) => console.error(line),
  });
  sprint.setModel(options.model ?? "agent default");

  const ctx = {
    sprint,
    effects,
    options,
    platform: options.platform,
    round: 0,
    roundReviewFile: makeRoundReviewFile(sprint),
    log: (line) => {
      if (!line) return;
      console.error(line);
      if (sprint.traceLog) appendLine(sprint.traceLog, line);
    },
    out: (text) => console.log(text),
  };

  const { stalled } = await runSprint(ctx);
  return stalled ? 2 : 0;
}

main().then(
  (code) => process.exit(code ?? 0),
  (err) => {
    console.error(`crew-afk: ${err?.stack || err}`);
    process.exit(1);
  },
);
