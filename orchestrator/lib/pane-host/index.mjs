/**
 * pane-host — the ambient integration with a terminal multiplexer, selected by
 * `effects.paneHost` ("herdr" | "orca" | null; resolvePaneHost in crew-config.mjs).
 *
 * Every coder/reviewer/triage dispatch is headless regardless of host. A host is asked for
 * one tab/terminal tailing the sprint's trace log, and one best-effort outcome push into the
 * pane that launched the run. Each adapter (herdr.mjs, orca.mjs) implements the same five
 * operations for those: preflight, ensureWorkspace, closeWorkspace, closeLogTab, notify.
 *
 * An adapter that also has openWorkerTerminal/closeWorkerTerminal (orca only) hosts each
 * headless dispatch in a terminal of its own, for watching (worker-terminal.mjs). Completion
 * still comes from the child's pid and exit code on disk, never from the host.
 *
 * Run-scoped state lives on `effects`: `_paneWorkspace` (cached promise),
 * `_paneWorkspaceReused` (never close a workspace this run didn't create),
 * `_paneLogTabId` and `_paneNotices` (the queued-push chain).
 */

import * as herdr from "./herdr.mjs";
import * as orca from "./orca.mjs";
import { spawnInWorkerTerminal } from "./worker-terminal.mjs";

const ADAPTERS = { herdr, orca };

function adapterFor(effects) {
  return ADAPTERS[effects.paneHost] ?? null;
}

/** Problems that should stop the sprint at startup, before any dispatch discovers them. */
export function preflightPaneHost(effects, paneHost) {
  return ADAPTERS[paneHost]?.preflight(effects) ?? [];
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
  if (!effects._paneLogTabId) return;
  try {
    await adapterFor(effects).closeLogTab(effects, effects._paneLogTabId);
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

/**
 * One advisory push into the triggering pane, so a caller waiting in it can stop polling.
 * Never throws. Returns `{sent, reason?}` so a caller with a durable log (notifyMilestone
 * in pipeline.mjs) can record a skip or failure — `effects.log` alone goes nowhere durable.
 */
export async function notifyTriggeringPane(effects, message) {
  const adapter = adapterFor(effects);
  if (!adapter) return { sent: false, reason: "no pane host" };
  return adapter.notify(effects, message);
}

/**
 * A mid-run push: queued, not awaited. An orca push takes ~8s (terminal show + send), and
 * awaited inline it held each issue's pipeline that long. The chain keeps pushes into the one
 * pane in order and never overlapping. `onResult` gets notifyTriggeringPane's `{sent, reason?}`.
 */
export function queuePaneNotice(effects, message, onResult) {
  const prior = effects._paneNotices ?? Promise.resolve();
  effects._paneNotices = prior.then(async () => {
    const result = await notifyTriggeringPane(effects, message);
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
