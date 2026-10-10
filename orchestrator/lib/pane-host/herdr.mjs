/**
 * herdr (https://herdr.dev): a workspace container holding tabs, each with panes. The sprint's
 * workspace is its `_feature` worktree's, holding the log tab and the feature agent's tab.
 * Ambient id: HERDR_PANE_ID (the launching pane, adopted as the agent when it is inside `_feature`).
 */

import { failureDetail, paneHostExec, paneHostJson, paneWorkspaceLabel } from "./shared.mjs";

/** A stalled server must not hang startup. */
const STATUS_TIMEOUT_MS = 10000;

export function preflight(effects) {
  const which = effects.exec("sh", ["-c", "command -v herdr"], { mutating: false });
  if (which.code !== 0) return ["pane host herdr, but the herdr CLI was not found on PATH"];
  const status = effects.exec("herdr", ["status"], { mutating: false, timeoutMs: STATUS_TIMEOUT_MS });
  if (status.code === 124) return [`pane host herdr, but \`herdr status\` timed out after ${STATUS_TIMEOUT_MS / 1000}s — is the herdr server responding?`];
  if (status.code !== 0 || !/status:\s*running/.test(status.stdout || "")) {
    return ["pane host herdr, but the herdr server is not running — start it with: herdr server"];
  }
  return [];
}

/** The pane that launched this run, for D6's adoption: herdr's ambient pane id. */
export const launcherHandle = () => process.env.HERDR_PANE_ID || null;

/**
 * The sprint's workspace is its feature-branch worktree (`worktree open` returns the workspace
 * already open on it, so a re-run reuses the one a live agent sits in, whatever pane launched this
 * run); with none (a dry run) the main checkout. Never the triggering workspace.
 * Returns `{workspaceId, created}`: `created` is false for a workspace `worktree open` found
 * already open (its `already_open`, which a host that omits it leaves false too: not ours to close).
 */
async function openFeatureWorkspace(effects, label) {
  const inWorktree = Boolean(effects.featureRoot) && effects.featureRoot !== effects.mainRoot;
  const create = inWorktree
    ? await paneHostExec(effects, ["worktree", "open", "--path", effects.featureRoot, "--label", label, "--no-focus"])
    : await paneHostExec(effects, ["workspace", "create", "--cwd", effects.mainRoot, "--label", label, "--no-focus"]);
  const result = paneHostJson(create)?.result;
  const workspaceId = result?.workspace?.workspace_id;
  if (create.code !== 0 || !workspaceId) {
    throw new Error(`herdr ${inWorktree ? "worktree open" : "workspace create"} failed: ${failureDetail(create)}`);
  }
  return { workspaceId, created: inWorktree ? result.already_open === false : true };
}

export async function ensureWorkspace(effects, { featureSlug, logFile }) {
  const label = paneWorkspaceLabel(featureSlug);
  const { workspaceId, created } = await openFeatureWorkspace(effects, label);
  effects._paneWorkspaceCreated = created;
  if (logFile) await openLogTab(effects, workspaceId, label, logFile);
  return workspaceId;
}

/** Closes only a workspace this run made; one that was already open is left to whoever opened it. */
export async function closeWorkspace(effects, workspaceId) {
  if (!effects._paneWorkspaceCreated) return;
  await paneHostExec(effects, ["workspace", "close", workspaceId]);
}

/**
 * `pane run` cannot report an exit code back, so the only thing herdr is ever asked to run
 * is a `tail -f` whose outcome nothing reads. Best-effort: never throws.
 */
async function openLogTab(effects, workspaceId, label, logFile) {
  try {
    const create = await paneHostExec(effects, [
      "tab",
      "create",
      "--workspace",
      workspaceId,
      "--cwd",
      effects.featureRoot ?? effects.mainRoot,
      "--label",
      `${label}-log`,
      "--no-focus",
    ]);
    const tabId = paneHostJson(create)?.result?.tab?.tab_id;
    const paneId = paneHostJson(create)?.result?.root_pane?.pane_id;
    if (create.code !== 0 || !paneId) return;
    effects._paneLogTabId = tabId;
    await paneHostExec(effects, ["pane", "run", paneId, "tail", "-f", logFile]);
  } catch {
    /* cosmetic */
  }
}

export async function closeLogTab(effects, tabId) {
  await paneHostExec(effects, ["tab", "close", tabId]);
}

/** Whether `paneId` is listed with an `agent_status` other than `unknown` (herdr detected an agent in it). */
export async function watchAlive(effects, paneId) {
  try {
    const list = await paneHostExec(effects, ["pane", "list"], STATUS_TIMEOUT_MS);
    if (list.code !== 0) return false;
    const pane = (paneHostJson(list)?.result?.panes ?? []).find((p) => p?.pane_id === paneId);
    const status = pane?.agent_status;
    return typeof status === "string" && status !== "" && status !== "unknown";
  } catch {
    return false;
  }
}

/**
 * The feature agent: a tab in the feature worktree's workspace (the one ensureWorkspace opened,
 * else `worktree open` again, which returns it), cwd `_feature`. Its workspace is not closed while
 * the agent lives (closePaneWorkspace). The agent is started with `pane run`; herdr detects it as
 * one. Returns `{handle}` (the pane id) or `{failure}`; a tab made before `pane run` failed is
 * closed again. Never throws.
 */
export async function openWatch(effects, { slug, command }) {
  let tabId = null;
  try {
    let workspaceId = null;
    try {
      workspaceId = (await effects._paneWorkspace) ?? null;
    } catch {
      /* the log tab's create failed: open the workspace again below */
    }
    workspaceId ??= (await openFeatureWorkspace(effects, paneWorkspaceLabel(slug))).workspaceId;
    const create = await paneHostExec(effects, [
      "tab",
      "create",
      "--workspace",
      workspaceId,
      "--cwd",
      effects.featureRoot ?? effects.mainRoot,
      "--label",
      `${slug}-watch`,
      "--no-focus",
    ]);
    const result = paneHostJson(create)?.result;
    tabId = result?.tab?.tab_id ?? null;
    let paneId = result?.root_pane?.pane_id;
    if (create.code === 0 && !paneId) {
      const list = await paneHostExec(effects, ["pane", "list", "--workspace", workspaceId], STATUS_TIMEOUT_MS);
      paneId = paneHostJson(list)?.result?.panes?.[0]?.pane_id;
    }
    if (create.code !== 0 || !paneId) return { failure: `herdr tab create exit=${create.code} ${failureDetail(create)}` };
    const run = await paneHostExec(effects, ["pane", "run", paneId, command]);
    if (run.code !== 0) {
      await closeTab(effects, tabId);
      return { failure: `herdr pane run exit=${run.code} ${failureDetail(run)}` };
    }
    return { handle: paneId };
  } catch (err) {
    await closeTab(effects, tabId);
    return { failure: `herdr feature agent threw: ${err.message}` };
  }
}

/** Closes a tab made for the agent when a later call failed. Cosmetic: never throws. */
async function closeTab(effects, tabId) {
  if (!tabId) return;
  try {
    await paneHostExec(effects, ["tab", "close", tabId], STATUS_TIMEOUT_MS);
  } catch {
    /* cosmetic */
  }
}

export async function notify(effects, paneId, message) {
  try {
    // --wait --until working is load-bearing: plain `agent prompt` exits 0 even when an
    // unattended pane never receives the message. --wait makes a stall a nonzero exit.
    const result = await paneHostExec(
      effects,
      ["agent", "prompt", paneId, message, "--wait", "--until", "working", "--timeout", "2000"],
      5000,
    );
    // spawnWithTimeout resolves on a nonzero exit rather than rejecting.
    if (result.code !== 0) {
      const reason = `herdr agent prompt exit=${result.code} ${failureDetail(result)}`;
      effects.log?.(`NOTIFY-FAIL ${reason}`);
      return { sent: false, reason };
    }
    return { sent: true };
  } catch (err) {
    const reason = `herdr agent prompt threw: ${err.message}`;
    effects.log?.(`NOTIFY-FAIL ${reason}`);
    return { sent: false, reason };
  }
}
