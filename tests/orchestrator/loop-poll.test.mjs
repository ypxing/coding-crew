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
