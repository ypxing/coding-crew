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
