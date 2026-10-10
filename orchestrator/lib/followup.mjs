/**
 * followup.mjs — `crew-afk followup start|wait|reply`: the watch agent asks for follow-up work
 * (`/crew-address-findings`, `/address-pr-comments`) on a finished sprint's feature branch, and a
 * worker agent does it in `crew/<slug>/_followup`, reached over the host's own agent channel
 * (pane-host/{orca,herdr}.mjs `openFollowup` / `awaitFollowup` / `replyFollowup`).
 *
 * One follow-up per slug, recorded in `.scratch/<slug>/followup.json` once the host has started
 * it and never before: a failed host call leaves nothing recorded and no worktree behind. The
 * record is "open" until `wait` has returned the worker's final result.
 *
 * `_followup` and a sprint's `_feature` are never both on the branch: `start` refuses while the
 * feature lease or a live run holds it, and a later run's checkout of the branch releases a clean
 * `_followup` (worktree.mjs releaseBranch) or refuses a dirty one.
 *
 * Every function returns its exit code and prints through `io.out` (stdout: the follow-up id, or
 * the worker's `QUESTION: …` / `DONE: …` line) and `io.err`.
 */

import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

import { ADAPTERS as PLATFORM_ADAPTERS } from "./adapters/index.mjs";
import { ROLE_POLICY, renderRolePrompt } from "./adapters/render.mjs";
import { isPidAlive, parseOwner, readOwner } from "./lease.mjs";
import {
  awaitFollowup,
  openFollowup,
  recordedWatch,
  replyFollowup,
  supportsFollowups,
  watchFile,
} from "./pane-host/index.mjs";
import { shellQuote } from "./pane-host/shared.mjs";
import { writeLaunchScript } from "./pane-host/worker-terminal.mjs";
import { applyWorktreeInclude, ensureWorktree, followupWorktreePath, removeWorktree } from "./worktree.mjs";

const NO_HOST = "crew-afk: follow-ups need orca or herdr as the pane host (this run has none) — set --pane-host orca|herdr or CREW_PANE_HOST";

const recordFile = (mainRoot, slug) => join(mainRoot, ".scratch", slug, "followup.json");

function readRecord(file) {
  try {
    return JSON.parse(readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}

function writeRecord(rec, mainRoot) {
  const file = recordFile(mainRoot, rec.slug);
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, `${JSON.stringify(rec, null, 2)}\n`);
}

/** The record whose id is `id`, found under any feature's `.scratch/<slug>/`; null when none. */
function findRecord(mainRoot, id) {
  const scratch = join(mainRoot, ".scratch");
  if (!existsSync(scratch)) return null;
  for (const entry of readdirSync(scratch, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const rec = readRecord(recordFile(mainRoot, entry.name));
    if (rec?.id === id) return rec;
  }
  return null;
}

/**
 * Why a follow-up may not start now, or null: a live run's sprint lock, the feature lease
 * (`lease.sh owner`, only when `useLease`: the github tracker's), or an open follow-up.
 */
function startRefusal(effects, { slug, useLease }) {
  const open = readRecord(recordFile(effects.mainRoot, slug));
  if (open && open.state !== "done") {
    return `crew-afk: a follow-up for ${slug} is already open (${open.id}) — followup wait ${open.id} for its response, or answer it with followup reply; if its worker is gone, delete ${recordFile(effects.mainRoot, slug)}`;
  }
  const lock = readRecord(join(effects.mainRoot, ".scratch", slug, ".crew-afk.lock"));
  if (lock?.pid && isPidAlive(lock.pid)) {
    return `crew-afk: a sprint for ${slug} is running (pid ${lock.pid}, started ${lock.startedAt}) and holds the feature branch — start a follow-up once it has ended`;
  }
  if (useLease) {
    let held;
    try {
      held = readOwner(effects, slug);
    } catch (err) {
      return `crew-afk: could not read feature ${slug}'s lease, so a follow-up cannot start: ${err.message}`;
    }
    if (held) {
      const owner = parseOwner(held.message);
      const who = owner ? `run ${owner.runId} on ${owner.host} (pid ${owner.pid}) since ${owner.at}` : `an unrecognised owner (${held.message || "no message"})`;
      return `crew-afk: feature ${slug} is leased by ${who} — a follow-up cannot start while a run holds it`;
    }
  }
  return null;
}

/** `start`: the worktree, the worker, the record; prints the follow-up id. */
async function start(effects, { slug, task, platform, model, effort, resolveBranch, useLease, io }) {
  if (!slug || !task) {
    io.err("usage: crew-afk followup start <slug> \"<task>\" --platform <name>");
    return 2;
  }
  const refusal = startRefusal(effects, { slug, useLease });
  if (refusal) {
    io.err(refusal);
    return 1;
  }
  const agent = PLATFORM_ADAPTERS[platform];
  if (!agent?.interactive) {
    io.err(`crew-afk: platform ${platform} has no interactive mode, so it cannot run a follow-up worker`);
    return 1;
  }
  const found = effects.exec?.("sh", ["-c", `command -v ${shellQuote(agent.cmd)}`], { mutating: false });
  if (found && found.code !== 0) {
    io.err(`crew-afk: the ${agent.cmd} CLI was not found on PATH`);
    return 1;
  }
  let branch;
  try {
    branch = resolveBranch(slug);
  } catch (err) {
    io.err(`crew-afk: could not resolve ${slug}'s feature branch: ${err.message}`);
    return 1;
  }
  if (!branch || effects.gitRead(["rev-parse", "--verify", "--quiet", `refs/heads/${branch}^{commit}`]).code !== 0) {
    io.err(`crew-afk: feature branch ${branch || `of ${slug}`} does not exist — run /crew-afk ${slug} first`);
    return 1;
  }

  const mainRoot = effects.mainRoot;
  const watch = recordedWatch(watchFile(mainRoot, slug), effects.paneHost);
  const coordinator = watch?.handle ?? (effects.paneHost === "orca" ? process.env.ORCA_TERMINAL_HANDLE : undefined);

  const path = followupWorktreePath(mainRoot, slug);
  const wt = ensureWorktree(effects, { mainRoot, branch, base: branch, mode: "checkout", path, adopt: { title: `${slug}-followup` } });
  if (wt.stale) {
    io.err(`crew-afk: ${wt.reason}`);
    return 1;
  }
  const discard = () => {
    removeWorktree(effects, { mainRoot, path: wt.path });
    effects.git(["worktree", "prune"]);
  };
  try {
    applyWorktreeInclude(mainRoot, wt.path);
  } catch {
    /* provisioning is best-effort, as for an issue worktree */
  }

  const id = `${slug}-fu-${Date.now().toString(36)}`;
  const brief = renderRolePrompt("followup", platform, { mainRoot });
  const argv = agent.interactive({
    cwd: wt.path,
    mainRoot,
    model,
    protocol: brief,
    policy: { ...ROLE_POLICY.followup, ...(effort ? { effort } : {}) },
  });
  const { command } = writeLaunchScript(effects, {
    dir: join(mainRoot, ".scratch", slug, "followup", id),
    cwd: wt.path,
    argv,
    env: agent.env,
  });
  const spec = `${brief}\n\n## Task\n\nFeature \`${slug}\`, branch \`${branch}\`, your checkout \`${wt.path}\`.\n\n${task}\n`;

  const opened = await openFollowup(effects, { slug, worktree: wt.path, command, spec, coordinator });
  if (opened.failure) {
    discard();
    io.err(`crew-afk: follow-up not started: ${opened.failure}`);
    return 1;
  }
  const rec = {
    id,
    slug,
    host: effects.paneHost,
    state: "open",
    branch,
    worktree: wt.path,
    task,
    startedAt: new Date().toISOString(),
    coordinator: coordinator ?? null,
    runId: opened.runId ?? null,
    handle: opened.terminal ?? opened.handle ?? null,
    answered: [],
    pending: null,
  };
  try {
    writeRecord(rec, mainRoot);
  } catch (err) {
    io.err(`crew-afk: the follow-up worker started (${rec.handle}) but could not be recorded: ${err.message}`);
    return 1;
  }
  io.err(`crew-afk: follow-up ${id} started in ${wt.path} on ${branch} — crew-afk followup wait ${id}`);
  io.out(id);
  return 0;
}

async function findOrFail(effects, id, io) {
  if (!id) {
    io.err("usage: crew-afk followup wait|reply <id> …");
    return { code: 2 };
  }
  const rec = findRecord(effects.mainRoot, id);
  if (!rec) {
    io.err(`crew-afk: no follow-up ${id} (looked in ${join(effects.mainRoot, ".scratch")}/*/followup.json)`);
    return { code: 1 };
  }
  if (rec.host !== effects.paneHost) {
    io.err(`crew-afk: follow-up ${id} runs under ${rec.host}, but the pane host here is ${effects.paneHost}`);
    return { code: 1 };
  }
  return { rec };
}

/** `wait`: blocks until the worker's final result or a question; prints `DONE: …` or `QUESTION: …`. */
async function wait(effects, { id, io, pollMs }) {
  const { rec, code } = await findOrFail(effects, id, io);
  if (!rec) return code;
  const answer = await awaitFollowup(effects, rec, { pollMs });
  if (answer.failure) {
    io.err(`crew-afk: follow-up ${id}: ${answer.failure}`);
    return 1;
  }
  if (answer.kind === "question") {
    rec.pending = { messageId: answer.messageId ?? null, text: answer.text };
  } else {
    rec.state = "done";
    rec.pending = null;
    rec.result = answer.text;
  }
  try {
    writeRecord(rec, effects.mainRoot);
  } catch (err) {
    io.err(`crew-afk: follow-up ${id}: could not record the response: ${err.message}`);
    return 1;
  }
  io.out(`${answer.kind === "question" ? "QUESTION" : "DONE"}: ${answer.text}`);
  return 0;
}

/** `reply`: delivers the answer to the worker's open question. */
async function reply(effects, { id, answer, io }) {
  const { rec, code } = await findOrFail(effects, id, io);
  if (!rec) return code;
  if (!answer) {
    io.err("usage: crew-afk followup reply <id> \"<answer>\"");
    return 2;
  }
  if (rec.state === "done") {
    io.err(`crew-afk: follow-up ${id} has already finished — start another with followup start`);
    return 1;
  }
  const sent = await replyFollowup(effects, rec, answer);
  if (sent.failure) {
    io.err(`crew-afk: follow-up ${id}: ${sent.failure}`);
    return 1;
  }
  if (rec.pending?.messageId) rec.answered.push(rec.pending.messageId);
  rec.pending = null;
  try {
    writeRecord(rec, effects.mainRoot);
  } catch (err) {
    io.err(`crew-afk: follow-up ${id}: the answer was delivered but could not be recorded: ${err.message}`);
    return 1;
  }
  io.err(`crew-afk: answer delivered — crew-afk followup wait ${id}`);
  return 0;
}

/**
 * @param {object} effects  `paneHost`, `mainRoot`, git/exec/bash effects (Effects)
 * @param {object} o
 * @param {"start"|"wait"|"reply"} o.action
 * @param {string} [o.slug]    start
 * @param {string} [o.task]    start
 * @param {string} [o.id]      wait, reply
 * @param {string} [o.answer]  reply
 * @param {string} [o.platform]  start: the CLI the worker runs on
 * @param {string} [o.model]
 * @param {string} [o.effort]
 * @param {(slug: string) => string} [o.resolveBranch]  start: the feature branch to check out
 * @param {boolean} [o.useLease] start: the tracker has a feature lease (github)
 * @param {number} [o.pollMs]    wait: the orca inbox poll interval
 * @param {{out: Function, err: Function}} o.io
 * @returns {Promise<number>} the exit code
 */
export async function runFollowup(effects, o) {
  if (!supportsFollowups(effects)) {
    o.io.err(NO_HOST);
    return 1;
  }
  switch (o.action) {
    case "start":
      return start(effects, o);
    case "wait":
      return wait(effects, o);
    case "reply":
      return reply(effects, o);
    default:
      o.io.err("usage: crew-afk followup start <slug> \"<task>\" | wait <id> | reply <id> \"<answer>\"");
      return 2;
  }
}
