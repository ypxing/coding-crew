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
 *   --platform <name>                      required (not for status): one of lib/adapters/index.mjs's PLATFORMS
 *   --pane-host <orca|herdr|auto|none>     [paneHost, ~/.coding-crew/config.json only; default
 *                                           none] or $CREW_PANE_HOST, which beats the file, as
 *                                           do the legacy $ORCA_ENV=1 / $HERDR_ENV=1 (orca
 *                                           first). Opens one tab tailing the trace log and
 *                                           one feature agent for the slug, both in its
 *                                           `_feature` worktree (reused across runs, never
 *                                           closed; `_feature` is kept while it lives), that
 *                                           every milestone and the outcome are pushed to;
 *                                           nothing load-bearing runs through it. Needs
 *                                           `herdr server` / `orca open` running. `run` prints
 *                                           `PANE-HOST: <host|none>` first, for a human or script
 *                                           that wants the resolved host (the launcher skills do
 *                                           not read it).
 *                                           See lib/pane-host/index.mjs, docs/orca-support.md.
 *   --model <alias|inherit>                coder model; every role on the same runtime
 *                                           matches it unless .coding-crew/config.json's
 *                                           afk.models names one (see lib/crew-config.mjs,
 *                                           which also lets a role run on another runtime)
 *   --feature-slug <slug>                  or derived from the first issue's dir
 *   --jira <KEY>                           e.g. PROJ-12: a feature branch this run creates is
 *                                           <afk.branchPrefix, default feature/><KEY>-<slug>.
 *                                           Ignored, with a warning, when the branch is already
 *                                           chosen (a sprint.env to resume)
 *
 * Each flag below overrides the config.json setting in brackets for one run (lib/crew-config.mjs):
 *   --fix-findings <actionable|critical|high|medium|none>  [fixFindings, default actionable]
 *                                           what is auto-fixed in Phase 2: every finding triage
 *                                           judges Actionable, or the lowest severity
 *   --max-parallel <n>                     [maxParallel] concurrent coders (the coder runtime's default)
 *   --max-wall <minutes>                   [maxWallMinutes] default 120, 0 = off; once elapsed no new issue is
 *                                          claimed, in-flight workers finish, Phase 2 is parked, exit 2
 *   --poll-interval <seconds>              default 30; while work is in flight and a slot is idle, list
 *                                           the tracker once per interval and start any issue made
 *                                           ready mid-run (linted first; an ERROR blocks it for this
 *                                           run only). 0 = claim new issues only when an attempt ends
 *   --coder-timeout <minutes>              [timeouts.coder, 60] a hung coder cannot hang the sprint
 *   --reviewer-timeout <minutes>           [timeouts.reviewer, 20]
 *   --no-deps                              [installDeps: false] skip both ensure-deps.sh call sites
 *   --squash                               [squashCommits, default false] squash the sprint's
 *                                           commits into one at the end; --no-squash turns it off
 *   --open-pr                              [openPr, default false] at the end, push the feature
 *                                           branch and create or update its PR, whose body
 *                                           closes the issues it merged; --no-open-pr turns it off
 *   --no-baseline                          [baselineCheck: false] skip running the checks once on
 *                                           the feature branch before any dispatch (a red one
 *                                           otherwise stops the run: every issue would fail it)
 *   --no-integration-check                 [integrationCheck: false] skip running the checks on
 *                                           the merged feature branch each time the queue drains
 *                                           (a red one is reported, and no PR is opened). The
 *                                           baseline flag does not turn it off
 *   --resume-coder-session                 [resumeCoderSession, default false] a fix round
 *                                           continues the claude coder session that wrote the
 *                                           branch, when that session is small and the branch
 *                                           has not moved since
 *
 *   --reclaim                              take over the feature lease (refs/crew-lock/<slug> on
 *                                           origin, held under `tracker: github`) when its holder
 *                                           is on another host or otherwise not provably dead. A
 *                                           lease left by a dead pid on this host is reclaimed
 *                                           without it. Use only when the holding run is gone
 *   --no-sync-main                         skip merging origin's default branch into a resumed feature
 *                                           branch that lacks it (done once, before the baseline;
 *                                           a conflict there stops the run)
 *   --allow-dirty                          accepted, does nothing (prints a notice): the main
 *                                           checkout is never switched or merged into, so its
 *                                           uncommitted changes never stop a run
 *
 * CREW_LOG_LEVEL=debug|info|warn|error|fatal sets the lowest level stderr shows (default
 * info); the trace log keeps every level either way. debug adds each dispatch's throttled
 * [TOOL] heartbeat, the effects log, and a script's stdout echoed after its own trace line.
 * CREW_VERBOSE=1 is the older spelling of debug. CREW_INSTALL_DIR overrides the `.coding-crew/`
 * this run's assets are read from (default: the one holding this crew-afk/; lib/install-dir.mjs).
 *
 * Exit codes: 0 clean · 2 stalled · 3 nothing to do · 1 setup error
 */

import { appendFileSync, existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, unlinkSync, writeFileSync } from "node:fs";
import { basename, dirname, isAbsolute, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

import { Effects, killAllGroups } from "./lib/effects.mjs";
import { atLeast, levelFor, stderrThreshold, writeLog } from "./lib/log.mjs";
import { Sprint } from "./lib/sprint.mjs";
import { discoverCommands } from "./lib/commands.mjs";
import { ADAPTERS, DEFAULT_PARALLEL, PLATFORMS } from "./lib/adapters/index.mjs";
import {
  ConfigError,
  ROLES,
  activeRoles,
  crewPreflight,
  describeModel,
  ignoredLimitsNotice,
  loadConfig,
  resolveCrew,
  resolvePaneHost,
  resolveSettings,
  resolveWorktreeRoot,
  retiredNotice,
  validateFlags,
} from "./lib/crew-config.mjs";
import { closePaneLogTab, closePaneWorkspace, closePaneWorkspaceSync, drainPaneNotices, ensurePaneWorkspace, ensureWatchSession, notifyWatchSession, queueRunStartNotice, settlePaneAgent } from "./lib/pane-host/index.mjs";
import { makeRoundReviewFile, runSprint } from "./lib/loop.mjs";
import { getTracker, selectDispatchable } from "./lib/tracker.mjs";
import { ensureWorktree, featureSlugOfPath, featureWorktreePath, removeWorktree, worktreeRoot } from "./lib/worktree.mjs";
import { resolveInstallDir } from "./lib/install-dir.mjs";
import { skillDirCandidates } from "./lib/skill-dirs.mjs";
import { acquireLease, releaseLease } from "./lib/lease.mjs";
import { sweepInProgress } from "./lib/labels.mjs";
import { closeShipped } from "./lib/shipped.mjs";
import { readTrackerConfig } from "../tracker/tracker-config.mjs";
import {
  baselineFailureMessage,
  checkRequires,
  dropStaleRetained,
  lintFailureMessage,
  lintIssues,
  missingAssets,
  missingAssetsMessage,
  runBaselineAsync,
  syncConflictMessage,
  syncFeatureBranch,
} from "./lib/preflight.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));

const COMMANDS = ["run", "plan", "status", "doctor"];

function parseArgs(argv) {
  const o = {
    command: "run",
    platform: null, // required: every launcher passes --platform
    paneHost: null, // resolved with the config (resolvePaneHost)
    model: null,
    featureSlug: null,
    // Flags that override a config.json setting; undefined = not given (resolveSettings).
    cli: { timeouts: {} },
    flagOf: {}, // setting → the flag that set it, when more than one can (for error text)
    // Test-only seams (not flags): cap attempts per issue / skip command discovery.
    maxRounds: Number(process.env.CREW_MAX_ROUNDS) || null,
    pollInterval: 30,
    commands: process.env.CREW_NO_COMMANDS !== "1",
    allowDirty: false,
    syncMain: true,
    reclaim: false,
    dryRun: false,
    passthrough: [],
    unknown: [],
    retired: [], // flags still accepted that no longer do anything (crew-config.mjs's retiredNotice)
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
      case "--prd-audit":
        value();
        o.retired.push(a);
        break;
      case "--max-parallel": o.cli.maxParallel = Number(args.shift()); break;
      case "--max-wall": o.cli.maxWallMinutes = Number(args.shift()); break;
      case "--poll-interval": o.pollInterval = Number(args.shift()); break;
      case "--pane-host": o.cli.paneHost = value(); break;
      case "--coder-timeout":
        o.cli.timeouts.coder = Number(args.shift());
        o.flagOf["timeouts.coder"] = a;
        break;
      case "--reviewer-timeout":
        o.cli.timeouts.reviewer = Number(args.shift());
        o.flagOf["timeouts.reviewer"] = a;
        break;
      case "--no-deps": o.cli.installDeps = false; break;
      case "--squash": o.cli.squashCommits = true; break;
      case "--no-squash": o.cli.squashCommits = false; break;
      case "--open-pr": o.cli.openPr = true; break;
      case "--no-open-pr": o.cli.openPr = false; break;
      case "--no-baseline": o.cli.baselineCheck = false; break;
      case "--no-integration-check": o.cli.integrationCheck = false; break;
      case "--resume-coder-session": o.cli.resumeCoderSession = true; break;
      case "--allow-dirty": o.allowDirty = true; break;
      case "--no-sync-main": o.syncMain = false; break;
      case "--reclaim": o.reclaim = true; break;
      case "--dry-run": o.dryRun = true; break;
      case "--jira": o.passthrough.push("--jira", value()); break;
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
 *
 * A cwd inside `<worktreeRoot>/crew/<slug>/_feature` names its feature, under any tracker, ahead
 * of the ready-issue scan; an explicit slug that differs from it is refused.
 */
function resolveFeatureSlug(mainRoot, explicitSlug, worktreeRootDir, cwd = process.cwd()) {
  const here = worktreeRootDir ? featureSlugOfPath(worktreeRootDir, cwd) : null;
  if (here) {
    if (explicitSlug && explicitSlug !== here) {
      return {
        error: `crew-afk: --feature-slug ${explicitSlug} names a different feature than the checkout this runs in: ${cwd} is the _feature worktree of '${here}'. Drop --feature-slug to run '${here}', or run '${explicitSlug}' from the main checkout.`,
      };
    }
    return { slug: here };
  }
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

/**
 * The main checkout, whichever worktree the run was launched from. From the shared git dir: its
 * parent when it is a `.git`; its `core.worktree` when set (a submodule's `.git/modules/<name>`);
 * else (a bare repo, no main checkout) this worktree's top level. Every script is handed it as
 * MAIN_ROOT; scripts/main-root.sh applies the same rule to a hand run and the gates.
 */
function gitRoot() {
  const r = spawnSync("git", ["rev-parse", "--path-format=absolute", "--git-common-dir", "--show-toplevel"], { encoding: "utf8" });
  if (r.status !== 0) {
    console.error("crew-afk: not inside a git repository.");
    process.exit(1);
  }
  const [common, top] = r.stdout.trim().split("\n");
  if (basename(common) === ".git") return realpathSync(dirname(common));
  const wt = spawnSync("git", ["--git-dir", common, "config", "--get", "core.worktree"], { encoding: "utf8" }).stdout?.trim();
  return realpathSync(wt ? resolve(common, wt) : top);
}

/**
 * A new feature branch forks from the local default branch; when that is behind origin the sprint
 * starts from stale code. Warn only, after a best-effort fetch: no origin or any failure stays silent.
 */
function warnDefaultBehindOrigin(effects, defaultBranch, log) {
  if (effects.gitRead(["remote", "get-url", "origin"]).code !== 0) return;
  if (effects.gitRead(["rev-parse", "--verify", "-q", `refs/heads/${defaultBranch}`]).code !== 0) return;
  if (effects.gitRead(["fetch", "-q", "origin", defaultBranch]).code !== 0) return;
  const behind = Number(effects.gitRead(["rev-list", "--count", `refs/heads/${defaultBranch}..refs/remotes/origin/${defaultBranch}`]).stdout.trim());
  if (behind > 0) {
    log(`WARNING: local ${defaultBranch} is ${behind} commit(s) behind origin/${defaultBranch}`);
    log(`The new feature branch is created from local ${defaultBranch}; update ${defaultBranch} first to start from current code.`);
  }
}

function resolveScriptsDir(mainRoot, platform) {
  // Project install, then user-level (`TARGET_REPO=$HOME`, the documented default), then this
  // repo's source tree (dev).
  const candidates = [
    process.env.CREW_SCRIPTS,
    ...skillDirCandidates(mainRoot, platform, "crew-afk").map((d) => join(d, "scripts")),
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
      `crew-afk run|plan|status|doctor --platform ${PLATFORMS.join("|")} [--model X]\n` +
        "  [--feature-slug S] [--jira KEY] [--fix-findings actionable|critical|high|medium|none]\n" +
        "  [--max-parallel N] [--coder-timeout MIN] [--reviewer-timeout MIN]\n" +
        "  [--max-wall MIN] [--poll-interval SEC] [--no-deps] [--squash] [--open-pr] [--no-baseline] [--no-integration-check]\n" +
        "  [--allow-dirty] [--no-sync-main] [--dry-run]\n" +
        "  [--reclaim]  (take over a github-tracker feature lease held by a run that is dead)\n" +
        "  [--resume-coder-session] [--pane-host orca|herdr|auto|none]\n" +
        "  --model sets the coder's model; every role on the same runtime matches it unless\n" +
        "  .coding-crew/config.json names one. Per role (coder, reviewer, triage,\n" +
        "  commandFinder, prWriter):\n" +
        '    { "afk": { "runtime": { "reviewer": "codex" },\n' +
        '               "models":  { "claude": { "triage": "opus" } } } }\n' +
        "  The other flags override config.json's afk settings for one run: fixFindings (actionable),\n" +
        "  maxParallel, timeouts.<role|merge> (minutes), installDeps, squashCommits\n" +
        "  (false), openPr (false), baselineCheck (true), integrationCheck (true), resumeCoderSession (false),\n" +
        "  and paneHost (none; ~/.coding-crew/config.json only, and $CREW_PANE_HOST beats it).\n" +
        "  A new feature branch is <branchPrefix><KEY>-<slug>: config.json's afk.branchPrefix\n" +
        "  (default feature/, \"\" for none; no flag) and --jira KEY (e.g. PROJ-12; omitted, no KEY-).\n" +
        "  No flag: limits.<role>.usd caps one dispatch of that role in dollars (off), on a runtime that supports a cap.\n",
    );
    return 0;
  }
  if (!COMMANDS.includes(options.command)) {
    console.error(`crew-afk: unknown command ${options.command} (expected ${COMMANDS.join(", ")})`);
    return 2;
  }
  // `status` only reads the sprint's state, so it dispatches nothing and needs no platform.
  if (!options.platform && options.command !== "status") {
    console.error(`crew-afk: --platform is required (expected ${PLATFORMS.join(", ")})`);
    return 1;
  }
  if (options.platform && !PLATFORMS.includes(options.platform)) {
    console.error(`crew-afk: unknown --platform ${options.platform} (expected ${PLATFORMS.join(", ")})`);
    return 1;
  }
  for (const flag of options.retired) console.error(`crew-afk: ${retiredNotice(flag)}`);
  if (options.allowDirty) {
    console.error("crew-afk: --allow-dirty no longer does anything: uncommitted changes in the main checkout never stop a run (every issue merges into the feature branch's own worktree).");
  }
  const mainRoot = gitRoot();
  if (options.unknown.length) {
    reportUnknownArgs(options.unknown, mainRoot);
    return 1;
  }

  const scriptsDir = resolveScriptsDir(mainRoot, options.platform);
  // Once per run; every child inherits it (session-init.sh also records it in sprint.env), and
  // each asset is a fixed sub-path of it — see install-dir.mjs.
  const installDir = resolveInstallDir(process.env, HERE);
  process.env.CREW_INSTALL_DIR = installDir;
  const stderrLevel = stderrThreshold();
  const shows = (level) => atLeast(level, stderrLevel.level);
  const logLines = [];
  const effects = new Effects({
    scriptsDir,
    mainRoot,
    dryRun: options.dryRun,
    // Every script, session-init.sh first (it writes sprint.env), uses this root rather than
    // deriving its own.
    env: { MAIN_ROOT: mainRoot },
    log: (line) => {
      logLines.push(line);
      if (shows("debug")) console.error(line);
    },
  });
  if (options.command === "status") {
    // No repo-wide pointer to "the" sprint: several run in one repo.
    if (!options.featureSlug) {
      console.error("crew-afk: status needs --feature-slug <slug> (several sprints can run in one repo).");
      return 2;
    }
    const sprint = Sprint.attach(effects, options.featureSlug);
    if (!sprint) {
      console.log(`No sprint initialised (.scratch/${options.featureSlug}/sprint.env absent).`);
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
  // Once per run: a cap a role's runtime cannot apply runs that role uncapped.
  const ignoredLimits = ignoredLimitsNotice(settings.limitsUsd, crew.roles);
  if (ignoredLimits) console.error(`crew-afk: ${ignoredLimits}`);
  const pane = resolvePaneHost({ afk: loaded.config.afk, cli: options.cli, origin: loaded.origin });
  for (const n of pane.notices) console.error(`crew-afk: ${n}`);
  options.paneHost = pane.paneHost;
  // Read by pane-host/, which keeps its run-scoped state on effects too.
  effects.paneHost = options.paneHost;
  const worktreeSetting = resolveWorktreeRoot({ afk: loaded.config.afk, origin: loaded.origin });
  // worktree.mjs and the child scripts all read the location from CREW_WORKTREE_ROOT, so a
  // config.json value travels the same way rather than as a second channel.
  if (worktreeSetting) process.env.CREW_WORKTREE_ROOT = worktreeSetting;
  options.worktreeRoot = worktreeRoot(mainRoot);
  if (worktreeSetting) {
    const rel = relative(mainRoot, options.worktreeRoot);
    const inside = rel && !rel.startsWith("..") && !isAbsolute(rel);
    if (inside && spawnSync("git", ["-C", mainRoot, "check-ignore", "-q", `${rel}/`]).status !== 0) {
      console.error(`crew-afk: WARNING: worktree root ${rel} is inside the repo but not gitignored — add "${rel}/" to .gitignore.`);
    }
  }

  options.parallel = settings.maxParallel ?? DEFAULT_PARALLEL[crew.roles.coder.runtime] ?? 2;
  options.effort = settings.effort;
  options.timeoutMs = Object.fromEntries(Object.entries(settings.timeouts).map(([k, min]) => [k, min * 60 * 1000]));
  const preflightCrew = ({ probeFlags = false } = {}) =>
    crewPreflight(effects, mainRoot, {
      crew: options.crew,
      roles: activeRoles(options),
      launcher: options.platform,
      paneHost: options.paneHost,
      probeFlags,
    });

  if (options.command === "doctor") {
    const problems = preflightCrew({ probeFlags: true });
    console.log(problems.length ? problems.map((p) => `PROBLEM: ${p}`).join("\n") : `OK: ${[...new Set(activeRoles(options).map((r) => options.crew[r].runtime))].join(", ")} can dispatch.`);
    return problems.length ? 1 : 0;
  }

  // --- plan: read-only, zero tokens ----------------------------------------
  if (options.command === "plan") {
    // Resolved exactly as `run` resolves it, so the preview matches what `run` would do.
    const resolved = resolveFeatureSlug(mainRoot, options.featureSlug, options.worktreeRoot);
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
    console.log(`wall cap:  ${options.maxWallMinutes > 0 ? `${options.maxWallMinutes} minutes` : "off"}${tag("maxWallMinutes")}`);
    console.log(`poll:      ${options.pollInterval > 0 ? `every ${options.pollInterval}s while a slot is idle` : "off (--poll-interval 0)"}`);
    console.log(`findings:  fix ${{ none: "none", actionable: "every Actionable finding" }[options.fixFindings] ?? `${options.fixFindings} and above`} in Phase 2${tag("fixFindings")}`);
    console.log(`effort:    ${Object.entries(options.effort).map(([r, e]) => `${r} ${e} [${loaded.origin[`effort.${r}`] ?? "default"}]`).join(", ")}`);
    console.log(`timeouts:  ${Object.entries(options.timeouts).map(([k, m]) => `${k} ${m}m${loaded.origin[`timeouts.${k}`] ? ` [${loaded.origin[`timeouts.${k}`]}]` : ""}`).join(", ")}`);
    const caps = Object.entries(options.limitsUsd ?? {});
    console.log(`limits:    ${caps.length ? caps.map(([r, usd]) => `${r} $${usd}${ADAPTERS[options.crew[r]?.runtime]?.budget ? "" : ` (ignored: not supported by ${options.crew[r]?.runtime})`}`).join(", ") : "none (afk.limits.<role>.usd caps one dispatch)"}`);
    console.log(`pane host: ${options.paneHost ?? "none"}${tag("paneHost")}`);
    console.log(`worktrees: ${options.worktreeRoot}${tag("worktreeRoot")}`);
    console.log(`scripts:   ${scriptsDir}`);
    const missing = missingAssets(installDir);
    console.log(`install:   ${installDir}${missing.length ? ` — run would stop, missing: ${missing.map((m) => m.file).join(", ")}` : ""}`);
    console.log(`preflight: ${problems.length ? problems.join("; ") : "ok"}`);
    console.log(`dispatchable now (${issues.length}):`);
    // github issues have no `.path`, only `.number`.
    for (const i of issues) console.log(`  - ${i.slug}  [${i.status}]  ${i.path ?? `#${i.number}`}`);
    const skipped = tracker.selectDispatchable(mainRoot, { status: "deferred-findings", featureSlug: resolved.slug });
    if (skipped.length) console.log(`parked fix issues (${skipped.length}): ${skipped.map((i) => i.slug).join(", ")}`);
    console.log("\npipeline per branch: deps → dispatch → verify → review (AC + findings) → merge → close");
    console.log(`commands:  ${options.commands ? "discover-commands.sh, once per sprint (bootstrap-only), before deps (cached at .coding-crew/dev-commands.json)" : "disabled"}`);
    const offBy = (k, flag) => `disabled (${loaded.origin[k] === "flag" ? flag : `${k}: false`})`;
    console.log(`deps:      ${options.installDeps ? "ensure-deps.sh, once per sprint and once per worktree, using a discovered install command when one was cached" : offBy("installDeps", "--no-deps")}`);
    console.log(`squash:    ${options.squashCommits ? "at the end of the sprint" : loaded.origin.squashCommits ? offBy("squashCommits", "--no-squash") : "off (opt in: squashCommits: true, or --squash)"}`);
    console.log(`open PR:   ${options.openPr ? "at the end: push the feature branch, create or update its PR (Closes lines for the issues it merged)" : loaded.origin.openPr ? offBy("openPr", "--no-open-pr") : "off (opt in: openPr: true, or --open-pr)"}`);
    console.log(`baseline:  ${options.baselineCheck ? "the checks run once on the feature branch before any dispatch; red stops the run" : offBy("baselineCheck", "--no-baseline")}`);
    console.log(`integration: ${options.integrationCheck ? "the checks run on the merged feature branch each time the queue drains; red is reported and no PR is opened" : offBy("integrationCheck", "--no-integration-check")}`);
    const requiring = tracker.selectDispatchable(mainRoot, { featureSlug: resolved.slug, includeBlocked: true }).filter((i) => /^## Requires\s*$/m.test(i.text ?? ""));
    console.log(`requires:  ${requiring.length ? `${requiring.map((i) => i.slug).join(", ")} — each ## Requires runs once before that issue's first dispatch; a failing one blocks it` : "no issue declares ## Requires"}`);
    console.log(`resume:    ${options.resumeCoderSession ? "a fix round continues the coder's own session when it is small and the branch has not moved" : "fix rounds start a fresh coder session"}`);
    return issues.length ? 0 : 3;
  }

  // --- run -----------------------------------------------------------------
  // The try starts here, not around runSprint, so a setup failure also reaches the
  // end-of-run push in `finally` — the feature agent's only notice that the run ended. State is
  // declared outside it so `finally` sees whatever got assigned.
  let sprint;
  // A run-stopping failure once the sprint exists: stderr for whoever launched the run, and the
  // log, which outlives the scrollback.
  // The first line of what stopped the run, for the final push when no summary file was written.
  let failureLine;
  const fatal = (message) => {
    failureLine ??= String(message).split("\n")[0];
    console.error(message);
    if (sprint?.traceLog) writeLog(sprint.traceLog, `[ABORT] ${message}`, "fatal");
  };
  // Every other sprint line: the trace log always, stderr at or above CREW_LOG_LEVEL.
  const emit = (line, level = levelFor(line)) => {
    if (!line) return;
    if (shows(level)) console.error(line);
    if (sprint?.traceLog) writeLog(sprint.traceLog, line, level);
  };
  let resolved;
  let stalled;
  let wallCapped = false;
  let attemptCapped = false;
  let exitCode = 0;
  let runError;
  // Set where a run ends early after run-start; the others are read off stalled/wallCapped/attemptCapped.
  let endReason;
  let runStarted = false;
  // `.scratch/<slug>/traces/summary-<runId>.md`, set once ctx exists: all ctx.out printed.
  let summaryFile;
  // Set when ctx.out kept summary text off stdout because the feature agent was there to get it.
  let outWithheld = false;
  // How the end push went; `sent: true` is what lets stdout end with a pointer line.
  let endPush = null;
  let lockPath;
  let lease;
  // The sprint's `crew/<slug>/_feature` worktree, once made. Removed on every ending unless the
  // feature agent is live in it (`keep`: the developer works there next); the branch stays.
  let featureWorktree;
  const removeFeatureWorktree = ({ keep = false } = {}) => {
    if (!featureWorktree || keep) return;
    const path = featureWorktree;
    featureWorktree = null;
    removeWorktree(effects, { mainRoot, path });
    effects.git(["worktree", "prune"]);
  };
  // Children run in their own sessions, so neither a terminal ^C nor its hangup (the terminal
  // closed, an SSH session dropped) reaches them: kill them here. Lease release is best effort:
  // SIGKILL cannot be caught, and the next run reclaims a dead pid.
  const SIGNAL_EXIT = { SIGHUP: 129, SIGINT: 130, SIGTERM: 143 };
  const onSignal = (signal) => {
    killAllGroups();
    // Why it ended, as the finally block below records for every other ending after run-start.
    if (runStarted) {
      try {
        sprint.endRun(`signal ${signal}`, SIGNAL_EXIT[signal]);
      } catch (err) {
        console.error(`crew-afk: could not record why the run ended: ${err.message}`);
      }
    }
    // A live feature agent keeps its worktree, as at a normal ending (the probe blocks: this
    // handler must not yield to the pipeline its children's exits would resume).
    const agentLive = settlePaneAgent(effects);
    // Not the `_feature` workspace this run made, left open on a removed path.
    if (!agentLive) closePaneWorkspaceSync(effects);
    removeFeatureWorktree({ keep: agentLive });
    if (lease) releaseLease(effects, lease);
    process.exit(SIGNAL_EXIT[signal]);
  };
  for (const signal of Object.keys(SIGNAL_EXIT)) process.once(signal, onSignal);
  try {
    // Before any sprint output, so a human or script reading stderr knows the resolved host
    // without re-deriving it from env and config.
    console.error(`PANE-HOST: ${options.paneHost ?? "none"}`);
    // After PANE-HOST, which stays stderr's first line.
    if (stderrLevel.warning) console.error(`crew-afk: ${stderrLevel.warning}`);
    const problems = preflightCrew();
    if (problems.length) {
      console.error(problems.map((p) => `crew-afk: ${p}`).join("\n"));
      exitCode = 1;
      return exitCode;
    }

    // Before session-init.sh touches disk — see readyFeatureCandidates.
    resolved = resolveFeatureSlug(mainRoot, options.featureSlug, options.worktreeRoot);
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

    // Before anything touches disk: a reviewer without its assets
    // spends turns searching for them, and a coder without dep-install cannot run a check.
    const missing = missingAssets(installDir);
    if (missing.length) {
      console.error(missingAssetsMessage(installDir, missing));
      exitCode = 1;
      return exitCode;
    }

    if (movesLegacy) console.error(`crew-afk: ${loaded.legacyMove.apply()}`);

    const init = {
      featureSlug: resolved.slug,
      branchPrefix: options.branchPrefix,
      passthrough: options.passthrough,
    };
    // Which branch and slug session-init.sh will use, before it touches disk: the branch gets its
    // own worktree first. The main checkout is never switched.
    const named = Sprint.resolveBranch(effects, init);
    const runId = new Date().toISOString();

    // Before the worktree, the baseline and any dispatch: a second run on this feature would
    // otherwise learn of the first only at push time, with its sprint stranded. Local trackers have
    // no remote to hold a lease on, and --dry-run changes nothing.
    if (!options.dryRun && readTrackerConfig(mainRoot).tracker === "github") {
      const got = acquireLease(effects, {
        slug: named.slug,
        runId,
        reclaim: options.reclaim,
        log: (line) => console.error(line),
      });
      if (got.error) {
        console.error(got.error);
        exitCode = 1;
        return exitCode;
      }
      lease = got.lease;
    }

    // Right after the lease, before session-init.sh: every feature-branch git operation (merge,
    // sync, squash, the read-only dispatches' view of the code) runs here, so the main checkout
    // keeps the user's branch. --dry-run changes nothing, so it has no worktree to make.
    if (!options.dryRun) {
      const base = effects.gitRead(["rev-parse", "--verify", "-q", `refs/heads/${named.defaultBranch}`]).code === 0 ? named.defaultBranch : "HEAD";
      const wt = ensureWorktree(effects, {
        mainRoot,
        branch: named.branch,
        base,
        mode: "checkout",
        path: featureWorktreePath(mainRoot, named.slug),
        adopt: { title: named.slug },
      });
      if (wt.stale) {
        console.error(`crew-afk: ${wt.reason}`);
        exitCode = 1;
        return exitCode;
      }
      featureWorktree = wt.path;
      effects.featureRoot = wt.path;
      if (!wt.reusedBranch) warnDefaultBehindOrigin(effects, named.defaultBranch, (line) => console.error(line));
    }

    sprint = await Sprint.init(effects, {
      ...init,
      featureSlug: named.slug,
      fixFindings: options.fixFindings,
      // Installed below, after command discovery has cached any install override.
      deps: false,
      log: (line) => {
        if (shows("info")) console.error(line);
      },
    });
    sprint.setModel(options.model ?? "agent default");

    if (lease) {
      const leaseLog = (line, level) => {
        console.error(line);
        if (sprint.traceLog) writeLog(sprint.traceLog, line, level);
      };
      // Holding the lease means no other run is alive: any `in-progress` left in the milestone is a dead run's.
      sweepInProgress({ effects, sprint, log: leaseLog });
      // …and every awaiting-merge issue is settled: those a merged PR names have shipped.
      closeShipped({ effects, sprint, log: leaseLog });
    }
    sprint.startRun(runId);
    runStarted = true;

    // Best-effort: the log file, not this tab, is the run's durable output.
    if (options.paneHost && !options.dryRun) {
      try {
        await ensurePaneWorkspace(effects, { featureSlug: resolved.slug, logFile: sprint.traceLog });
      } catch (err) {
        console.error(`crew-afk: could not open the ${options.paneHost} log tab: ${err.message} — continuing without one.`);
      }
      // Best-effort too (it logs its own WARN): the milestone pushes it receives are advisory.
      await ensureWatchSession(effects, {
        slug: sprint.featureSlug,
        platform: options.platform,
        // The coder's resolved model, when the coder runs on this platform (else the CLI's own).
        model: options.crew.coder.runtime === options.platform ? options.model : undefined,
        effort: options.effort?.followup,
        // A failed open is a WARN that must outlive the scrollback, not a debug-level effects line.
        log: (line) => emit(line.replace(/^WARN /, ""), /^WARN /.test(line) ? "warn" : "info"),
      });
      // A reused or adopted agent may hold the checkout from an earlier run's end notice.
      queueRunStartNotice(effects, sprint.featureSlug, (result) => {
        if (!result.sent) emit(`[RUN-START-PUSH-SKIPPED] ${result.reason}`, "debug");
      });
    }

    // Before anything reads the feature branch: a resumed branch whose earlier work was
    // squash-merged lacks origin's default branch, so its baseline and version checks measure
    // from a stale merge-base. A conflict stops the run; no origin or no fetch does not.
    const sync = syncFeatureBranch({ sprint, effects, options, log: emit });
    if (sync.status === "conflict") {
      fatal(syncConflictMessage(sprint.featureBranch, sync.output));
      endReason = "preflight: origin's default branch conflicts with the feature branch";
      exitCode = 1;
      return exitCode;
    }

    // Before anything reads retention (the claims, the summary, the PR's draft reasons): a record
    // whose issue is closed or gone, or whose branch is gone, is one no run can retry.
    dropStaleRetained({ sprint, effects, options, log: emit }, await getTracker(mainRoot));

    // Before command discovery (a model call) and any worktree: a cycle or an unmatched
    // `## Blocked by` is cheaper to fix in the issue files than after a coder ran on them.
    const lint = await lintIssues({ sprint, effects, options, log: emit });
    if (lint.status === "fail" && !options.dryRun) {
      fatal(lintFailureMessage(lint.errors));
      endReason = "preflight: issue lint errors";
      exitCode = 1;
      return exitCode;
    }

    if (options.commands) {
      await discoverCommands(effects, {
        platform: options.crew.commandFinder.runtime,
        model: options.crew.commandFinder.model,
        timeoutMs: options.timeoutMs.commandFinder,
        maxBudgetUsd: options.limitsUsd?.commandFinder,
        // Persisted too: this runs unattended, and a failure must outlive the scrollback.
        log: emit,
        recordCost: (r) => sprint.recordDispatchCost(r, { slug: "commands", role: "commandFinder", attempt: 1 }),
      });
    }

    // After command discovery: ensure-deps.sh reads the install command it cached.
    if (options.installDeps) {
      // Stderr only, as before: the install's own output is debug, its DEPS: outcome info.
      await sprint.installDeps((line) => {
        if (shows(/^DEPS:/.test(line) ? "info" : "debug")) console.error(line);
      });
    }

    summaryFile = join(dirname(sprint.traceLog), `summary-${runId.replaceAll(":", "-")}.md`);
    const ctx = {
      sprint,
      effects,
      options,
      roundReviewFile: makeRoundReviewFile(sprint),
      log: emit,
      // A dispatch's [TOOL] heartbeat. The dispatch already wrote it to the trace log, and a
      // launcher agent pays tokens for every stderr line it reads, so it is debug here.
      heartbeat: (line) => {
        if (shows("debug")) console.error(line);
      },
      out: (text) => {
        // With a live feature agent the summary goes to the file alone: the agent gets it at the
        // end push, and stdout ends with a pointer or, failing that, the file (below).
        if (!effects._paneWatch) console.log(text);
        else outWithheld = true;
        try {
          appendFileSync(summaryFile, `${text}\n`);
        } catch {
          /* the file is a convenience; stdout is the summary's primary home */
        }
      },
    };

    // Once, before any dispatch, and only when there is something to dispatch. It runs alongside
    // the first coders (up to --parallel); no verify starts before its verdict, and a red one
    // stops further claims (loop.mjs) and the run (below).
    if (options.baselineCheck && !options.dryRun) {
      const tracker = await getTracker(mainRoot);
      if (tracker.selectDispatchable(mainRoot, { featureSlug: sprint.featureSlug }).length) {
        ctx.baseline = runBaselineAsync(ctx);
      }
    }

    // Once, before any dispatch: what each dispatchable issue says it needs (## Requires). A
    // failing one is blocked here, so no coder is paid to rediscover a missing credential. An
    // issue still waiting on a blocker is probed when it is first claimed (loop.mjs) instead:
    // its requirement may be what the blocker lands.
    if (!options.dryRun) {
      const tracker = await getTracker(mainRoot);
      await checkRequires(ctx, tracker.selectDispatchable(mainRoot, { featureSlug: sprint.featureSlug }));
    }

    const sprintResult = await runSprint(ctx);
    stalled = sprintResult.stalled;
    wallCapped = Boolean(sprintResult.wallCapped);
    attemptCapped = Boolean(sprintResult.capped);
    if (sprintResult.baselineFailed) {
      fatal(baselineFailureMessage(sprint.featureBranch, sprintResult.baselineFailed));
      endReason = "baseline red";
      exitCode = 1;
      return exitCode;
    }
    exitCode = stalled ? 2 : 0;
    return exitCode;
  } catch (err) {
    runError = err;
    failureLine ??= String(err?.message ?? err).split("\n")[0];
    exitCode = 1;
    if (sprint?.traceLog) writeLog(sprint.traceLog, `[CRASH] ${err?.stack || err}`, "fatal");
    throw err;
  } finally {
    // Every ending after run-start, so the next run's summary can say why this one ended (a
    // signal records its own in onSignal); a hard kill writes none, which the next run-start reads
    // as killed or crashed.
    if (runStarted) {
      const reason = runError
        ? `error: ${String(runError?.message ?? runError).split("\n")[0]}`
        : endReason ?? (wallCapped ? "wall-clock cap" : stalled ? "stalled" : attemptCapped ? "attempt cap" : "finished");
      try {
        sprint.endRun(reason, exitCode);
      } catch (err) {
        console.error(`crew-afk: could not record why the run ended: ${err.message}`);
      }
    }
    // The feature agent outlives the run: `_feature` and the workspace holding it stay while it
    // is there (a failed open, a dead agent, --dry-run or no host leaves none, and both go as before).
    const agentLive = settlePaneAgent(effects);
    // No-ops unless opened above; here so a thrown error can't leave them dangling.
    await closePaneLogTab(effects);
    await closePaneWorkspace(effects);
    // Every ending, setup failures included: a caller waiting on this push instead of
    // polling has no other way to learn the run is over.
    if (options.paneHost) {
      await drainPaneNotices(effects);
      const outcome = runError ? "errored" : exitCode === 1 ? "setup failed" : wallCapped ? "stopped at the wall-clock cap — re-run to continue" : stalled ? "stalled — blockers need a human" : "finished";
      const label = resolved?.slug ? `crew-afk (${resolved.slug})` : "crew-afk";
      // The summary file names itself; a run that never reached ctx has only the failure's first line.
      const detail = summaryFile && existsSync(summaryFile) ? `Summary: ${summaryFile}` : failureLine ?? "no summary was written";
      endPush = await notifyWatchSession(effects, `${label}: sprint ${outcome}. ${detail}`);
    }
    removeFeatureWorktree({ keep: agentLive });
    if (lease) {
      const r = releaseLease(effects, lease);
      if (r.superseded) console.error(`crew-afk: feature lease ${lease.slug} is now held by another run — left alone.`);
      if (r.failed) {
        const text = `crew-afk: could not release the feature lease: ${r.failed}\nRelease it by hand: ${r.command}`;
        console.error(text);
        console.log(`\n## Feature lease\n\n**Not released:** ${r.failed}\n\nRelease it by hand: \`${r.command}\`\n`);
        if (sprint?.traceLog) writeLog(sprint.traceLog, `[LEASE] ${text}`, "error");
      }
    }
    // Last: released earlier, a second `run` could start while this one is still closing.
    releaseSprintLock(lockPath);
    if (outWithheld && summaryFile) {
      if (endPush?.sent) {
        console.log(`crew-afk: summary sent to the ${sprint?.featureSlug ?? resolved?.slug} agent in ${effects.featureRoot} — also at ${summaryFile}`);
      } else {
        try {
          process.stdout.write(readFileSync(summaryFile, "utf8"));
        } catch {
          /* nothing was written, so nothing was withheld */
        }
      }
    }
    for (const signal of Object.keys(SIGNAL_EXIT)) process.removeListener(signal, onSignal);
  }
}

main().then(
  (code) => process.exit(code ?? 0),
  (err) => {
    console.error(`crew-afk: ${err?.stack || err}`);
    process.exit(1);
  },
);
