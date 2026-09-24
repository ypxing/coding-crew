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
 *   $HERDR_ENV=1 / $ORCA_ENV=1              mutually exclusive; pick one pane host (neither:
 *                                           none). Opens one tab tailing the trace log and
 *                                           pushes the outcome to the launching pane at the
 *                                           end; nothing load-bearing runs through it. Needs
 *                                           `herdr server` / `orca open` running. See
 *                                           lib/pane-host/index.mjs and docs/orca-support.md.
 *   --model <alias|inherit>                coder model; reviewer/triage/commandsDiscovery/
 *                                           coverageValidation match it unless
 *                                           .coding-crew/afk-models.json names them explicitly
 *   --feature-slug <slug>                  or derived from the first issue's dir
 *   --coverage                             opt into the PRD coverage report
 *   --promote <critical|critical-high>      findings promotion threshold
 *   --max-parallel <n>                     concurrent workers (platform default)
 *   --worker-timeout <minutes>             default 45 — a hung worker cannot hang the sprint
 *   --merge-timeout <minutes>              default 10 — merge/close block the event loop
 *                                           (spawnSync), so a hang would freeze the sprint
 *   --max-rounds <n>                       hard cap on attempts *per issue* this invocation
 *                                           makes (independent of, and typically larger than,
 *                                           each issue's own 2-attempt cap before it blocks)
 *   --no-deps                              skip both ensure-deps.sh call sites
 *   --no-commands                          skip one-time command discovery (verify-worktree.sh
 *                                           falls back to its own CLAUDE.md/Makefile heuristics)
 *   --no-squash                            skip the end-of-sprint squash
 *
 * Exit codes: 0 clean · 2 stalled · 3 nothing to do · 1 setup error
 */

import { existsSync, mkdirSync, readdirSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

import { Effects, appendLine } from "./lib/effects.mjs";
import { Sprint } from "./lib/sprint.mjs";
import { discoverCommands } from "./lib/commands.mjs";
import { DEFAULT_PARALLEL, PLATFORMS, preflight } from "./lib/dispatch.mjs";
import { closePaneLogTab, closePaneWorkspace, ensurePaneWorkspace, notifyTriggeringPane } from "./lib/pane-host/index.mjs";
import { makeRoundReviewFile, runSprint } from "./lib/loop.mjs";
import { loadModelConfig, resolveModelTiers } from "./lib/model-config.mjs";
import { getTracker, selectDispatchable } from "./lib/tracker.mjs";
import { ensureWorktreeInclude } from "./lib/worktree.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));

function parseArgs(argv) {
  const o = {
    command: "run",
    platform: process.env.CREW_PLATFORM || "pi",
    paneHost: process.env.ORCA_ENV === "1" ? "orca" : process.env.HERDR_ENV === "1" ? "herdr" : null,
    model: null,
    featureSlug: null,
    coverage: false,
    promote: null,
    parallel: null,
    workerTimeoutMs: 45 * 60 * 1000,
    reviewTimeoutMs: 20 * 60 * 1000,
    mergeTimeoutMs: 10 * 60 * 1000,
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
      case "--merge-timeout": o.mergeTimeoutMs = Number(args.shift()) * 60 * 1000; break;
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
          // Collected, not forwarded — see reportUnknownArgs.
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

// " (reviewer: X, triage: Y)" — only when .coding-crew/afk-models.json made one of them
// diverge from the coder's model; the common case (all three identical) prints nothing extra.
function modelBreakdownSuffix(options) {
  const parts = [];
  if (options.reviewerModel !== options.model) parts.push(`reviewer: ${options.reviewerModel ?? "inherit"}`);
  if (options.triageModel !== options.model) parts.push(`triage: ${options.triageModel ?? "inherit"}`);
  return parts.length ? ` (${parts.join(", ")})` : "";
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
 * Feature slug → its ready-for-agent, unblocked issue slugs, from an unscoped
 * selectDispatchable() (no sprint exists yet). session-init.sh's own no-slug fallback
 * picks an arbitrary feature once two have ready issues; this lets resolveFeatureSlug
 * refuse instead, identically for every launcher.
 *
 * Local-only on purpose: under `tracker: github` there is no cross-feature scan (a
 * milestone query needs the slug already), so this finds nothing and session-init.sh's
 * own `--feature-slug`-required error applies.
 */
function readyFeatureCandidates(mainRoot) {
  const byFeature = new Map();
  for (const i of selectDispatchable(mainRoot)) {
    const m = /\.scratch[\\/]([^\\/]+)[\\/]/.exec(i.path);
    if (!m) continue;
    const feature = m[1];
    if (!byFeature.has(feature)) byFeature.set(feature, []);
    byFeature.get(feature).push(i.slug);
  }
  return byFeature;
}

/**
 * Resolve the one feature slug a bare invocation (no --feature-slug, no .scratch/<slug>/
 * path) would mean, or explain why it can't. Returns `{ slug }` (slug may be null when
 * nothing is ready yet — session-init.sh's own "No issues found" error still covers that),
 * or `{ error }` when more than one feature dir has a ready issue.
 */
function resolveFeatureSlug(mainRoot, explicitSlug) {
  if (explicitSlug) return { slug: explicitSlug };
  const candidates = readyFeatureCandidates(mainRoot);
  if (candidates.size <= 1) return { slug: candidates.size === 1 ? [...candidates.keys()][0] : null };
  const lines = [
    `crew-afk: ${candidates.size} feature dirs have ready-for-agent issues — refusing to guess which one this run means.`,
    ...[...candidates].map(
      ([slug, slugs]) => `  --feature-slug ${slug}  (${slugs.length} issue(s): ${slugs.join(", ")})`,
    ),
    "Pass --feature-slug <slug> or a .scratch/<slug>/... path to pick one.",
  ];
  return { error: lines.join("\n") };
}

/**
 * A pidfile at .scratch/<slug>/.crew-afk.lock: a second `run` for the same slug refuses
 * rather than racing the first for the same worktrees/branches (the loser would burn real
 * attempts off its retry cap). A lock whose pid is dead (crash, SIGKILL) is reclaimed.
 */
function acquireSprintLock(mainRoot, slug) {
  const lockPath = join(mainRoot, ".scratch", slug, ".crew-afk.lock");
  if (existsSync(lockPath)) {
    let holder;
    try {
      holder = JSON.parse(readFileSync(lockPath, "utf8"));
    } catch {
      holder = null;
    }
    if (holder?.pid && isPidAlive(holder.pid)) {
      return {
        error: `crew-afk: a sprint for feature-slug '${slug}' is already running (pid ${holder.pid}, started ${holder.startedAt}) — wait for it to finish, or remove ${lockPath} if that process is actually gone.`,
      };
    }
  }
  mkdirSync(dirname(lockPath), { recursive: true });
  writeFileSync(lockPath, JSON.stringify({ pid: process.pid, startedAt: new Date().toISOString() }));
  return { lockPath };
}

function isPidAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function releaseSprintLock(lockPath) {
  if (!lockPath) return;
  try {
    unlinkSync(lockPath);
  } catch {
    /* already gone, or this process never held one */
  }
}

/**
 * A bare word that isn't a flag or a .scratch/ path. Reported here, with the accepted
 * forms and a likely-typo suggestion, rather than forwarded to session-init.sh, whose
 * downstream scripts only know --jira.
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
  // Project install first (a pinned copy wins), then user-level (`TARGET_REPO=$HOME`, the
  // documented default), then this repo's source tree (dev). $HOME before os.homedir():
  // on Windows homedir() reads USERPROFILE and would ignore a $HOME override.
  const home = process.env.HOME || homedir();
  const candidates = [
    process.env.CREW_SCRIPTS,
    ...PROJECT_SKILL_DIRS.map((d) => join(mainRoot, d)),
    ...USER_SKILL_DIRS.map((d) => join(home, d)),
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
        "  [--max-parallel N] [--worker-timeout MIN] [--merge-timeout MIN] [--max-rounds N] [--no-deps] [--no-commands] [--no-squash]\n" +
        "  --model sets the coder's model; reviewer/triage/commandsDiscovery/coverageValidation\n" +
        "  match it unless .coding-crew/afk-models.json names\n" +
        "  {coder, reviewer, triage, commandsDiscovery, coverageValidation} explicitly.",
    );
    return 0;
  }
  if (!PLATFORMS.includes(options.platform)) {
    console.error(`crew-afk: unknown --platform ${options.platform} (expected ${PLATFORMS.join(", ")})`);
    return 1;
  }
  if (process.env.HERDR_ENV === "1" && process.env.ORCA_ENV === "1") {
    console.error("crew-afk: HERDR_ENV=1 and ORCA_ENV=1 are both set — pick one pane host.");
    return 1;
  }

  const mainRoot = gitRoot();
  if (options.unknown.length) {
    reportUnknownArgs(options.unknown, mainRoot);
    return 1;
  }

  // .coding-crew/afk-models.json is optional; absent, every tier follows --model.
  const resolvedModels = resolveModelTiers({
    fileConfig: loadModelConfig(mainRoot),
    cliModel: options.model,
    platform: options.platform,
  });
  options.model = resolvedModels.coder;
  options.reviewerModel = resolvedModels.reviewer;
  options.triageModel = resolvedModels.triage;
  options.commandsDiscoveryModel = resolvedModels.commandsDiscovery;
  options.coverageValidationModel = resolvedModels.coverageValidation;
  for (const w of resolvedModels.warnings) console.error(`crew-afk: WARNING: ${w}`);

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
  // Read by pane-host/, which keeps its run-scoped state on effects too.
  effects.paneHost = options.paneHost;

  if (options.command === "doctor") {
    const problems = preflight(effects, options.platform, mainRoot, ["crew-coder", "crew-code-reviewer", "crew-triage"], {
      paneHost: options.paneHost,
    });
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
    // Resolved exactly as `run` resolves it, so the preview matches what `run` would do.
    const resolved = resolveFeatureSlug(mainRoot, options.featureSlug);
    if (resolved.error) {
      console.error(resolved.error);
      return 1;
    }
    const tracker = await getTracker(mainRoot);
    const issues = tracker.selectDispatchable(mainRoot, { featureSlug: resolved.slug });
    const problems = preflight(effects, options.platform, mainRoot, ["crew-coder", "crew-code-reviewer", "crew-triage"], {
      paneHost: options.paneHost,
    });
    console.log(`platform:  ${options.platform}`);
    console.log(`model:     ${options.model ?? "platform default"}${modelBreakdownSuffix(options)}`);
    console.log(`parallel:  ${options.parallel}`);
    console.log(`scripts:   ${scriptsDir}`);
    console.log(`preflight: ${problems.length ? problems.join("; ") : "ok"}`);
    console.log(`dispatchable now (${issues.length}):`);
    // github issues have no `.path`, only `.number`.
    for (const i of issues) console.log(`  - ${i.slug}  [${i.status}]  ${i.path ?? `#${i.number}`}`);
    const skipped = tracker.selectDispatchable(mainRoot, { status: "deferred-findings", featureSlug: resolved.slug });
    if (skipped.length) console.log(`parked fix issues (${skipped.length}): ${skipped.map((i) => i.slug).join(", ")}`);
    console.log("\npipeline per branch: deps → dispatch → verify → review (AC + findings) → merge → close");
    console.log(`commands:  ${options.commands ? "discover-commands.sh, once per sprint (bootstrap-only), before deps (cached at .coding-crew/dev-commands.json)" : "disabled (--no-commands)"}`);
    console.log(`deps:      ${options.deps ? "ensure-deps.sh, once per sprint and once per worktree, using a discovered install command when one was cached" : "disabled (--no-deps)"}`);
    return issues.length ? 0 : 3;
  }

  // --- run -----------------------------------------------------------------
  // The try starts here, not around runSprint, so a setup failure also reaches the
  // end-of-run push in `finally` — the only nudge the triggering pane gets. State is
  // declared outside it so `finally` sees whatever got assigned.
  let sprint;
  let resolved;
  let stalled;
  let exitCode = 0;
  let runError;
  let lockPath;
  try {
    const problems = preflight(effects, options.platform, mainRoot, ["crew-coder", "crew-code-reviewer", "crew-triage"], {
      paneHost: options.paneHost,
    });
    if (problems.length) {
      console.error(problems.map((p) => `crew-afk: ${p}`).join("\n"));
      exitCode = 1;
      return exitCode;
    }

    // Before session-init.sh touches disk — see readyFeatureCandidates.
    resolved = resolveFeatureSlug(mainRoot, options.featureSlug);
    if (resolved.error) {
      console.error(resolved.error);
      exitCode = 1;
      return exitCode;
    }

    // A null slug (session-init.sh's single-feature fallback) has nothing to lock on.
    if (resolved.slug) {
      const lock = acquireSprintLock(mainRoot, resolved.slug);
      if (lock.error) {
        console.error(lock.error);
        exitCode = 1;
        return exitCode;
      }
      lockPath = lock.lockPath;
    }

    // Before any worktree exists, so every one gets the included files at creation.
    ensureWorktreeInclude(mainRoot);

    sprint = await Sprint.init(effects, {
      featureSlug: resolved.slug,
      coverage: options.coverage,
      promote: options.promote,
      passthrough: options.passthrough,
      // Installed below, after command discovery has cached any install override.
      deps: false,
      log: (line) => console.error(line),
    });
    sprint.setModel(options.model ?? "agent default");

    // Best-effort: the log file, not this tab, is the run's durable output.
    if (options.paneHost && !options.dryRun) {
      try {
        await ensurePaneWorkspace(effects, { featureSlug: resolved.slug, logFile: sprint.traceLog });
      } catch (err) {
        console.error(`crew-afk: could not open the ${options.paneHost} log tab: ${err.message} — continuing without one.`);
      }
    }

    if (options.commands) {
      await discoverCommands(effects, {
        platform: options.platform,
        model: options.commandsDiscoveryModel,
        timeoutMs: options.reviewTimeoutMs,
        // Persisted too: this runs unattended, and a failure must outlive the scrollback.
        log: (line) => {
          console.error(line);
          if (sprint.traceLog) appendLine(sprint.traceLog, line);
        },
      });
    }

    // After command discovery: ensure-deps.sh reads the install command it cached.
    if (options.deps) await sprint.installDeps((line) => console.error(line));

    const ctx = {
      sprint,
      effects,
      options,
      platform: options.platform,
      roundReviewFile: makeRoundReviewFile(sprint),
      log: (line) => {
        if (!line) return;
        console.error(line);
        if (sprint.traceLog) appendLine(sprint.traceLog, line);
      },
      out: (text) => console.log(text),
    };

    ({ stalled } = await runSprint(ctx));
    exitCode = stalled ? 2 : 0;
    return exitCode;
  } catch (err) {
    runError = err;
    exitCode = 1;
    throw err;
  } finally {
    // No-ops unless opened above; here so a thrown error can't leave them dangling.
    await closePaneLogTab(effects);
    await closePaneWorkspace(effects);
    // Every ending, setup failures included: a caller waiting on this push instead of
    // polling has no other way to learn the run is over.
    if (options.paneHost) {
      const outcome = runError ? "errored" : exitCode === 1 ? "setup failed" : stalled ? "stalled — blockers need a human" : "finished";
      const label = resolved?.slug ? `crew-afk (${resolved.slug})` : "crew-afk";
      await notifyTriggeringPane(effects, `${label}: sprint ${outcome}. Check this pane's scrollback for the summary.`);
    }
    // Last: released earlier, a second `run` could start while this one is still closing.
    releaseSprintLock(lockPath);
  }
}

main().then(
  (code) => process.exit(code ?? 0),
  (err) => {
    console.error(`crew-afk: ${err?.stack || err}`);
    process.exit(1);
  },
);
