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
