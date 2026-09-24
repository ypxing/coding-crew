/**
 * herdr (https://herdr.dev): a workspace container holding tabs, each with panes.
 * Ambient ids: HERDR_WORKSPACE_ID / HERDR_TAB_ID / HERDR_PANE_ID.
 */

import { failureDetail, paneHostExec, paneHostJson, paneWorkspaceLabel } from "./shared.mjs";

/** A stalled server must not hang startup. */
const STATUS_TIMEOUT_MS = 10000;

export function preflight(effects) {
  const which = effects.exec("sh", ["-c", "command -v herdr"], { mutating: false });
  if (which.code !== 0) return ["HERDR_ENV=1 but the herdr CLI was not found on PATH"];
  const status = effects.exec("herdr", ["status"], { mutating: false, timeoutMs: STATUS_TIMEOUT_MS });
  if (status.code === 124) return [`HERDR_ENV=1 but \`herdr status\` timed out after ${STATUS_TIMEOUT_MS / 1000}s — is the herdr server responding?`];
  if (status.code !== 0 || !/status:\s*running/.test(status.stdout || "")) {
    return ["HERDR_ENV=1 but the herdr server is not running — start it with: herdr server"];
  }
  return [];
}

/**
 * Inside a herdr pane already, reuse that pane's workspace (marked _paneWorkspaceReused so
 * it is never closed out from under the human using it); otherwise create one.
 */
export async function ensureWorkspace(effects, { featureSlug, logFile }) {
  const label = paneWorkspaceLabel(featureSlug);
  const triggeringWorkspaceId = process.env.HERDR_WORKSPACE_ID;
  if (triggeringWorkspaceId) {
    effects._paneWorkspaceReused = true;
    await renameTriggeringTab(effects, featureSlug);
    if (logFile) await openLogTab(effects, triggeringWorkspaceId, label, logFile);
    return triggeringWorkspaceId;
  }
  const create = await paneHostExec(effects, ["workspace", "create", "--cwd", effects.mainRoot, "--label", label, "--no-focus"]);
  const workspaceId = paneHostJson(create)?.result?.workspace?.workspace_id;
  if (create.code !== 0 || !workspaceId) {
    throw new Error(`herdr workspace create failed: ${failureDetail(create)}`);
  }
  if (logFile) await openLogTab(effects, workspaceId, label, logFile);
  return workspaceId;
}

export async function closeWorkspace(effects, workspaceId) {
  await paneHostExec(effects, ["workspace", "close", workspaceId]);
}

/** Cosmetic: a failed rename never fails the run. Skipped with no slug to rename to. */
async function renameTriggeringTab(effects, featureSlug) {
  const tabId = process.env.HERDR_TAB_ID;
  if (!featureSlug || !tabId) return;
  try {
    await paneHostExec(effects, ["tab", "rename", tabId, featureSlug]);
  } catch {
    /* cosmetic */
  }
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
      effects.mainRoot,
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

export async function notify(effects, message) {
  const paneId = process.env.HERDR_PANE_ID;
  if (!paneId) {
    effects.log?.("NOTIFY-SKIP no HERDR_PANE_ID in env");
    return { sent: false, reason: "no HERDR_PANE_ID in env" };
  }
  try {
    // --wait --until working is load-bearing: plain `agent prompt` exits 0 even when an
    // unattended pane never receives the message. --wait makes a stall a nonzero exit.
    const result = await paneHostExec(
      effects,
      ["agent", "prompt", paneId, message, "--wait", "--until", "working", "--timeout-ms", "2000"],
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
