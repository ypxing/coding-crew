import { test } from "node:test";
import assert from "node:assert/strict";

import { Effects } from "../../orchestrator/lib/effects.mjs";

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
