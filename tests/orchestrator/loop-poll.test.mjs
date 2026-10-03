/**
 * Idle-slot polling (--poll-interval) in loop.mjs, driven with a stub tracker, stub pipeline
 * stages and a fake clock: no process, no git, no model.
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { runSprint } from "../../orchestrator/lib/loop.mjs";

const flush = () => new Promise((r) => setImmediate(r));

function harness({ pollInterval, parallel = 2, initial = ["a"], lintBlocks = [] }) {
  const ready = initial.map((slug) => ({ slug, number: null }));
  const done = new Set();
  const listings = { n: 0 };
  const tracker = {
    selectDispatchable: () => {
      listings.n++;
      return ready.filter((i) => !done.has(i.slug));
    },
    listOpen: () => [],
    listOpenIssueFiles: () => [],
    parseIssue: () => ({}),
  };
  const attempts = new Map();
  const blocked = new Set();
  const sprint = {
    featureSlug: "demo",
    PRDAudit: "off",
    fixFindings: "actionable",
    triageFallbacks: [],
    env: {},
    get: () => null,
    childEnv: () => ({}),
    isBlockedThisRun: (s) => blocked.has(s),
    attemptCount: (s) => attempts.get(s) ?? 0,
    bumpAttempt: (s) => { attempts.set(s, (attempts.get(s) ?? 0) + 1); return attempts.get(s); },
    retentionReason: () => null,
  };
  const effects = {
    mainRoot: "/nowhere",
    bash: () => ({ code: 0, stdout: "FLUSH: promoted=0", stderr: "" }),
    exec: () => ({ code: 0, stdout: "", stderr: "" }),
  };
  const gates = new Map(); // slug → release()
  const started = [];
  const sleeps = [];
  const linted = [];
  const stages = {
    checkRequires: async () => [],
    runWorker: async (_c, issue) => {
      started.push(issue.slug);
      await new Promise((resolve) => gates.set(issue.slug, resolve));
      return { issue };
    },
    runHousekeeping: async (_c, w) => { done.add(w.issue.slug); return { status: "complete" }; },
    lintMidRunIssues: async (_c, issues) => {
      linted.push(...issues.map((i) => i.slug));
      const bad = issues.filter((i) => lintBlocks.includes(i.slug)).map((i) => i.slug);
      bad.forEach((s) => blocked.add(s));
      return bad;
    },
  };
  const ctx = {
    sprint, effects, tracker, stages,
    options: { parallel, pollInterval, integrationCheck: false, crew: { coder: { runtime: "pi" } } },
    log: () => {},
    out: () => {},
    sleep: () => new Promise((resolve) => sleeps.push(resolve)),
  };
  // wrapUp shells out; stub-safe because every effect above returns empty success.
  return { ctx, ready, listings, gates, started, sleeps, linted, blocked, done };
}

const settle = async () => { for (let i = 0; i < 5; i++) await flush(); };

test("an issue made ready mid-run is claimed within one interval and runs concurrently", async () => {
  const h = harness({ pollInterval: 5 });
  const run = runSprint(h.ctx);
  await settle();
  assert.deepEqual(h.started, ["a"]);
  h.ready.push({ slug: "b", number: null });
  h.sleeps.shift()();
  await settle();
  assert.deepEqual(h.started, ["a", "b"]);
  h.gates.get("a")(); h.gates.get("b")();
  await run;
});

test("--poll-interval 0: the new issue waits for the in-flight attempt to end", async () => {
  const h = harness({ pollInterval: 0 });
  const run = runSprint(h.ctx);
  await settle();
  h.ready.push({ slug: "b", number: null });
  await settle();
  assert.equal(h.sleeps.length, 0);
  assert.deepEqual(h.started, ["a"]);
  h.gates.get("a")();
  await settle();
  assert.deepEqual(h.started, ["a", "b"]);
  h.gates.get("b")();
  await run;
});

test("N idle slots cost one listing per interval; polling stops once nothing is in flight", async () => {
  const h = harness({ pollInterval: 5, parallel: 4 });
  const run = runSprint(h.ctx);
  await settle();
  const before = h.listings.n;
  h.sleeps.shift()(); // nothing new: one listing
  await settle();
  assert.equal(h.listings.n - before, 1);
  h.gates.get("a")();
  await run;
  const after = h.listings.n;
  for (const s of h.sleeps.splice(0)) s();
  await settle();
  assert.equal(h.listings.n, after);
});

test("a mid-run issue with a lint ERROR is blocked without stopping the others; seeded issues are not re-linted", async () => {
  const h = harness({ pollInterval: 5, lintBlocks: ["bad"] });
  const run = runSprint(h.ctx);
  await settle();
  h.ready.push({ slug: "bad", number: null }, { slug: "good", number: null });
  h.sleeps.shift()();
  await settle();
  assert.deepEqual(h.linted, ["bad", "good"]);
  assert.deepEqual(h.started, ["a", "good"]);
  assert.ok(h.blocked.has("bad"));
  h.gates.get("a")(); h.gates.get("good")();
  await run;
});

test("a fix issue this run created is not linted", async () => {
  const h = harness({ pollInterval: 5, initial: ["a", "b"] });
  h.ctx.stages.runHousekeeping = async (_c, w) => {
    h.done.add(w.issue.slug);
    return w.issue.slug === "b" ? { status: "complete", promotedRef: 9 } : { status: "complete" };
  };
  const run = runSprint(h.ctx);
  await settle();
  h.gates.get("b")(); // b finishes and files fix issue #9 while a is still running
  await settle();
  h.ready.push({ slug: "fix", number: 9 });
  h.sleeps.shift()();
  await settle();
  assert.deepEqual(h.linted, []);
  assert.deepEqual(h.started, ["a", "b", "fix"]);
  h.gates.get("a")(); h.gates.get("fix")();
  await run;
});

test("wall-clock cap: once elapsed nothing new is claimed, the running worker finishes, run is stalled and names the cap", async () => {
  const h = harness({ pollInterval: 0, parallel: 1 });
  let t = 0;
  h.ctx.now = () => t;
  h.ctx.options.maxWallMinutes = 10;
  const out = [];
  h.ctx.out = (s) => out.push(s);
  const run = runSprint(h.ctx);
  await settle();
  assert.deepEqual(h.started, ["a"]);
  h.ready.push({ slug: "b", number: null }, { slug: "c", number: null });
  t = 10 * 60_000;
  h.gates.get("a")();
  const result = await run;
  assert.deepEqual(h.started, ["a"]);
  assert.ok(h.done.has("a"));
  assert.equal(result.stalled, true);
  const text = out.join("\n");
  assert.match(text, /10-minute cap/);
  assert.match(text, /- b\n- c/);
});

test("wall-clock cap 0 disables it", async () => {
  const h = harness({ pollInterval: 0, parallel: 1, initial: ["a", "b"] });
  h.ctx.now = () => 1e12;
  h.ctx.options.maxWallMinutes = 0;
  const run = runSprint(h.ctx);
  await settle();
  h.gates.get("a")();
  await settle();
  h.gates.get("b")();
  const result = await run;
  assert.deepEqual(h.started, ["a", "b"]);
  assert.equal(result.stalled, false);
});

test("wall-clock cap elapsed with nothing ready: flush is skipped, integration still runs, summary and reason name the cap", async () => {
  const h = harness({ pollInterval: 0, parallel: 1 });
  let t = 0;
  h.ctx.now = () => t;
  h.ctx.options.maxWallMinutes = 10;
  h.ctx.options.integrationCheck = true;
  const calls = [];
  const out = [];
  h.ctx.out = (s) => out.push(s);
  const bash = h.ctx.effects.bash;
  h.ctx.effects.bash = (name, args, o) => { calls.push({ name, args }); return bash(name, args, o); };
  h.ctx.sprint.get = (k) => (k === "merged" ? "crew/demo/a" : null);
  // Integration check answers from cache (tree already passed): proves it still runs past the cap.
  Object.assign(h.ctx.sprint, { featureBranch: "crew/demo", readState: () => ({ passing_trees: ["T"] }), state: () => {} });
  h.ctx.effects.gitRead = () => ({ stdout: "T\n", code: 0 });
  const logs = [];
  h.ctx.log = (m) => logs.push(m);
  const run = runSprint(h.ctx);
  await settle();
  t = 10 * 60_000;
  h.gates.get("a")();
  const result = await run;
  assert.ok(logs.some((m) => /INTEGRATION|cached/.test(String(m))), "integration check ran");
  assert.equal(result.stalled, true);
  assert.ok(!calls.some((c) => c.name === "promote-findings.sh" && c.args[0] === "flush"), "flush must not run past the cap");
  assert.match(out.join("\n"), /## Wall-clock cap[\s\S]*Phase 2 fix issues stayed parked/);
});

test("wall-clock cap with --open-pr: open-pr.sh gets --draft and a note naming the cap", async () => {
  const { mkdtempSync, readFileSync, writeFileSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const dir = mkdtempSync(join(tmpdir(), "wallcap-"));
  const h = harness({ pollInterval: 0, parallel: 1 });
  let t = 0;
  h.ctx.now = () => t;
  h.ctx.options.maxWallMinutes = 10;
  h.ctx.options.openPr = true;
  Object.assign(h.ctx.sprint, {
    env: { SPRINT_DIR: dir },
    featureBranch: "crew/demo",
    readState: () => ({}),
    getList: () => [],
  });
  h.ctx.sprint.get = (k) => (k === "merged" ? "crew/demo/a" : null);
  const calls = [];
  const bash = h.ctx.effects.bash;
  h.ctx.effects.bash = (name, args, o) => {
    calls.push({ name, args });
    return name === "open-pr.sh" ? { code: 0, stdout: "PR: http://x/1\n", stderr: "" } : bash(name, args, o);
  };
  const run = runSprint(h.ctx);
  await settle();
  t = 10 * 60_000;
  h.gates.get("a")();
  await run;
  const pr = calls.find((c) => c.name === "open-pr.sh");
  assert.ok(pr, "open-pr.sh called");
  assert.ok(pr.args.includes("--draft"));
  const note = pr.args[pr.args.indexOf("--note-file") + 1];
  assert.match(readFileSync(note, "utf8"), /wall-clock cap was hit/);
});
