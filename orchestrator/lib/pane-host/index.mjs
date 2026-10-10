/**
 * pane-host — the ambient integration with a terminal multiplexer, selected by
 * `effects.paneHost` ("herdr" | "orca" | null; resolvePaneHost in crew-config.mjs).
 *
 * Every coder/reviewer/triage dispatch is headless regardless of host. A host is asked for
 * one tab/terminal tailing the sprint's trace log and one long-lived interactive feature agent
 * for the sprint's slug (ensureWatchSession), both in the sprint's own `_feature` worktree
 * (`effects.featureRoot`), and best-effort pushes into that agent: each milestone and the
 * outcome. Each adapter (herdr.mjs, orca.mjs) implements the same operations for those:
 * preflight, ensureWorkspace, closeWorkspace, closeLogTab, openWatch, watchAlive, notify,
 * launcherHandle.
 * An adapter may also implement adoptWorktree (orca only): told of each worktree the orchestrator
 * creates, so the host can show it by name under its parent. See adoptWorktree below.
 *
 * An adapter that also has openWorkerTerminal/closeWorkerTerminal (orca only) hosts each
 * headless dispatch in a terminal of its own, for watching (worker-terminal.mjs). Completion
 * still comes from the child's pid and exit code on disk, never from the host.
 *
 * Run-scoped state lives on `effects`: `_paneWorkspace` (cached promise),
 * `_paneLogTabId`, `_paneNotices` (the queued-push chain), `_paneWatch` (`{host, handle}` of
 * the feature agent, null when none is live) and `_paneWatchReused` (that agent was reused or
 * adopted, not opened by this run: it may hold the checkout from an earlier run's end notice). The agent is never closed by anything here, and
 * neither is a workspace holding it.
 */

import { mkdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { isAbsolute, join, relative } from "node:path";

import { ADAPTERS as PLATFORM_ADAPTERS } from "../adapters/index.mjs";
import { ROLE_POLICY, renderRolePrompt } from "../adapters/render.mjs";
import * as herdr from "./herdr.mjs";
import * as orca from "./orca.mjs";
import { shellQuote } from "./shared.mjs";
import { spawnInWorkerTerminal, writeLaunchScript } from "./worker-terminal.mjs";

const ADAPTERS = { herdr, orca };

function adapterFor(effects) {
  return ADAPTERS[effects.paneHost] ?? null;
}

/** Problems that should stop the sprint at startup, before any dispatch discovers them. */
export function preflightPaneHost(effects, paneHost) {
  return ADAPTERS[paneHost]?.preflight(effects) ?? [];
}

/**
 * Announce a worktree the orchestrator just created (native git; the host never creates one) to
 * a host that wants to know of it: `{title, issue, parent}` is its display name, its issue number
 * and its parent worktree's path. Best-effort and synchronous, called from ensureWorktree: a
 * failure is logged, never thrown, and no host (or one without the op) calls nothing.
 */
export function adoptWorktree(effects, path, meta) {
  const adapter = adapterFor(effects);
  if (!adapter?.adoptWorktree || effects.dryRun) return;
  try {
    adapter.adoptWorktree(effects, path, meta);
  } catch (err) {
    effects.log?.(`WARN pane host ${effects.paneHost}: could not adopt worktree ${path} — ${err.message}`);
  }
}

/**
 * Created by whichever caller gets here first, shared by every later one. Cached as a
 * promise, assigned before the first await, so concurrent callers never race two creates;
 * a rejection is cached too, so a broken host fails every caller the same way once.
 */
export function ensurePaneWorkspace(effects, { featureSlug, logFile } = {}) {
  if (!effects._paneWorkspace) {
    effects._paneWorkspace = adapterFor(effects).ensureWorkspace(effects, { featureSlug, logFile });
  }
  return effects._paneWorkspace;
}

/**
 * End of run. A no-op when nothing was created, or while the feature agent lives in it (it is
 * the developer's terminal now). Swallows failures: the run's exit code is already decided, and
 * a stray workspace is cosmetic.
 */
export async function closePaneWorkspace(effects) {
  if (!effects._paneWorkspace || hasPaneAgent(effects)) return;
  try {
    await adapterFor(effects).closeWorkspace(effects, await effects._paneWorkspace);
  } catch {
    /* already reported where it first failed, or nothing was ever created */
  }
}

/**
 * End of run, alongside closePaneWorkspace: the log tab is this run's own even when the
 * workspace it lives in is not. Swallows failures (an already-closed tab, for one).
 */
export async function closePaneLogTab(effects) {
  if (effects._paneLogTabId) {
    try {
      await adapterFor(effects).closeLogTab(effects, effects._paneLogTabId);
    } catch {
      /* cosmetic */
    }
  }
  // Sweep: any terminal this run opened that a close never confirmed gone.
  try {
    await adapterFor(effects)?.closeTerminals?.(effects);
  } catch {
    /* cosmetic */
  }
}

/**
 * spawnWithTimeout's contract, hosted in a worker terminal when the pane host has them.
 * `--dry-run` always takes spawnWithTimeout, which records instead of running.
 */
export function spawnDispatch(effects, cmd, args, opts) {
  const adapter = adapterFor(effects);
  if (effects.dryRun || !adapter?.openWorkerTerminal) return effects.spawnWithTimeout(cmd, args, opts);
  return spawnInWorkerTerminal(effects, adapter, cmd, args, opts);
}

/** `.scratch/<slug>/watch.json`: `{host, handle}` of the slug's watch agent. */
export const watchFile = (mainRoot, slug) => join(mainRoot, ".scratch", slug, "watch.json");

/** The recorded `{host, handle}` when it is usable under `host`; null for a missing, unparseable or another host's. */
export function recordedWatch(file, host) {
  try {
    const rec = JSON.parse(readFileSync(file, "utf8"));
    return rec?.host === host && typeof rec.handle === "string" && rec.handle ? { host, handle: rec.handle } : null;
  } catch {
    return null;
  }
}

/**
 * Whether this run has a feature agent: one reused, adopted or opened at its start, and not
 * dropped since (a failed open leaves none). It decides what outlives the run (`_feature`, the
 * agent's workspace), so a push that later finds the agent closed is only a skipped push.
 */
export const hasPaneAgent = (effects) => Boolean(effects._paneWatch?.handle);

/** Whether `dir` is `root` or inside it, by real path. */
function insideDir(root, dir) {
  const rel = relative(realpathOr(root), realpathOr(dir));
  return rel === "" || (!rel.startsWith("..") && !isAbsolute(rel));
}

function realpathOr(path) {
  try {
    return realpathSync(path);
  } catch {
    return path;
  }
}

/**
 * The sprint's feature agent: its platform CLI, interactive, in `crew/<slug>/_feature`
 * (`effects.featureRoot`), briefed by the `followup` role as its initial prompt and started with
 * crew-afk's env (worker-terminal.mjs's writeLaunchScript), plus `CREW_PANE_HOST=<the host this
 * run resolved>`, so a crew-afk command the agent runs resolves the same host as this run. One
 * per slug, in this order:
 *   1. the handle recorded in `watch.json`, while the host still reports a live agent there;
 *   2. the pane that launched this run (ORCA_TERMINAL_HANDLE / HERDR_PANE_ID), when cwd is inside
 *      `_feature` and the host reports a live agent there: recorded in `watch.json`, no agent opens;
 *   3. a new agent, its handle recorded (a dead or missing one is replaced).
 * Best-effort, never throws: a failure is a WARN and a null `_paneWatch`, so later pushes are
 * skipped and the run's exit code is what it would be with no host. No-op under --dry-run or
 * with no host. Returns `{host, handle}` or null. `log` receives its lines (default `effects.log`).
 */
export async function ensureWatchSession(effects, { slug, platform, model, effort, log = effects.log?.bind(effects) } = {}) {
  effects._paneWatch = null;
  effects._paneWatchReused = false;
  const adapter = adapterFor(effects);
  if (!adapter?.openWatch || effects.dryRun || !slug) return null;
  const cwd = effects.featureRoot ?? effects.mainRoot;
  // The launch env file holds credentials and is only deleted by a script a host actually ran.
  let envFile = null;
  const fail = (reason) => {
    if (envFile) rmSync(envFile, { force: true });
    log?.(`WARN watch session (${effects.paneHost}): ${reason} — no watch agent, pushes are skipped`);
    return null;
  };
  const record = (file, watch) => {
    try {
      mkdirSync(join(effects.mainRoot, ".scratch", slug), { recursive: true });
      writeFileSync(file, `${JSON.stringify(watch)}\n`);
    } catch (err) {
      log?.(`WARN watch session: could not record ${file} — ${err.message}; a later run opens a new agent`);
    }
  };
  try {
    const file = watchFile(effects.mainRoot, slug);
    const recorded = recordedWatch(file, effects.paneHost);
    if (recorded && (await adapter.watchAlive(effects, recorded.handle))) {
      log?.(`WATCH-SESSION reused host=${recorded.host} handle=${recorded.handle}`);
      effects._paneWatchReused = true;
      return (effects._paneWatch = recorded);
    }

    // Launched from an agent pane inside `_feature`: that pane is the agent.
    const launcher = adapter.launcherHandle?.();
    if (launcher && effects.featureRoot && insideDir(effects.featureRoot, process.cwd()) && (await adapter.watchAlive(effects, launcher))) {
      const watch = { host: effects.paneHost, handle: launcher };
      record(file, watch);
      log?.(`WATCH-SESSION adopted host=${watch.host} handle=${watch.handle}`);
      effects._paneWatchReused = true;
      return (effects._paneWatch = watch);
    }

    const agent = PLATFORM_ADAPTERS[platform];
    if (!agent?.interactive) return fail(`platform ${platform} has no interactive mode`);
    const found = effects.exec?.("sh", ["-c", `command -v ${shellQuote(agent.cmd)}`], { mutating: false });
    if (found && found.code !== 0) return fail(`the ${agent.cmd} CLI was not found on PATH`);

    const policy = { ...ROLE_POLICY.followup, ...(effort ? { effort } : {}) };
    const argv = agent.interactive({
      cwd,
      mainRoot: effects.mainRoot,
      model,
      protocol: renderRolePrompt("followup", platform, { mainRoot: effects.mainRoot }),
      policy,
    });
    const launch = writeLaunchScript(effects, {
      dir: join(effects.mainRoot, ".scratch", slug, "watch"),
      cwd,
      argv,
      env: { ...agent.env, CREW_PANE_HOST: effects.paneHost },
    });
    envFile = launch.envFile;
    const { command } = launch;
    const opened = await adapter.openWatch(effects, { slug, command });
    if (!opened.handle) return fail(opened.failure);

    const watch = { host: effects.paneHost, handle: opened.handle };
    record(file, watch);
    log?.(`WATCH-SESSION opened host=${watch.host} handle=${watch.handle}`);
    return (effects._paneWatch = watch);
  } catch (err) {
    effects._paneWatch = null;
    return fail(err.message);
  }
}

/**
 * One advisory push into the sprint's feature agent, so a caller waiting in it can stop polling.
 * Never throws. Returns `{sent, reason?}` so a caller with a durable log (notifyMilestone
 * in pipeline.mjs) can record a skip or failure — `effects.log` alone goes nowhere durable.
 * The target is always `_paneWatch`'s handle: the launching pane only when ensureWatchSession adopted it.
 */
export async function notifyWatchSession(effects, message) {
  const adapter = adapterFor(effects);
  if (!adapter) return { sent: false, reason: "no pane host" };
  const handle = effects._paneWatch?.handle;
  if (!handle) {
    effects.log?.("NOTIFY-SKIP no watch session");
    return { sent: false, reason: "no watch session" };
  }
  return adapter.notify(effects, handle, message);
}

/**
 * A mid-run push: queued, not awaited. An orca push takes ~8s (terminal show + send), and
 * awaited inline it held each issue's pipeline that long. The chain keeps pushes into the one
 * agent in order and never overlapping. `onResult` gets notifyWatchSession's `{sent, reason?}`.
 */
export function queuePaneNotice(effects, message, onResult) {
  const prior = effects._paneNotices ?? Promise.resolve();
  effects._paneNotices = prior.then(async () => {
    const result = await notifyWatchSession(effects, message);
    try {
      onResult?.(result);
    } catch {
      /* a logging callback must not break the chain */
    }
  });
}

/**
 * The first push of a run, to an agent it reused or adopted (a new one is briefed as it starts):
 * the sprint is merging into `_feature` again, so followup.md's "until the end notice" rules apply
 * again to an agent an earlier run's end notice handed the checkout. Queued like a milestone.
 */
export function queueRunStartNotice(effects, slug, onResult) {
  if (!effects._paneWatchReused || !effects._paneWatch?.handle) return;
  queuePaneNotice(
    effects,
    `[${slug}] crew-afk run started — the sprint is merging into this checkout again: leave it unchanged until the end notice.`,
    onResult,
  );
}

/** Before the end-of-run push, so it lands last and none is cut off by exit. */
export async function drainPaneNotices(effects) {
  await effects._paneNotices;
}
