/**
 * A headless dispatch hosted in a pane-host terminal, so a human can watch it live. The
 * child is the exact argv spawnWithTimeout would run, and resolves to the same
 * `{code, stdout, stderr, timedOut}`.
 *
 * Nothing is read from the terminal. A pane host's `--command` is typed into a login shell
 * that outlives it, so the host can report neither exit nor exit code. run.sh writes the
 * child's pid and exit code to files beside the dispatch's outFile, and this module polls
 * those:
 *
 *   rc present                        → done, with that code
 *   past timeoutMs                    → SIGKILL the pid; 124, as spawnWithTimeout
 *   pid dead and no rc after a grace  → the terminal died under it (host quit); 1
 *   no pid within startTimeoutMs      → the shell never ran run.sh; close it, 127
 *
 * The pid check needs the terminal on crew-afk's own host, which holds for the one case this
 * runs in: crew-afk launched from a pane-host terminal in the same checkout.
 */

import { closeSync, existsSync, mkdirSync, openSync, readFileSync, readSync, rmSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import { shellQuote } from "./shared.mjs";

export const TIMING = { pollMs: 500, startTimeoutMs: 30000, exitGraceMs: 5000 };

const FOLLOWER = fileURLToPath(new URL("./follow-output.mjs", import.meta.url));

/**
 * The terminal's shell has its own env; the child must see crew-afk's, and only that: a
 * variable crew-afk unset (a GH_TOKEN copilot must not see) would otherwise come back from
 * the shell's profile. Left alone either way: names a shell can't export, the terminal's
 * own geometry and cwd, and the ambient ids that must keep naming the worker's terminal
 * rather than the triggering one.
 */
const ENV_SKIP = /^(TERM|COLUMNS|LINES|PWD|OLDPWD|SHLVL|_|ORCA_TERMINAL_HANDLE|ORCA_TAB_ID|ORCA_WORKTREE_ID)$/;
const ENV_NAME = /^[A-Za-z_][A-Za-z0-9_]*$/;

/**
 * @param {object} adapter  `{openWorkerTerminal, closeWorkerTerminal}` from the pane host
 * @param {object} o
 * @param {string} o.stem          file prefix (the dispatch's outFile); files go in `<stem>.term/`
 * @param {string} o.title         terminal title
 * @param {string} [o.jsonEvents]  platform whose event stream the terminal shows as trace lines
 * @param {string} [o.agent]
 */
export async function spawnInWorkerTerminal(
  effects,
  adapter,
  cmd,
  args,
  { cwd, env = {}, timeoutMs, onLine, stem, title, jsonEvents, agent, timing = TIMING } = {},
) {
  const dir = `${stem}.term`;
  const f = (name) => join(dir, name);
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(dir, { recursive: true });
  writeFileSync(f("env.sh"), envScript({ ...process.env, ...effects.env, ...env }), { mode: 0o600 });
  writeFileSync(f("run.sh"), runScript({ f, cwd, cmd, args, jsonEvents, agent }));

  effects.recorded?.push({ argv: [cmd, ...args], cwd, env });
  effects.log?.(`SPAWN-TERMINAL ${title} ${[cmd, ...args].map(shellQuote).join(" ")}`);

  const opened = await adapter.openWorkerTerminal(effects, { title, command: `bash ${shellQuote(f("run.sh"))}` });
  if (!opened.handle) {
    rmSync(dir, { recursive: true, force: true });
    effects.log?.(`SPAWN-TERMINAL-FALLBACK ${opened.failure} — running headless`);
    return effects.spawnWithTimeout(cmd, args, { cwd, env, timeoutMs, onLine });
  }

  const out = tailer(f("out"), onLine);
  const started = Date.now();
  let deadSince = null;
  let result;
  for (;;) {
    await sleep(timing.pollMs);
    out.drain();
    const rc = readInt(f("rc"));
    if (rc !== null) {
      result = { code: rc, timedOut: false };
      break;
    }
    const pid = readInt(f("pid"));
    const now = Date.now();
    if (timeoutMs && now - started >= timeoutMs) {
      if (pid) kill(pid);
      result = { code: 124, timedOut: true };
      break;
    }
    if (pid === null) {
      if (now - started < timing.startTimeoutMs) continue;
      result = { code: 127, timedOut: false, reason: `worker terminal "${title}" never started run.sh` };
      break;
    }
    if (alive(pid)) {
      deadSince = null;
      continue;
    }
    deadSince ??= now;
    if (now - deadSince >= timing.exitGraceMs) {
      result = { code: 1, timedOut: false, reason: `worker pid ${pid} exited without an exit code — its terminal closed under it` };
      break;
    }
  }
  out.drain();
  out.close();

  try {
    await adapter.closeWorkerTerminal(effects, opened.handle);
  } catch {
    /* cosmetic */
  }
  // A run.sh that started after startTimeoutMs gave up on it must not keep running.
  if (result.code === 127) {
    const latePid = readInt(f("pid"));
    if (latePid) kill(latePid);
  }

  const stderr = [readText(f("err")), result.reason].filter(Boolean).join("\n");
  // Kept on failure for inspection, minus the env (it can hold credentials).
  if (result.code === 0) rmSync(dir, { recursive: true, force: true });
  else rmSync(f("env.sh"), { force: true });
  return { code: result.code, stdout: out.text(), stderr, timedOut: result.timedOut };
}

function envScript(env) {
  const vars = Object.entries(env).filter(([k, v]) => v !== undefined && ENV_NAME.test(k) && !ENV_SKIP.test(k));
  const keep = ` ${vars.map(([k]) => k).join(" ")} `;
  return [
    `__keep=${shellQuote(keep)}`,
    'for __v in $(compgen -e); do [[ "$__keep" == *" $__v "* || "$__v" =~ ' + ENV_SKIP.source + ' ]] || unset "$__v" 2>/dev/null; done',
    "unset __keep __v",
    ...vars.map(([k, v]) => `export ${k}=${shellQuote(v)}`),
    "",
  ].join("\n");
}

/**
 * bash, whatever the terminal's login shell. `sh -c 'echo $$ …; exec'` records the pid the
 * child keeps (BASHPID is bash 4+; macOS ships 3.2). The child writes straight to `out`;
 * what the terminal shows is a separate follower process, so a display failure can never
 * reach the child. It follows `out` for an event stream it can parse (claude, copilot), and
 * `err` otherwise: pi and codex's bash dispatchers put raw events on stdout and their own
 * `[TOOL]` lines, plus the CLI's errors, on stderr.
 */
function runScript({ f, cwd, cmd, args, jsonEvents, agent }) {
  const q = shellQuote;
  const p = (name) => q(f(name));
  return [
    "#!/usr/bin/env bash",
    `. ${p("env.sh")}; rm -f ${p("env.sh")}`,
    `cd ${q(cwd)} || { echo 127 > ${p("rc")}; exit; }`,
    `: > ${p("out")}; : > ${p("err")}`,
    `${q(process.execPath)} ${q(FOLLOWER)} ${p(jsonEvents ? "out" : "err")} ${p("rc")} ${q(jsonEvents ?? "")} ${q(agent ?? "")} &`,
    `sh -c 'echo $$ > "$0.tmp" && mv "$0.tmp" "$0" && exec "$@"' ${p("pid")} ${[cmd, ...args].map(q).join(" ")} > ${p("out")} 2> ${p("err")} < /dev/null`,
    `echo $? > ${p("rc.tmp")} && mv ${p("rc.tmp")} ${p("rc")}`,
    "wait",
    "",
  ].join("\n");
}

/** Hands onLine raw chunks as the file grows, like spawnWithTimeout's stdout handler. */
function tailer(file, onLine) {
  let fd = null;
  let offset = 0;
  let text = "";
  const buf = Buffer.alloc(64 * 1024);
  return {
    drain() {
      if (fd === null) {
        if (!existsSync(file)) return;
        fd = openSync(file, "r");
      }
      for (;;) {
        const n = readSync(fd, buf, 0, buf.length, offset);
        if (n <= 0) return;
        offset += n;
        const chunk = buf.toString("utf8", 0, n);
        text += chunk;
        onLine?.(chunk);
      }
    },
    close() {
      if (fd !== null) closeSync(fd);
    },
    text: () => text,
  };
}

function readInt(file) {
  const t = readText(file).trim();
  return /^\d+$/.test(t) ? Number(t) : null;
}

function readText(file) {
  try {
    return readFileSync(file, "utf8");
  } catch {
    return "";
  }
}

function alive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return err.code === "EPERM";
  }
}

function kill(pid) {
  try {
    process.kill(pid, "SIGKILL");
  } catch {
    /* already gone */
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
