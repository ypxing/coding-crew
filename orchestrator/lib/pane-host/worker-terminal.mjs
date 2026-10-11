/**
 * A headless dispatch in a pane-host terminal, for watching; resolves like spawnWithTimeout. The host
 * cannot report an exit code (`--command` is typed into a shell that outlives it), so run.sh writes the
 * child's pid and rc beside outFile and this polls them. The pid check assumes crew-afk's own host.
 */

import { closeSync, existsSync, mkdirSync, openSync, readFileSync, readSync, rmSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import { killGroup, registerExternalPid, unregisterExternalPid } from "../effects.mjs";
import { shellQuote } from "./shared.mjs";

export const TIMING = { pollMs: 500, startTimeoutMs: 30000, exitGraceMs: 5000 };

const FOLLOWER = fileURLToPath(new URL("./follow-output.mjs", import.meta.url));

/**
 * The child must see crew-afk's env and only that: a variable crew-afk unset (a GH_TOKEN copilot
 * must not see) would otherwise come back from the shell's profile. Skipped: names a shell can't
 * export, the terminal's geometry and cwd, and the ambient ids that must name the worker's terminal.
 */
const ENV_SKIP = /^(TERM|COLUMNS|LINES|PWD|OLDPWD|SHLVL|_|ORCA_TERMINAL_HANDLE|ORCA_TAB_ID|ORCA_WORKTREE_ID|HERDR_PANE_ID|HERDR_TAB_ID|HERDR_WORKSPACE_ID)$/;
const ENV_NAME = /^[A-Za-z_][A-Za-z0-9_]*$/;

export async function spawnInWorkerTerminal(
  effects,
  adapter,
  cmd,
  args,
  { cwd, env = {}, timeoutMs, onLine, input, stem, title, jsonEvents, agent, timing = TIMING } = {},
) {
  const dir = `${stem}.term`;
  const f = (name) => join(dir, name);
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(dir, { recursive: true });
  writeFileSync(f("env.sh"), envScript({ ...process.env, ...effects.env, ...env }), { mode: 0o600 });
  if (input !== undefined) writeFileSync(f("in"), input, { mode: 0o600 });
  writeFileSync(f("run.sh"), runScript({ f, cwd, cmd, args, jsonEvents, agent, stdin: input !== undefined }));

  effects.recorded?.push({ argv: [cmd, ...args], cwd, env });
  effects.log?.(`SPAWN-TERMINAL ${title} ${[cmd, ...args].map(shellQuote).join(" ")}`);

  const opened = await adapter.openWorkerTerminal(effects, { title, command: `bash ${shellQuote(f("run.sh"))}`, worktree: cwd });
  if (!opened.handle) {
    rmSync(dir, { recursive: true, force: true });
    effects.log?.(`WARN SPAWN-TERMINAL-FALLBACK ${title} ${opened.failure} — running headless`);
    return effects.spawnWithTimeout(cmd, args, { cwd, env, timeoutMs, onLine, input });
  }

  const out = tailer(f("out"), onLine);
  const started = Date.now();
  let deadSince = null;
  let result;
  let registered = null;
  try {
  for (;;) {
    await sleep(timing.pollMs);
    out.drain();
    const rc = readInt(f("rc"));
    if (rc !== null) {
      result = { code: rc, timedOut: false };
      break;
    }
    const pid = readInt(f("pid"));
    if (pid && registered !== pid) {
      registered = pid;
      registerExternalPid(pid);
    }
    const now = Date.now();
    // No pid yet under load is no reason to skip the kill: keep polling (bounded by startTimeoutMs).
    if (timeoutMs && now - started >= timeoutMs && pid) {
      // run.sh's job control made the child its group's leader: the group goes with it.
      killGroup(pid);
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
  } finally {
    if (registered) unregisterExternalPid(registered);
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
    if (latePid) killGroup(latePid);
  }

  const stderr = [readText(f("err")), result.reason].filter(Boolean).join("\n");
  // Kept on failure for inspection, minus the env (it can hold credentials).
  if (result.code === 0) rmSync(dir, { recursive: true, force: true });
  else rmSync(f("env.sh"), { force: true });
  return { code: result.code, stdout: out.text(), stderr, timedOut: result.timedOut };
}

/**
 * A host-started interactive agent gets the host's shell env, so it runs through the same `env.sh`
 * (0600, sourced then deleted) and `exec`s the argv. The argv holds a protocol too long to type, so
 * the host is given `command`, which runs the script.
 */
export function writeLaunchScript(effects, { dir, cwd, argv, env = {} }) {
  mkdirSync(dir, { recursive: true });
  const envFile = join(dir, "env.sh");
  const script = join(dir, "launch.sh");
  writeFileSync(envFile, envScript({ ...process.env, ...effects.env, ...env }), { mode: 0o600 });
  writeFileSync(
    script,
    [
      "#!/usr/bin/env bash",
      `. ${shellQuote(envFile)}; rm -f ${shellQuote(envFile)}`,
      `cd -P ${shellQuote(cwd)} || exit 127`,
      `exec ${argv.map(shellQuote).join(" ")}`,
      "",
    ].join("\n"),
  );
  return { command: `bash ${shellQuote(script)}`, script, envFile };
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
 * bash, whatever the login shell. `sh -c 'echo $$ …; exec'` records the pid the child keeps
 * (BASHPID is bash 4+; macOS ships 3.2). The display is a separate follower process, so a display
 * failure never reaches the child.
 */
function runScript({ f, cwd, cmd, args, jsonEvents, agent, stdin = false }) {
  const q = shellQuote;
  const p = (name) => q(f(name));
  return [
    "#!/usr/bin/env bash",
    `. ${p("env.sh")}; rm -f ${p("env.sh")}`,
    `cd -P ${q(cwd)} || { echo 127 > ${p("rc")}; exit; }`,
    `: > ${p("out")}; : > ${p("err")}`,
    `${q(process.execPath)} ${q(FOLLOWER)} ${p(jsonEvents ? "out" : "err")} ${p("rc")} ${q(jsonEvents ?? "")} ${q(agent ?? "")} &`,
    // Job control: the child leads its own process group, so killing the group takes its children.
    "set -m",
    `sh -c 'echo $$ > "$0.tmp" && mv "$0.tmp" "$0" && exec "$@"' ${p("pid")} ${[cmd, ...args].map(q).join(" ")} > ${p("out")} 2> ${p("err")} < ${stdin ? p("in") : "/dev/null"}`,
    `echo $? > ${p("rc.tmp")} && mv ${p("rc.tmp")} ${p("rc")}`,
    "wait",
    "",
  ].join("\n");
}

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


const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
