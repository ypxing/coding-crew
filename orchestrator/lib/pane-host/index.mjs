/**
 * pane-host — the ambient integration with a terminal multiplexer, selected by
 * `effects.paneHost` ("herdr" | "orca" | null; resolvePaneHost in crew-config.mjs).
 *
 * Every coder/reviewer/triage dispatch is headless regardless of host. A host is asked for
 * one tab/terminal tailing the sprint's trace log, one long-lived interactive watch agent for
 * the sprint's slug (ensureWatchSession), and best-effort pushes into that agent: each
 * milestone and the outcome. Never into the pane that launched the run. Each adapter (herdr.mjs,
 * orca.mjs) implements the same operations for those: preflight, ensureWorkspace, closeWorkspace,
 * closeLogTab, openWatch, watchAlive, notify.
 * An adapter may also implement a follow-up worker's three ops, openFollowup / awaitFollowup /
 * replyFollowup (see below; `crew-afk followup`, lib/followup.mjs), and adoptWorktree (orca only): told of each worktree the orchestrator
 * creates, so the host can show it by name under its parent. See adoptWorktree below.
 *
 * An adapter that also has openWorkerTerminal/closeWorkerTerminal (orca only) hosts each
 * headless dispatch in a terminal of its own, for watching (worker-terminal.mjs). Completion
 * still comes from the child's pid and exit code on disk, never from the host.
 *
 * Run-scoped state lives on `effects`: `_paneWorkspace` (cached promise),
 * `_paneWorkspaceReused` (never close a workspace this run didn't create),
 * `_paneLogTabId`, `_paneNotices` (the queued-push chain) and `_paneWatch` (`{host, handle}` of
 * the watch agent, null when none opened). The watch agent is never closed by anything here.
 */

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

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
 * End of run. A no-op when nothing was created or the workspace was reused. Swallows
 * failures: the run's exit code is already decided, and a stray workspace is cosmetic.
 */
export async function closePaneWorkspace(effects) {
  if (!effects._paneWorkspace || effects._paneWorkspaceReused) return;
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
 * The sprint's watch agent: its platform CLI, interactive, in the main checkout, briefed by the
 * `watcher` role as its initial prompt and started with crew-afk's env (worker-terminal.mjs's
 * writeLaunchScript). One per slug: the handle recorded in `watch.json` is reused while the host
 * still reports a live agent there; a dead or missing one is replaced and the file rewritten.
 * Best-effort, never throws: a failure is a WARN and a null `_paneWatch`, so later pushes are
 * skipped and the run's exit code is what it would be with no host. No-op under --dry-run or
 * with no host. Returns `{host, handle}` or null.
 */
export async function ensureWatchSession(effects, { slug, platform, model, effort } = {}) {
  effects._paneWatch = null;
  const adapter = adapterFor(effects);
  if (!adapter?.openWatch || effects.dryRun || !slug) return null;
  const fail = (reason) => {
    effects.log?.(`WARN watch session (${effects.paneHost}): ${reason} — no watch agent, pushes are skipped`);
    return null;
  };
  try {
    const file = watchFile(effects.mainRoot, slug);
    const recorded = recordedWatch(file, effects.paneHost);
    if (recorded && (await adapter.watchAlive(effects, recorded.handle))) {
      effects.log?.(`WATCH-SESSION reused host=${recorded.host} handle=${recorded.handle}`);
      return (effects._paneWatch = recorded);
    }

    const agent = PLATFORM_ADAPTERS[platform];
    if (!agent?.interactive) return fail(`platform ${platform} has no interactive mode`);
    const found = effects.exec?.("sh", ["-c", `command -v ${shellQuote(agent.cmd)}`], { mutating: false });
    if (found && found.code !== 0) return fail(`the ${agent.cmd} CLI was not found on PATH`);

    const policy = { ...ROLE_POLICY.watcher, ...(effort ? { effort } : {}) };
    const argv = agent.interactive({
      cwd: effects.mainRoot,
      mainRoot: effects.mainRoot,
      model,
      protocol: renderRolePrompt("watcher", platform, { mainRoot: effects.mainRoot }),
      policy,
    });
    const { command } = writeLaunchScript(effects, {
      dir: join(effects.mainRoot, ".scratch", slug, "watch"),
      cwd: effects.mainRoot,
      argv,
      env: agent.env,
    });
    const opened = await adapter.openWatch(effects, { slug, command });
    if (!opened.handle) return fail(opened.failure);

    const watch = { host: effects.paneHost, handle: opened.handle };
    try {
      mkdirSync(join(effects.mainRoot, ".scratch", slug), { recursive: true });
      writeFileSync(file, `${JSON.stringify(watch)}\n`);
    } catch (err) {
      effects.log?.(`WARN watch session: could not record ${file} — ${err.message}; a later run opens a new agent`);
    }
    effects.log?.(`WATCH-SESSION opened host=${watch.host} handle=${watch.handle}`);
    return (effects._paneWatch = watch);
  } catch (err) {
    effects._paneWatch = null;
    return fail(err.message);
  }
}

/**
 * One advisory push into the sprint's watch agent, so a caller waiting in it can stop polling.
 * Never throws. Returns `{sent, reason?}` so a caller with a durable log (notifyMilestone
 * in pipeline.mjs) can record a skip or failure — `effects.log` alone goes nowhere durable.
 * The target is always `_paneWatch`'s handle: never ORCA_TERMINAL_HANDLE or HERDR_PANE_ID.
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

/** Before the end-of-run push, so it lands last and none is cut off by exit. */
export async function drainPaneNotices(effects) {
  await effects._paneNotices;
}

/**
 * Follow-ups: a feature-level worker agent the watch agent asks for work, reached over the host's
 * own agent channel (orca `orchestration`, herdr `agent`). Each op returns the adapter's result
 * (`{failure}` when the host call failed, with the host's own text) and never throws.
 */

/** Whether the selected host (none, for no host) can run a follow-up worker. */
export function supportsFollowups(effects) {
  const adapter = adapterFor(effects);
  return Boolean(adapter?.openFollowup && adapter.awaitFollowup && adapter.replyFollowup);
}

async function followupOp(effects, op, ...args) {
  try {
    return await adapterFor(effects)[op](effects, ...args);
  } catch (err) {
    return { failure: `${effects.paneHost} ${op} threw: ${err.message}` };
  }
}

/**
 * The follow-up worker: the platform CLI interactive in `worktree` with `command` (a launch
 * script carrying crew-afk's env, as for the watch agent), given `spec`, the brief and the task.
 * `coordinator` is the watch agent's handle. Returns the host's record of it (`runId` and
 * `terminal` under orca, `handle` under herdr), or `{failure}`.
 */
export const openFollowup = (effects, o) => followupOp(effects, "openFollowup", o);

/** Blocks until the worker answers: `{kind: "done"|"question", text, messageId?}` or `{failure}`. */
export const awaitFollowup = (effects, rec, o) => followupOp(effects, "awaitFollowup", rec, o);

/** Delivers the answer to the worker's open question; `{failure}` when the host refused it. */
export const replyFollowup = (effects, rec, answer) => followupOp(effects, "replyFollowup", rec, answer);
