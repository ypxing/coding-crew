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
 *   --pane-host <orca|herdr|auto|none>     [paneHost, ~/.coding-crew/config.json only; default
 *                                           none] or $CREW_PANE_HOST, which beats the file, as
 *                                           do the legacy $ORCA_ENV=1 / $HERDR_ENV=1 (orca
 *                                           first). Opens one tab tailing the trace log and
 *                                           pushes the outcome to the launching pane at the
 *                                           end; nothing load-bearing runs through it. Needs
 *                                           `herdr server` / `orca open` running. `run` prints
 *                                           `PANE-HOST: <host|none>` first, for the launcher.
 *                                           See lib/pane-host/index.mjs, docs/orca-support.md.
 *   --model <alias|inherit>                coder model; every role on the same runtime
 *                                           matches it unless .coding-crew/config.json's
 *                                           afk.models names one (see lib/crew-config.mjs,
 *                                           which also lets a role run on another runtime)
 *   --feature-slug <slug>                  or derived from the first issue's dir
 *
 * Each flag below overrides the config.json setting in brackets for one run (lib/crew-config.mjs):
 *   --fix-findings <critical|high|medium|none>  [fixFindings, default high] lowest reviewer
 *                                           severity auto-fixed in Phase 2 (--promote: old name)
 *   --prd-audit <off|report|fix>           [PRDAudit, default fix] audit the sprint against its
 *                                           PRD.md after Phase 1; `fix` queues ✗ missing gaps
 *                                           for Phase 2 (--coverage: old name, means `report`)
 *   --max-parallel <n>                     [maxParallel] concurrent coders (the coder runtime's default)
 *   --coder-timeout <minutes>              [timeouts.coder, 45] a hung coder cannot hang the sprint
 *                                           (--worker-timeout: old name)
 *   --reviewer-timeout <minutes>           [timeouts.reviewer, 20] (--review-timeout, the old
 *                                           name, also sets triage, commandFinder and prdAuditor)
 *   --merge-timeout <minutes>              [timeouts.merge, 5] merge/close block the event loop
 *                                           (spawnSync), so a hang would freeze the sprint
 *   --no-deps                              [installDeps: false] skip both ensure-deps.sh call sites
 *   --no-squash                            [squashCommits: false] skip the end-of-sprint squash
 *
 *   --max-rounds <n>                       cap on attempts per issue this invocation. Each issue
 *                                           already blocks after 2, so only `1` (no retry) changes
 *                                           anything: stop every issue after one attempt
 *   --no-commands                          skip one-time command discovery (verify-worktree.sh
 *                                           falls back to its own CLAUDE.md/Makefile heuristics)
 *
 * CREW_VERBOSE=1 also puts each dispatch's throttled [TOOL] heartbeat and the effects log on
 * stderr; the trace log has both either way.
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
import { DEFAULT_PARALLEL, PLATFORMS } from "./lib/dispatch.mjs";
import {
  ConfigError,
  DISPATCHER,
  ROLES,
  activeRoles,
  crewPreflight,
  describeModel,
  loadConfig,
  resolveCrew,
  resolvePaneHost,
  resolveSettings,
  validateFlags,
} from "./lib/crew-config.mjs";
import { closePaneLogTab, closePaneWorkspace, drainPaneNotices, ensurePaneWorkspace, notifyTriggeringPane } from "./lib/pane-host/index.mjs";
import { makeRoundReviewFile, runSprint } from "./lib/loop.mjs";
import { getTracker, selectDispatchable } from "./lib/tracker.mjs";
import { ensureWorktreeInclude } from "./lib/worktree.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));

function parseArgs(argv) {
  const o = {
    command: "run",
    platform: process.env.CREW_PLATFORM || "pi",
    paneHost: null, // resolved with the config (resolvePaneHost)
    model: null,
    featureSlug: null,
    // Flags that override a config.json setting; undefined = not given (resolveSettings).
    cli: { timeouts: {} },
    flagOf: {}, // setting → the flag that set it, when more than one can (for error text)
    maxRounds: null,
    commands: true,
    dryRun: false,
    passthrough: [],
    unknown: [],
  };
  const args = [...argv];
  // A setting flag with no value is "", which fails validation, rather than no flag at all.
  const value = () => args.shift() ?? "";
  if (args[0] && !args[0].startsWith("-")) o.command = args.shift();
  while (args.length) {
    const a = args.shift();
    switch (a) {
      case "--platform": o.platform = args.shift(); break;
      case "--model": o.model = args.shift(); break;
      case "--feature-slug": o.featureSlug = args.shift(); break;
      case "--fix-findings": o.cli.fixFindings = value(); break;
      case "--promote": {
        const v = value();
        o.cli.fixFindings = { critical: "critical", "critical-high": "high" }[v] ?? v;
        o.flagOf.fixFindings = "--promote";
        break;
      }
      case "--prd-audit": o.cli.PRDAudit = value(); break;
      case "--coverage": o.cli.PRDAudit = "report"; break;
      case "--max-parallel": o.cli.maxParallel = Number(args.shift()); break;
      case "--pane-host": o.cli.paneHost = value(); break;
      case "--coder-timeout": case "--worker-timeout":
        o.cli.timeouts.coder = Number(args.shift());
        o.flagOf["timeouts.coder"] = a;
        break;
      case "--reviewer-timeout":
        o.cli.timeouts.reviewer = Number(args.shift());
        o.flagOf["timeouts.reviewer"] = a;
        break;
      case "--review-timeout": {
        const min = Number(args.shift());
        for (const k of ["reviewer", "triage", "commandFinder", "prdAuditor"]) {
          o.cli.timeouts[k] = min;
          o.flagOf[`timeouts.${k}`] = a;
        }
        break;
      }
      case "--merge-timeout": o.cli.timeouts.merge = Number(args.shift()); break;
      case "--max-rounds": o.maxRounds = Number(args.shift()); break;
      case "--no-deps": o.cli.installDeps = false; break;
      case "--no-commands": o.commands = false; break;
      case "--no-squash": o.cli.squashCommits = false; break;
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

/**
 * `plan`'s role table: one line per role, its runtime and model, and which config file set
 * either — with two files merged, a value's source is otherwise a guess.
 */
function crewTable(crew, origin = {}) {
  const width = Math.max(...ROLES.map((r) => r.length));
  return ROLES.map((r) => {
    const { runtime, model } = crew[r];
    const from = [
      origin[`runtime.${r}`] && `runtime: ${origin[`runtime.${r}`]}`,
      origin[`models.${runtime}.${r}`] && `model: ${origin[`models.${runtime}.${r}`]}`,
    ].filter(Boolean);
    const tag = from.length ? `  [${from.join(", ")}]` : "";
    return `  ${r.padEnd(width)}  ${runtime.padEnd(7)}  ${describeModel(runtime, model)}${tag}`;
  });
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
const PROJECT_SKILL_DIRS = {
  pi: ".pi/skills/crew-afk/scripts",
  claude: ".claude/skills/crew-afk/scripts",
  codex: ".agents/skills/crew-afk/scripts",
  copilot: ".github/skills/crew-afk/scripts",
};
const USER_SKILL_DIRS = {
  pi: ".pi/agent/skills/crew-afk/scripts",
  claude: ".claude/skills/crew-afk/scripts",
  codex: ".agents/skills/crew-afk/scripts",
  copilot: ".copilot/skills/crew-afk/scripts",
};

/** `platform`'s own dir first: only its install carries its dispatcher (pi's, codex's). */
const ownFirst = (dirs, platform) => [dirs[platform], ...Object.values(dirs).filter((d) => d !== dirs[platform])].filter(Boolean);

function resolveScriptsDir(mainRoot, platform) {
  // Project install first (a pinned copy wins), then user-level (`TARGET_REPO=$HOME`, the
  // documented default), then this repo's source tree (dev). $HOME before os.homedir():
  // on Windows homedir() reads USERPROFILE and would ignore a $HOME override.
  const home = process.env.HOME || homedir();
  const candidates = [
    process.env.CREW_SCRIPTS,
    ...ownFirst(PROJECT_SKILL_DIRS, platform).map((d) => join(mainRoot, d)),
    ...ownFirst(USER_SKILL_DIRS, platform).map((d) => join(home, d)),
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

/**
 * The scripts dir holding `runtime`'s own dispatcher, or null. A role on another runtime than
 * the launcher's needs that runtime's install, not the launcher's: install.sh ships each
 * dispatcher only to its own platform.
 */
function resolveDispatcherDir(mainRoot, runtime) {
  const script = DISPATCHER[runtime];
  if (!script) return null;
  const home = process.env.HOME || homedir();
  const candidates = [
    process.env.CREW_SCRIPTS,
    join(mainRoot, PROJECT_SKILL_DIRS[runtime]),
    join(home, USER_SKILL_DIRS[runtime]),
    join(HERE, "../skills/crew-afk/scripts"),
  ].filter(Boolean);
  const found = candidates.find((c) => existsSync(join(c, script)));
  return found ? resolve(found) : null;
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.command === "help") {
    console.log(
      "crew-afk run|plan|status|doctor [--platform pi|codex|claude|copilot] [--model X]\n" +
        "  [--feature-slug S] [--fix-findings critical|high|medium|none] [--prd-audit off|report|fix]\n" +
        "  [--max-parallel N] [--coder-timeout MIN] [--reviewer-timeout MIN] [--merge-timeout MIN]\n" +
        "  [--max-rounds N] [--no-deps] [--no-commands] [--no-squash] [--pane-host orca|herdr|auto|none]\n" +
        "  --model sets the coder's model; every role on the same runtime matches it unless\n" +
        "  .coding-crew/config.json names one. Per role (coder, reviewer, triage,\n" +
        "  commandFinder, prdAuditor):\n" +
        '    { "afk": { "runtime": { "reviewer": "codex" },\n' +
        '               "models":  { "claude": { "triage": "opus" } } } }\n' +
        "  The other flags override config.json's afk settings for one run: fixFindings (high),\n" +
        "  PRDAudit (fix), maxParallel, timeouts.<role|merge> (minutes), installDeps, squashCommits,\n" +
        "  and paneHost (none; ~/.coding-crew/config.json only, and $CREW_PANE_HOST beats it).",
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

  const scriptsDir = resolveScriptsDir(mainRoot, options.platform);
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
  if (options.command === "status") {
    const sprint = Sprint.attach(effects);
    if (!sprint) {
      console.log("No sprint initialised (.scratch/sprint.env absent).");
      return 3;
    }
    console.log(JSON.stringify({ env: sprint.env, state: sprint.readState() }, null, 2));
    return 0;
  }

  // .coding-crew/config.json (the repo's, over ~/.coding-crew/config.json) is optional;
  // absent, every role runs on --platform with --model.
  // Only a real `run` moves a legacy afk-models.json into it on disk, once setup has passed.
  let loaded;
  try {
    loaded = loadConfig(mainRoot);
  } catch (err) {
    if (!(err instanceof ConfigError)) throw err;
    console.error(`crew-afk: ${err.message}`);
    return 1;
  }
  for (const n of loaded.notices) console.error(`crew-afk: ${n}`);
  const movesLegacy = loaded.legacyMove && options.command === "run" && !options.dryRun;
  if (loaded.legacyMove && !movesLegacy) console.error(`crew-afk: ${loaded.legacyMove.pending}`);
  const flagProblems = validateFlags(options.cli, options.flagOf);
  if (flagProblems.length) {
    console.error(`crew-afk: ${flagProblems.join("; ")}`);
    return 1;
  }
  const crew = resolveCrew({ afk: loaded.config.afk, cliPlatform: options.platform, cliModel: options.model });
  for (const w of crew.warnings) console.error(`crew-afk: WARNING: ${w}`);
  // --model beats the file's coder model, so `plan` must not credit the file with it.
  if (options.model && crew.roles.coder.runtime === options.platform) {
    loaded.origin[`models.${options.platform}.coder`] = "--model";
  }
  options.crew = crew.roles;
  options.model = crew.roles.coder.model;
  const settings = resolveSettings({ afk: loaded.config.afk, cli: options.cli, origin: loaded.origin });
  Object.assign(options, settings);
  const pane = resolvePaneHost({ afk: loaded.config.afk, cli: options.cli, origin: loaded.origin });
  for (const n of pane.notices) console.error(`crew-afk: ${n}`);
  options.paneHost = pane.paneHost;
  // Read by pane-host/, which keeps its run-scoped state on effects too.
  effects.paneHost = options.paneHost;
  options.parallel = settings.maxParallel ?? DEFAULT_PARALLEL[crew.roles.coder.runtime] ?? 2;
  options.timeoutMs = Object.fromEntries(Object.entries(settings.timeouts).map(([k, min]) => [k, min * 60 * 1000]));
  options.dispatcherDirs = Object.fromEntries(
    [...new Set(ROLES.map((r) => crew.roles[r].runtime))].map((rt) => [rt, resolveDispatcherDir(mainRoot, rt)]),
  );
  const preflightCrew = () =>
    crewPreflight(effects, mainRoot, {
      crew: options.crew,
      roles: activeRoles(options),
      launcher: options.platform,
      paneHost: options.paneHost,
      dispatcherDirs: options.dispatcherDirs,
    });

  if (options.command === "doctor") {
    const problems = preflightCrew();
    console.log(problems.length ? problems.map((p) => `PROBLEM: ${p}`).join("\n") : `OK: ${[...new Set(activeRoles(options).map((r) => options.crew[r].runtime))].join(", ")} can dispatch.`);
    return problems.length ? 1 : 0;
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
    const problems = preflightCrew();
    console.log(`platform:  ${options.platform}`);
    console.log("crew:");
    for (const line of crewTable(options.crew, loaded.origin)) console.log(line);
    const tag = (k) => (loaded.origin[k] ? `  [${loaded.origin[k]}]` : "");
    console.log(`parallel:  ${options.parallel}${tag("maxParallel")}`);
    console.log(`findings:  fix ${options.fixFindings === "none" ? "none" : `${options.fixFindings} and above`} in Phase 2${tag("fixFindings")}`);
    console.log(`PRD audit: ${options.PRDAudit}${tag("PRDAudit")}`);
    console.log(`timeouts:  ${Object.entries(options.timeouts).map(([k, m]) => `${k} ${m}m${loaded.origin[`timeouts.${k}`] ? ` [${loaded.origin[`timeouts.${k}`]}]` : ""}`).join(", ")}`);
    console.log(`pane host: ${options.paneHost ?? "none"}${tag("paneHost")}`);
    console.log(`scripts:   ${scriptsDir}`);
    console.log(`preflight: ${problems.length ? problems.join("; ") : "ok"}`);
    console.log(`dispatchable now (${issues.length}):`);
    // github issues have no `.path`, only `.number`.
    for (const i of issues) console.log(`  - ${i.slug}  [${i.status}]  ${i.path ?? `#${i.number}`}`);
    const skipped = tracker.selectDispatchable(mainRoot, { status: "deferred-findings", featureSlug: resolved.slug });
    if (skipped.length) console.log(`parked fix issues (${skipped.length}): ${skipped.map((i) => i.slug).join(", ")}`);
    console.log("\npipeline per branch: deps → dispatch → verify → review (AC + findings) → merge → close");
    console.log(`commands:  ${options.commands ? "discover-commands.sh, once per sprint (bootstrap-only), before deps (cached at .coding-crew/dev-commands.json)" : "disabled (--no-commands)"}`);
    const offBy = (k, flag) => `disabled (${loaded.origin[k] === "flag" ? flag : `${k}: false`})`;
    console.log(`deps:      ${options.installDeps ? "ensure-deps.sh, once per sprint and once per worktree, using a discovered install command when one was cached" : offBy("installDeps", "--no-deps")}`);
    console.log(`squash:    ${options.squashCommits ? "at the end of the sprint" : offBy("squashCommits", "--no-squash")}`);
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
    // Before any sprint output, so a launcher knows the resolved host without re-deriving it
    // from env and config.
    console.error(`PANE-HOST: ${options.paneHost ?? "none"}`);
    const problems = preflightCrew();
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

    if (movesLegacy) console.error(`crew-afk: ${loaded.legacyMove.apply()}`);

    // Before any worktree exists, so every one gets the included files at creation.
    ensureWorktreeInclude(mainRoot);

    sprint = await Sprint.init(effects, {
      featureSlug: resolved.slug,
      fixFindings: options.fixFindings,
      PRDAudit: options.PRDAudit,
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
        platform: options.crew.commandFinder.runtime,
        model: options.crew.commandFinder.model,
        timeoutMs: options.timeoutMs.commandFinder,
        // Persisted too: this runs unattended, and a failure must outlive the scrollback.
        log: (line) => {
          console.error(line);
          if (sprint.traceLog) appendLine(sprint.traceLog, line);
        },
      });
    }

    // After command discovery: ensure-deps.sh reads the install command it cached.
    if (options.installDeps) await sprint.installDeps((line) => console.error(line));

    const ctx = {
      sprint,
      effects,
      options,
      roundReviewFile: makeRoundReviewFile(sprint),
      log: (line) => {
        if (!line) return;
        console.error(line);
        if (sprint.traceLog) appendLine(sprint.traceLog, line);
      },
      // A dispatch's [TOOL] heartbeat. The dispatch already wrote it to the trace log, and a
      // launcher agent pays tokens for every stderr line it reads, so it is opt-in here.
      heartbeat: (line) => {
        if (process.env.CREW_VERBOSE) console.error(line);
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
      await drainPaneNotices(effects);
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
