/**
 * orca (https://onorca.dev): flat — a worktree is the container and a terminal the pane, so there
 * is no workspace to create or close. Terminals are scoped by `--worktree path:<dir>`, which orca
 * refuses for a worktree it does not know. See docs/orca-support.md.
 */

import { failureDetail, paneHostExec, paneHostJson, paneWorkspaceLabel, shellQuote } from "./shared.mjs";

/** orca is a desktop app that can be quit mid-run; no call may block startup or exit. */
const CALL_TIMEOUT_MS = 10000;

/** `terminal send` into a live agent pane waits for turn start (~8s measured). */
const SEND_TIMEOUT_MS = 20000;

export function preflight(effects) {
  const which = effects.exec("sh", ["-c", "command -v orca"], { mutating: false });
  if (which.code !== 0) return ["pane host orca, but the orca CLI was not found on PATH"];
  const status = effects.exec("orca", ["status", "--json"], { mutating: false, timeoutMs: CALL_TIMEOUT_MS });
  if (status.code === 124) return [`pane host orca, but \`orca status\` timed out after ${CALL_TIMEOUT_MS / 1000}s — is orca responding?`];
  if (status.code !== 0) return ["pane host orca, but `orca status` failed — start it with: orca open"];
  try {
    const parsed = JSON.parse(status.stdout || "{}");
    if (!parsed?.result?.runtime?.reachable) {
      return ["pane host orca, but the orca runtime is not reachable — start it with: orca open"];
    }
  } catch {
    return ["pane host orca, but `orca status --json` returned unparseable output"];
  }
  // Every terminal is scoped to mainRoot. In a checkout orca doesn't manage, each create
  // fails and every dispatch quietly falls back to headless, so no tab ever appears.
  const show = effects.exec("orca", ["worktree", "show", "--worktree", `path:${effects.mainRoot}`, "--json"], { mutating: false, timeoutMs: CALL_TIMEOUT_MS });
  if (show.code === 124) return [`pane host orca, but \`orca worktree show\` timed out after ${CALL_TIMEOUT_MS / 1000}s — is orca responding?`];
  if (show.code !== 0) {
    return [`pane host orca, but orca does not manage ${effects.mainRoot} — add it as a repo in the orca app (on the host this runs on), or pick another pane host (CREW_PANE_HOST=none)`];
  }
  return [];
}

/** Names a natively created worktree to orca, so it lists under the sprint; only an adopted one scopes a terminal. */
export function adoptWorktree(effects, path, { title, issue, parent }) {
  const args = ["worktree", "set", "--worktree", `path:${path}`, "--display-name", title];
  if (issue != null) args.push("--issue", String(issue));
  if (parent) args.push("--parent-worktree", `path:${parent}`);
  const r = effects.exec("orca", args, { timeoutMs: CALL_TIMEOUT_MS });
  if (r.code !== 0) {
    effects.log?.(`WARN orca worktree set ${path} exit=${r.code} ${failureDetail(r)}`);
    return;
  }
  (effects._paneAdopted ??= new Set()).add(path);
}

/** `_feature` once adopted, else the main checkout: orca refuses a terminal in a worktree it does not know. */
const featureWorktree = (effects) => (effects.featureRoot && effects._paneAdopted?.has(effects.featureRoot) ? effects.featureRoot : effects.mainRoot);

export const launcherHandle = () => process.env.ORCA_TERMINAL_HANDLE || null;

/** Throws: with no workspace create to fail loudly, a failure would otherwise leave no tab and no reason. */
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

/** `--command` is typed into the terminal's shell, so the path is shell-quoted. */
async function openLogTerminal(effects, label, logFile) {
  try {
    const create = await paneHostExec(effects, [
      "terminal",
      "create",
      "--worktree",
      `path:${featureWorktree(effects)}`,
      "--title",
      `${label}-log`,
      "--command",
      `tail -f ${shellQuote(logFile)}`,
      "--json",
    ], CALL_TIMEOUT_MS);
    const handle = paneHostJson(create)?.result?.terminal?.handle;
    if (create.code !== 0 || !handle) return `exit=${create.code} ${failureDetail(create)}`;
    effects._paneLogTabId = handle;
    track(effects, handle);
  } catch (err) {
    return err.message;
  }
}

export const CLOSE_ATTEMPTS = 3;

const track = (effects, handle) => (effects._paneTerminals ??= new Set()).add(handle);

/**
 * `terminal close` can exit 0 and leave the tab listed, so each close is checked with `terminal
 * show` (a failing show means gone). One never confirmed gone stays tracked for the end-of-run sweep.
 */
export async function closeTerminal(effects, handle) {
  let last = "";
  for (let attempt = 1; attempt <= CLOSE_ATTEMPTS; attempt++) {
    try {
      const close = await paneHostExec(effects, ["terminal", "close", "--terminal", handle, "--json"], CALL_TIMEOUT_MS);
      if (close.code !== 0) last = `close exit=${close.code} ${failureDetail(close)}`;
      const show = await paneHostExec(effects, ["terminal", "show", "--terminal", handle, "--json"], CALL_TIMEOUT_MS);
      if (show.code !== 0) {
        effects._paneTerminals?.delete(handle);
        return true;
      }
      if (close.code === 0) last = `still listed after close: ${failureDetail(show)}`;
    } catch (err) {
      last = `threw: ${err.message}`;
    }
  }
  effects.log?.(`WARN orca terminal ${handle} not closed after ${CLOSE_ATTEMPTS} attempts — ${last}`);
  return false;
}

export const closeLogTab = closeTerminal;

export async function closeTerminals(effects) {
  for (const handle of [...(effects._paneTerminals ?? [])]) await closeTerminal(effects, handle);
}

/** Scoped to the dispatch's worktree once adopted, else the main checkout. Never throws. */
export async function openWorkerTerminal(effects, { title, command, worktree }) {
  try {
    const create = await paneHostExec(effects, [
      "terminal",
      "create",
      "--worktree",
      `path:${worktree && effects._paneAdopted?.has(worktree) ? worktree : effects.mainRoot}`,
      "--title",
      title,
      "--command",
      command,
      "--json",
    ], CALL_TIMEOUT_MS);
    const handle = paneHostJson(create)?.result?.terminal?.handle;
    if (create.code !== 0 || !handle) return { failure: `orca terminal create exit=${create.code} ${failureDetail(create)}` };
    track(effects, handle);
    return { handle };
  } catch (err) {
    return { failure: `orca terminal create threw: ${err.message}` };
  }
}

export const closeWorkerTerminal = closeTerminal;

/**
 * A terminal that can take input: orca keeps listing one whose PTY is gone (`orphaned`) or whose
 * renderer detached, `agentIdentity` included. An absent field is not read as a failure.
 */
function usableTerminal(show) {
  const terminal = show.code === 0 ? paneHostJson(show)?.result?.terminal : null;
  if (!terminal || terminal.orphaned === true || terminal.writable === false || terminal.connected === false) return null;
  return terminal;
}

/** `agentIdentity` is set for an agent pane, absent for a shell or a closed terminal. */
const terminalHostsAgent = (show) => Boolean(usableTerminal(show)?.agentIdentity);

export async function watchAlive(effects, handle) {
  try {
    return terminalHostsAgent(await paneHostExec(effects, ["terminal", "show", "--terminal", handle, "--json"], CALL_TIMEOUT_MS));
  } catch {
    return false;
  }
}

/** Blocking: a signal handler cannot await. */
export function watchAliveSync(effects, handle) {
  try {
    return terminalHostsAgent(effects.exec("orca", ["terminal", "show", "--terminal", handle, "--json"], { mutating: false, timeoutMs: CALL_TIMEOUT_MS }));
  } catch {
    return false;
  }
}

/** watchAliveSync's looser twin: the terminal exists. A CLI still starting has no `agentIdentity` yet. */
export function watchPresentSync(effects, handle) {
  try {
    const show = effects.exec("orca", ["terminal", "show", "--terminal", handle, "--json"], { mutating: false, timeoutMs: CALL_TIMEOUT_MS });
    return Boolean(usableTerminal(show));
  } catch {
    return false;
  }
}

/** Its handle is deliberately never `track`ed, so no sweep can close the feature agent. */
export async function openWatch(effects, { slug, command }) {
  try {
    const create = await paneHostExec(effects, [
      "terminal",
      "create",
      "--worktree",
      `path:${featureWorktree(effects)}`,
      "--title",
      `${slug}-watch`,
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

/** In a plain shell `terminal send` runs the message as a command, so send only to an `agentIdentity`. */
export async function notify(effects, handle, message) {
  let show;
  try {
    show = await paneHostExec(effects, ["terminal", "show", "--terminal", handle, "--json"], 5000);
  } catch (err) {
    const reason = `orca terminal show threw: ${err.message}`;
    effects.log?.(`NOTIFY-FAIL ${reason}`);
    return { sent: false, reason };
  }
  // A failed show (orca quit, timed out) is orca's problem, not the pane's: say which.
  if (show.code !== 0) {
    const reason = `orca terminal show exit=${show.code} ${failureDetail(show)}`;
    effects.log?.(`NOTIFY-FAIL ${reason}`);
    return { sent: false, reason };
  }
  try {
    const agentIdentity = paneHostJson(show)?.result?.terminal?.agentIdentity;
    if (!agentIdentity) {
      const reason = "agent terminal is not running an agent orca recognises";
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
