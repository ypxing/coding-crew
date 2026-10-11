/**
 * orca (https://onorca.dev): flat — a worktree is the container and a terminal the pane, so there
 * is no workspace to create or close. Terminals are scoped by `--worktree path:<dir>`, which orca
 * refuses for a worktree it does not know; crew-afk uses only `_feature` and the worktrees it named.
 * See docs/orca-support.md.
 */

import { failureDetail, insideDir, paneHostExec, paneHostJson, paneWorkspaceLabel, shellQuote } from "./shared.mjs";

/** orca is a desktop app that can be quit mid-run; no call may block startup or exit. */
const CALL_TIMEOUT_MS = 10000;

/** `terminal send` into a live agent pane waits for turn start (~8s measured). */
const SEND_TIMEOUT_MS = 20000;

/** How long a new worktree may take to appear in orca after `git worktree add`, and how often to look. */
export const ADOPT_WAIT = { pollMs: 500, timeoutMs: 60000 };

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
  // orca names only worktrees of a repo it manages: in a checkout it doesn't, nothing is named
  // and every dispatch quietly falls back to headless, so no tab ever appears.
  const show = effects.exec("orca", ["worktree", "show", "--worktree", `path:${effects.mainRoot}`, "--json"], { mutating: false, timeoutMs: CALL_TIMEOUT_MS });
  if (show.code === 124) return [`pane host orca, but \`orca worktree show\` timed out after ${CALL_TIMEOUT_MS / 1000}s — is orca responding?`];
  if (show.code !== 0) {
    return [`pane host orca, but orca does not manage ${effects.mainRoot} — add it as a repo in the orca app (on the host this runs on), or pick another pane host (CREW_PANE_HOST=none)`];
  }
  return [];
}

/**
 * Names a natively created worktree to orca, so it lists under the sprint; only a named one scopes a
 * terminal. orca finds a new worktree on its own a moment after `git worktree add`, so this first
 * waits (bounded) for `worktree show` to see it. Resolves whether it was named; never rejects.
 */
export function adoptWorktree(effects, path, meta) {
  const adopting = nameWorktree(effects, path, meta).catch((err) => {
    effects.log?.(`WARN orca could not name worktree ${path} — ${err.message}`);
    return false;
  });
  (effects._paneAdoptions ??= new Map()).set(path, adopting);
  (effects._paneAdoptMeta ??= new Map()).set(path, meta);
  return adopting;
}

async function nameWorktree(effects, path, meta) {
  if (!(await listedByOrca(effects, path))) {
    effects.log?.(`WARN orca never listed worktree ${path} within ${ADOPT_WAIT.timeoutMs / 1000}s — not named yet; the next terminal for it looks again`);
    return false;
  }
  return setWorktree(effects, path, meta, effects.log);
}

/** `log` is omitted by a re-probe: the adoption already warned. */
async function setWorktree(effects, path, { title, issue, parent }, log) {
  const args = ["worktree", "set", "--worktree", `path:${path}`, "--display-name", title];
  if (issue != null) args.push("--issue", String(issue));
  if (parent) args.push("--parent-worktree", `path:${parent}`);
  const r = await paneHostExec(effects, args, CALL_TIMEOUT_MS);
  if (r.code !== 0) {
    log?.(`WARN orca worktree set ${path} exit=${r.code} ${failureDetail(r)}`);
    return false;
  }
  (effects._paneAdopted ??= new Set()).add(path);
  return true;
}

/**
 * Gives up only once a look started at or after the deadline fails: a blocking check elsewhere can
 * hold the event loop past the whole wait, and a look made before it says nothing about after.
 */
async function listedByOrca(effects, path) {
  const deadline = Date.now() + ADOPT_WAIT.timeoutMs;
  for (;;) {
    const started = Date.now();
    const show = await paneHostExec(effects, ["worktree", "show", "--worktree", `path:${path}`, "--json"], CALL_TIMEOUT_MS);
    if (show.code === 0) return true;
    if (started >= deadline) return false;
    const left = deadline - Date.now();
    if (left > 0) await sleep(Math.min(ADOPT_WAIT.pollMs, left));
  }
}

/**
 * Whether `path` is named to orca, once any naming still under way has settled. One whose adoption
 * ended unnamed gets one more look, so a worktree orca lists only after the wait is named at the next
 * spawn; a miss is not cached, so the spawn after that looks again.
 */
async function named(effects, path) {
  if (!path) return false;
  const adoption = effects._paneAdoptions?.get(path);
  await adoption;
  if (effects._paneAdopted?.has(path)) return true;
  return adoption ? nameIfListedNow(effects, path) : false;
}

/** Concurrent spawns share one probe, so a worktree gets one `worktree set`. Silent: the adoption already warned. */
function nameIfListedNow(effects, path) {
  const probes = (effects._paneReprobes ??= new Map());
  if (!probes.has(path)) {
    const probe = (async () => {
      const show = await paneHostExec(effects, ["worktree", "show", "--worktree", `path:${path}`, "--json"], CALL_TIMEOUT_MS);
      return show.code === 0 && setWorktree(effects, path, effects._paneAdoptMeta.get(path));
    })()
      .catch(() => false)
      .finally(() => probes.delete(path));
    probes.set(path, probe);
  }
  return probes.get(path);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** `_feature` once named, else null: no sprint tab opens in the main checkout, which is the developer's. */
const featureWorktree = async (effects) => ((await named(effects, effects.featureRoot)) ? effects.featureRoot : null);

const unnamedFeature = (effects) => `_feature ${effects.featureRoot ?? "(none)"} is not named to orca`;

export const launcherHandle = () => process.env.ORCA_TERMINAL_HANDLE || null;

/** Throws: with no workspace create to fail loudly, a failure would otherwise leave no tab and no reason. */
export async function ensureWorkspace(effects, { featureSlug, logFile }) {
  await renameTriggeringTerminal(effects, featureSlug);
  if (logFile) {
    const worktree = await featureWorktree(effects);
    if (!worktree) {
      effects.log?.(`WARN orca: ${unnamedFeature(effects)} — no log tab`);
    } else {
      const failure = await openLogTerminal(effects, paneWorkspaceLabel(featureSlug), logFile, worktree);
      if (failure) throw new Error(`orca terminal create failed: ${failure}`);
    }
  }
  return process.env.ORCA_WORKTREE_ID ?? null;
}

export async function closeWorkspace() {}

/** Only a terminal launched inside `_feature` is the sprint's: any other is the developer's own. */
async function renameTriggeringTerminal(effects, featureSlug) {
  const handle = process.env.ORCA_TERMINAL_HANDLE;
  if (!featureSlug || !handle || !effects.featureRoot || !insideDir(effects.featureRoot, process.cwd())) return;
  try {
    await paneHostExec(effects, ["terminal", "rename", "--terminal", handle, "--title", featureSlug, "--json"], CALL_TIMEOUT_MS);
  } catch {
    /* cosmetic */
  }
}

/** `--command` is typed into the terminal's shell, so the path is shell-quoted. */
async function openLogTerminal(effects, label, logFile, worktree) {
  try {
    const create = await paneHostExec(effects, [
      "terminal",
      "create",
      "--worktree",
      `path:${worktree}`,
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

/** Scoped to the dispatch's worktree once named, else `_feature`; with neither, a failure (headless). Never throws. */
export async function openWorkerTerminal(effects, { title, command, worktree }) {
  try {
    const scope = (await named(effects, worktree)) ? worktree : await featureWorktree(effects);
    if (!scope) return { failure: `orca: neither ${worktree ?? "the dispatch's worktree"} nor _feature ${effects.featureRoot ?? "(none)"} is named to orca` };
    const create = await paneHostExec(effects, [
      "terminal",
      "create",
      "--worktree",
      `path:${scope}`,
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
    const worktree = await featureWorktree(effects);
    if (!worktree) return { failure: unnamedFeature(effects) };
    const create = await paneHostExec(effects, [
      "terminal",
      "create",
      "--worktree",
      `path:${worktree}`,
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
