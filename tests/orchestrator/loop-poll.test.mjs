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
    listFeatureIssues: () => [],
    isPrdIssue: () => false,
    fixIssuesCreatedReady: false,
  };
  const attempts = new Map();
  const blocked = new Set();
  const sprint = {
    featureSlug: "demo",
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

test("wall-clock cap elapsing after the last issue is done is not a cap hit", async () => {
  // Nothing unclaimed and nothing parked: the cap cut nothing short, so the run is green.
  const h = harness({ pollInterval: 0, parallel: 1 });
  let t = 0;
  h.ctx.now = () => t;
  h.ctx.options.maxWallMinutes = 10;
  const out = [];
  h.ctx.out = (s) => out.push(s);
  const run = runSprint(h.ctx);
  await settle();
  t = 10 * 60_000;
  h.gates.get("a")();
  const result = await run;
  assert.equal(result.stalled, false);
  assert.doesNotMatch(out.join("\n"), /Wall-clock cap/);
});

test("past the cap the poller lists the tracker no more", async () => {
  const h = harness({ pollInterval: 5, parallel: 2 });
  let t = 0;
  h.ctx.now = () => t;
  h.ctx.options.maxWallMinutes = 10;
  const run = runSprint(h.ctx);
  await settle();
  t = 10 * 60_000;
  const before = h.listings.n;
  for (let i = 0; i < 3 && h.sleeps.length; i++) { h.sleeps.shift()(); await settle(); }
  assert.equal(h.listings.n, before);
  h.gates.get("a")();
  await run;
});

test("a red baseline stops the running dispatches and the poller, and claims nothing more", async () => {
  const h = harness({ pollInterval: 5, parallel: 1 });
  let red;
  h.ctx.baseline = new Promise((r) => (red = r));
  let interrupted = 0;
  h.ctx.effects.interruptDispatches = () => { interrupted++; return 1; };
  const run = runSprint(h.ctx);
  await settle();
  assert.deepEqual(h.started, ["a"]);
  h.ready.push({ slug: "b", number: null });
  red({ status: "fail" });
  await settle();
  assert.equal(interrupted, 1);
  assert.equal(h.ctx.baselineRed, true);
  const before = h.listings.n;
  for (let i = 0; i < 3 && h.sleeps.length; i++) { h.sleeps.shift()(); await settle(); }
  assert.equal(h.listings.n, before);
  h.gates.get("a")();
  await run;
  assert.deepEqual(h.started, ["a"]);
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
  // A parked fix issue exists (flush would promote it), so skipping flush is the cap's doing.
  h.ctx.effects.bash = (name, args, o) => {
    calls.push({ name, args });
    if (name === "promote-findings.sh" && args[0] === "flush") return { code: 0, stdout: "FLUSH: promoted=1", stderr: "" };
    if (name === "promote-findings.sh" && args[0] === "list") return { code: 0, stdout: "deferred: x.md\nDEFERRED: count=1", stderr: "" };
    return bash(name, args, o);
  };
  h.ctx.sprint.get = (k) => (k === "merged" ? "crew/demo/a" : null);
  // Integration check answers from cache (tree already passed): proves it still runs past the cap.
  Object.assign(h.ctx.sprint, { featureBranch: "crew/demo", readState: () => ({ passing_trees: ["T"] }), state: () => {} });
  // The feature review finds no default branch to measure from, and skips.
  h.ctx.effects.gitRead = (args) => (args[0] === "rev-parse" ? { stdout: "T\n", code: 0 } : { stdout: "", code: 1 });
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
  const { mkdtempSync, readFileSync } = await import("node:fs");
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
  h.ctx.effects.gitRead = () => ({ code: 1, stdout: "" }); // no origin: the PR body has no range
  h.ctx.sprint.get = (k) => (k === "merged" ? "crew/demo/a" : null);
  const calls = [];
  const bash = h.ctx.effects.bash;
  h.ctx.effects.bash = (name, args, o) => {
    calls.push({ name, args });
    // A parked fix issue the cap leaves for the next run.
    if (name === "promote-findings.sh" && args[0] === "list") return { code: 0, stdout: "DEFERRED: count=1", stderr: "" };
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

test("--open-pr: an issue blocked with no branch (a failing ## Requires) is listed with its reason", async () => {
  const { mkdtempSync, readFileSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const dir = mkdtempSync(join(tmpdir(), "blocked-note-"));
  const h = harness({ pollInterval: 0, parallel: 1 });
  h.ctx.options.openPr = true;
  Object.assign(h.ctx.sprint, {
    env: { SPRINT_DIR: dir },
    featureBranch: "crew/demo",
    readState: () => ({ blocked_reasons: { req: "requires failed: docker not running" } }),
    getList: (k) => (k === "blocked" ? ["req"] : []),
  });
  h.ctx.effects.gitRead = () => ({ code: 1, stdout: "" });
  h.ctx.sprint.get = (k) => (k === "merged" ? "crew/demo/a" : null);
  const calls = [];
  const bash = h.ctx.effects.bash;
  h.ctx.effects.bash = (name, args, o) => {
    calls.push({ name, args });
    return name === "open-pr.sh" ? { code: 0, stdout: "PR: http://x/1\n", stderr: "" } : bash(name, args, o);
  };
  const run = runSprint(h.ctx);
  await settle();
  h.gates.get("a")();
  await run;
  const pr = calls.find((c) => c.name === "open-pr.sh");
  const note = pr.args[pr.args.indexOf("--note-file") + 1];
  assert.match(readFileSync(note, "utf8"), /- req — requires failed: docker not running/);
});

test("a poll whose tracker listing throws is logged as a warning and the next interval polls again", async () => {
  const h = harness({ pollInterval: 5 });
  const logs = [];
  h.ctx.log = (m, level) => logs.push({ m: String(m), level });
  const list = h.ctx.tracker.selectDispatchable;
  let failNext = false;
  h.ctx.tracker.selectDispatchable = (...a) => {
    if (failNext) { failNext = false; throw new Error('gh issue list failed (exit 1): Post "https://api.github.com/graphql": EOF'); }
    return list(...a);
  };
  const run = runSprint(h.ctx);
  await settle();
  failNext = true;
  h.sleeps.shift()();
  await settle();
  assert.ok(logs.some((l) => l.level === "warn" && l.m.includes("graphql\": EOF")), JSON.stringify(logs));
  h.ready.push({ slug: "b", number: null });
  h.sleeps.shift()();
  await settle();
  assert.deepEqual(h.started, ["a", "b"]);
  h.gates.get("a")(); h.gates.get("b")();
  await run;
});

test("a poll whose mid-run lint throws re-lints those issues on the next poll and never dispatches them unlinted", async () => {
  const h = harness({ pollInterval: 5, lintBlocks: ["bad"] });
  const logs = [];
  h.ctx.log = (m, level) => logs.push({ m: String(m), level });
  const lint = h.ctx.stages.lintMidRunIssues;
  let failNext = true;
  h.ctx.stages.lintMidRunIssues = async (c, issues) => {
    if (failNext) { failNext = false; throw new Error('gh issue comment failed (exit 1): EOF'); }
    return lint(c, issues);
  };
  const run = runSprint(h.ctx);
  await settle();
  h.ready.push({ slug: "bad", number: null });
  h.sleeps.shift()();
  await settle();
  assert.ok(logs.some((l) => l.level === "warn" && l.m.includes("EOF")), JSON.stringify(logs));
  assert.deepEqual(h.started, ["a"]);
  h.sleeps.shift()();
  await settle();
  assert.deepEqual(h.linted, ["bad"]);
  assert.ok(h.blocked.has("bad"));
  h.gates.get("a")();
  await run;
  assert.deepEqual(h.started, ["a"]);
});

const EOF_ERROR = 'gh issue list failed (exit 1): Post "https://api.github.com/graphql": EOF';

/** --open-pr against stub effects: every bash call is recorded, open-pr.sh answers with a URL. */
async function withOpenPr(h) {
  const { mkdtempSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  h.ctx.options.openPr = true;
  Object.assign(h.ctx.sprint, {
    env: { SPRINT_DIR: mkdtempSync(join(tmpdir(), "list-failed-")) },
    featureBranch: "crew/demo",
    readState: () => ({}),
    getList: () => [],
  });
  h.ctx.effects.gitRead = () => ({ code: 1, stdout: "" });
  h.ctx.sprint.get = (k) => (k === "merged" ? "crew/demo/a" : null);
  const calls = [];
  const bash = h.ctx.effects.bash;
  h.ctx.effects.bash = (name, args, o) => {
    calls.push({ name, args });
    return name === "open-pr.sh" ? { code: 0, stdout: "PR: http://x/1\n", stderr: "" } : bash(name, args, o);
  };
  return calls;
}

const argAfter = (call, flag) => call?.args[call.args.indexOf(flag) + 1];

test("a claim listing that fails with nothing in flight stalls the run at once, names the failure, and no worker lists again", async () => {
  const { readFileSync } = await import("node:fs");
  const h = harness({ pollInterval: 0, parallel: 2 });
  const calls = await withOpenPr(h);
  const list = h.ctx.tracker.selectDispatchable;
  let failures = 0;
  h.ctx.tracker.selectDispatchable = (...a) => {
    if (h.done.has("a")) { failures++; throw new Error(EOF_ERROR); }
    return list(...a);
  };
  const run = runSprint(h.ctx);
  await settle();
  h.gates.get("a")();
  const result = await run;
  assert.equal(result.stalled, true);
  assert.equal(failures, 1);
  const summary = calls.find((c) => c.name === "crew-summary.sh");
  assert.ok(summary.args.includes("--stalled"));
  assert.match(argAfter(summary, "--stall-reason"), /listing the tracker failed.*EOF/);
  const pr = calls.find((c) => c.name === "open-pr.sh");
  const note = readFileSync(argAfter(pr, "--note-file"), "utf8");
  assert.match(note, /listing the tracker failed.*EOF/);
  assert.match(note, /<!-- crew-afk:draft stalled -->/);
});

test("a claim listing that fails while a sibling is in flight claims nothing; the next wake lists again and the sprint completes", async () => {
  const h = harness({ pollInterval: 0, parallel: 2, initial: ["a", "b"] });
  const logs = [];
  h.ctx.log = (m, level) => logs.push({ m: String(m), level });
  const list = h.ctx.tracker.selectDispatchable;
  let failNext = false;
  h.ctx.tracker.selectDispatchable = (...a) => {
    if (failNext) { failNext = false; throw new Error(EOF_ERROR); }
    return list(...a);
  };
  const run = runSprint(h.ctx);
  await settle();
  assert.deepEqual(h.started, ["a", "b"]);
  failNext = true;
  h.gates.get("a")();
  await settle();
  assert.ok(logs.some((l) => l.level === "warn" && /\[CLAIM-LIST-FAILED\].*EOF/.test(l.m)), JSON.stringify(logs));
  h.ready.push({ slug: "c", number: null });
  h.gates.get("b")();
  await settle();
  assert.deepEqual(h.started, ["a", "b", "c"]);
  h.gates.get("c")();
  const result = await run;
  assert.equal(result.stalled, false);
});

/** Runs a one-issue sprint whose tracker throws where `arm` says; returns the result, bash calls and output. */
async function stalledRun(h, arm) {
  const calls = [];
  const out = [];
  h.ctx.out = (s) => out.push(s);
  const bash = h.ctx.effects.bash;
  h.ctx.effects.bash = (name, args, o) => { calls.push({ name, args }); return bash(name, args, o); };
  arm();
  const run = runSprint(h.ctx);
  await settle();
  h.gates.get("a")();
  const result = await run;
  const summary = calls.find((c) => c.name === "crew-summary.sh");
  return { result, calls, out: out.join("\n"), reason: argAfter(summary, "--stall-reason") };
}

test("a failed listing in cappedByMaxRounds stalls the run naming it", async () => {
  const h = harness({ pollInterval: 0, parallel: 1 });
  h.ctx.options.maxRounds = 3;
  const list = h.ctx.tracker.selectDispatchable;
  // Listing 1 is the run-start seenNow, 2 and 3 the claims (a, then nothing); 4 is the drain's round-cap check.
  const { result, reason } = await stalledRun(h, () => {
    h.ctx.tracker.selectDispatchable = (...a) => {
      if (h.listings.n >= 3) throw new Error(EOF_ERROR);
      return list(...a);
    };
  });
  assert.equal(result.stalled, true);
  assert.equal(result.capped, false);
  assert.match(reason, /listing the tracker failed.*EOF/);
});

test("a failed listing in unclaimedByCap stalls the run naming it", async () => {
  const h = harness({ pollInterval: 0, parallel: 1 });
  let t = 0;
  h.ctx.now = () => t;
  h.ctx.options.maxWallMinutes = 10;
  const list = h.ctx.tracker.selectDispatchable;
  const { result, reason } = await stalledRun(h, () => {
    h.ctx.tracker.selectDispatchable = (...a) => {
      if (t) throw new Error(EOF_ERROR);
      return list(...a);
    };
    h.ctx.stages.runHousekeeping = async (_c, w) => { t = 10 * 60_000; h.done.add(w.issue.slug); return { status: "complete" }; };
  });
  assert.equal(result.stalled, true);
  assert.match(reason, /listing the tracker failed.*EOF/);
});

test("a failed openIssues listing stalls the run naming it instead of ending green", async () => {
  const h = harness({ pollInterval: 0, parallel: 1 });
  const { result, reason } = await stalledRun(h, () => {
    h.ctx.tracker.listFeatureIssues = () => { throw new Error(EOF_ERROR); };
  });
  assert.equal(result.stalled, true);
  assert.match(reason, /listing the tracker failed.*EOF/);
});

test("a failed listing while awaiting a fix issue ends the wait: the ref is named unlisted and the run stalls naming it", async () => {
  const h = harness({ pollInterval: 0, parallel: 1 });
  h.ctx.tracker.fixIssuesCreatedReady = true;
  h.ctx.sprint.get = (k) => (k === "merged" ? "crew/demo/a" : null);
  h.ctx.sprint.state = () => {};
  h.ctx.effects.gitRead = () => ({ code: 1, stdout: "" });
  const reviews = [];
  h.ctx.stages.runFeatureReview = async (_c, opts) => {
    reviews.push(opts);
    return { report: "r.md", findings: [], promoted: 1, promotedRef: 7 };
  };
  const { result, reason, out } = await stalledRun(h, () => {
    h.ctx.tracker.listFeatureIssues = () => { throw new Error(EOF_ERROR); };
  });
  assert.equal(result.stalled, true);
  assert.match(reason, /listing the tracker failed.*EOF/);
  assert.match(out, /#7 \(review findings\) was created but never appeared in the milestone listing/);
  assert.equal(reviews.length, 1, "no closing review after a failed listing");
});

test("a failed seenNow listing is a warning: the run continues and dispatches the remaining issues", async () => {
  const h = harness({ pollInterval: 5, parallel: 2, initial: ["a", "b"] });
  const logs = [];
  h.ctx.log = (m, level) => logs.push({ m: String(m), level });
  const list = h.ctx.tracker.selectDispatchable;
  h.ctx.tracker.selectDispatchable = (...a) => {
    if (h.listings.n === 0) { h.listings.n++; throw new Error(EOF_ERROR); }
    return list(...a);
  };
  const run = runSprint(h.ctx);
  await settle();
  assert.deepEqual(h.started, ["a", "b"]);
  assert.ok(logs.some((l) => l.level === "warn" && /\[SEEN-LIST-FAILED\].*EOF/.test(l.m)), JSON.stringify(logs));
  h.gates.get("a")(); h.gates.get("b")();
  const result = await run;
  assert.equal(result.stalled, false);
});

test("a run that stalls on a failed listing still releases the in-progress labels it holds", async () => {
  const h = harness({ pollInterval: 0, parallel: 1 });
  h.ready[0].number = 41;
  h.ctx.stages.runHousekeeping = async () => ({ status: "partial" });
  const list = h.ctx.tracker.selectDispatchable;
  const { result, calls } = await stalledRun(h, () => {
    h.ctx.tracker.selectDispatchable = (...a) => {
      if (h.started.length) throw new Error(EOF_ERROR);
      return list(...a);
    };
  });
  assert.equal(result.stalled, true);
  const labels = calls.filter((c) => c.name === "issue-labels.sh").map((c) => c.args.join(" "));
  assert.deepEqual(labels, ["claim 41", "release 41"]);
});

for (const pollInterval of [5, 0]) {
  test(`--poll-interval ${pollInterval}: an issue made ready mid-run and claimed when a worker finishes is linted first; a lint ERROR blocks it`, async () => {
    const h = harness({ pollInterval, parallel: 1, lintBlocks: ["bad"] });
    const run = runSprint(h.ctx);
    await settle();
    h.ready.push({ slug: "bad", number: null }, { slug: "good", number: null });
    h.gates.get("a")();
    await settle();
    assert.deepEqual(h.linted, ["bad", "good"]);
    assert.ok(h.blocked.has("bad"));
    assert.deepEqual(h.started, ["a", "good"]);
    h.gates.get("good")();
    await run;
    assert.deepEqual(h.started, ["a", "good"]);
  });
}

/** Runs `order` to completion, one release per settle; returns the run's result. */
async function runInOrder(h, order) {
  const run = runSprint(h.ctx);
  for (const slug of order) {
    await settle();
    h.gates.get(slug)();
  }
  return run;
}

test("--poll-interval 0: issues listed at run start and a fix issue Phase 2 promotes are claimed without a lint", async () => {
  const h = harness({ pollInterval: 0, parallel: 1, initial: ["a", "b"] });
  let flushed = false;
  const bash = h.ctx.effects.bash;
  h.ctx.effects.bash = (name, args, o) => {
    if (name === "promote-findings.sh" && args[0] === "flush" && !flushed) {
      flushed = true;
      h.ready.push({ slug: "parked-fix", number: null, path: "/m/.scratch/demo/issues/open/03-parked-fix.md" });
      return { code: 0, stdout: "flushed: .scratch/demo/issues/open/03-parked-fix.md\nFLUSH: promoted=1", stderr: "" };
    }
    return bash(name, args, o);
  };
  await runInOrder(h, ["a", "b", "parked-fix"]);
  assert.deepEqual(h.started, ["a", "b", "parked-fix"]);
  assert.deepEqual(h.linted, []);
});

test("--poll-interval 0: a github fix issue the feature review created ready is claimed without a lint", async () => {
  const h = harness({ pollInterval: 0, parallel: 1 });
  h.ctx.tracker.fixIssuesCreatedReady = true;
  h.ctx.tracker.listFeatureIssues = () => h.ready;
  h.ctx.sprint.get = (k) => (k === "merged" ? "crew/demo/a" : null);
  h.ctx.sprint.state = () => {};
  h.ctx.effects.gitRead = () => ({ code: 1, stdout: "" });
  h.ctx.stages.runFeatureReview = async (_c, { promote }) => {
    if (!promote) return { skipped: true };
    h.ready.push({ slug: "review-fix", number: 7 });
    return { report: "r.md", findings: [], promoted: 1, promotedRef: 7 };
  };
  await runInOrder(h, ["a", "review-fix"]);
  assert.deepEqual(h.started, ["a", "review-fix"]);
  assert.deepEqual(h.linted, []);
});

test("a claim-time lint that throws with a sibling in flight claims nothing; the issue stays unseen and the next claim lints it", async () => {
  const h = harness({ pollInterval: 0, parallel: 2, initial: ["a", "c"] });
  const lint = h.ctx.stages.lintMidRunIssues;
  let tries = 0;
  h.ctx.stages.lintMidRunIssues = async (c, issues) => {
    if (tries++ === 0) throw new Error("gh issue comment failed (exit 1): EOF");
    return lint(c, issues);
  };
  const run = runSprint(h.ctx);
  await settle();
  h.ready.push({ slug: "b", number: null });
  h.gates.get("a")();
  await settle();
  assert.deepEqual(h.started, ["a", "c"]);
  h.gates.get("c")();
  await settle();
  assert.equal(tries, 2);
  assert.deepEqual(h.linted, ["b"]);
  assert.deepEqual(h.started, ["a", "c", "b"]);
  h.gates.get("b")();
  const result = await run;
  assert.equal(result.stalled, false);
});

test("a claim-time lint that throws with nothing in flight claims nothing and resolves the run stalled naming the lint failure", async () => {
  const h = harness({ pollInterval: 0, parallel: 1 });
  h.ctx.stages.lintMidRunIssues = async () => { throw new Error("gh issue comment failed (exit 1): EOF"); };
  const { result, reason } = await stalledRun(h, () => {
    h.ctx.stages.runHousekeeping = async (_c, w) => {
      h.done.add(w.issue.slug);
      h.ready.push({ slug: "b", number: null });
      return { status: "complete" };
    };
  });
  assert.deepEqual(h.started, ["a"]);
  assert.equal(result.stalled, true);
  assert.match(result.stallReason, /linting a mid-run issue failed.*EOF/);
  assert.match(reason, /linting a mid-run issue failed.*EOF/);
});

test("a mid-run lint that blocks one issue then throws does not lint (or block) that issue a second time", async () => {
  const h = harness({ pollInterval: 5 });
  const calls = [];
  h.ctx.stages.lintMidRunIssues = async (_c, issues) => {
    calls.push(issues.map((i) => i.slug));
    if (calls.length === 1) {
      h.blocked.add("bad1");
      throw new Error("gh issue comment failed (exit 1): EOF");
    }
    return [];
  };
  const run = runSprint(h.ctx);
  await settle();
  h.ready.push({ slug: "bad1", number: null }, { slug: "bad2", number: null });
  h.sleeps.shift()();
  await settle();
  h.sleeps.shift()();
  await settle();
  assert.deepEqual(calls, [["bad1", "bad2"], ["bad2"]]);
  h.gates.get("a")();
  await settle();
  h.gates.get("bad2")?.();
  await run;
});

test("after a flush, an issue a human readied during the drain is linted; the flushed fix issue is not", async () => {
  const h = harness({ pollInterval: 0, parallel: 1, lintBlocks: ["bad"] });
  let flushes = 0;
  const bash = h.ctx.effects.bash;
  h.ctx.effects.bash = (name, args, o) => {
    if (name === "promote-findings.sh" && args[0] === "flush" && ++flushes === 1) {
      h.ready.push({ slug: "fix", number: null, path: "/m/.scratch/demo/issues/open/09-fix.md" }, { slug: "bad", number: null });
      return { code: 0, stdout: "flushed: .scratch/demo/issues/open/09-fix.md\nFLUSH: promoted=1", stderr: "" };
    }
    return bash(name, args, o);
  };
  const run = runSprint(h.ctx);
  await settle();
  h.gates.get("a")();
  await settle();
  assert.deepEqual(h.linted, ["bad"]);
  assert.ok(h.blocked.has("bad"));
  assert.deepEqual(h.started, ["a", "fix"]);
  h.gates.get("fix")();
  await run;
});

test("a red drain's 'Not run' feature-review entry survives a later drain whose unclaimedByCap listing fails", async () => {
  const h = harness({ pollInterval: 0, parallel: 1 });
  let t = 0;
  h.ctx.now = () => t;
  h.ctx.options.maxWallMinutes = 10;
  h.ctx.options.integrationCheck = true;
  h.ctx.sprint.get = (k) => (k === "merged" ? "crew/demo/a" : null);
  h.ctx.sprint.state = () => {};
  let checks = 0;
  h.ctx.stages.runIntegrationCheck = () =>
    ++checks === 1 ? { status: "fail", commit: "a".repeat(40), failed: [], reason: "red" } : { status: "pass", commit: "b".repeat(40), failed: [] };
  h.ctx.stages.fixIntegration = async () => ({ verdict: "not-fixable", reason: "stub", commit: "a".repeat(40) });
  h.ctx.stages.runFeatureReview = async (_c, { integration }) =>
    integration?.status === "fail" ? { skipped: "the integration check is red" } : { report: "r.md", findings: [] };
  let flushes = 0;
  const bash = h.ctx.effects.bash;
  h.ctx.effects.bash = (name, args, o) => {
    if (name === "promote-findings.sh" && args[0] === "flush" && ++flushes === 1) {
      h.ready.push({ slug: "fix", number: null, path: "/m/.scratch/demo/issues/open/09-fix.md" });
      return { code: 0, stdout: "flushed: .scratch/demo/issues/open/09-fix.md\nFLUSH: promoted=1", stderr: "" };
    }
    return bash(name, args, o);
  };
  const list = h.ctx.tracker.selectDispatchable;
  h.ctx.tracker.selectDispatchable = (...a) => {
    if (t) throw new Error(EOF_ERROR);
    return list(...a);
  };
  const out = [];
  h.ctx.out = (s) => out.push(s);
  const run = runSprint(h.ctx);
  await settle();
  h.gates.get("a")();
  await settle();
  t = 10 * 60_000;
  h.gates.get("fix")();
  const result = await run;
  assert.equal(result.stalled, true);
  assert.match(out.join("\n"), /## Feature Review/);
});
