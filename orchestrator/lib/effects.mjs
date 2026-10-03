/**
 * effects.mjs — the one place that runs a subprocess.
 *
 * Every mutating step of a sprint is an existing, tested bash script
 * (verify-worktree.sh, merge-branches.sh, close-issue.sh, receipts.sh, …). JS owns
 * control flow; bash keeps the effects. This wrapper exists so that:
 *
 *   - `--dry-run` records the exact command sequence instead of running it, which
 *     makes the whole state machine inspectable and testable for zero tokens;
 *   - every command is logged in one place, in order, with its exit code;
 *   - nothing in the pipeline builds a shell string by hand.
 */

import { spawn, spawnSync } from "node:child_process";
import { appendFileSync, mkdirSync } from "node:fs";
import { constants as osConstants } from "node:os";
import { dirname, join } from "node:path";

/**
 * Process groups of live children. Every async child is spawned `detached` (its own group, pid == pgid)
 * so a timeout or an interrupt can kill the whole tree, grandchildren included. Blocking `exec`
 * stays in the terminal's foreground group so ^C reaches it while `spawnSync` blocks.
 */
const liveGroups = new Set();

/** SIGKILL a child's whole process group; falls back to the pid alone. Never throws. */
export function killGroup(pid, signal = "SIGKILL") {
  if (!pid) return;
  try {
    process.kill(-pid, signal);
  } catch {
    try {
      process.kill(pid, signal);
    } catch {}
  }
}

/** Kill every process group still running (interrupt path). */
export function killAllGroups(signal = "SIGKILL") {
  for (const pid of liveGroups) killGroup(pid, signal);
  liveGroups.clear();
}

/**
 * An external pid (one effects.mjs did not spawn, e.g. run.sh inside a pane-host terminal) the
 * interrupt path must also kill. Pair every register with an unregister on every exit path.
 */
export function registerExternalPid(pid) {
  if (pid) liveGroups.add(pid);
}

export function unregisterExternalPid(pid) {
  liveGroups.delete(pid);
}

/** The pids the interrupt path would kill now. */
export function registeredPids() {
  return [...liveGroups];
}

process.on("exit", () => killAllGroups());

export class Effects {
  /**
   * @param {object} o
   * @param {string} o.scriptsDir  crew-afk's scripts/ dir (bash mechanism layer)
   * @param {string} o.mainRoot    the main checkout
   * @param {boolean} o.dryRun
   * @param {(line: string) => void} o.log
   */
  constructor({ scriptsDir, mainRoot, dryRun = false, log = () => {}, env = {} }) {
    this.scriptsDir = scriptsDir;
    this.mainRoot = mainRoot;
    this.dryRun = dryRun;
    this.log = log;
    this.env = env;
    /** @type {{argv: string[], cwd: string}[]} */
    this.recorded = [];
    /** Counts effects that may change the repository (start and end of each): lets a read-only guard tell its dispatch from a concurrent merge. */
    this.mutations = 0;
  }

  script(name) {
    return join(this.scriptsDir, name);
  }

  /** Run a crew-afk bash script. Returns { code, stdout, stderr }. */
  bash(name, args = [], opts = {}) {
    return this.exec("bash", [this.script(name), ...args], opts);
  }

  /**
   * The non-blocking twin of `bash`, for effects that run for minutes (verify, deps): the event
   * loop keeps serving the other worker loops while the child runs. Same contract as `bash`.
   */
  bashAsync(name, args = [], opts = {}) {
    return this.execAsync("bash", [this.script(name), ...args], opts);
  }

  exec(cmd, args, { cwd = this.mainRoot, env = {}, input, mutating = true, timeoutMs } = {}) {
    const argv = [cmd, ...args];
    if (this.dryRun && mutating) {
      this.recorded.push({ argv, cwd });
      this.log(`DRY  ${argv.map(quote).join(" ")}`);
      return { code: 0, stdout: "", stderr: "", dryRun: true };
    }
    this.recorded.push({ argv, cwd });
    if (mutating) this.mutations++;
    const r = spawnSync(cmd, args, {
      cwd,
      input,
      encoding: "utf8",
      env: { ...process.env, ...this.env, ...env },
      maxBuffer: 64 * 1024 * 1024,
      ...(timeoutMs ? { timeout: timeoutMs, killSignal: "SIGKILL" } : {}),
    });
    // status === null: killed by a signal. Our own `timeout` is the one signal that is a
    // verdict (124, as always); any other was sent from outside — an interruption, not a
    // result, so it gets the shell's 128+signal and `interrupted`, never the timeout's 124.
    const timedOut = r.error?.code === "ETIMEDOUT";
    if (timedOut) killGroup(r.pid);
    const interrupted = r.status === null && !timedOut && Boolean(r.signal);
    const code = interrupted ? 128 + (osConstants.signals[r.signal] ?? 0) : r.status === null ? 124 : r.status;
    this.log(`RUN  (${code}) ${argv.map(quote).join(" ")}${interrupted ? ` [${r.signal}]` : ""}`);
    if (r.error) this.log(`ERR  ${r.error.message}`);
    if (mutating) this.mutations++;
    return { code, stdout: r.stdout ?? "", stderr: r.stderr ?? "", error: r.error, interrupted, signal: r.signal ?? null };
  }

  /**
   * `exec` without blocking the event loop. Resolves to the same `{ code, stdout, stderr }`;
   * a timeout kills the child and maps to exit 124, exactly as `exec` does.
   */
  execAsync(cmd, args, { cwd = this.mainRoot, env = {}, input, mutating = true, timeoutMs } = {}) {
    const argv = [cmd, ...args];
    if (this.dryRun && mutating) {
      this.recorded.push({ argv, cwd });
      this.log(`DRY  ${argv.map(quote).join(" ")}`);
      return Promise.resolve({ code: 0, stdout: "", stderr: "", dryRun: true });
    }
    this.recorded.push({ argv, cwd });
    if (mutating) this.mutations++;
    return new Promise((resolve) => {
      let stdout = "";
      let stderr = "";
      let error;
      let settled = false;
      let timedOut = false;
      let timer = null;
      const finish = (status, signal = null) => {
        if (mutating) this.mutations++;
        if (settled) return;
        settled = true;
        if (timer) clearTimeout(timer);
        if (child.pid) {
          liveGroups.delete(child.pid);
          if (timedOut) killGroup(child.pid);
        }
        // As in exec: our own timeout is exit 124; a signal from outside is an interruption (128+signal).
        const interrupted = !timedOut && (status === null || status === undefined) && Boolean(signal);
        const code = interrupted ? 128 + (osConstants.signals[signal] ?? 0) : timedOut || status === null || status === undefined ? 124 : status;
        this.log(`RUN  (${code}) ${argv.map(quote).join(" ")}${interrupted ? ` [${signal}]` : ""}`);
        if (error) this.log(`ERR  ${error.message}`);
        resolve({ code, stdout, stderr, error, interrupted, signal: signal ?? null });
      };
      const child = spawn(cmd, args, {
        cwd,
        env: { ...process.env, ...this.env, ...env },
        stdio: [input === undefined ? "ignore" : "pipe", "pipe", "pipe"],
        detached: true,
      });
      if (child.pid) liveGroups.add(child.pid);
      if (timeoutMs) {
        timer = setTimeout(() => {
          timedOut = true;
          killGroup(child.pid);
        }, timeoutMs);
      }
      child.stdout.setEncoding("utf8").on("data", (d) => (stdout += d));
      child.stderr.setEncoding("utf8").on("data", (d) => (stderr += d));
      child.stdin?.on("error", () => {});
      if (input !== undefined) child.stdin.end(input);
      // spawnSync reports a failed spawn as status null (exit 124 here) with `error` set.
      child.on("error", (e) => {
        error = e;
        finish(null);
      });
      child.on("close", (code, signal) => finish(code, signal));
    });
  }

  git(args, opts = {}) {
    return this.exec("git", ["-C", opts.cwd ?? this.mainRoot, ...args], {
      ...opts,
      mutating: opts.mutating ?? true,
    });
  }

  /** Read-only git — always really runs, even under --dry-run. */
  gitRead(args, opts = {}) {
    return this.exec("git", ["-C", opts.cwd ?? this.mainRoot, ...args], {
      ...opts,
      mutating: false,
    });
  }

  /**
   * Spawn a long-running child (a worker dispatch) with a hard timeout.
   * A hung worker used to block `wait` forever and the sprint never ended.
   */
  spawnWithTimeout(cmd, args, { cwd, env = {}, timeoutMs, onLine } = {}) {
    const argv = [cmd, ...args];
    if (this.dryRun) {
      this.recorded.push({ argv, cwd, env });
      this.log(`DRY  ${argv.map(quote).join(" ")}`);
      return Promise.resolve({ code: 0, stdout: "", stderr: "", dryRun: true });
    }
    this.recorded.push({ argv, cwd, env });
    this.log(`SPAWN ${argv.map(quote).join(" ")}`);
    return new Promise((resolve) => {
      const child = spawn(cmd, args, {
        cwd,
        env: { ...process.env, ...this.env, ...env },
        stdio: ["ignore", "pipe", "pipe"],
        detached: true,
      });
      if (child.pid) liveGroups.add(child.pid);
      let stdout = "";
      let stderr = "";
      let timedOut = false;
      const timer = timeoutMs
        ? setTimeout(() => {
            timedOut = true;
            killGroup(child.pid);
          }, timeoutMs)
        : null;
      child.stdout.on("data", (d) => {
        stdout += d;
        onLine?.(String(d));
      });
      child.stderr.on("data", (d) => {
        stderr += d;
      });
      child.on("error", (e) => {
        if (timer) clearTimeout(timer);
        if (child.pid) liveGroups.delete(child.pid);
        resolve({ code: 127, stdout, stderr: `${stderr}${e.message}`, timedOut });
      });
      child.on("close", (code) => {
        if (timer) clearTimeout(timer);
        if (child.pid) {
          liveGroups.delete(child.pid);
          if (timedOut) killGroup(child.pid);
        }
        resolve({ code: timedOut ? 124 : (code ?? 1), stdout, stderr, timedOut });
      });
    });
  }
}

function quote(s) {
  return /[^\w@%+=:,./-]/.test(s) ? `'${String(s).replace(/'/g, "'\\''")}'` : s;
}

export function appendLine(file, line) {
  mkdirSync(dirname(file), { recursive: true });
  appendFileSync(file, `${line}\n`);
}
