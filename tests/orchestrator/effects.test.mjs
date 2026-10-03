/**
 * Effects.execAsync — the non-blocking twin of exec, used for verify and deps.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { Effects } from "../../orchestrator/lib/effects.mjs";

const mk = (o = {}) => new Effects({ scriptsDir: "/nonexistent", mainRoot: process.cwd(), ...o });

test("execAsync returns code, stdout and stderr like exec", async () => {
  const e = mk();
  const r = await e.execAsync("sh", ["-c", "echo out; echo err >&2; exit 3"]);
  assert.deepEqual({ code: r.code, stdout: r.stdout, stderr: r.stderr }, { code: 3, stdout: "out\n", stderr: "err\n" });
});

test("execAsync maps a timeout to exit 124, as exec does", async () => {
  const e = mk();
  const sync = e.exec("sh", ["-c", "sleep 5"], { timeoutMs: 100 });
  const async_ = await e.execAsync("sh", ["-c", "sleep 5"], { timeoutMs: 100 });
  assert.equal(sync.code, 124);
  assert.equal(async_.code, 124);
});

test("execAsync does not block the event loop", async () => {
  const e = mk();
  let ticks = 0;
  const t = setInterval(() => ticks++, 20);
  await e.execAsync("sh", ["-c", "sleep 0.4"]);
  clearInterval(t);
  assert.ok(ticks >= 5, `the event loop was starved: ${ticks} ticks`);
});

test("two execAsync calls overlap", async () => {
  const e = mk();
  const t0 = Date.now();
  await Promise.all([e.execAsync("sh", ["-c", "sleep 0.5"]), e.execAsync("sh", ["-c", "sleep 0.5"])]);
  assert.ok(Date.now() - t0 < 900, `ran back to back: ${Date.now() - t0}ms`);
});

test("execAsync under dryRun records instead of running", async () => {
  const e = mk({ dryRun: true });
  const r = await e.execAsync("false", []);
  assert.equal(r.code, 0);
  assert.equal(r.dryRun, true);
  assert.deepEqual(e.recorded[0].argv, ["false"]);
});

test("execAsync passes input and a missing command is not a crash", async () => {
  const e = mk();
  assert.equal((await e.execAsync("cat", [], { input: "hi" })).stdout, "hi");
  const r = await e.execAsync("definitely-not-a-command-xyz", []);
  assert.equal(r.code, 124);
  assert.ok(r.error);
});

const effects = () => new Effects({ scriptsDir: process.cwd(), mainRoot: process.cwd(), dryRun: false });

test("a child killed by a signal from outside is interrupted: 128+signal, never the timeout's 124", () => {
  const r = effects().exec("bash", ["-c", "kill -TERM $$"], { mutating: false });
  assert.equal(r.interrupted, true);
  assert.equal(r.signal, "SIGTERM");
  assert.equal(r.code, 143);
});

test("the call's own timeoutMs is still 124, and not an interruption", () => {
  const r = effects().exec("sleep", ["5"], { mutating: false, timeoutMs: 100 });
  assert.equal(r.code, 124);
  assert.equal(r.interrupted, false);
});

test("an ordinary failing exit is neither", () => {
  const r = effects().exec("bash", ["-c", "exit 3"], { mutating: false });
  assert.equal(r.code, 3);
  assert.equal(r.interrupted, false);
});

test("execAsync reports an outside signal as interrupted (128+signal), a timeout as 124", async () => {
  const e = effects();
  const r = await e.execAsync("bash", ["-c", "kill -TERM $$"], { mutating: false });
  assert.equal(r.interrupted, true);
  assert.equal(r.signal, "SIGTERM");
  assert.equal(r.code, 143);
  const t = await e.execAsync("sleep", ["5"], { mutating: false, timeoutMs: 100 });
  assert.equal(t.code, 124);
  assert.equal(t.interrupted, false);
});

// --- timeouts kill the whole process group ---
import { mkdtempSync, readFileSync, existsSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const alive = (pid) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};
const gone = async (pid) => {
  for (let i = 0; i < 40 && alive(pid); i++) await new Promise((r) => setTimeout(r, 50));
  return !alive(pid);
};
const grandchildScript = () => {
  const dir = mkdtempSync(join(tmpdir(), "gc-"));
  const f = join(dir, "pid");
  return { dir, f, sh: `sleep 30 & echo $! > ${f}; wait` };
};
const readPid = async (f) => {
  for (let i = 0; i < 40 && !existsSync(f); i++) await new Promise((r) => setTimeout(r, 50));
  await new Promise((r) => setTimeout(r, 50));
  return Number(readFileSync(f, "utf8"));
};

test("spawnWithTimeout timeout leaves no grandchild", async () => {
  const { dir, f, sh } = grandchildScript();
  const r = await mk().spawnWithTimeout("sh", ["-c", sh], { cwd: process.cwd(), timeoutMs: 500 });
  assert.equal(r.code, 124);
  assert.ok(await gone(await readPid(f)));
  rmSync(dir, { recursive: true });
});

test("execAsync timeout leaves no grandchild", async () => {
  const { dir, f, sh } = grandchildScript();
  const r = await mk().execAsync("sh", ["-c", sh], { timeoutMs: 500 });
  assert.equal(r.code, 124);
  assert.ok(await gone(await readPid(f)));
  rmSync(dir, { recursive: true });
});

test("a blocking timed exec interrupted by a signal returns at once with interrupted and 128+signal", () => {
  const t = Date.now();
  const r = mk().exec("sh", ["-c", "kill -INT $$; sleep 30"], { timeoutMs: 20000 });
  assert.ok(Date.now() - t < 5000);
  assert.equal(r.interrupted, true);
  assert.equal(r.code, 130);
});

test("a blocking timed exec that times out still returns 124", () => {
  const r = mk().exec("sh", ["-c", "sleep 5"], { timeoutMs: 200 });
  assert.equal(r.code, 124);
  assert.equal(r.interrupted, false);
});

test("register/unregister put an external pid on the interrupt path", async () => {
  const { registerExternalPid, unregisterExternalPid, registeredPids, killAllGroups } = await import("../../orchestrator/lib/effects.mjs");
  const { spawn } = await import("node:child_process");
  const c = spawn("sleep", ["30"], { stdio: "ignore" });
  registerExternalPid(c.pid);
  assert.ok(registeredPids().includes(c.pid));
  killAllGroups();
  assert.ok(await gone(c.pid));
  unregisterExternalPid(c.pid);
});

test("killAllGroups kills live dispatch groups", async () => {
  const { killAllGroups } = await import("../../orchestrator/lib/effects.mjs");
  const { dir, f, sh } = grandchildScript();
  const p = mk().spawnWithTimeout("sh", ["-c", sh], { cwd: process.cwd() });
  const pid = await readPid(f);
  killAllGroups();
  await p;
  assert.ok(await gone(pid));
  rmSync(dir, { recursive: true });
});
