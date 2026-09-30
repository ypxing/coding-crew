import { test } from "node:test";
import assert from "node:assert/strict";
import { acquireLease, releaseLease, parseOwner, refusalMessage } from "../../orchestrator/lib/lease.mjs";

// A fake lease.sh: `held` is the one ref's { sha, message } or null.
function fake(held, { rejectWrites = false } = {}) {
  const calls = [];
  return {
    calls,
    bash(name, args) {
      calls.push(args);
      const verb = args[0];
      if (verb === "owner") return { code: 0, stdout: held ? `SHA ${held.sha}\nOWNER ${held.message}\n` : "NONE\n", stderr: "" };
      if (rejectWrites) return { code: 3, stdout: "", stderr: "" };
      if (verb === "release") return { code: 0, stdout: "", stderr: "" };
      return { code: 0, stdout: "SHA new\n", stderr: "" };
    },
  };
}
const base = { slug: "f", runId: "r2", host: "h1", pid: 10, now: () => Date.parse("2026-01-01T01:00:00Z") };
const msg = (host, pid) => `run=r1 host=${host} pid=${pid} at=2026-01-01T00:00:00.000Z`;

test("acquires when free", () => {
  const e = fake(null);
  assert.deepEqual(acquireLease(e, base).lease, { slug: "f", sha: "new" });
  assert.equal(e.calls[1][0], "acquire");
});

test("live owner: refuses naming run, host, start, --reclaim; writes nothing", () => {
  const e = fake({ sha: "abc", message: msg("h1", 99) });
  const r = acquireLease(e, { ...base, pidAlive: () => true });
  assert.match(r.error, /run r1 on h1 since 2026-01-01T00:00:00.000Z \(1h 0m ago\).*--reclaim/);
  assert.deepEqual(e.calls.map((c) => c[0]), ["owner"]);
});

test("dead pid on this host: reclaimed on the stale sha and logged", () => {
  const e = fake({ sha: "abc", message: msg("h1", 99) });
  const logs = [];
  const r = acquireLease(e, { ...base, pidAlive: () => false, log: (l) => logs.push(l) });
  assert.ok(r.lease);
  assert.equal(e.calls[1][0], "reclaim");
  assert.equal(e.calls[1][e.calls[1].indexOf("--expect") + 1], "abc");
  assert.match(logs[0], /reclaimed/);
});

test("dead-looking pid on another host is not reclaimed without --reclaim", () => {
  const e = fake({ sha: "abc", message: msg("h2", 99) });
  assert.ok(acquireLease(e, { ...base, pidAlive: () => false }).error);
  assert.ok(acquireLease(fake({ sha: "abc", message: msg("h2", 99) }), { ...base, reclaim: true }).lease);
});

test("a lost reclaim race refuses instead of taking the winner's lease", () => {
  const e = fake({ sha: "abc", message: msg("h2", 99) }, { rejectWrites: true });
  const r = acquireLease(e, { ...base, reclaim: true });
  assert.ok(r.error);
  assert.equal(e.calls.filter((c) => c[0] === "reclaim").length, 1);
});

test("release: ok, superseded, and failed with the manual command", () => {
  const ok = releaseLease(fake(null), { slug: "f", sha: "x" });
  assert.deepEqual(ok, { released: true });
  const sup = releaseLease(fake(null, { rejectWrites: true }), { slug: "f", sha: "x" });
  assert.equal(sup.superseded, true);
  const bad = releaseLease({ bash: () => ({ code: 1, stdout: "", stderr: "boom" }) }, { slug: "f", sha: "x" });
  assert.equal(bad.command, "git push origin :refs/crew-lock/f");
  assert.equal(bad.failed, "boom");
});

test("parseOwner / refusalMessage tolerate an unparseable message", () => {
  assert.equal(parseOwner("junk"), null);
  assert.match(refusalMessage("f", null, "junk"), /unrecognised owner \(junk\).*--reclaim/);
});
