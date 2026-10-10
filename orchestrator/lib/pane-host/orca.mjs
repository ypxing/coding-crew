/**
 * orca (https://onorca.dev): flat — a worktree is the container, a terminal is the pane,
 * so there is no workspace object to create, reuse or close. The main checkout is already
 * an orca-managed worktree; a terminal is scoped to it by `--worktree path:<mainRoot>`, or to the
 * dispatch's own worktree once adoptWorktree has named that to orca.
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

/**
 * A worktree the orchestrator created with native git: name it, link its issue and parent, so
 * orca lists it under the sprint. Only an adopted worktree scopes a worker terminal (below).
 * Returns nothing and throws nothing worth stopping for — index.mjs's adoptWorktree logs a throw.
 */
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

/**
 * Throws when the log terminal can't be created: with no workspace create to fail loudly,
 * a failure preflight didn't catch would otherwise leave no tab and no reason.
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
    track(effects, handle);
  } catch (err) {
    return err.message;
  }
}

/** How many close attempts a terminal gets before it is logged as stuck. */
export const CLOSE_ATTEMPTS = 3;

const track = (effects, handle) => (effects._paneTerminals ??= new Set()).add(handle);

/**
 * `terminal close` can exit 0 and leave the tab listed (or orphaned), so each close is
 * followed by a `terminal show`: a show that fails means the terminal is gone. Still listed
 * → close again, up to CLOSE_ATTEMPTS. A terminal never confirmed gone stays in
 * `effects._paneTerminals` for the end-of-run sweep (closePaneTerminals) and is logged WARN
 * with the handle and orca's last output. Never throws.
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

/** End of sprint: close every terminal this run opened that is still listed. */
export async function closeTerminals(effects) {
  for (const handle of [...(effects._paneTerminals ?? [])]) await closeTerminal(effects, handle);
}

/**
 * One terminal per dispatch (worker-terminal.mjs), scoped to the dispatch's own worktree when
 * adoptWorktree named it to orca, else to the main checkout (the one worktree guaranteed to be
 * orca's already, like the log terminal). Returns
 * `{handle}` or `{failure}`, never throws.
 */
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
 * Whether `handle` still reports a live agent: `terminal show` has an `agentIdentity` (set for
 * an agent pane, absent for a shell, and missing once the terminal is closed or orca is gone).
 */
export async function watchAlive(effects, handle) {
  try {
    const show = await paneHostExec(effects, ["terminal", "show", "--terminal", handle, "--json"], CALL_TIMEOUT_MS);
    return show.code === 0 && Boolean(paneHostJson(show)?.result?.terminal?.agentIdentity);
  } catch {
    return false;
  }
}

/**
 * The watch agent: a terminal in the main checkout running `command`. Its handle is deliberately
 * never `track`ed, so no sweep (closeTerminals) can close it. Returns `{handle}` or `{failure}`,
 * never throws.
 */
export async function openWatch(effects, { slug, command }) {
  try {
    const create = await paneHostExec(effects, [
      "terminal",
      "create",
      "--worktree",
      `path:${effects.mainRoot}`,
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

/**
 * `terminal send` types into any terminal, and in a plain shell the message plus Enter
 * runs as a command. So send only when `terminal show` reports an `agentIdentity` (set for
 * an agent pane, including mid-tool-call; absent for a shell). No identity, no send.
 */
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
      const reason = "watch terminal is not running an agent orca recognises";
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
