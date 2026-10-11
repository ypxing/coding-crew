import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { acquireLease, releaseLease, parseOwner, refusalMessage, leaseNamespace } from "../../orchestrator/lib/lease.mjs";

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

// The namespace end to end: lease.mjs driving the real lease.sh against a bare repo as origin.
const LEASE_SH = join(dirname(fileURLToPath(import.meta.url)), "../../skills/crew-afk/scripts/lease.sh");

function leaseRepo() {
  const dir = mkdtempSync(join(tmpdir(), "crew-lease-ns-"));
  const remote = join(dir, "remote.git");
  const repo = join(dir, "repo");
  const git = (...args) => execFileSync("git", args, { cwd: dir, stdio: "pipe" });
  git("init", "-q", "--bare", remote);
  git("init", "-q", "-b", "main", repo);
  git("-C", repo, "-c", "user.email=t@test", "-c", "user.name=T", "commit", "-q", "--allow-empty", "-m", "init");
  git("-C", repo, "remote", "add", "origin", remote);
  const effects = {
    bash(name, args) {
      // The environment at call time, as the orchestrator's own effects pass it: lease.sh and
      // lease.mjs read the one CREW_LEASE_NAMESPACE.
      const env = { ...process.env, MAIN_ROOT: repo };
      const r = spawnSync("bash", [LEASE_SH, ...args], { cwd: repo, env, encoding: "utf8" });
      return { code: r.status, stdout: r.stdout, stderr: r.stderr };
    },
  };
  const remoteRefs = (pattern) => execFileSync("git", ["ls-remote", remote, pattern], { encoding: "utf8" }).trim();
  return { dir, remote, effects, remoteRefs };
}

function withNamespace(ns, fn) {
  const prev = process.env.CREW_LEASE_NAMESPACE;
  if (ns === undefined) delete process.env.CREW_LEASE_NAMESPACE; else process.env.CREW_LEASE_NAMESPACE = ns;
  try {
    return fn();
  } finally {
    if (prev === undefined) delete process.env.CREW_LEASE_NAMESPACE; else process.env.CREW_LEASE_NAMESPACE = prev;
  }
}

test("CREW_LEASE_NAMESPACE moves the whole lease, and the manual release command with it", () => {
  const { effects, remoteRefs, dir } = leaseRepo();
  try {
    withNamespace("refs/tags/crew-lock/", () => {
      const { lease } = acquireLease(effects, base);
      assert.ok(lease, "acquired");
      assert.notEqual(remoteRefs("refs/tags/crew-lock/f"), "");
      assert.equal(remoteRefs("refs/crew-lock/f"), "");
      const failed = releaseLease({ bash: () => ({ code: 1, stdout: "", stderr: "boom" }) }, { ...lease });
      assert.equal(failed.command, "git push origin :refs/tags/crew-lock/f");
      assert.deepEqual(releaseLease(effects, lease), { released: true });
      assert.equal(remoteRefs("refs/tags/crew-lock/f"), "");
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a host that refuses the namespace: the run stops naming the lease ref and the fallback, not a lost race", () => {
  const { effects, remote, dir } = leaseRepo();
  try {
    const hook = join(remote, "hooks/pre-receive");
    writeFileSync(hook, '#!/bin/sh\nwhile read old new ref; do case "$ref" in refs/crew-lock/*) echo "namespace not allowed" >&2; exit 1;; esac; done\n');
    chmodSync(hook, 0o755);
    const { error } = withNamespace(undefined, () => acquireLease(effects, base));
    assert.match(error ?? "", /lease refs\/crew-lock\/f on origin: .*rejected the lease ref refs\/crew-lock\/f/s);
    assert.match(error, /CREW_LEASE_NAMESPACE=refs\/tags\/crew-lock/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("the default namespace is refs/crew-lock", () => {
  assert.equal(leaseNamespace({}), "refs/crew-lock");
});
