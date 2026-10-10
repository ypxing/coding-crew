/**
 * herdr (https://herdr.dev): a workspace container holding tabs, each with panes.
 * Ambient ids: HERDR_WORKSPACE_ID / HERDR_TAB_ID / HERDR_PANE_ID.
 */

import { failureDetail, hostFailure, lastMarkerLine, paneHostExec, paneHostJson, paneWorkspaceLabel, textAfterPrompt } from "./shared.mjs";

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
  // The sprint's workspace is its feature-branch worktree; with none (a dry run) the main checkout.
  const inWorktree = Boolean(effects.featureRoot) && effects.featureRoot !== effects.mainRoot;
  const create = inWorktree
    ? await paneHostExec(effects, ["worktree", "open", "--path", effects.featureRoot, "--label", label, "--no-focus"])
    : await paneHostExec(effects, ["workspace", "create", "--cwd", effects.mainRoot, "--label", label, "--no-focus"]);
  const workspaceId = paneHostJson(create)?.result?.workspace?.workspace_id;
  if (create.code !== 0 || !workspaceId) {
    throw new Error(`herdr ${inWorktree ? "worktree open" : "workspace create"} failed: ${failureDetail(create)}`);
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
 * A fresh pane with cwd `cwd`: a new tab in the triggering workspace when there is one, else a
 * workspace of its own, named `label`. Returns `{paneId, container}` (`container` closes it again)
 * or `{failure}`.
 */
async function newPane(effects, { label, cwd }) {
  const workspaceId = process.env.HERDR_WORKSPACE_ID;
  const create = workspaceId
    ? await paneHostExec(effects, ["tab", "create", "--workspace", workspaceId, "--cwd", cwd, "--label", label, "--no-focus"])
    : await paneHostExec(effects, ["workspace", "create", "--cwd", cwd, "--label", label, "--no-focus"]);
  const what = workspaceId ? "tab create" : "workspace create";
  const result = paneHostJson(create)?.result;
  let paneId = result?.root_pane?.pane_id;
  if (create.code === 0 && !paneId && result?.workspace?.workspace_id) {
    const list = await paneHostExec(effects, ["pane", "list", "--workspace", result.workspace.workspace_id], STATUS_TIMEOUT_MS);
    paneId = paneHostJson(list)?.result?.panes?.[0]?.pane_id;
  }
  if (create.code !== 0 || !paneId) return { failure: `herdr ${what} exit=${create.code} ${failureDetail(create)}` };
  const container = workspaceId ? ["tab", "close", result?.tab?.tab_id] : ["workspace", "close", result?.workspace?.workspace_id];
  return { paneId, container: container[2] ? container : null };
}

/** Closes the tab or workspace newPane made, when a later call failed. Cosmetic: never throws. */
async function closeContainer(effects, made) {
  if (!made?.container) return;
  try {
    await paneHostExec(effects, made.container, STATUS_TIMEOUT_MS);
  } catch {
    /* cosmetic */
  }
}

/**
 * The watch agent: a new tab in the triggering workspace, or outside herdr a `<slug>-watch`
 * workspace on the main checkout (never closed, unlike the sprint's own). The agent is started
 * with `pane run`; herdr detects it as one. Returns `{handle}` (the pane id) or `{failure}`;
 * a pane made before `pane run` failed is closed again. Never throws.
 */
export async function openWatch(effects, { slug, command }) {
  let made = null;
  try {
    made = await newPane(effects, { label: `${slug}-watch`, cwd: effects.mainRoot });
    if (made.failure) return { failure: made.failure };
    const run = await paneHostExec(effects, ["pane", "run", made.paneId, command]);
    if (run.code !== 0) {
      await closeContainer(effects, made);
      return { failure: `herdr pane run exit=${run.code} ${failureDetail(run)}` };
    }
    return { handle: made.paneId };
  } catch (err) {
    await closeContainer(effects, made);
    return { failure: `herdr watch agent threw: ${err.message}` };
  }
}

/** How many lines of a follow-up worker's pane `awaitFollowup` reads. */
const FOLLOWUP_READ_LINES = 400;

/** How long a fresh agent gets to take its first prompt: it is still starting up. */
const FOLLOWUP_START_TIMEOUT_MS = 60000;

/** How long a fresh agent gets to start and finish the turn its initial prompt (the brief) opens. */
const FOLLOWUP_FIRST_TURN_TIMEOUT_MS = 120000;

/**
 * A follow-up worker (D15): a pane with cwd `worktree` (a new tab beside the watch agent, or a
 * workspace of its own) running `command`, which herdr detects as an agent and which starts a turn
 * on the brief it was launched with. That turn is waited out (`idle` or `done`) before `spec` is
 * prompted, or the spec would land in it and be read as part of the brief's turn; then the spec
 * is waited until the agent is `working`. Returns `{handle}` (the pane id) or
 * `{failure}` (host's own text); a pane made before a call failed is closed again. Never throws.
 */
export async function openFollowup(effects, { slug, worktree, command, spec }) {
  let made = null;
  const closeMade = () => closeContainer(effects, made);
  try {
    made = await newPane(effects, { label: `${slug}-followup`, cwd: worktree });
    if (made.failure) return { failure: made.failure };
    const run = await paneHostExec(effects, ["pane", "run", made.paneId, command]);
    if (run.code !== 0) {
      await closeMade();
      return { failure: hostFailure("herdr pane run", run) };
    }
    const first = await paneHostExec(
      effects,
      ["agent", "wait", made.paneId, "--until", "idle", "--until", "done", "--timeout", String(FOLLOWUP_FIRST_TURN_TIMEOUT_MS)],
      FOLLOWUP_FIRST_TURN_TIMEOUT_MS + 5000,
    );
    if (first.code !== 0) {
      await closeMade();
      return { failure: hostFailure("herdr agent wait", first, FOLLOWUP_FIRST_TURN_TIMEOUT_MS) };
    }
    const prompt = await paneHostExec(
      effects,
      ["agent", "prompt", made.paneId, spec, "--wait", "--until", "working", "--timeout", String(FOLLOWUP_START_TIMEOUT_MS)],
      FOLLOWUP_START_TIMEOUT_MS + 5000,
    );
    if (prompt.code !== 0) {
      await closeMade();
      return { failure: hostFailure("herdr agent prompt", prompt, FOLLOWUP_START_TIMEOUT_MS) };
    }
    return { handle: made.paneId };
  } catch (err) {
    await closeMade();
    return { failure: `herdr follow-up threw: ${err.message}` };
  }
}

/**
 * The worker's turn, once it ends (`done`, `idle` or `blocked`, with no timeout of its own): the
 * last `QUESTION: …` or `DONE: …` line of the pane's recent text. A worker's question also ends
 * its turn as `done`, so the marker, not the state, tells them apart. After an answer
 * (`rec.lastAnswer`, what crew-afk last sent) only a marker below that answer's echo counts: the
 * text still holds the earlier turns, and a turn that wrote no marker must not be read as the
 * question before it. A full read with no echo is a turn that scrolled it out, read whole. Returns `{kind: "done"|"question", text}` or `{failure}`, never throws.
 */
export async function awaitFollowup(effects, rec) {
  try {
    const wait = await paneHostExec(effects, ["agent", "wait", rec.handle, "--until", "done", "--until", "idle", "--until", "blocked"]);
    if (wait.code !== 0) return { failure: hostFailure("herdr agent wait", wait) };
    const read = await paneHostExec(effects, ["agent", "read", rec.handle, "--source", "recent-unwrapped", "--lines", String(FOLLOWUP_READ_LINES)], STATUS_TIMEOUT_MS);
    if (read.code !== 0) return { failure: hostFailure("herdr agent read", read, STATUS_TIMEOUT_MS) };
    const parsed = paneHostJson(read)?.result;
    const text = typeof parsed?.read?.text === "string" ? parsed.read.text : typeof parsed?.text === "string" ? parsed.text : read.stdout;
    const tail = String(text ?? "").trim().split("\n").slice(-12).join("\n");
    let turn = text;
    if (rec.lastAnswer) {
      turn = textAfterPrompt(text, rec.lastAnswer);
      // A full read with no echo: the turn outgrew the read and scrolled the answer out, so all of it is this turn's.
      if (turn === null && String(text ?? "").replace(/\n+$/, "").split("\n").length >= FOLLOWUP_READ_LINES) turn = text;
      if (turn === null) {
        return { failure: `the answer crew-afk sent is not in the pane's recent text, so the worker's response cannot be told from an earlier turn's; its pane ends:\n${tail}` };
      }
    }
    const marker = lastMarkerLine(turn);
    if (marker) return marker;
    return { failure: `the worker's turn ended with no QUESTION:/DONE: line; its pane ends:\n${tail}` };
  } catch (err) {
    return { failure: `herdr follow-up wait threw: ${err.message}` };
  }
}

/** The answer as a new prompt, waited until the worker is `working` again so the next wait is for its next turn. */
export async function replyFollowup(effects, rec, answer) {
  try {
    const prompt = await paneHostExec(
      effects,
      ["agent", "prompt", rec.handle, answer, "--wait", "--until", "working", "--timeout", String(FOLLOWUP_START_TIMEOUT_MS)],
      FOLLOWUP_START_TIMEOUT_MS + 5000,
    );
    if (prompt.code !== 0) return { failure: hostFailure("herdr agent prompt", prompt, FOLLOWUP_START_TIMEOUT_MS) };
    return {};
  } catch (err) {
    return { failure: `herdr agent prompt threw: ${err.message}` };
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
