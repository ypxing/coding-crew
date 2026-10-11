/** herdr (https://herdr.dev): a workspace holds tabs, each with panes; the sprint's is its `_feature` worktree's. */

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

export const launcherHandle = () => process.env.HERDR_PANE_ID || null;

/**
 * `worktree open` returns the workspace already open on `_feature`, so a re-run reuses the one a
 * live agent sits in; `created` is false for it (not ours to close). `--cwd` names the repo: herdr
 * resolves `--path` against it (or the focused workspace), not the CLI's cwd.
 */
async function openFeatureWorkspace(effects, label) {
  const inWorktree = Boolean(effects.featureRoot) && effects.featureRoot !== effects.mainRoot;
  const create = inWorktree
    ? await paneHostExec(effects, ["worktree", "open", "--path", effects.featureRoot, "--cwd", effects.mainRoot, "--label", label, "--no-focus"])
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
  effects._paneWorkspaceId = workspaceId;
  if (logFile) await openLogTab(effects, workspaceId, label, logFile);
  return workspaceId;
}

/** Closes only a workspace this run made; one that was already open is left to whoever opened it. */
export async function closeWorkspace(effects, workspaceId) {
  if (!effects._paneWorkspaceCreated) return;
  await paneHostExec(effects, ["workspace", "close", workspaceId]);
}

/** Blocking: a signal handler cannot await the cached workspace promise. */
export function closeWorkspaceSync(effects) {
  if (!effects._paneWorkspaceCreated || !effects._paneWorkspaceId) return;
  effects.exec("herdr", ["workspace", "close", effects._paneWorkspaceId], { timeoutMs: STATUS_TIMEOUT_MS });
}

/** `pane run` cannot report an exit code, so herdr only ever runs a `tail -f` nothing reads. */
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

/** An `agent_status` other than `unknown` means herdr detected an agent in the pane. */
function paneHostsAgent(list, paneId) {
  if (list.code !== 0) return false;
  const pane = (paneHostJson(list)?.result?.panes ?? []).find((p) => p?.pane_id === paneId);
  const status = pane?.agent_status;
  return typeof status === "string" && status !== "" && status !== "unknown";
}

export async function watchAlive(effects, paneId) {
  try {
    return paneHostsAgent(await paneHostExec(effects, ["pane", "list"], STATUS_TIMEOUT_MS), paneId);
  } catch {
    return false;
  }
}

/** Blocking: a signal handler cannot await. */
export function watchAliveSync(effects, paneId) {
  try {
    return paneHostsAgent(effects.exec("herdr", ["pane", "list"], { mutating: false, timeoutMs: STATUS_TIMEOUT_MS }), paneId);
  } catch {
    return false;
  }
}

function paneListed(list, paneId) {
  if (list.code !== 0) return false;
  return (paneHostJson(list)?.result?.panes ?? []).some((p) => p?.pane_id === paneId);
}

/** watchAliveSync's looser twin: the pane exists. A CLI still starting has no `agent_status` yet. */
export function watchPresentSync(effects, paneId) {
  try {
    return paneListed(effects.exec("herdr", ["pane", "list"], { mutating: false, timeoutMs: STATUS_TIMEOUT_MS }), paneId);
  } catch {
    return false;
  }
}

/** Its workspace is not closed while the agent lives; a tab made before a failed `pane run` is closed again. */
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

/**
 * A tab of the sprint's workspace, started in the dispatch's own cwd; its handle is the tab, which
 * closing takes the pane with. A tab made before a failed `pane run` is closed again. Never throws.
 */
export async function openWorkerTerminal(effects, { title, command, worktree }) {
  let tabId = null;
  try {
    let workspaceId = null;
    try {
      workspaceId = (await effects._paneWorkspace) ?? null;
    } catch {
      /* reported where the workspace open failed */
    }
    if (!workspaceId) return { failure: "herdr: the sprint has no workspace" };
    const create = await paneHostExec(effects, [
      "tab",
      "create",
      "--workspace",
      workspaceId,
      "--cwd",
      worktree ?? effects.featureRoot ?? effects.mainRoot,
      "--label",
      title,
      "--no-focus",
    ], STATUS_TIMEOUT_MS);
    const result = paneHostJson(create)?.result;
    tabId = result?.tab?.tab_id ?? null;
    const paneId = result?.root_pane?.pane_id;
    if (create.code !== 0 || !paneId) {
      await closeTab(effects, tabId);
      return { failure: `herdr tab create exit=${create.code} ${failureDetail(create)}` };
    }
    const run = await paneHostExec(effects, ["pane", "run", paneId, command], STATUS_TIMEOUT_MS);
    if (run.code !== 0) {
      await closeTab(effects, tabId);
      return { failure: `herdr pane run exit=${run.code} ${failureDetail(run)}` };
    }
    return { handle: tabId };
  } catch (err) {
    await closeTab(effects, tabId);
    return { failure: `herdr worker tab threw: ${err.message}` };
  }
}

export const closeWorkerTerminal = (effects, tabId) => closeTab(effects, tabId);

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
