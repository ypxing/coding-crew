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
 *   --no-commands                          skip one-time command discovery (verify-worktree.sh
 *                                           falls back to its own CLAUDE.md/Makefile heuristics)
 *   --no-squash                            skip the end-of-sprint squash
 *
 * Exit codes: 0 clean · 2 stalled · 3 nothing to do · 1 setup error
 */

import { existsSync, readdirSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

import { Effects, appendLine } from "./lib/effects.mjs";
import { Sprint } from "./lib/sprint.mjs";
import { discoverCommands } from "./lib/commands.mjs";
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
    commands: true,
    noSquash: false,
    dryRun: false,
    passthrough: [],
    unknown: [],
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
      case "--no-commands": o.commands = false; break;
      case "--no-squash": o.noSquash = true; break;
      case "--dry-run": o.dryRun = true; break;
      case "--jira": o.passthrough.push("--jira", args.shift()); break;
      case "-h": case "--help": o.command = "help"; break;
      default:
        if (a.startsWith(".scratch/")) {
          // A path argument names the sprint: derive the slug from it, exactly once.
          o.featureSlug ??= a.replace(/^\.scratch\//, "").split("/")[0] || null;
        } else {
          // Anything else is not a recognised flag or a .scratch/ path. Collect it rather
          // than forward it — session-init.sh and feature-branch-setup.sh two hops down
          // only know --jira, so a stray word used to die there with a confusing
          // "Unknown argument" from a script the user never invoked. Fail here instead,
          // where we can name the accepted forms and, once mainRoot is known, suggest the
          // closest existing .scratch/<feature-slug> dir for a likely typo.
          o.unknown.push(a);
        }
    }
  }
  if (o.command === "plan") o.dryRun = true;
  o.model = o.model === "inherit" ? null : o.model;
  o.parallel ??= DEFAULT_PARALLEL[o.platform] ?? 2;
  return o;
}

// Plain Levenshtein edit distance — no dependency, and small enough to stay honest.
function editDistance(a, b) {
  const dp = Array.from({ length: a.length + 1 }, (_, i) => {
    const row = new Array(b.length + 1);
    row[0] = i;
    return row;
  });
  for (let j = 0; j <= b.length; j++) dp[0][j] = j;
  for (let i = 1; i <= a.length; i++) {
    for (let j = 1; j <= b.length; j++) {
      dp[i][j] = a[i - 1] === b[j - 1]
        ? dp[i - 1][j - 1]
        : 1 + Math.min(dp[i - 1][j], dp[i][j - 1], dp[i - 1][j - 1]);
    }
  }
  return dp[a.length][b.length];
}

/** Every existing .scratch/<feature-slug> directory name, for a typo suggestion. */
function existingFeatureSlugs(mainRoot) {
  const scratch = join(mainRoot, ".scratch");
  if (!existsSync(scratch)) return [];
  return readdirSync(scratch, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => d.name);
}

/**
 * A bare word that isn't a recognised flag or a .scratch/ path used to be forwarded
 * unexamined to session-init.sh, then to feature-branch-setup.sh, which only knows
 * --jira and dies with "Unknown argument" — two hops from where the mistake was made,
 * in a script whose job has nothing to do with crew-afk's own CLI. Report it here
 * instead, where the accepted forms are known and a likely typo can be named.
 */
function reportUnknownArgs(unknown, mainRoot) {
  const slugs = existingFeatureSlugs(mainRoot);
  const lines = [
    `crew-afk: unrecognized argument${unknown.length > 1 ? "s" : ""}: ${unknown.join(" ")}`,
    "",
    "Accepted forms: --feature-slug <slug>, --jira TICKET-123, a .scratch/<feature-slug>/... path,",
    "or one of the flags in `crew-afk help`.",
  ];
  for (const a of unknown) {
    if (a.startsWith("-") || a.includes("/") || a.includes(" ")) continue;
    let best = null;
    let bestDist = Infinity;
    for (const slug of slugs) {
      const d = editDistance(a, slug);
      if (d < bestDist) {
        bestDist = d;
        best = slug;
      }
    }
    if (best && bestDist > 0 && bestDist <= Math.max(2, Math.ceil(best.length * 0.3))) {
      lines.push(`Did you mean --feature-slug ${best}? (found .scratch/${best}/)`);
    }
  }
  console.error(lines.join("\n"));
}

function gitRoot() {
  const r = spawnSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8" });
  if (r.status !== 0) {
    console.error("crew-afk: not inside a git repository.");
    process.exit(1);
  }
  return r.stdout.trim();
}

// Where each platform's installer puts a skill, relative to a scope root. Project scope and
// user scope differ per platform (pi nests under .pi/agent/, Copilot reads .github/ in a repo
// but ~/.copilot/ at user level), so both lists are spelled out rather than derived.
const PROJECT_SKILL_DIRS = [
  ".pi/skills/crew-afk/scripts",
  ".claude/skills/crew-afk/scripts",
  ".agents/skills/crew-afk/scripts",
  ".github/skills/crew-afk/scripts",
];
const USER_SKILL_DIRS = [
  ".pi/agent/skills/crew-afk/scripts",
  ".claude/skills/crew-afk/scripts",
  ".agents/skills/crew-afk/scripts",
  ".copilot/skills/crew-afk/scripts",
];

function resolveScriptsDir(mainRoot) {
  // Project install first — a repo that pins its own copy means it. Then the user-level
  // install, which is the documented default (`TARGET_REPO=$HOME`, "works in any project"):
  // without it a sprint could only run in a repo that had installed crew-afk itself, and
  // reported that as the skill being half-installed. Then this repo's source tree (dev).
  const candidates = [
    process.env.CREW_SCRIPTS,
    ...PROJECT_SKILL_DIRS.map((d) => join(mainRoot, d)),
    ...USER_SKILL_DIRS.map((d) => join(homedir(), d)),
    join(HERE, "../skills/crew-afk/scripts"),
  ].filter(Boolean);
  for (const c of candidates) if (existsSync(join(c, "state.sh"))) return resolve(c);
  console.error(
    "crew-afk: cannot find crew-afk's scripts/ dir. Install crew-afk in this repo" +
      " (./install.sh <platform> --skill crew-afk) or user-level (TARGET_REPO=$HOME), or set" +
      " CREW_SCRIPTS to its scripts/ dir.",
  );
  process.exit(1);
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.command === "help") {
    console.log(
      "crew-afk run|plan|status|doctor [--platform pi|codex|claude|copilot] [--model X]\n" +
        "  [--feature-slug S] [--coverage] [--promote critical|critical-high]\n" +
        "  [--max-parallel N] [--worker-timeout MIN] [--max-rounds N] [--no-deps] [--no-commands] [--no-squash]",
    );
    return 0;
  }
  if (!PLATFORMS.includes(options.platform)) {
    console.error(`crew-afk: unknown --platform ${options.platform} (expected ${PLATFORMS.join(", ")})`);
    return 1;
  }

  const mainRoot = gitRoot();
  if (options.unknown.length) {
    reportUnknownArgs(options.unknown, mainRoot);
    return 1;
  }
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
    const problems = preflight(effects, options.platform, mainRoot, ["crew-coder", "crew-code-reviewer", "crew-triage"]);
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
    const problems = preflight(effects, options.platform, mainRoot, ["crew-coder", "crew-code-reviewer", "crew-triage"]);
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
    console.log(`commands:  ${options.commands ? "discover-commands.sh, once per sprint (bootstrap-only), before deps (cached at .coding-crew/dev-commands.json)" : "disabled (--no-commands)"}`);
    console.log(`deps:      ${options.deps ? "ensure-deps.sh, once per sprint and once per worktree, using a discovered install command when one was cached" : "disabled (--no-deps)"}`);
    return issues.length ? 0 : 3;
  }

  // --- run -----------------------------------------------------------------
  const problems = preflight(effects, options.platform, mainRoot, ["crew-coder", "crew-code-reviewer", "crew-triage"]);
  if (problems.length) {
    console.error(problems.map((p) => `crew-afk: ${p}`).join("\n"));
    return 1;
  }

  const sprint = Sprint.init(effects, {
    featureSlug: options.featureSlug,
    coverage: options.coverage,
    promote: options.promote,
    passthrough: options.passthrough,
    // Deps are not installed as part of init here — commands finding runs first, below, so
    // its own cached "install" override (when it finds one) is already on disk before the
    // sprint's first ensure-deps.sh call reads it.
    deps: false,
    log: (line) => console.error(line),
  });
  sprint.setModel(options.model ?? "agent default");

  if (options.commands) {
    await discoverCommands(effects, {
      platform: options.platform,
      model: options.model,
      timeoutMs: options.reviewTimeoutMs,
      // Persisted, not just printed: this step runs once, unattended, before any
      // worktree exists, and its own dispatch failure (bad model output, timeout) was
      // otherwise visible only in a live terminal — gone the moment it scrolled past,
      // with no artifact left afterwards to diagnose it from.
      log: (line) => {
        console.error(line);
        if (sprint.traceLog) appendLine(sprint.traceLog, line);
      },
    });
  }

  // Deps, once per sprint against $MAIN_ROOT, after commands finding — not before: a
  // documented install command discover-commands.sh finds is only usable by ensure-deps.sh
  // if the cache it lands in already exists by the time this runs.
  if (options.deps) sprint.installDeps((line) => console.error(line));

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
