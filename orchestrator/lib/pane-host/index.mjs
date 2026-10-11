/**
 * pane-host — the optional terminal-multiplexer integration (`effects.paneHost`: herdr | orca | null).
 * Dispatches stay headless; a host only gets a log tab, one interactive feature agent per slug and
 * best-effort pushes into it, and completion never comes from it. Run-scoped state lives on
 * `effects._pane*`; nothing here closes the feature agent or a workspace holding it.
 */

import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { ADAPTERS as PLATFORM_ADAPTERS } from "../adapters/index.mjs";
import { ROLE_POLICY, renderRolePrompt } from "../adapters/render.mjs";
import * as herdr from "./herdr.mjs";
import * as orca from "./orca.mjs";
import { insideDir, shellQuote } from "./shared.mjs";
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
 * Tells a host of a worktree the orchestrator created (`{title, issue, parent}`). Logs, never throws;
 * returns the host's promise of whether it was named, for a caller that needs to wait on it.
 */
export function adoptWorktree(effects, path, meta) {
  const adapter = adapterFor(effects);
  if (!adapter?.adoptWorktree || effects.dryRun) return undefined;
  try {
    return adapter.adoptWorktree(effects, path, meta);
  } catch (err) {
    effects.log?.(`WARN pane host ${effects.paneHost}: could not adopt worktree ${path} — ${err.message}`);
    return undefined;
  }
}

/**
 * Cached as a promise before the first await, so concurrent callers never race two creates; a
 * rejection is cached too, so a broken host fails every caller once.
 */
export function ensurePaneWorkspace(effects, { featureSlug, logFile } = {}) {
  if (!effects._paneWorkspace) {
    effects._paneWorkspace = adapterFor(effects).ensureWorkspace(effects, { featureSlug, logFile });
  }
  return effects._paneWorkspace;
}

/** Not while the feature agent lives in it. Swallows failures: the run's exit code is already decided. */
export async function closePaneWorkspace(effects) {
  if (!effects._paneWorkspace || hasPaneAgent(effects)) return;
  try {
    await adapterFor(effects).closeWorkspace(effects, await effects._paneWorkspace);
  } catch {
    /* already reported where it first failed, or nothing was ever created */
  }
}

/** closePaneWorkspace for a signal handler, which must not yield. */
export function closePaneWorkspaceSync(effects) {
  if (hasPaneAgent(effects)) return;
  try {
    adapterFor(effects)?.closeWorkspaceSync?.(effects);
  } catch {
    /* cosmetic */
  }
}

/** The log tab is this run's own even when its workspace is not. */
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

/** spawnWithTimeout's contract, in a worker terminal when the host has them; never under --dry-run. */
export function spawnDispatch(effects, cmd, args, opts) {
  const adapter = adapterFor(effects);
  if (effects.dryRun || !adapter?.openWorkerTerminal) return effects.spawnWithTimeout(cmd, args, opts);
  return spawnInWorkerTerminal(effects, adapter, cmd, args, opts);
}

export const watchFile = (mainRoot, slug) => join(mainRoot, ".scratch", slug, "watch.json");

export function recordedWatch(file, host) {
  try {
    const rec = JSON.parse(readFileSync(file, "utf8"));
    return rec?.host === host && typeof rec.handle === "string" && rec.handle ? { host, handle: rec.handle } : null;
  } catch {
    return null;
  }
}

export const hasPaneAgent = (effects) => Boolean(effects._paneWatch?.handle);

/** How long after opening an agent the host may not yet identify it as one. */
export const AGENT_START_GRACE_MS = 120_000;

/**
 * End of run: drops a dead feature agent so nothing is kept for it. Blocking, for a signal handler.
 * Within AGENT_START_GRACE_MS of opening, presence alone counts. Returns whether a live agent remains.
 */
export function settlePaneAgent(effects) {
  if (!hasPaneAgent(effects)) return false;
  const { handle } = effects._paneWatch;
  let alive = false;
  try {
    const adapter = adapterFor(effects);
    alive = Boolean(adapter?.watchAliveSync?.(effects, handle));
    // Presence alone stands in only while the CLI may still be starting: herdr's pane (and its shell)
    // outlives an agent that exited, so later a listed pane is no sign of one.
    const starting = !effects._paneWatchReused && Date.now() - (effects._paneWatchOpenedAt ?? 0) < AGENT_START_GRACE_MS;
    if (!alive && starting) alive = Boolean(adapter?.watchPresentSync?.(effects, handle));
  } catch {
    /* an unreachable host reads as no agent */
  }
  if (!alive) {
    effects.log?.(`WATCH-SESSION gone host=${effects._paneWatch.host} handle=${handle} — nothing is kept for it`);
    effects._paneWatch = null;
  }
  return alive;
}

/**
 * The feature agent, one per slug: the one in `watch.json` while alive, else the launching pane
 * inside `_feature`, else a new CLI briefed by `followup` (CREW_PANE_HOST set, so its crew-afk
 * commands resolve this host). Best-effort: a failure is a WARN and a null `_paneWatch`.
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
    effects._paneWatchOpenedAt = Date.now();
    record(file, watch);
    log?.(`WATCH-SESSION opened host=${watch.host} handle=${watch.handle}`);
    return (effects._paneWatch = watch);
  } catch (err) {
    effects._paneWatch = null;
    return fail(err.message);
  }
}

/** One advisory push into the feature agent; `{sent, reason?}` is for a caller with a durable log. */
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

/** Queued, not awaited: an orca push takes ~8s and would hold the issue's pipeline. Kept in order. */
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
 * First push to a reused or adopted agent: the sprint merges into `_feature` again, so
 * followup.md's "until the end notice" rules apply again.
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
