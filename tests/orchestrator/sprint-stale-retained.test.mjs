/**
 * Sprint suite — a retained-branch record whose issue is closed or gone, or whose branch is gone,
 * is dropped at run start (preflight.mjs's dropStaleRetained), so it never counts toward Partial,
 * ## Retained Branches, the stall verdict or the PR's draft reasons. Issue #246.
 */

import assert from "node:assert/strict";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { MAIN, SCRIPTS, FAKE, sh, fixtureRepo, addIssue, runSprint, traceLog, state, githubFixtureRepo, stubGh, GH_ALPHA, test } from "./helpers/sprint.mjs";
import { dropStaleRetained } from "../../orchestrator/lib/preflight.mjs";

const seedState = (root, extra) =>
  writeFileSync(join(root, ".scratch/demo/sprint-state.json"), JSON.stringify({ feature_slug: "demo", ...extra }));

const retainedRecord = (slug, reason) => ({
  retained_branches: { [slug]: `crew/demo/${slug}` },
  retention: { [slug]: { branch: `crew/demo/${slug}`, reason } },
});

const branch = (root, name) => sh("git", ["-C", root, "branch", name]);

// ─── unit: the decision, against a fake tracker and git ──────────────────────

function fakeCtx({ state: st, branches = [], dryRun = false }) {
  const dropped = [];
  const logs = [];
  const ctx = {
    options: { dryRun },
    log: (line) => logs.push(line),
    sprint: {
      featureSlug: "demo",
      readState: () => st,
      dropRetained: (slug, reason, { issueGone = false } = {}) => dropped.push({ slug, reason, issueGone }),
    },
    effects: {
      mainRoot: "/nowhere",
      gitRead: (args) => ({ code: branches.includes(args.at(-1).replace(/^refs\/heads\//, "")) ? 0 : 1, stdout: "", stderr: "" }),
    },
  };
  return { ctx, dropped, logs };
}

const tracker = (issues) => ({ listFeatureIssues: () => issues, isPrdIssue: () => false });
const issue = (slug, status) => ({ slug, status, number: 1, title: slug });

test("dropStaleRetained drops a closed (done) issue's and an absent issue's record, and says why", () => {
  const st = {
    retained_branches: { gamma: "crew/demo/gamma", delta: "crew/demo/delta" },
    retention: { gamma: { branch: "crew/demo/gamma", reason: "verification-failed:fixable" }, delta: { branch: "crew/demo/delta", reason: "partial" } },
  };
  const { ctx, dropped, logs } = fakeCtx({ state: st, branches: ["crew/demo/gamma", "crew/demo/delta"] });
  const out = dropStaleRetained(ctx, tracker([issue("gamma", "done"), issue("alpha", "ready-for-agent")]));
  assert.deepEqual(dropped.map((d) => [d.slug, d.issueGone]).sort(), [["delta", true], ["gamma", true]]);
  assert.match(dropped.find((d) => d.slug === "gamma").reason, /issue closed/);
  assert.match(dropped.find((d) => d.slug === "delta").reason, /no longer in the tracker/);
  assert.deepEqual(out.map((d) => d.slug).sort(), ["delta", "gamma"]);
  assert.ok(logs.some((l) => /^\[RETAINED-DROPPED\] slug=gamma branch=crew\/demo\/gamma — issue closed/.test(l)), logs.join("\n"));
});

test("dropStaleRetained drops an open issue's record whose branch is gone, keeping its blocked entries", () => {
  const st = retainedRecord("gamma", "blocked — tests red");
  const { ctx, dropped } = fakeCtx({ state: st, branches: [] });
  dropStaleRetained(ctx, tracker([issue("gamma", "ready-for-agent")]));
  assert.deepEqual(dropped, [{ slug: "gamma", reason: "branch crew/demo/gamma no longer exists", issueGone: false }]);
});

test("dropStaleRetained keeps an open issue's record whose branch exists, ready or not, blocked or not", () => {
  const st = {
    retained_branches: { a: "crew/demo/a", b: "crew/demo/b", c: "crew/demo/c" },
    retention: {
      a: { branch: "crew/demo/a", reason: "partial" },
      b: { branch: "crew/demo/b", reason: "blocked — tests red" },
      c: { branch: "crew/demo/c", reason: "criteria-unmet" },
    },
  };
  const { ctx, dropped } = fakeCtx({ state: st, branches: ["crew/demo/a", "crew/demo/b", "crew/demo/c"] });
  dropStaleRetained(ctx, tracker([issue("a", "ready-for-agent"), issue("b", "ready-for-agent"), issue("c", "ready-for-human")]));
  assert.deepEqual(dropped, []);
});

test("dropStaleRetained drops nothing when the tracker listing fails or comes back empty", () => {
  const st = retainedRecord("gamma", "partial");
  const failing = { listFeatureIssues: () => { throw new Error("gh issue list failed (exit 1): offline"); }, isPrdIssue: () => false };
  const a = fakeCtx({ state: st, branches: [] });
  assert.deepEqual(dropStaleRetained(a.ctx, failing), []);
  assert.deepEqual(a.dropped, []);
  assert.ok(a.logs.some((l) => /RETAINED: kept every record — could not list the tracker: .*offline/.test(l)), a.logs.join("\n"));

  // An empty listing (a milestone not created, an issues dir gone) cannot tell "every issue is gone"
  // from "nothing was listed": the branch check alone still runs on nothing, so nothing is dropped.
  const b = fakeCtx({ state: st, branches: [] });
  assert.deepEqual(dropStaleRetained(b.ctx, tracker([])), []);
  assert.deepEqual(b.dropped, []);
});

test("dropStaleRetained under --dry-run reports what it would drop and drops nothing", () => {
  const { ctx, dropped, logs } = fakeCtx({ state: retainedRecord("gamma", "partial"), branches: [], dryRun: true });
  dropStaleRetained(ctx, tracker([issue("gamma", "done")]));
  assert.deepEqual(dropped, []);
  assert.ok(logs.some((l) => /would drop slug=gamma/.test(l)), logs.join("\n"));
});

// ─── end to end: local tracker ───────────────────────────────────────────────

test("a retained record whose issue is closed is dropped at start, logged, and the summary lists it nowhere", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  mkdirSync(join(root, ".scratch/demo/issues/done"), { recursive: true });
  writeFileSync(join(root, ".scratch/demo/issues/done/02-gamma.md"), "# gamma\n\nStatus: done\n\n## Acceptance criteria\n\n- [x] gamma exists\n");
  branch(root, "crew/demo/gamma");
  seedState(root, retainedRecord("gamma", "verification-failed:fixable"));
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(traceLog(root), /\[RETAINED-DROPPED\] slug=gamma branch=crew\/demo\/gamma — issue closed/);
  const s = state(root);
  assert.equal(s.retention?.gamma, undefined);
  assert.equal(s.retained_branches?.gamma, undefined);
  assert.match(r.stdout, /^Partial \(0\): none$/m);
  assert.doesNotMatch(r.stdout, /## Retained Branches/);
  assert.doesNotMatch(r.stdout, /STALLED/);
});

test("a retained record whose branch is gone is dropped at start; its open issue then runs fresh", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-gamma.md");
  seedState(root, retainedRecord("gamma", "verification-failed:fixable"));
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const log = traceLog(root);
  assert.match(log, /\[RETAINED-DROPPED\] slug=gamma branch=crew\/demo\/gamma — branch crew\/demo\/gamma no longer exists/);
  assert.doesNotMatch(log, /\[RESUME\] slug=gamma/, "a dropped record is not a resume");
  assert.match(r.stdout, /^Partial \(0\): none$/m);
  assert.doesNotMatch(r.stdout, /## Retained Branches/);
  assert.deepEqual(state(root).completed_slugs.sort(), ["alpha", "gamma"]);
});

test("a retained record whose issue is open and whose branch exists is kept and retried on that branch", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const git = (...a) => sh("git", ["-C", root, ...a]);
  git("checkout", "-q", "-b", "crew/demo/alpha");
  writeFileSync(join(root, "prior.txt"), "earlier attempt\n");
  git("add", "prior.txt");
  git("commit", "-q", "-m", "earlier attempt");
  git("checkout", "-q", "main");
  seedState(root, retainedRecord("alpha", "partial"));
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.doesNotMatch(traceLog(root), /RETAINED-DROPPED/);
  assert.deepEqual(state(root).completed_slugs, ["alpha"]);
  assert.equal(git("show", "feature/demo:prior.txt").stdout, "earlier attempt\n", "the retained branch's work was not retried and merged");
});

// ─── end to end: github tracker, --open-pr ───────────────────────────────────

test("github --open-pr: with only stale records left (one closed, one absent), the run is not stalled and the PR is not a draft", () => {
  const root = githubFixtureRepo();
  const closed = { number: 2, title: "gamma", body: "# gamma\n\n## Acceptance criteria\n\n- [x] gamma exists\n", labels: [{ name: "ready-for-agent" }, { name: "blocked" }], state: "CLOSED" };
  const { stub, log } = stubGh(root, [GH_ALPHA, closed]);
  const remote = join(root, ".scratch/remote.git");
  sh("git", ["init", "-q", "--bare", remote]);
  sh("git", ["-C", root, "remote", "set-url", "origin", remote]);
  mkdirSync(join(root, ".scratch/demo"), { recursive: true });
  branch(root, "crew/demo/gamma");
  branch(root, "crew/demo/delta");
  // gamma: blocked in an earlier run, then shipped elsewhere and closed; delta: its issue left the milestone.
  seedState(root, {
    retained_branches: { gamma: "crew/demo/gamma", delta: "crew/demo/delta" },
    retention: {
      gamma: { branch: "crew/demo/gamma", reason: "blocked — tests red" },
      delta: { branch: "crew/demo/delta", reason: "verification-failed:fixable" },
    },
    blocked_slugs: ["gamma"],
    blocked_reasons: { gamma: "tests red" },
    blocked_labelled: { gamma: 2 },
  });
  const r = sh("node", [MAIN, "run", "--platform", "pi", "--feature-slug", "demo", "--open-pr"], {
    cwd: root,
    env: { ...process.env, CREW_SCRIPTS: SCRIPTS, CREW_FAKE_DISPATCH: FAKE, CREW_FAKE_DIR: join(root, ".scratch/fake"), MAIN_ROOT: root, PATH: `${stub}:${process.env.PATH}` },
  });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const trace = traceLog(root);
  assert.match(trace, /\[RETAINED-DROPPED\] slug=gamma .*— issue closed/);
  assert.match(trace, /\[RETAINED-DROPPED\] slug=delta .*— issue no longer in the tracker/);
  const calls = readFileSync(log, "utf8");
  assert.match(calls, /pr create /);
  assert.doesNotMatch(calls, /pr create --draft/);
  assert.match(r.stdout, /\*\*Ready:\*\* the run finished green\./);
  assert.match(r.stdout, /^Partial \(0\): none$/m);
  assert.match(r.stdout, /^Blocked \(0\): none$/m);
  assert.doesNotMatch(r.stdout, /## Retained Branches/);
  assert.doesNotMatch(r.stdout, /STALLED/);
  assert.doesNotMatch(r.stdout, /gh issue edit 2 --remove-label blocked/);
});
