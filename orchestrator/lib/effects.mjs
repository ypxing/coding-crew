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
import { dirname, join } from "node:path";

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
  }

  script(name) {
    return join(this.scriptsDir, name);
  }

  /** Run a crew-afk bash script. Returns { code, stdout, stderr }. */
  bash(name, args = [], opts = {}) {
    return this.exec("bash", [this.script(name), ...args], opts);
  }

  exec(cmd, args, { cwd = this.mainRoot, env = {}, input, mutating = true } = {}) {
    const argv = [cmd, ...args];
    if (this.dryRun && mutating) {
      this.recorded.push({ argv, cwd });
      this.log(`DRY  ${argv.map(quote).join(" ")}`);
      return { code: 0, stdout: "", stderr: "", dryRun: true };
    }
    this.recorded.push({ argv, cwd });
    const r = spawnSync(cmd, args, {
      cwd,
      input,
      encoding: "utf8",
      env: { ...process.env, ...this.env, ...env },
      maxBuffer: 64 * 1024 * 1024,
    });
    const code = r.status === null ? 124 : r.status;
    this.log(`RUN  (${code}) ${argv.map(quote).join(" ")}`);
    if (r.error) this.log(`ERR  ${r.error.message}`);
    return { code, stdout: r.stdout ?? "", stderr: r.stderr ?? "", error: r.error };
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
      this.recorded.push({ argv, cwd });
      this.log(`DRY  ${argv.map(quote).join(" ")}`);
      return Promise.resolve({ code: 0, stdout: "", stderr: "", dryRun: true });
    }
    this.recorded.push({ argv, cwd });
    this.log(`SPAWN ${argv.map(quote).join(" ")}`);
    return new Promise((resolve) => {
      const child = spawn(cmd, args, {
        cwd,
        env: { ...process.env, ...this.env, ...env },
        stdio: ["ignore", "pipe", "pipe"],
      });
      let stdout = "";
      let stderr = "";
      let timedOut = false;
      const timer = timeoutMs
        ? setTimeout(() => {
            timedOut = true;
            child.kill("SIGKILL");
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
        resolve({ code: 127, stdout, stderr: `${stderr}${e.message}`, timedOut });
      });
      child.on("close", (code) => {
        if (timer) clearTimeout(timer);
        resolve({ code: timedOut ? 124 : (code ?? 1), stdout, stderr, timedOut });
      });
    });
  }
}

function quote(s) {
  return /[^\w@%+=:,./-]/.test(s) ? `'${String(s).replace(/'/g, "'\\''")}'` : s;
}

/** Bounded-concurrency map — the pool that replaces "batches of 3" in prose. */
export async function mapPool(items, limit, fn) {
  const out = new Array(items.length);
  let next = 0;
  const workers = Array.from({ length: Math.max(1, Math.min(limit, items.length)) }, async () => {
    while (true) {
      const i = next++;
      if (i >= items.length) return;
      out[i] = await fn(items[i], i);
    }
  });
  await Promise.all(workers);
  return out;
}

export function appendLine(file, line) {
  mkdirSync(dirname(file), { recursive: true });
  appendFileSync(file, `${line}\n`);
}
