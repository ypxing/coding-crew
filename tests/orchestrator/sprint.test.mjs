/**
 * sprint.test.mjs — the state machine end to end, with every model dispatch faked.
 *
 * These are the assertions the deleted prose used to make about itself: a clean issue
 * merges and closes, a failing check never merges, an unmet criteria verdict never
 * merges, a review that did not happen is a gap rather than a clean pass, and two dry
 * rounds stall instead of looping forever.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = join(HERE, "../..");
const MAIN = join(REPO, "orchestrator/main.mjs");
const SCRIPTS = join(REPO, "skills/crew-afk/scripts");
const FAKE = join(HERE, "fixtures/fake-dispatch.sh");

function sh(cmd, args, opts = {}) {
  const r = spawnSync(cmd, args, { encoding: "utf8", ...opts });
  return { code: r.status, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
}

function fixtureRepo() {
  const root = mkdtempSync(join(tmpdir(), "crew-sprint-"));
  const git = (...args) => sh("git", ["-C", root, ...args]);
  git("init", "-q", "-b", "main");
  git("config", "user.email", "t@test");
  git("config", "user.name", "T");
  // A Makefile gives verify-worktree.sh discoverable check commands.
  writeFileSync(
    join(root, "Makefile"),
    "test:\n\t@echo ok\nlint:\n\t@echo ok\ntypecheck:\n\t@echo ok\n",
  );
  writeFileSync(join(root, ".gitignore"), ".scratch/\n");
  git("add", "-A");
  git("commit", "-q", "-m", "init");
  git("checkout", "-q", "-b", "feature/demo");
  mkdirSync(join(root, ".scratch/demo/issues/open"), { recursive: true });
  mkdirSync(join(root, ".scratch/fake"), { recursive: true });
  return root;
}

function addIssue(root, name, { status = "ready-for-agent", body = "", blockedBy = [] } = {}) {
  const slug = name.replace(/\.md$/, "").replace(/^[0-9]+[-_]?/, "");
  const lines = [
    `# ${slug}`,
    "",
    `Status: ${status}`,
    "",
    "## Acceptance criteria",
    "",
    `- [ ] ${slug} exists`,
    "",
  ];
  if (blockedBy.length) lines.push("## Blocked by", "", ...blockedBy.map((b) => `- ${b}`), "");
  if (body) lines.push(body, "");
  writeFileSync(join(root, ".scratch/demo/issues/open", name), lines.join("\n"));
  return slug;
}

function runSprint(root, extra = []) {
  return sh("node", [MAIN, "run", "--platform", "pi", "--feature-slug", "demo", ...extra], {
    cwd: root,
    env: {
      ...process.env,
      CREW_SCRIPTS: SCRIPTS,
      CREW_FAKE_DISPATCH: FAKE,
      CREW_FAKE_DIR: join(root, ".scratch/fake"),
      MAIN_ROOT: root,
    },
  });
}

function state(root) {
  const f = join(root, ".scratch/demo/sprint-state.json");
  return existsSync(f) ? JSON.parse(readFileSync(f, "utf8")) : {};
}

function fake(root, name, content = "") {
  writeFileSync(join(root, ".scratch/fake", name), content);
}

test("plan lists dispatchable issues and changes nothing", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-parked.md", { status: "deferred-findings" });
  addIssue(root, "03-blocked.md", { blockedBy: ["01-alpha.md"] });
  const r = sh("node", [MAIN, "plan", "--platform", "pi"], {
    cwd: root,
    env: { ...process.env, CREW_SCRIPTS: SCRIPTS, CREW_FAKE_DISPATCH: FAKE },
  });
  assert.equal(r.code, 0, r.stderr);
  assert.match(r.stdout, /dispatchable now \(1\):/);
  assert.match(r.stdout, /- alpha/);
  assert.match(r.stdout, /parked fix issues \(1\): parked/);
  assert.doesNotMatch(r.stdout, /- blocked/);
  assert.equal(existsSync(join(root, ".scratch/demo/sprint-state.json")), false);
});

test("a clean issue is verified, reviewed, merged and closed", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const s = state(root);
  assert.deepEqual(s.completed_slugs, ["alpha"]);
  assert.deepEqual(s.merged_branches, ["crew/demo/alpha"]);
  assert.equal(existsSync(join(root, ".scratch/demo/issues/done/01-alpha.md")), true);
  assert.equal(existsSync(join(root, ".scratch/demo/issues/open/01-alpha.md")), false);
  // The gate receipts both exist and the sprint ends cleanly.
  assert.equal(existsSync(join(root, ".scratch/demo/dispatch/alpha.verify.ok")), true);
  assert.equal(existsSync(join(root, ".scratch/demo/dispatch/alpha.ac.ok")), true);
  assert.match(r.stdout, /NO MORE TASKS/);
});

test("a worker-reported failing check is demoted and never merges", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(
    root,
    "alpha.worker",
    ['## Issue: alpha', 'Status: complete', '', '```json', '{"status":"complete","checks":{"test":"fail","lint":"pass","typecheck":"pass"},"progress":"tests red"}', '```'].join("\n"),
  );
  const r = runSprint(root);
  const s = state(root);
  assert.equal(r.code, 2, "a sprint that completes nothing twice is a stall");
  assert.deepEqual(s.completed_slugs ?? [], []);
  assert.deepEqual(s.merged_branches ?? [], []);
  assert.equal(s.retention.alpha.reason, "reported checks failed: test");
  assert.equal(existsSync(join(root, ".scratch/demo/issues/open/01-alpha.md")), true);
  assert.match(readFileSync(join(root, ".scratch/demo/issues/open/01-alpha.md"), "utf8"), /## Progress/);
});

test("an unmet acceptance-criteria verdict retains the branch and closes nothing", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.review", "## Branch: crew/demo/alpha\nAC: unmet — no test covers the criterion\n");
  const r = runSprint(root);
  const s = state(root);
  assert.equal(r.code, 2);
  assert.deepEqual(s.merged_branches ?? [], []);
  assert.match(s.retention.alpha.reason, /criteria-unmet/);
  assert.equal(existsSync(join(root, ".scratch/demo/dispatch/alpha.ac.ok")), false);
  assert.equal(existsSync(join(root, ".scratch/demo/issues/open/01-alpha.md")), true);
});

test("a review that produced nothing is a gap, not a clean pass", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.review", ""); // empty review report
  const r = runSprint(root);
  const s = state(root);
  assert.equal(s.retention.alpha.reason, "review-not-run");
  assert.deepEqual(s.merged_branches ?? [], []);
  assert.match(r.stdout, /Unreviewed Branches|review/i);
});

test("an unparseable worker report is blocked, never complete", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.worker", "All done, everything works great!");
  const r = runSprint(root);
  const s = state(root);
  assert.deepEqual(s.blocked_slugs, ["alpha"]);
  assert.deepEqual(s.merged_branches ?? [], []);
  assert.match(readFileSync(join(root, ".scratch/demo/issues/open/01-alpha.md"), "utf8"), /## Blocked/);
});

test("a dead dispatch is blocked with the worker-failed reason", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.exit", "7");
  const r = runSprint(root);
  const s = state(root);
  assert.deepEqual(s.blocked_slugs, ["alpha"]);
  assert.match(s.retention.alpha.reason, /worker process failed/);
});

test("a blocked-by dependency is not dispatched until its blocker closes", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-beta.md", { blockedBy: ["01-alpha.md"] });
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const s = state(root);
  // alpha closes in round 1, which unblocks beta for round 2 — both merge.
  assert.deepEqual(s.completed_slugs.sort(), ["alpha", "beta"]);
  assert.ok(s.rounds >= 2, `expected at least 2 rounds, got ${s.rounds}`);
});

test("CRITICAL findings are promoted into a Phase 2 fix issue and run again", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(
    root,
    "alpha.review",
    [
      "## Branch: crew/demo/alpha",
      "AC: all-met",
      "FINDING: CRITICAL | src/alpha.txt:1 | Reject unsigned input before use",
      "FINDING: MEDIUM | src/alpha.txt:2 | Rename the variable",
    ].join("\n"),
  );
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const s = state(root);
  assert.ok(s.completed_slugs.includes("alpha"));
  // The promoted fix issue ran as its own issue in Phase 2.
  const fixIssues = s.completed_slugs.filter((x) => x !== "alpha");
  assert.equal(fixIssues.length, 1, `expected one promoted fix issue, got ${JSON.stringify(s.completed_slugs)}`);
  const criteria = join(root, ".scratch/demo/reviews/alpha.criteria.md");
  assert.equal(existsSync(criteria), true);
  const text = readFileSync(criteria, "utf8");
  assert.match(text, /\[CRITICAL\] Reject unsigned input before use \(src\/alpha\.txt:1\)/);
  assert.doesNotMatch(text, /MEDIUM/, "MEDIUM is never promoted");
});

test("two dry rounds stall instead of looping forever", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.worker", '## Issue: alpha\nStatus: partial\n\n```json\n{"status":"partial","progress":"stuck"}\n```');
  const r = runSprint(root);
  assert.equal(r.code, 2, "stall exits 2");
  const s = state(root);
  assert.equal(s.rounds, 2, "one dry round is a retry, two is a stall");
  assert.match(s.retention.alpha.reason, /partial/);
});
