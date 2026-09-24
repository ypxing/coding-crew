/**
 * orca (https://onorca.dev): flat — a worktree is the container, a terminal is the pane,
 * so there is no workspace object to create, reuse or close. The main checkout is already
 * an orca-managed worktree; every terminal is scoped to it by `--worktree path:<mainRoot>`.
 * Ambient ids: ORCA_WORKTREE_ID / ORCA_TAB_ID / ORCA_TERMINAL_HANDLE. See
 * docs/orca-support.md.
 */

import { failureDetail, paneHostExec, paneHostJson, paneWorkspaceLabel, shellQuote } from "./shared.mjs";

/** orca is a desktop app that can be quit mid-run; no call may block startup or exit. */
const CALL_TIMEOUT_MS = 10000;

/** `terminal send` into a live agent pane waits for turn start (~8s measured). */
const SEND_TIMEOUT_MS = 20000;

export function preflight(effects) {
  const which = effects.exec("sh", ["-c", "command -v orca"], { mutating: false });
  if (which.code !== 0) return ["ORCA_ENV=1 but the orca CLI was not found on PATH"];
  const status = effects.exec("orca", ["status", "--json"], { mutating: false });
  if (status.code !== 0) return ["ORCA_ENV=1 but `orca status` failed — start it with: orca open"];
  try {
    const parsed = JSON.parse(status.stdout || "{}");
    if (!parsed?.result?.runtime?.reachable) {
      return ["ORCA_ENV=1 but the orca runtime is not reachable — start it with: orca open"];
    }
  } catch {
    return ["ORCA_ENV=1 but `orca status --json` returned unparseable output"];
  }
  return [];
}

/**
 * Throws when the log terminal can't be created: with no workspace create to fail loudly,
 * this is the only place the likeliest misconfiguration (ORCA_ENV=1 in a checkout orca
 * doesn't manage) can surface.
 */
export async function ensureWorkspace(effects, { featureSlug, logFile }) {
  await renameTriggeringTerminal(effects, featureSlug);
  if (logFile) {
    const failure = await openLogTerminal(effects, paneWorkspaceLabel(featureSlug), logFile);
    if (failure) throw new Error(`orca terminal create failed: ${failure}`);
  }
  return process.env.ORCA_WORKTREE_ID ?? null;
}

export async function closeWorkspace() {}

async function renameTriggeringTerminal(effects, featureSlug) {
  const handle = process.env.ORCA_TERMINAL_HANDLE;
  if (!featureSlug || !handle) return;
  try {
    await paneHostExec(effects, ["terminal", "rename", "--terminal", handle, "--title", featureSlug, "--json"], CALL_TIMEOUT_MS);
  } catch {
    /* cosmetic */
  }
}

/**
 * `--command` is typed into the terminal's shell, so the path is shell-quoted. Returns a
 * failure reason instead of throwing.
 */
async function openLogTerminal(effects, label, logFile) {
  try {
    const create = await paneHostExec(effects, [
      "terminal",
      "create",
      "--worktree",
      `path:${effects.mainRoot}`,
      "--title",
      `${label}-log`,
      "--command",
      `tail -f ${shellQuote(logFile)}`,
      "--json",
    ], CALL_TIMEOUT_MS);
    const handle = paneHostJson(create)?.result?.terminal?.handle;
    if (create.code !== 0 || !handle) return `exit=${create.code} ${failureDetail(create)}`;
    effects._paneLogTabId = handle;
  } catch (err) {
    return err.message;
  }
}

export async function closeLogTab(effects, handle) {
  await paneHostExec(effects, ["terminal", "close", "--terminal", handle, "--json"], CALL_TIMEOUT_MS);
}

/**
 * One terminal per dispatch (worker-terminal.mjs), scoped to the main checkout like the log
 * terminal: orca accepts any git worktree path, but the main one is the only worktree
 * guaranteed to be orca's already, and it keeps every worker tab in one place. Returns
 * `{handle}` or `{failure}`, never throws.
 */
export async function openWorkerTerminal(effects, { title, command }) {
  try {
    const create = await paneHostExec(effects, [
      "terminal",
      "create",
      "--worktree",
      `path:${effects.mainRoot}`,
      "--title",
      title,
      "--command",
      command,
      "--json",
    ], CALL_TIMEOUT_MS);
    const handle = paneHostJson(create)?.result?.terminal?.handle;
    if (create.code !== 0 || !handle) return { failure: `orca terminal create exit=${create.code} ${failureDetail(create)}` };
    return { handle };
  } catch (err) {
    return { failure: `orca terminal create threw: ${err.message}` };
  }
}

export const closeWorkerTerminal = closeLogTab;

/**
 * `terminal send` types into any terminal, and in a plain shell the message plus Enter
 * runs as a command. So send only when `terminal show` reports an `agentIdentity` (set for
 * an agent pane, including mid-tool-call; absent for a shell). No identity, no send.
 */
export async function notify(effects, message) {
  const handle = process.env.ORCA_TERMINAL_HANDLE;
  if (!handle) {
    effects.log?.("NOTIFY-SKIP no ORCA_TERMINAL_HANDLE in env");
    return { sent: false, reason: "no ORCA_TERMINAL_HANDLE in env" };
  }
  try {
    const show = await paneHostExec(effects, ["terminal", "show", "--terminal", handle, "--json"], 5000);
    const agentIdentity = paneHostJson(show)?.result?.terminal?.agentIdentity;
    if (show.code !== 0 || !agentIdentity) {
      const reason = "triggering terminal is not running an agent orca recognises";
      effects.log?.(`NOTIFY-SKIP ${reason}`);
      return { sent: false, reason };
    }
    const result = await paneHostExec(effects, ["terminal", "send", "--terminal", handle, "--text", message, "--enter", "--json"], SEND_TIMEOUT_MS);
    if (result.code !== 0) {
      const reason = `orca terminal send exit=${result.code} ${failureDetail(result)}`;
      effects.log?.(`NOTIFY-FAIL ${reason}`);
      return { sent: false, reason };
    }
    const send = paneHostJson(result)?.result?.send;
    if (send && send.accepted === false) {
      const reason = `orca terminal send not accepted: ${JSON.stringify(send)}`;
      effects.log?.(`NOTIFY-FAIL ${reason}`);
      return { sent: false, reason };
    }
    return { sent: true };
  } catch (err) {
    const reason = `orca terminal send threw: ${err.message}`;
    effects.log?.(`NOTIFY-FAIL ${reason}`);
    return { sent: false, reason };
  }
}
