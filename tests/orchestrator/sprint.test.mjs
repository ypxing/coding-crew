/**
 * sprint.test.mjs — the state machine end to end, with every model dispatch faked.
 *
 * These are the assertions the deleted prose used to make about itself: a clean issue
 * merges and closes, a failing check never merges, an unmet criteria verdict never
 * merges, a review that did not happen is a gap rather than a clean pass, and two dry
 * rounds stall instead of looping forever.
 */

import { test, after } from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { chmodSync, cpSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync, existsSync, unlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { Sprint } from "../../orchestrator/lib/sprint.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = join(HERE, "../..");
const MAIN = join(REPO, "orchestrator/main.mjs");

// Mirrors what install.sh actually produces for a real crew-afk install: its own
// skills/crew-afk/scripts/ merged with the shared scripts its registry.json entry declares
// (feature-branch-setup.sh, discover-commands.sh, write-commands-cache.sh), whose canonical
// source is scripts/skill-utils/git-workflow/, not skills/crew-afk/scripts/ — see that
// directory's README. Computed once here rather than duplicating those files by hand, which
// is exactly the drift the skill-utils mechanism exists to avoid.
//
// Nested three levels under REPO (.scratch/<random>/scripts), the same depth as the real
// skills/crew-afk/scripts/ — ensure-deps.sh's own _script_roots() walks up exactly that many
// parents to find a sibling dep-install install, so a flat os.tmpdir() location (any other
// depth) makes it search the wrong ancestry and report DEPS: none for every fixture.
mkdirSync(join(REPO, ".scratch"), { recursive: true });
const SCRIPTS_BASE = mkdtempSync(join(REPO, ".scratch", "test-scripts-"));
const SCRIPTS = join(SCRIPTS_BASE, "scripts");
mkdirSync(SCRIPTS);
cpSync(join(REPO, "skills/crew-afk/scripts"), SCRIPTS, { recursive: true });
for (const f of ["feature-branch-setup.sh", "discover-commands.sh", "write-commands-cache.sh"]) {
  cpSync(join(REPO, "scripts/skill-utils/git-workflow", f), join(SCRIPTS, f));
}
after(() => rmSync(SCRIPTS_BASE, { recursive: true, force: true }));
const FAKE = join(HERE, "fixtures/fake-dispatch.sh");

// Every call site below spreads process.env into its own `env` (or omits `env` and gets
// it by default); this test's own process inherits CREW_PANE_HOST, HERDR_ENV/HERDR_PANE_ID (or
// ORCA_ENV/ORCA_TERMINAL_HANDLE) whenever it runs inside a real herdr/orca pane, and
// main.mjs's notifyTriggeringPane sends the fixture sprint's outcome straight to that real
// pane if those leak through — stripped here, once, so no call site has to remember to.
//
// HOME likewise: a real ~/.coding-crew/config.json would retarget every fixture sprint's roles,
// so an inherited HOME is swapped for an empty one. A test that sets its own HOME keeps it.
const EMPTY_HOME = mkdtempSync(join(tmpdir(), "crew-sprint-home-"));
after(() => rmSync(EMPTY_HOME, { recursive: true, force: true }));
function sh(cmd, args, opts = {}) {
  const env = { ...(opts.env ?? process.env) };
  if (env.HOME === process.env.HOME) env.HOME = EMPTY_HOME;
  delete env.CREW_PANE_HOST;
  delete env.HERDR_ENV;
  delete env.HERDR_PANE_ID;
  delete env.ORCA_ENV;
  delete env.ORCA_TERMINAL_HANDLE;
  const r = spawnSync(cmd, args, { encoding: "utf8", ...opts, env });
  return { code: r.status, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
}

// Every fixture repo, removed after the file: ~130 per run otherwise fill /tmp's inodes.
const FIXTURE_ROOTS = [];
after(() => FIXTURE_ROOTS.forEach((d) => rmSync(d, { recursive: true, force: true })));

function fixtureRepo() {
  const root = mkdtempSync(join(tmpdir(), "crew-sprint-"));
  FIXTURE_ROOTS.push(root);
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

function runSprint(root, extra = [], env = {}) {
  return sh("node", [MAIN, "run", "--platform", "pi", "--feature-slug", "demo", ...extra], {
    cwd: root,
    env: {
      ...process.env,
      CREW_SCRIPTS: SCRIPTS,
      CREW_FAKE_DISPATCH: FAKE,
      CREW_FAKE_DIR: join(root, ".scratch/fake"),
      MAIN_ROOT: root,
      ...env,
    },
  });
}

function traceLog(root) {
  const f = join(root, ".scratch/demo/traces/orchestrator.log");
  return existsSync(f) ? readFileSync(f, "utf8") : "";
}

/** Line index of the first occurrence of a marker in the trace log. */
function markerAt(log, marker) {
  const lines = log.split("\n");
  const i = lines.findIndex((l) => l.includes(`[${marker}]`));
  assert.notEqual(i, -1, `no [${marker}] line in the trace log:\n${log}`);
  return i;
}

function reviewReports(root) {
  const dir = join(root, ".scratch/demo/reviews");
  return existsSync(dir) ? readdirSync(dir).filter((f) => f.startsWith("sprint-review-")) : [];
}

function state(root) {
  const f = join(root, ".scratch/demo/sprint-state.json");
  return existsSync(f) ? JSON.parse(readFileSync(f, "utf8")) : {};
}

function fake(root, name, content = "") {
  writeFileSync(join(root, ".scratch/fake", name), content);
}

// ─── private script copies, for tests that must make one specific script fail once ──
//
// The global SCRIPTS dir above is shared by every test in this file, so patching a
// script in place would leak into every other test that runs after it. These tests
// need merge-branches.sh / close-issue.sh to fail exactly once and then behave exactly
// as the real script does — the retry itself (already-merged short-circuit, receipt
// re-checks) is that script's own job, not the pipeline's, so the real script still
// has to run on the second call. A private copy of SCRIPTS, patched only there, keeps
// that fault contained to the one test that injected it.
const PRIVATE_SCRIPT_DIRS = [];
after(() => PRIVATE_SCRIPT_DIRS.forEach((d) => rmSync(d, { recursive: true, force: true })));

function privateScripts() {
  const base = mkdtempSync(join(REPO, ".scratch", "test-scripts-"));
  PRIVATE_SCRIPT_DIRS.push(base);
  const dir = join(base, "scripts");
  cpSync(SCRIPTS, dir, { recursive: true });
  return dir;
}

/**
 * Replaces <scriptName> inside <scriptsDir> with a shim that fails once — the first
 * time it is invoked, it writes <marker> and exits 1 with <message> on stderr, without
 * touching anything else the real script would have touched. Every call after that
 * delegates to the untouched original, copied alongside it under the same directory so
 * its own sibling-script lookups (receipts.sh, trace.sh, ...) still resolve.
 */
function failFirstCall(scriptsDir, scriptName, marker, message) {
  const real = join(scriptsDir, `_real-${scriptName}`);
  cpSync(join(scriptsDir, scriptName), real);
  const lines = [
    "#!/usr/bin/env bash",
    "set -uo pipefail",
    `MARKER=${JSON.stringify(marker)}`,
    'if [ ! -f "$MARKER" ]; then',
    '  mkdir -p "$(dirname "$MARKER")"',
    '  touch "$MARKER"',
    `  echo ${JSON.stringify(message)} >&2`,
    "  exit 1",
    "fi",
    `exec bash ${JSON.stringify(real)} "$@"`,
    "",
  ];
  writeFileSync(join(scriptsDir, scriptName), lines.join("\n"));
}

// Spawned directly, not through sh(): sh() strips both vars, which is exactly what this
// test needs set. `plan`, so no orca is ever called.
test("HERDR_ENV and ORCA_ENV both set: orca, with a notice", () => {
  const root = fixtureRepo();
  const env = { ...process.env, HOME: EMPTY_HOME, HERDR_ENV: "1", ORCA_ENV: "1", HERDR_PANE_ID: "", ORCA_TERMINAL_HANDLE: "", CREW_SCRIPTS: SCRIPTS, CREW_FAKE_DISPATCH: FAKE };
  delete env.CREW_PANE_HOST;
  const r = spawnSync("node", [MAIN, "plan", "--platform", "pi", "--feature-slug", "demo"], { cwd: root, encoding: "utf8", env });
  assert.match(r.stderr, /ORCA_ENV=1 and HERDR_ENV=1 are both set — using orca/);
  assert.match(r.stdout, /pane host: orca {2}\[ORCA_ENV\]/);
});

test("run names the resolved pane host before anything else it does", () => {
  const root = fixtureRepo();
  const r = sh("node", [MAIN, "run", "--dry-run", "--platform", "pi", "--feature-slug", "demo"], {
    cwd: root,
    env: { ...process.env, CREW_SCRIPTS: SCRIPTS, CREW_FAKE_DISPATCH: FAKE },
  });
  assert.match(r.stderr, /^PANE-HOST: none$/m);
});

// A repo can hold installs for several platforms, but only its own has pi's or codex's
// dispatcher. The first install found used to win whatever --platform said, so a codex
// sprint in a repo also installed for pi ran .pi/…/dispatch-codex-agent.sh, which isn't there.
test("the running platform's own install supplies the scripts dir, not whichever is found first", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const dirs = { pi: ".pi/skills", codex: ".agents/skills", claude: ".claude/skills", copilot: ".github/skills" };
  for (const d of Object.values(dirs)) cpSync(SCRIPTS, join(root, d, "crew-afk/scripts"), { recursive: true });
  const home = mkdtempSync(join(tmpdir(), "crew-home-"));
  for (const [platform, d] of Object.entries(dirs)) {
    const r = sh("node", [MAIN, "plan", "--platform", platform], { cwd: root, env: { ...process.env, HOME: home, CREW_SCRIPTS: "" } });
    assert.equal(r.code, 0, r.stderr);
    assert.match(r.stdout, new RegExp(`^scripts: +${join(root, d, "crew-afk/scripts").replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}$`, "m"), platform);
  }
});

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
  assert.equal(existsSync(join(root, ".scratch/demo/dispatch/01-alpha.verify.json")), true);
  assert.equal(existsSync(join(root, ".scratch/demo/dispatch/alpha.ac.ok")), true);
  assert.match(r.stdout, /NO MORE TASKS/);
  // The reviewer was handed the verification result, so a criterion that ends "and the
  // tests pass" is answerable by the read-only reviewer instead of stalling the branch.
  const reviewPromptText = readFileSync(join(root, ".scratch/demo/dispatch/01-alpha.review-prompt.md"), "utf8");
  assert.match(reviewPromptText, /Checks already run by the pipeline/);
  assert.match(reviewPromptText, /test=pass/);
});

test("every cached check is run by the gate, whatever the worker reported, and stated to the reviewer with its log", () => {
  const root = fixtureRepo();
  mkdirSync(join(root, ".coding-crew"), { recursive: true });
  writeFileSync(
    join(root, ".coding-crew/dev-commands.json"),
    JSON.stringify({ test: "make test", lint: "make lint", typecheck: "make typecheck", coverage: "echo Branches: 82.35%", integration: null }),
  );
  sh("git", ["-C", root, "add", "-A"]);
  sh("git", ["-C", root, "commit", "-q", "-m", "cache"]);
  // The fake discovery's default answer nulls coverage/integration; answer as the cache does.
  fake(root, "commands.response", '{"install": null, "env": null, "credential_target": null}');
  addIssue(root, "01-alpha.md");
  fake(
    root,
    "alpha.worker",
    ['## Issue: alpha', 'Status: complete', '', '```json', '{"status":"complete","checks":{"test":"pass","lint":"pass","typecheck":"pass"},"progress":""}', '```'].join("\n"),
  );
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const reviewPromptText = readFileSync(join(root, ".scratch/demo/dispatch/01-alpha.review-prompt.md"), "utf8");
  assert.match(reviewPromptText, /coverage=pass \(full output: [^)]*verify-coverage\.log\)/);
  // The worker never mentioned coverage; the gate ran it from the cache anyway. integration is
  // `null` there, and the reviewer is told so rather than left to infer it from what is absent.
  assert.doesNotMatch(reviewPromptText, /integration=/);
  assert.match(reviewPromptText, /Not run by the pipeline, no command configured: integration/);
  assert.match(reviewPromptText, /The gate's own record of that run: \S+\/01-alpha\.verify\.json/);
  // The logs live beside the record, so they outlive the worktree.
  assert.match(reviewPromptText, /coverage=pass \(full output: \S+\/dispatch\/01-alpha\.verify-coverage\.log\)/);
  assert.equal(existsSync(join(root, ".scratch/demo/dispatch/01-alpha.verify-coverage.log")), true);
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
  assert.equal(r.code, 2, "the issue spends both its retry attempts and stays blocked");
  assert.deepEqual(s.completed_slugs ?? [], []);
  assert.deepEqual(s.merged_branches ?? [], []);
  assert.equal(s.retention.alpha.reason, "blocked — retry limit reached (2 attempts) — reported checks failed: test");
  assert.equal(existsSync(join(root, ".scratch/demo/issues/open/01-alpha.md")), true);
  assert.match(readFileSync(join(root, ".scratch/demo/issues/open/01-alpha.md"), "utf8"), /## Progress/);
});

test("a worker-reported partial carries its own unmet criteria into the Progress section", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(
    root,
    "alpha.worker",
    [
      '## Issue: alpha',
      'Status: partial',
      '',
      '```json',
      '{"status":"partial","checks":{"test":"pass","lint":"pass","typecheck":"pass"},"criteria":[{"text":"docs updated","met":false},{"text":"resolver implemented","met":true}],"progress":"Remaining work: docs"}',
      '```',
    ].join("\n"),
  );
  const r = runSprint(root);
  const s = state(root);
  assert.equal(r.code, 2, "the issue spends both its retry attempts and stays blocked");
  assert.equal(s.retention.alpha.reason, "blocked — retry limit reached (2 attempts) — partial");
  const issueText = readFileSync(join(root, ".scratch/demo/issues/open/01-alpha.md"), "utf8");
  // The next round's resume must not depend on the coder's own prose having named every
  // gap — the structured criteria array from its report is carried forward verbatim.
  assert.match(issueText, /Unmet criteria \(from the worker's own report\):\n- docs updated/);
  assert.doesNotMatch(issueText, /- resolver implemented/);
});

test("an unmet acceptance-criteria verdict retains the branch and closes nothing", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(
    root,
    "alpha.review",
    `## Branch: crew/demo/alpha\n\`\`\`json\n${JSON.stringify({ branch: "crew/demo/alpha", slug: "alpha", verdict: "unmet", detail: "no test covers the criterion", findings: [] })}\n\`\`\`\n`,
  );
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
  fake(root, "alpha.review", ""); // empty review report, every round — never recovers
  const r = runSprint(root);
  const s = state(root);
  // The first attempt's failure is a review-not-run retry (see the next tests for that
  // shape in isolation, via .review-once). This fixture keeps failing every attempt, so the
  // second attempt spends this issue's retry cap and it blocks instead of retrying forever —
  // naming why the review never ran, not only that it didn't.
  assert.match(s.retention.alpha.reason, /^blocked — retry limit reached \(2 attempts\) — review-not-run — no report\.json — the reviewer never wrote its verdict file$/);
  assert.deepEqual(s.merged_branches ?? [], []);
  assert.match(r.stdout, /Unreviewed Branches|review/i);
});

test("a review that ended without a verdict is retried once in the same round", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  // The first review leaves no report (the shape a reviewer that stopped short leaves
  // behind); the in-round retry succeeds — no second round, no second verify.
  fake(root, "alpha.review-once", "1");
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const s = state(root);
  assert.deepEqual(s.merged_branches, ["crew/demo/alpha"]);
  assert.equal(s.rounds, 1);
  assert.equal(lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length, 1);
  assert.equal(lines.filter((l) => /^SPAWN .*--agent crew-reviewer/.test(l)).length, 2);
  const log = traceLog(root);
  assert.match(log, /\[REVIEW-RETRY\] slug=alpha round=1 — no report\.json/);
  assert.equal((log.match(/step=verify/g) ?? []).length, 1);
  assert.doesNotMatch(log, /\[SKIP-WORKER\]/);
});

test("a timed-out review is not retried in the same round", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.review-sleep", "3");
  const { r, lines } = commandLines(root, ["--max-rounds", "1", "--reviewer-timeout", "0.02"]);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(lines.filter((l) => /^SPAWN .*--agent crew-reviewer/.test(l)).length, 1);
  assert.doesNotMatch(traceLog(root), /\[REVIEW-RETRY\]/);
  assert.equal(state(root).retention.alpha.reason, "review-not-run — review dispatch timed out");
});

test("a review-not-run retry round skips the coder dispatch and succeeds on its review", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  // Both round-1 reviews (the first and its in-round retry) leave no report; round 2
  // retries only the review — the worker itself never runs a second time.
  fake(root, "alpha.review-once", "2");
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const s = state(root);
  assert.deepEqual(s.completed_slugs, ["alpha"]);
  assert.deepEqual(s.merged_branches, ["crew/demo/alpha"]);
  assert.equal(s.retention?.alpha, undefined, "the issue should have completed, not stayed retained");
  assert.ok(s.rounds >= 2, `expected at least 2 rounds, got ${s.rounds}`);
  assert.equal(lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length, 1);
  assert.match(traceLog(root), /\[SKIP-WORKER\] slug=alpha reason=review-not-run/);
});

test("a non-empty review report with no verdict line and no findings is review-not-run, not criteria-unmet", () => {
  // Distinct from the truly-empty case above: a garbled capture of the reviewer's reply
  // (non-empty text, but no fenced json and no `AC:` line, and no FINDING:/[SEV] content
  // either) used to parse as a genuine `AC: unmet` verdict — routing the retry through a
  // full, expensive coder redispatch to "fix" acceptance criteria the review never
  // actually found unmet. It must route the same cheap way review-once does.
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.review-once-garbled", "");
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const s = state(root);
  assert.deepEqual(s.completed_slugs, ["alpha"]);
  assert.deepEqual(s.merged_branches, ["crew/demo/alpha"]);
  assert.equal(s.retention?.alpha, undefined, "the issue should have completed, not stayed retained");
  // The coder ran exactly once — only the review was retried, and the fixPrompt /
  // criteria-unmet path was never taken.
  assert.equal(lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length, 1);
  assert.match(traceLog(root), /\[REVIEW-RETRY\] slug=alpha /);
  assert.doesNotMatch(traceLog(root), /criteria-unmet/);
});

test("every agent dispatch's cost is recorded, not only the coder's", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.review-once", "1");
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  // One coder and two reviewer dispatches.
  assert.equal(lines.filter((l) => /^RUN .*state\.sh.* dispatch-cost /.test(l)).length, 3);
});

test("a merge-failed retry skips the worker, verify, and review, and succeeds on a retried merge", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const scripts = privateScripts();
  const marker = join(root, ".scratch/merge-fail.marker");
  failFirstCall(scripts, "merge-branches.sh", marker, "MERGE: forced failure for test");

  const round1 = commandLines(root, ["--max-rounds", "1"], { scripts });
  assert.equal(round1.r.code, 0, `${round1.r.stdout}\n${round1.r.stderr}`);
  let s = state(root);
  assert.equal(s.retention?.alpha?.reason, "merge-failed");
  assert.deepEqual(s.merged_branches ?? [], []);
  assert.deepEqual(s.completed_slugs ?? [], []);
  assert.equal(round1.lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length, 1);
  assert.equal(round1.lines.filter((l) => /^SPAWN .*--agent crew-reviewer/.test(l)).length, 1);
  assert.equal(round1.lines.filter((l) => /verify-worktree\.sh --dir/.test(l)).length, 1);
  assert.equal(existsSync(join(root, ".scratch/demo/issues/open/01-alpha.md")), true);
  // Same mechanism finishPartial already uses for every other partial reason: the
  // Progress section is what makes hasProgress (and sprint.resumeBranch()) true.
  assert.match(
    readFileSync(join(root, ".scratch/demo/issues/open/01-alpha.md"), "utf8"),
    /## Progress/,
  );

  const round2 = commandLines(root, ["--max-rounds", "1"], { scripts });
  assert.equal(round2.r.code, 0, `${round2.r.stdout}\n${round2.r.stderr}`);
  s = state(root);
  assert.deepEqual(s.completed_slugs, ["alpha"]);
  assert.deepEqual(s.merged_branches, ["crew/demo/alpha"]);
  assert.equal(s.retention?.alpha, undefined);
  assert.equal(existsSync(join(root, ".scratch/demo/issues/done/01-alpha.md")), true);
  // No worker, verify, or review ran in round 2 — only the merge (and then close) retried.
  assert.equal(round2.lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length, 0);
  assert.equal(round2.lines.filter((l) => /^SPAWN .*--agent crew-reviewer/.test(l)).length, 0);
  assert.equal(round2.lines.filter((l) => /verify-worktree\.sh --dir/.test(l)).length, 0);
  assert.equal(round2.lines.filter((l) => /merge-branches\.sh /.test(l)).length, 1);
  assert.match(traceLog(root), /\[SKIP-TO-MERGE\] slug=alpha reason=merge-failed/);
});

// Two issues editing the same file, dispatched in one round: whichever merges second
// conflicts. Retrying only its merge would conflict again and block; instead the retry
// leaves the conflicted sync merge in its worktree for the coder, then re-runs verify and
// review on the resolution.
test("a merge conflict is retried through the coder, resolved, re-verified, re-reviewed and merged", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-beta.md");
  fake(root, "alpha.shared");
  fake(root, "beta.shared");
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);

  const s = state(root);
  assert.deepEqual([...s.completed_slugs].sort(), ["alpha", "beta"]);
  assert.deepEqual([...s.merged_branches].sort(), ["crew/demo/alpha", "crew/demo/beta"]);
  const shared = sh("git", ["-C", root, "show", "feature/demo:src/shared.txt"]).stdout;
  assert.deepEqual(shared.trim().split("\n").sort(), ["alpha", "beta"], "both sides survive the resolution");

  const log = traceLog(root);
  const kept = log.match(/\[SYNC-CONFLICT-KEPT\] slug=(\w+) branch=\S+ files=src\/shared\.txt/);
  assert.ok(kept, `no kept sync conflict in the trace log:\n${log}`);
  const loser = kept[1];
  assert.match(log, new RegExp(`MERGE\\] branch=crew/demo/${loser} success=false reason=conflict`));
  assert.doesNotMatch(log, /\[SKIP-TO-MERGE\]/, "a conflict must not take the merge-only route");
  const prompt = readFileSync(join(root, `.scratch/demo/dispatch/${loser === "alpha" ? "01" : "02"}-${loser}.prompt.md`), "utf8");
  assert.match(prompt, /A merge of `feature\/demo` into this branch is in progress/);
  assert.match(prompt, /^- src\/shared\.txt$/m);

  // Three coder runs (two issues, plus the resolution), and verify + review re-ran on it.
  assert.equal(lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length, 3);
  assert.equal(lines.filter((l) => /^SPAWN .*--agent crew-reviewer/.test(l)).length, 3);
  assert.equal(lines.filter((l) => /verify-worktree\.sh --dir/.test(l)).length, 3);
});

// Three issues on one file, all dispatched at once: two conflict. Their retries each resolve
// against the feature-branch tip, so run together the second would conflict again with the
// first's resolution and hit the retry cap. One at a time, both merge.
test("merge-conflict retries run one at a time, so a sibling's resolution can't re-conflict the next", () => {
  const root = fixtureRepo();
  for (const name of ["01-alpha.md", "02-beta.md", "03-gamma.md"]) {
    fake(root, `${addIssue(root, name)}.shared`);
  }
  const { r } = commandLines(root, ["--max-parallel", "3"]);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);

  const s = state(root);
  assert.deepEqual([...s.completed_slugs].sort(), ["alpha", "beta", "gamma"], traceLog(root));
  const shared = sh("git", ["-C", root, "show", "feature/demo:src/shared.txt"]).stdout;
  assert.deepEqual(shared.trim().split("\n").sort(), ["alpha", "beta", "gamma"]);
  assert.match(traceLog(root), /\[CONFLICT-RETRY-WAIT\] slug=\w+/);
});

test("a rerun after a merge conflict spent the retry cap resolves it through the coder, not a restart", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-beta.md");
  fake(root, "alpha.shared");
  fake(root, "beta.shared");
  // Whichever loses the first merge can't resolve it, so its one retry conflicts again.
  fake(root, "alpha.no-resolve");
  fake(root, "beta.no-resolve");
  const capped = commandLines(root, ["--max-parallel", "2"]);
  assert.equal(capped.r.code, 2, `${capped.r.stdout}\n${capped.r.stderr}`);
  let s = state(root);
  assert.equal(s.blocked_slugs?.length, 1, traceLog(root));
  const loser = s.blocked_slugs[0];
  assert.match(s.retention?.[loser]?.reason ?? "", /retry limit reached .* merge-conflict/);

  unlinkSync(join(root, ".scratch/fake", `${loser}.no-resolve`));
  const rerun = commandLines(root);
  assert.equal(rerun.r.code, 0, `${rerun.r.stdout}\n${rerun.r.stderr}`);
  s = state(root);
  assert.deepEqual([...s.completed_slugs].sort(), ["alpha", "beta"]);
  assert.match(traceLog(root), new RegExp(`\\[SYNC-CONFLICT-KEPT\\] slug=${loser} `));
  const shared = sh("git", ["-C", root, "show", "feature/demo:src/shared.txt"]).stdout;
  assert.deepEqual(shared.trim().split("\n").sort(), ["alpha", "beta"]);
});

// Any retry can find the feature branch moved on under its branch, not only a
// merge-conflict one: a sibling merged while this issue waited on its fix. Aborting that
// sync blocked the issue; the coder resolves it instead, alongside whatever it was
// retrying for. Run 1 retains alpha; in run 2, beta (sorted first, --max-parallel 1)
// merges an edit to the same file before alpha's retry syncs.
for (const [label, retained, setup] of [
  ["a criteria-unmet retry", /criteria-unmet/, (root) => fake(root, "alpha.review", `\`\`\`json\n${JSON.stringify({ branch: "crew/demo/alpha", slug: "alpha", verdict: "unmet", detail: "AC 1 has no test", findings: [] })}\n\`\`\`\n`)],
  ["a review-only retry", /^review-not-run — /, (root) => fake(root, "alpha.review-once", "2")],
]) {
  test(`${label} whose sync conflicts hands the conflict to the coder instead of blocking`, () => {
    const root = fixtureRepo();
    addIssue(root, "01-alpha.md");
    fake(root, "alpha.shared");
    setup(root);
    const first = commandLines(root, ["--max-rounds", "1"]);
    assert.equal(first.r.code, 0, `${first.r.stdout}\n${first.r.stderr}`);
    assert.match(state(root).retention?.alpha?.reason ?? "", retained);

    rmSync(join(root, ".scratch/fake/alpha.review"), { force: true });
    addIssue(root, "00-beta.md");
    fake(root, "beta.shared");
    const second = commandLines(root, ["--max-parallel", "1"]);
    assert.equal(second.r.code, 0, `${second.r.stdout}\n${second.r.stderr}`);
    const s = state(root);
    assert.deepEqual([...s.completed_slugs].sort(), ["alpha", "beta"], traceLog(root));
    assert.match(traceLog(root), /\[SYNC-CONFLICT-KEPT\] slug=alpha /);
    assert.doesNotMatch(traceLog(root), /\[SYNC-CONFLICT\] slug=alpha/);
    const prompt = readFileSync(join(root, ".scratch/demo/dispatch/01-alpha.prompt.md"), "utf8");
    assert.match(prompt, /A merge of `feature\/demo` into this branch is in progress/);
    if (label.startsWith("a criteria")) assert.match(prompt, /AC 1 has no test/, "the review fix is still asked for");
    const shared = sh("git", ["-C", root, "show", "feature/demo:src/shared.txt"]).stdout;
    assert.deepEqual(shared.trim().split("\n").sort(), ["alpha", "beta"]);
  });
}

test("a close-refused retry skips the worker, verify, and review, no-ops the already-merged retry, and succeeds on a retried close", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const scripts = privateScripts();
  const marker = join(root, ".scratch/close-fail.marker");
  failFirstCall(scripts, "close-issue.sh", marker, "ERROR: forced close failure for test");

  const round1 = commandLines(root, ["--max-rounds", "1"], { scripts });
  assert.equal(round1.r.code, 0, `${round1.r.stdout}\n${round1.r.stderr}`);
  let s = state(root);
  assert.match(s.retention?.alpha?.reason ?? "", /^close-refused/);
  // retain() (unlike complete()) never adds to merged_branches, and actively strips the
  // branch back out of it — merged_branches tracks *closed* issues, not git-level merge
  // success — so the merge having actually succeeded shows up in the trace log instead.
  assert.deepEqual(s.merged_branches ?? [], []);
  assert.deepEqual(s.completed_slugs ?? [], []);
  assert.match(traceLog(root), /\[MERGE\] branch=crew\/demo\/alpha success=true/);
  assert.equal(round1.lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length, 1);
  assert.equal(round1.lines.filter((l) => /^SPAWN .*--agent crew-reviewer/.test(l)).length, 1);
  assert.equal(round1.lines.filter((l) => /verify-worktree\.sh --dir/.test(l)).length, 1);
  assert.equal(existsSync(join(root, ".scratch/demo/issues/open/01-alpha.md")), true, "close was refused, so the issue stays open");
  assert.match(
    readFileSync(join(root, ".scratch/demo/issues/open/01-alpha.md"), "utf8"),
    /## Progress/,
  );

  const round2 = commandLines(root, ["--max-rounds", "1"], { scripts });
  assert.equal(round2.r.code, 0, `${round2.r.stdout}\n${round2.r.stderr}`);
  s = state(root);
  assert.deepEqual(s.completed_slugs, ["alpha"]);
  assert.equal(s.retention?.alpha, undefined);
  assert.equal(existsSync(join(root, ".scratch/demo/issues/done/01-alpha.md")), true);
  // No worker, verify, or review ran in round 2. The merge ran again too — merge-
  // branches.sh's own already-merged short-circuit is what makes that safe, not new
  // pipeline logic — and reported success with no action before close retried.
  assert.equal(round2.lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length, 0);
  assert.equal(round2.lines.filter((l) => /^SPAWN .*--agent crew-reviewer/.test(l)).length, 0);
  assert.equal(round2.lines.filter((l) => /verify-worktree\.sh --dir/.test(l)).length, 0);
  assert.match(round2.r.stderr, /already-merged/);
  assert.match(traceLog(root), /\[SKIP-TO-MERGE\] slug=alpha reason=close-refused/);
});

test("an ac receipt that can't be written retries review without the coder, blocks with the error, and resumes at verify once fixed", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  // `receipts.sh write ac` fails while the flag exists; every other receipts.sh call (the
  // verify receipt, the checks) runs the real script. Removing the flag is the human fix.
  const scripts = privateScripts();
  const flag = join(root, ".scratch/ac-receipt-broken");
  writeFileSync(flag, "");
  const real = join(scripts, "_real-receipts.sh");
  cpSync(join(scripts, "receipts.sh"), real);
  writeFileSync(
    join(scripts, "receipts.sh"),
    [
      "#!/usr/bin/env bash",
      `if [ "$1 $2" = "write ac" ] && [ -f ${JSON.stringify(flag)} ]; then`,
      '  echo "ERROR: forced ac receipt failure" >&2',
      "  exit 1",
      "fi",
      `exec bash ${JSON.stringify(real)} "$@"`,
      "",
    ].join("\n"),
  );
  const count = (lines, re) => lines.filter((l) => re.test(l)).length;

  const broken = commandLines(root, [], { scripts });
  assert.equal(broken.r.code, 2, `${broken.r.stdout}\n${broken.r.stderr}`);
  let s = state(root);
  assert.deepEqual(s.blocked_slugs, ["alpha"]);
  assert.match(s.retention?.alpha?.reason ?? "", /retry limit reached .* ac-receipt-failed — ERROR: forced ac receipt failure/);
  assert.equal(count(broken.lines, /^SPAWN .*--agent crew-coder/), 1, "the retry never re-ran the coder");
  assert.equal(count(broken.lines, /^SPAWN .*--agent crew-reviewer/), 2, "the retry re-ran review before rewriting the receipt");
  assert.match(traceLog(root), /\[SKIP-WORKER\] slug=alpha reason=ac-receipt-retry/);
  const issue = readFileSync(join(root, ".scratch/demo/issues/open/01-alpha.md"), "utf8");
  assert.match(issue, /## Blocked[\s\S]*ERROR: forced ac receipt failure/, "the human sees the real cause");

  rmSync(flag);
  const fixed = commandLines(root, [], { scripts });
  assert.equal(fixed.r.code, 0, `${fixed.r.stdout}\n${fixed.r.stderr}`);
  s = state(root);
  assert.deepEqual(s.completed_slugs, ["alpha"]);
  assert.deepEqual(s.merged_branches, ["crew/demo/alpha"]);
  assert.equal(count(fixed.lines, /^SPAWN .*--agent crew-coder/), 0, "resumed at verify, not a coder restart");
  assert.equal(count(fixed.lines, /^SPAWN .*--agent crew-reviewer/), 1);
  assert.equal(existsSync(join(root, ".scratch/demo/issues/done/01-alpha.md")), true);
});

test("a blocked issue's branch is resumed and synced on the next run, not re-blocked as stale once siblings merge", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-beta.md");
  // alpha's worker commits, then reports itself blocked; beta then merges, moving the
  // feature branch past the point alpha's branch forked from.
  const blockedReport = (dir) =>
    `## Issue: alpha\nStatus: blocked\n\n\`\`\`json\n${JSON.stringify({ status: "blocked", branch: "crew/demo/alpha", working_directory: dir, checks: { test: "pass", lint: "pass", typecheck: "pass" }, progress: "", notes: "needs a decision on the API shape" })}\n\`\`\`\n`;
  fake(root, "alpha.worker", blockedReport(join(root, ".scratch/worktrees/crew/demo/alpha")));

  const first = commandLines(root, ["--max-parallel", "1"]);
  let s = state(root);
  assert.deepEqual(s.blocked_slugs, ["alpha"], `${first.r.stdout}\n${first.r.stderr}`);
  assert.deepEqual(s.merged_branches, ["crew/demo/beta"]);
  assert.match(readFileSync(join(root, ".scratch/demo/issues/open/01-alpha.md"), "utf8"), /## Blocked/);

  // The human answers the question; the worker now completes.
  rmSync(join(root, ".scratch/fake/alpha.worker"));
  const second = commandLines(root, ["--max-parallel", "1"]);
  assert.equal(second.r.code, 0, `${second.r.stdout}\n${second.r.stderr}`);
  s = state(root);
  assert.doesNotMatch(traceLog(root), /\[STALE-BRANCH\] slug=alpha/);
  assert.deepEqual([...s.completed_slugs].sort(), ["alpha", "beta"]);
  assert.equal(second.lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length, 1);
  // Resumed on the blocked worker's branch: each fake worker run appends one line, so the
  // blocked attempt's line is still there alongside the resumed one's.
  assert.equal(readFileSync(join(root, "src/alpha.txt"), "utf8"), "// alpha\n// alpha\n");
});

test("a branch refused as stale stays refused on the next run, not resumed as the issue's own", () => {
  const root = fixtureRepo();
  const git = (...args) => sh("git", ["-C", root, ...args]);
  const count = (lines, re) => lines.filter((l) => re.test(l)).length;
  addIssue(root, "01-alpha.md");
  // A leftover branch with unique work, forked before the feature branch moved on.
  git("checkout", "-q", "-b", "crew/demo/alpha");
  writeFileSync(join(root, "leftover.txt"), "abandoned work\n");
  git("add", "-A");
  git("commit", "-q", "-m", "leftover work");
  git("checkout", "-q", "feature/demo");
  writeFileSync(join(root, "advance.txt"), "advance\n");
  git("add", "-A");
  git("commit", "-q", "-m", "advance the feature branch");

  const first = commandLines(root, ["--max-parallel", "1"]);
  assert.deepEqual(state(root).blocked_slugs, ["alpha"], `${first.r.stdout}\n${first.r.stderr}`);
  assert.equal(state(root).retained_branches?.alpha, undefined, "a refused branch is not this issue's own");

  const second = commandLines(root, ["--max-parallel", "1"]);
  assert.match(traceLog(root), /\[STALE-BRANCH\] slug=alpha/, "still refused on the rerun");
  assert.equal(count(second.lines, /^SPAWN .*--agent crew-coder/), 0, "no coder is dispatched onto the leftover branch");
});

test("a criteria-unmet retry still redispatches the full worker, not just review", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(
    root,
    "alpha.review",
    `## Branch: crew/demo/alpha\n\`\`\`json\n${JSON.stringify({ branch: "crew/demo/alpha", slug: "alpha", verdict: "unmet", detail: "no test covers the criterion", findings: [] })}\n\`\`\`\n`,
  );
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 2, "unmet criteria never resolve on their own, so the sprint stalls");
  const s = state(root);
  assert.match(s.retention.alpha.reason, /criteria-unmet/);
  assert.equal(
    lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length,
    2,
    "the coder must run again — a criteria-unmet retention means the branch's content needs work, not just another review",
  );
});

test("a verification-failed retry still redispatches the full worker, not just review", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  // Override the Makefile so the real check the pipeline runs fails, regardless of what
  // the worker's own report claims (the default fake worker reports every check as pass).
  writeFileSync(join(root, "Makefile"), "test:\n\t@echo boom && exit 1\nlint:\n\t@echo ok\ntypecheck:\n\t@echo ok\n");
  sh("git", ["-C", root, "add", "-A"]);
  sh("git", ["-C", root, "commit", "-q", "-m", "make test always fail"]);
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 2);
  const s = state(root);
  assert.equal(s.retention.alpha.reason, "blocked — retry limit reached (2 attempts) — verification-failed");
  assert.equal(
    lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length,
    2,
    "the coder must run again — a verification-failed branch needs its content fixed, not just a review retry",
  );
  // A failed verify routes to triage (not the coder) to classify the failure — that
  // dispatch needs the same live-stream visibility as the coder/review dispatches.
  const steps = r.stderr.split("\n").filter((l) => l.startsWith("[STEP]") && l.includes("slug=01-alpha"));
  assert.ok(
    steps.some((l) => /^\[STEP\] slug=01-alpha round=1 step=dispatch-triage model=.+$/.test(l)),
    `expected a round-1 dispatch-triage step marker, got:\n${steps.join("\n")}`,
  );
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

test("a rerun after a block with no commits is not told commits are preserved", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.exit", "7");
  runSprint(root);
  assert.deepEqual(state(root).blocked_slugs, ["alpha"]);

  rmSync(join(root, ".scratch/fake/alpha.exit"));
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const prompt = readFileSync(join(root, ".scratch/demo/dispatch/01-alpha.prompt.md"), "utf8");
  assert.match(prompt, /## Blocked/);
  assert.doesNotMatch(prompt, /preserved on branch/);
});

test("a blocked-by dependency is not dispatched until its blocker closes, and dispatches the moment it does", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-beta.md", { blockedBy: ["01-alpha.md"] });
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const s = state(root);
  assert.deepEqual(s.completed_slugs.sort(), ["alpha", "beta"]);
  // Neither issue needs a retry — beta is picked up by a freed pool slot the instant alpha
  // closes, not on some later synchronization point, so both complete on their first
  // attempt: "Rounds: 1" (the highest per-issue attempt count reached by either).
  assert.equal(s.rounds, 1, `expected exactly 1 attempt per issue, got ${s.rounds}`);
});

test("--max-rounds caps attempts per issue, not the sprint's total dispatch count", () => {
  // A continuous pool has no round barrier serializing "everyone gets one attempt before
  // anyone gets a second" for free — --max-rounds has to enforce that itself, per issue,
  // or the first issue a worker claims could exhaust the whole budget while its siblings
  // never run even once.
  const root = fixtureRepo();
  const slugs = ["alpha", "beta", "gamma"];
  slugs.forEach((n, i) => {
    addIssue(root, `0${i + 1}-${n}.md`);
    fake(
      root,
      `${n}.worker`,
      ['## Issue: ' + n, 'Status: partial', '', '```json', '{"status":"partial","checks":{"test":"pass","lint":"pass","typecheck":"pass"},"progress":"stuck"}', '```'].join("\n"),
    );
  });
  const { r, lines } = commandLines(root, ["--max-rounds", "1"]);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const s = state(root);
  for (const slug of slugs) {
    assert.equal(s.retention?.[slug]?.reason, "partial", `${slug} never got its one attempt`);
  }
  assert.equal(
    lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length,
    3,
    "all three issues must be dispatched once, not just the first one claimed",
  );
});

test("CRITICAL findings are promoted into a Phase 2 fix issue and run again", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(
    root,
    "alpha.review",
    `## Branch: crew/demo/alpha\n\`\`\`json\n${JSON.stringify({
      branch: "crew/demo/alpha",
      slug: "alpha",
      verdict: "all-met",
      findings: [
        { severity: "CRITICAL", location: "src/alpha.txt:1", criterion: "Reject unsigned input before use" },
        { severity: "MEDIUM", location: "src/alpha.txt:2", criterion: "Rename the variable" },
      ],
    })}\n\`\`\`\n`,
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

// ─── what the deleted claude prose used to assert about itself ───────────────
//
// The claude cutover removed the last hand-written orchestrator body that named the
// pipeline. Its prose assertions (review before merge, review before squash, no
// post-squash review, the report path, the skip case, the resume note, retention
// surviving cleanup, the wrap-up order) are behaviour, so they are asserted here on a
// real run with every model dispatch faked.

test("the gates run in order: verify → AC receipt → merge → close, and squash last", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const log = traceLog(root);
  const verify = markerAt(log, "VERIFY");
  const ac = markerAt(log, "ACVERIFY");
  const merge = markerAt(log, "MERGE");
  const close = markerAt(log, "CLOSE");
  const squash = markerAt(log, "SQUASH");
  assert.ok(verify < ac, "the AC receipt was written before verification finished");
  assert.ok(ac < merge, "the branch merged before its acceptance criteria were verified");
  assert.ok(merge < close, "the issue closed before the merge — a failed merge would orphan it");
  assert.ok(close < squash, "the squash ran before the pipeline finished");
});

test("the review is written to the sprint's reviews dir, before the squash", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  runSprint(root);
  const reports = reviewReports(root);
  assert.equal(reports.length, 1, `expected one sprint-review file, got ${JSON.stringify(reports)}`);
  const text = readFileSync(join(root, ".scratch/demo/reviews", reports[0]), "utf8");
  assert.match(text, /## Branch: /);
  // The review is the merge's gate, so it cannot be a post-squash pass over merged code.
  const log = traceLog(root);
  assert.ok(markerAt(log, "ACVERIFY") < markerAt(log, "SQUASH"));
});

test("a branch that fails verification is never reviewed, and no report is written", () => {
  // The old prose said: with no verified branches this round, print "skipped" and write
  // no report. The code equivalent is that nothing is dispatched and no file appears.
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(
    root,
    "alpha.worker",
    ['## Issue: alpha', 'Status: complete', '', '```json', '{"status":"complete","checks":{"test":"fail","lint":"pass","typecheck":"pass"},"progress":"red"}', '```'].join("\n"),
  );
  runSprint(root);
  assert.deepEqual(reviewReports(root), []);
  assert.equal(existsSync(join(root, ".scratch/demo/dispatch/01-alpha.review.md")), false);
});

test("a retained branch survives cleanup, is named in the summary, and resumes next round", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.worker", '## Issue: alpha\nStatus: partial\n\n```json\n{"status":"partial","progress":"stuck"}\n```');
  const r = runSprint(root);
  assert.equal(r.code, 2);
  // Cleanup deletes merged branches only; a retained one keeps its committed WIP.
  const branches = sh("git", ["-C", root, "branch", "--list", "crew/demo/alpha"]).stdout.trim();
  assert.match(branches, /crew\/demo\/alpha/, "cleanup deleted a retained branch");
  assert.match(r.stdout, /## Retained Branches/);
  assert.match(r.stdout, /partial/);
  // Round 2 was told to resume on that branch rather than start over — and that the
  // notes are context alongside the preserved code, not a substitute for it.
  const prompt = readFileSync(join(root, ".scratch/demo/dispatch/01-alpha.prompt.md"), "utf8");
  assert.match(prompt, /Resume on that existing branch/);
  assert.match(prompt, /crew\/demo\/alpha/);
  assert.match(prompt, /not a substitute for it/);
});

test("a merged branch's worktree and ref are both gone after cleanup", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  runSprint(root);
  assert.equal(existsSync(join(root, ".scratch/worktrees/crew/demo/alpha")), false);
  assert.equal(sh("git", ["-C", root, "branch", "--list", "crew/demo/alpha"]).stdout.trim(), "");
});

test("the summary names the resolved model, rendered from disk", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const r = runSprint(root, ["--model", "sonnet"]);
  assert.match(r.stdout, /Model:\s+sonnet/);
  assert.equal(state(root).model, "sonnet");
  assert.match(traceLog(root), /\[MODEL\]/);
});

test(".coding-crew/config.json lets the reviewer diverge from the coder's model, on the claude platform", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  mkdirSync(join(root, ".coding-crew"), { recursive: true });
  writeFileSync(
    join(root, ".coding-crew/config.json"),
    JSON.stringify({ afk: { models: { claude: { coder: "sonnet", reviewer: "opus" } } } }),
  );
  const { r, lines } = commandLines(root, [], { platform: "claude" });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.ok(
    lines.some((l) => /^SPAWN .*--agent crew-coder/.test(l) && / --model sonnet/.test(l)),
    `expected the coder dispatched with --model sonnet, got:\n${lines.join("\n")}`,
  );
  assert.ok(
    lines.some((l) => /^SPAWN .*--agent crew-reviewer/.test(l) && / --model opus/.test(l)),
    `expected the reviewer dispatched with --model opus, got:\n${lines.join("\n")}`,
  );
});

test("a legacy afk-models.json is moved into config.json by `run`, and still ignored on a non-claude platform", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  mkdirSync(join(root, ".coding-crew"), { recursive: true });
  writeFileSync(
    join(root, ".coding-crew/afk-models.json"),
    JSON.stringify({ coder: "sonnet", reviewer: "opus" }),
  );
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stderr, /moved \.coding-crew\/afk-models\.json into \.coding-crew\/config\.json/);
  assert.equal(existsSync(join(root, ".coding-crew/afk-models.json")), false);
  assert.deepEqual(JSON.parse(readFileSync(join(root, ".coding-crew/config.json"), "utf8")), {
    afk: { models: { claude: { coder: "sonnet", reviewer: "opus" } } },
  });
  assert.ok(
    lines.some((l) => /^SPAWN .*--agent crew-coder/.test(l) && !/ --model /.test(l)),
    `expected the pi coder dispatched with no --model, got:\n${lines.join("\n")}`,
  );
});

test("a `run` that fails setup leaves a legacy afk-models.json where it is", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  mkdirSync(join(root, ".coding-crew"), { recursive: true });
  writeFileSync(join(root, ".coding-crew/afk-models.json"), JSON.stringify({ coder: "opus" }));
  const r = sh("node", [MAIN, "run", "--platform", "claude", "--feature-slug", "demo", "--max-parallel"], {
    cwd: root,
    env: { ...process.env, CREW_SCRIPTS: SCRIPTS, CREW_FAKE_DISPATCH: FAKE, MAIN_ROOT: root },
  });
  assert.equal(r.code, 1, `${r.stdout}\n${r.stderr}`);
  assert.doesNotMatch(r.stderr, /moved \.coding-crew\/afk-models\.json/);
  assert.equal(existsSync(join(root, ".coding-crew/afk-models.json")), true);
  assert.equal(existsSync(join(root, ".coding-crew/config.json")), false);
});

test("`plan` does not move a legacy afk-models.json, only says it would", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  mkdirSync(join(root, ".coding-crew"), { recursive: true });
  writeFileSync(join(root, ".coding-crew/afk-models.json"), JSON.stringify({ coder: "opus" }));
  const r = sh("node", [MAIN, "plan", "--platform", "claude", "--feature-slug", "demo"], {
    cwd: root,
    env: { ...process.env, CREW_SCRIPTS: SCRIPTS, CREW_FAKE_DISPATCH: FAKE, MAIN_ROOT: root },
  });
  assert.match(r.stderr, /will be moved into \.coding-crew\/config\.json/);
  assert.equal(existsSync(join(root, ".coding-crew/afk-models.json")), true);
  assert.equal(existsSync(join(root, ".coding-crew/config.json")), false);
  assert.match(r.stdout, /coder\s+claude\s+opus/);
});

test("`plan` shows which config file set each role's runtime and model", () => {
  const root = fixtureRepo();
  const home = mkdtempSync(join(tmpdir(), "crew-sprint-userhome-"));
  mkdirSync(join(home, ".coding-crew"), { recursive: true });
  mkdirSync(join(root, ".coding-crew"), { recursive: true });
  writeFileSync(join(home, ".coding-crew/config.json"), JSON.stringify({ afk: { runtime: { reviewer: "codex" } } }));
  writeFileSync(join(root, ".coding-crew/config.json"), JSON.stringify({ afk: { models: { claude: { triage: "opus" } } } }));
  const r = sh("node", [MAIN, "plan", "--platform", "claude", "--feature-slug", "demo"], {
    cwd: root,
    env: { ...process.env, HOME: home, CREW_SCRIPTS: SCRIPTS, CREW_FAKE_DISPATCH: FAKE, MAIN_ROOT: root },
  });
  assert.match(r.stdout, /reviewer\s+codex\s+runtime default\s+\[runtime: user\]/, r.stdout);
  assert.match(r.stdout, /triage\s+claude\s+opus.*\[model: project\]/, r.stdout);
  assert.match(r.stdout, /coder\s+claude\s+sonnet(?!.*\[)/, r.stdout);
  rmSync(home, { recursive: true, force: true });
});

test("`plan` credits --model, not the config file, when it overrides the file's coder model", () => {
  const root = fixtureRepo();
  mkdirSync(join(root, ".coding-crew"), { recursive: true });
  writeFileSync(join(root, ".coding-crew/config.json"), JSON.stringify({ afk: { models: { claude: { coder: "haiku" } } } }));
  const r = sh("node", [MAIN, "plan", "--platform", "claude", "--model", "opus", "--feature-slug", "demo"], {
    cwd: root,
    env: { ...process.env, CREW_SCRIPTS: SCRIPTS, CREW_FAKE_DISPATCH: FAKE, MAIN_ROOT: root },
  });
  assert.match(r.stdout, /coder\s+claude\s+opus.*\[model: --model\]/, r.stdout);
  assert.doesNotMatch(r.stdout, /coder.*\[model: project\]/, r.stdout);
});

test("a mixed crew dispatches each role on its own runtime, with only that runtime's model", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  mkdirSync(join(root, ".coding-crew"), { recursive: true });
  writeFileSync(
    join(root, ".coding-crew/config.json"),
    JSON.stringify({ afk: { runtime: { reviewer: "codex" }, models: { claude: { coder: "sonnet" } } } }),
  );
  const { r, lines } = commandLines(root, [], { platform: "claude" });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const spawn = (agent) => lines.find((l) => new RegExp(`^SPAWN .*--agent ${agent} `).test(l)) ?? "";
  assert.match(spawn("crew-coder"), / --runtime claude .* --model sonnet/);
  assert.match(spawn("crew-reviewer"), / --runtime codex /);
  assert.doesNotMatch(spawn("crew-reviewer"), / --model /, "a claude alias must never reach codex");
});

test("a runtime's model env var (ANTHROPIC_DEFAULT_*_MODEL) reaches the dispatched child", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const { r } = commandLines(root, [], {
    platform: "claude",
    env: { ANTHROPIC_DEFAULT_SONNET_MODEL: "au.anthropic.claude-sonnet-5", CREW_FAKE_ECHO_ENV: "ANTHROPIC_DEFAULT_SONNET_MODEL" },
  });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  // Agent dispatches and the agent-less plain dispatch (command discovery) alike.
  for (const agent of ["crew-coder", "crew-reviewer", "commands-discovery"]) {
    assert.equal(
      readFileSync(join(root, ".scratch/fake", `env.${agent}`), "utf8").trim(),
      "ANTHROPIC_DEFAULT_SONNET_MODEL=au.anthropic.claude-sonnet-5",
      agent,
    );
  }
});

test("an invalid config.json is a setup error naming every problem", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  mkdirSync(join(root, ".coding-crew"), { recursive: true });
  writeFileSync(
    join(root, ".coding-crew/config.json"),
    JSON.stringify({ afk: { runtime: { reviwer: "codex", triage: "cursor" } } }),
  );
  const { r } = commandLines(root);
  assert.equal(r.code, 1);
  assert.match(r.stderr, /unknown role "afk\.runtime\.reviwer"/);
  assert.match(r.stderr, /"afk\.runtime\.triage" is "cursor"/);
});

test("doctor names the role when a runtime other than the launcher's is not installed", () => {
  const root = fixtureRepo();
  mkdirSync(join(root, ".coding-crew"), { recursive: true });
  writeFileSync(join(root, ".coding-crew/config.json"), JSON.stringify({ afk: { runtime: { reviewer: "codex" } } }));
  const env = { ...process.env, CREW_SCRIPTS: SCRIPTS, MAIN_ROOT: root, HOME: root };
  delete env.CREW_FAKE_DISPATCH;
  const r = sh("node", [MAIN, "doctor", "--platform", "claude"], { cwd: root, env });
  assert.equal(r.code, 1);
  assert.match(r.stdout, /PROBLEM: reviewer → codex: crew-reviewer agent definition not installed for codex/);
  assert.doesNotMatch(r.stdout, /→ codex: crew-coder/);
});

const lineOf = (log, text) => log.split("\n").findIndex((l) => l.includes(text));
const AUDIT_WITH_GAP = [
  "✗ Users can export to CSV: no evidence",
  "```json",
  JSON.stringify({ covered: 1, partial: 0, missing: [{ requirement: "Users can export to CSV", detail: "PRD: Export" }] }),
  "```",
].join("\n");

test("the PRD audit runs by default after Phase 1, before the flush and the squash", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  writeFileSync(join(root, ".scratch/demo/PRD.md"), "# PRD\n\n- The widget exists\n");
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(existsSync(join(root, ".scratch/demo/prd-audit.md")), true);
  assert.match(r.stdout, /## PRD Audit/);
  const log = traceLog(root);
  const audit = lineOf(log, "step=prd-audit mode=fix");
  assert.notEqual(audit, -1, log);
  assert.ok(markerAt(log, "MERGE") < audit, "the audit follows Phase 1's merges");
  assert.ok(audit < markerAt(log, "FLUSH"), "…and precedes the flush that starts Phase 2");
  assert.ok(audit < markerAt(log, "SQUASH"));
  assert.match(log, /PRD audit: no missing requirements\./);

  // off: never runs, however much PRD there is.
  const root2 = fixtureRepo();
  addIssue(root2, "01-alpha.md");
  writeFileSync(join(root2, ".scratch/demo/PRD.md"), "# PRD\n\n- The widget exists\n");
  const off = runSprint(root2, ["--prd-audit", "off"]);
  assert.equal(off.code, 0, `${off.stdout}\n${off.stderr}`);
  assert.equal(existsSync(join(root2, ".scratch/demo/prd-audit.md")), false);
  assert.doesNotMatch(off.stdout, /## PRD Audit/);
});

test("PRDAudit fix: missing requirements become one Phase 2 fix issue, audited no further", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  writeFileSync(join(root, ".scratch/demo/PRD.md"), "# PRD\n\n- Export to CSV\n");
  fake(root, "prd-audit.response", AUDIT_WITH_GAP);
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.deepEqual(state(root).completed_slugs, ["alpha", "fix-prd-gaps"]);
  const issue = readFileSync(join(root, ".scratch/demo/issues/done/02-fix-prd-gaps.md"), "utf8");
  assert.match(issue, /^Source: .*prd-audit\.md \(prd-audit\)$/m, "the Source: line is the depth bound");
  assert.match(issue, /- \[[ x]\] Users can export to CSV — PRD: Export/);
  const log = traceLog(root);
  assert.equal(log.split("step=prd-audit").length - 1, 1, "one audit per sprint, none after Phase 2");
});

test("PRDAudit report: the audit runs, and its gaps are left for a human", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  writeFileSync(join(root, ".scratch/demo/PRD.md"), "# PRD\n\n- Export to CSV\n");
  fake(root, "prd-audit.response", AUDIT_WITH_GAP);
  mkdirSync(join(root, ".coding-crew"), { recursive: true });
  writeFileSync(join(root, ".coding-crew/config.json"), JSON.stringify({ afk: { PRDAudit: "report" } }));
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.deepEqual(state(root).completed_slugs, ["alpha"]);
  assert.match(r.stdout, /## PRD Audit/);
  // --coverage, the old flag, is `report` too.
  const root2 = fixtureRepo();
  addIssue(root2, "01-alpha.md");
  writeFileSync(join(root2, ".scratch/demo/PRD.md"), "# PRD\n\n- Export to CSV\n");
  fake(root2, "prd-audit.response", AUDIT_WITH_GAP);
  const old = runSprint(root2, ["--coverage"]);
  assert.equal(old.code, 0, `${old.stdout}\n${old.stderr}`);
  assert.deepEqual(state(root2).completed_slugs, ["alpha"]);
  assert.match(readFileSync(join(root2, ".scratch/demo/sprint.env"), "utf8"), /CREW_PRD_AUDIT="report"/);
});

test("a PRD audit that fails is named in the summary, not only the trace", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  writeFileSync(join(root, ".scratch/demo/PRD.md"), "# PRD\n\n- Export to CSV\n");
  fake(root, "prd-audit.md.exit", "1");
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stdout, /## PRD Audit\n\n\*\*Failed:\*\* the audit did not complete \(exit 1\)/);
});

test("the PRD audit does not run while a Phase 1 issue is still open", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-beta.md");
  writeFileSync(join(root, ".scratch/demo/PRD.md"), "# PRD\n\n- Export to CSV\n");
  fake(root, "prd-audit.response", AUDIT_WITH_GAP);
  fake(root, "beta.exit", "1");
  const r = runSprint(root);
  assert.equal(r.code, 2, `${r.stdout}\n${r.stderr}`);
  const log = traceLog(root);
  assert.match(log, /PRD audit: skipped — 1 Phase 1 issue\(s\) still open \(beta\)/);
  assert.equal(log.includes("step=prd-audit"), false, "no auditor is dispatched");
  assert.equal(existsSync(join(root, ".scratch/demo/prd-audit.md")), false);
  assert.match(r.stdout, /\*\*Not run:\*\* 1 Phase 1 issue\(s\) still open \(beta\)/, "the summary says so, not only the trace");
  assert.equal(readdirSync(join(root, ".scratch/demo/issues/open")).some((f) => /fix-prd-gaps/.test(f)), false);
});

test("a feature slug containing 'skipped' does not silently cancel the PRD audit", () => {
  // Regression: loop.mjs used to test /skipped/i against the audit script's *entire*
  // stdout, not just its one-line skip message. That stdout embeds $PRD_PATH (which embeds
  // $FEATURE_SLUG) on every non-skip line ("PRD found at .scratch/<slug>/PRD.md", "Extract
  // all requirements from ...", "Completed issues in .scratch/<slug>/issues/done/"), so a
  // feature slug that happens to contain the substring "skipped" — a perfectly ordinary name
  // for a feature about skip logic — made that regex match and cancelled a validation the
  // user explicitly asked for. The same bug as command discovery's, just
  // triggered through the slug instead of a quoted file's content.
  const root = mkdtempSync(join(tmpdir(), "crew-sprint-"));
  const git = (...args) => sh("git", ["-C", root, ...args]);
  git("init", "-q", "-b", "main");
  git("config", "user.email", "t@test");
  git("config", "user.name", "T");
  writeFileSync(join(root, "Makefile"), "test:\n\t@echo ok\nlint:\n\t@echo ok\ntypecheck:\n\t@echo ok\n");
  writeFileSync(join(root, ".gitignore"), ".scratch/\n");
  git("add", "-A");
  git("commit", "-q", "-m", "init");
  git("checkout", "-q", "-b", "feature/skipped-flow");
  mkdirSync(join(root, ".scratch/skipped-flow/issues/open"), { recursive: true });
  mkdirSync(join(root, ".scratch/fake"), { recursive: true });
  writeFileSync(
    join(root, ".scratch/skipped-flow/issues/open/01-alpha.md"),
    "# alpha\n\nStatus: ready-for-agent\n\n## Acceptance criteria\n\n- [ ] alpha exists\n",
  );
  writeFileSync(join(root, ".scratch/skipped-flow/PRD.md"), "# PRD\n\n- The widget exists\n");

  const r = runSprint(root, ["--prd-audit", "report", "--feature-slug", "skipped-flow"]);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(
    existsSync(join(root, ".scratch/skipped-flow/prd-audit.md")),
    true,
    "a feature slug containing 'skipped' must not cancel a requested PRD audit",
  );
  assert.match(r.stdout, /## PRD Audit/);
});

// ─── what the last prose bodies used to assert about themselves ──────────────
//
// The copilot cutover emptied AFK_PROSE_VARIANTS, so the bats suites that looped over it
// stopped having a subject. Three of those assertions had no direct code equivalent, only
// an adjacent one, and are written here before they are deleted there: the promotion
// threshold has one source, the sprint reports once and last, and a review gap is named in
// the summary rather than merely counted in the state file.

test("the promotion threshold has one source: fixFindings reaches findingsAtOrAbove", () => {
  const reviewWith = (severity) =>
    [
      "## Branch: crew/demo/alpha",
      "```json",
      JSON.stringify({
        branch: "crew/demo/alpha",
        verdict: "all-met",
        findings: [{ severity, location: "src/alpha.txt:1", criterion: "Move the trust boundary check before the write" }],
      }),
      "```",
    ].join("\n");
  const sprintWith = (severity, extra = [], config = null) => {
    const root = fixtureRepo();
    addIssue(root, "01-alpha.md");
    fake(root, "alpha.review", reviewWith(severity));
    if (config) {
      mkdirSync(join(root, ".coding-crew"), { recursive: true });
      writeFileSync(join(root, ".coding-crew/config.json"), JSON.stringify({ afk: config }));
    }
    const r = runSprint(root, extra);
    assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
    return { root, r };
  };

  // Default: high. The HIGH becomes a Phase 2 fix issue; the threshold is read from
  // sprint.env (CREW_FIX_FINDINGS), not restated anywhere.
  const high = sprintWith("HIGH");
  assert.equal(state(high.root).completed_slugs.length, 2, "the HIGH should have run as its own fix issue");
  const criteria = readFileSync(join(high.root, ".scratch/demo/reviews/alpha.criteria.md"), "utf8");
  assert.match(criteria, /\[HIGH\] Move the trust boundary check before the write/);
  assert.match(readFileSync(join(high.root, ".scratch/demo/sprint.env"), "utf8"), /CREW_FIX_FINDINGS="high"/);

  // A MEDIUM is reported, never promoted, at the default — left open and attributed.
  const medium = sprintWith("MEDIUM");
  assert.deepEqual(state(medium.root).completed_slugs, ["alpha"], "no fix issue for a MEDIUM at the default");
  assert.match(medium.r.stdout, /## Next Step/);

  // config.json's afk.fixFindings: medium promotes it.
  const onMedium = sprintWith("MEDIUM", [], { fixFindings: "medium" });
  assert.equal(state(onMedium.root).completed_slugs.length, 2);

  // --promote critical, the old flag, still narrows to CRITICAL — and names the setting.
  const critical = sprintWith("HIGH", ["--promote", "critical"]);
  assert.deepEqual(state(critical.root).completed_slugs, ["alpha"]);
  assert.match(critical.r.stdout, /afk\.fixFindings, or --fix-findings/);

  // none: nothing promoted, whatever the severity.
  const none = sprintWith("CRITICAL", ["--fix-findings", "none"]);
  assert.deepEqual(state(none.root).completed_slugs, ["alpha"]);
});

test("a bad flag value is a setup error naming the flag", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const r = runSprint(root, ["--fix-findings", "severe", "--coder-timeout", "0"]);
  assert.equal(r.code, 1);
  assert.match(r.stderr, /--fix-findings is "severe"/);
  assert.match(r.stderr, /--coder-timeout must be a positive number of minutes/);
  // The flag the user typed, even an old name.
  const old = runSprint(root, ["--worker-timeout", "abc"]);
  assert.equal(old.code, 1);
  assert.match(old.stderr, /--worker-timeout must be/);
  // A setting flag left without its value is an error, not silently the default.
  const bare = runSprint(root, ["--prd-audit"]);
  assert.equal(bare.code, 1);
  assert.match(bare.stderr, /--prd-audit is ""/);
});

test("config.json's squashCommits and installDeps turn those steps off, as their flags do", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  mkdirSync(join(root, ".coding-crew"), { recursive: true });
  writeFileSync(join(root, ".coding-crew/config.json"), JSON.stringify({ afk: { squashCommits: false, installDeps: false } }));
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const log = traceLog(root);
  assert.doesNotMatch(log, /step=deps/);
  assert.match(`${r.stdout}\n${r.stderr}\n${log}`, /squash skipped|--no-squash|skipping squash/i);
});

test("`plan` shows each setting and which file or flag set it", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  mkdirSync(join(root, ".coding-crew"), { recursive: true });
  writeFileSync(join(root, ".coding-crew/config.json"), JSON.stringify({ afk: { fixFindings: "medium", timeouts: { coder: 60 } } }));
  const r = sh("node", [MAIN, "plan", "--platform", "pi", "--feature-slug", "demo", "--prd-audit", "report"], {
    cwd: root,
    env: { ...process.env, CREW_SCRIPTS: SCRIPTS, CREW_FAKE_DISPATCH: FAKE, MAIN_ROOT: root },
  });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stdout, /findings: +fix medium and above in Phase 2 +\[project\]/);
  assert.match(r.stdout, /PRD audit: report +\[flag\]/);
  assert.match(r.stdout, /timeouts: +coder 60m \[project\], reviewer 20m, triage 20m, commandFinder 5m, prdAuditor 20m, merge 5m/);
});

test("`plan` shows the worktree root and which file set it", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  mkdirSync(join(root, ".coding-crew"), { recursive: true });
  writeFileSync(join(root, ".coding-crew/config.json"), JSON.stringify({ afk: { worktreeRoot: "../wt" } }));
  const env = { ...process.env, CREW_SCRIPTS: SCRIPTS, CREW_FAKE_DISPATCH: FAKE, MAIN_ROOT: root };
  delete env.CREW_WORKTREE_ROOT;
  const r = sh("node", [MAIN, "plan", "--platform", "pi", "--feature-slug", "demo"], { cwd: root, env });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.ok(r.stdout.includes(`worktrees: ${join(root, "../wt")}  [project]`), r.stdout);
  assert.doesNotMatch(r.stderr, /not gitignored/);
});

test("`plan` warns when a configured worktree root inside the repo is not gitignored", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const env = { ...process.env, CREW_SCRIPTS: SCRIPTS, CREW_FAKE_DISPATCH: FAKE, MAIN_ROOT: root, CREW_WORKTREE_ROOT: "wt" };
  const r = sh("node", [MAIN, "plan", "--platform", "pi", "--feature-slug", "demo"], { cwd: root, env });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stdout, /worktrees: .*\/wt  \[CREW_WORKTREE_ROOT\]/);
  assert.match(r.stderr, /WARNING: worktree root wt is inside the repo but not gitignored/);
});

test("the sprint reports once, from disk, and the summary is the last thing printed", () => {
  // Three copies of the same content used to reach one context window: a per-round rollup
  // (`crew-summary.sh --no-reminder`), a verbatim echo of every worker report, and the
  // summary's per-issue detail. The wrap-up renders it once, and the findings reminder is
  // part of that single render — so it prints exactly once, last.
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-beta.md");
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);

  const rollups = r.stdout.match(/^Rounds: /gm) ?? [];
  assert.equal(rollups.length, 1, "the rollup is rendered once, not once per round");
  const reminders = r.stdout.match(/No open review findings\.|^## Next Step/gm) ?? [];
  assert.equal(reminders.length, 1, "the findings reminder prints exactly once");

  const tail = r.stdout.trim().split("\n");
  assert.equal(tail.at(-1), "NO MORE TASKS");
  // The pipeline's own narration goes to stderr; stdout is the one render, so the summary
  // is the whole of it.
  assert.equal(tail[0], "Rounds: 1", `stdout starts with something other than the summary:\n${r.stdout}`);
  assert.doesNotMatch(r.stdout, /^(RECEIPT|MERGE|Closed|Verifying)/m, "pipeline output leaked into the report");
  assert.doesNotMatch(r.stdout, /^## Issue: /m, "a worker report was echoed verbatim");
  assert.doesNotMatch(r.stdout, /^### Per-issue/m, "per-issue detail is a third copy of the state file");
});

test("a review that never ran is named in the summary, not just counted in the state", () => {
  // "advisory" must not degrade into "reported as clean": the gap is recorded with
  // promote-findings.sh mark-not-run and surfaced under its own heading, on every attempt —
  // including the one that escalates the repeat failure to blocked (see the previous test).
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.review", "");
  const r = runSprint(root);
  assert.match(r.stdout, /## Unreviewed Branches/);
  assert.match(r.stdout, /crew\/demo\/alpha/);
  assert.match(state(root).retention.alpha.reason, /^blocked — retry limit reached \(2 attempts\) — review-not-run — no report\.json — the reviewer never wrote its verdict file$/);
});

// ─── GitHub tracker backend wiring ────────────────────────────────────────────
//
// Regression for a gap the PRD's own Decisions section explicitly called for (callers
// "stop importing local.mjs directly and call through the factory instead") but no
// issue's acceptance criteria ever operationalised: main.mjs/loop.mjs/pipeline.mjs used
// to import tracker.mjs's static, local-only re-exports directly, so a repo configured
// for `tracker: github` still dispatched against local .scratch/ files — finding none —
// instead of ever calling into trackers/github.mjs. `gh` is stubbed on PATH; these tests
// pin that the wiring reaches it at all, not real GitHub behaviour (already covered by
// tracker-github.test.mjs).

function githubFixtureRepo() {
  const root = mkdtempSync(join(tmpdir(), "crew-sprint-gh-"));
  FIXTURE_ROOTS.push(root);
  const git = (...args) => sh("git", ["-C", root, ...args]);
  git("init", "-q", "-b", "main");
  git("config", "user.email", "t@test");
  git("config", "user.name", "T");
  writeFileSync(join(root, "Makefile"), "test:\n\t@echo ok\nlint:\n\t@echo ok\ntypecheck:\n\t@echo ok\n");
  writeFileSync(join(root, ".gitignore"), ".scratch/\n");
  mkdirSync(join(root, ".coding-crew/docs"), { recursive: true });
  writeFileSync(
    join(root, ".coding-crew/docs/issue-tracker.md"),
    "---\ntracker: github\n---\n\n# Issue tracker: GitHub Issues\n",
  );
  // close-issue.sh/promote-findings.sh look for tracker-config.sh at their own script dir,
  // then at .coding-crew/scripts/ (the installed layout), then at scripts/tracker/ (this
  // source tree) — none of which a bare fixture repo has, so without this copy every
  // lookup falls through to its own "missing means local" default, silently defeating the
  // very test this fixture exists for.
  mkdirSync(join(root, ".coding-crew/scripts"), { recursive: true });
  cpSync(join(REPO, "scripts/tracker/tracker-config.sh"), join(root, ".coding-crew/scripts/tracker-config.sh"));
  git("add", "-A");
  git("commit", "-q", "-m", "init");
  git("checkout", "-q", "-b", "feature/demo");
  mkdirSync(join(root, ".scratch/fake"), { recursive: true });
  return root;
}

/**
 * A fake `gh` on its own PATH-prepended dir: logs every invocation (one line per call) to
 * `gh.log` and answers just enough of the CLI surface a live sprint's dispatch loop and
 * close-issue.sh's github branch actually call — `issue list` from the fixture's own
 * `gh-issues.json` (mutated to `state: CLOSED` by `issue close`, so a second `listOpen`
 * fetch sees the closed state the same way a real re-fetch would), `issue view --json
 * body --jq .body` echoing that same issue's body, `issue close`/`issue comment` as
 * plain no-ops. Everything else exits 0 — this pins the wiring, not the full `gh` surface
 * (already covered by tracker-github.test.mjs / tracker-mark-done-github.bats).
 */
function stubGh(root, issues) {
  const stub = join(root, ".stub");
  mkdirSync(stub, { recursive: true });
  const log = join(root, "gh.log");
  writeFileSync(log, "");
  const issuesFile = join(root, "gh-issues.json");
  writeFileSync(issuesFile, JSON.stringify(issues));
  // The issues-file path is passed as a node argv, never interpolated into the -e source
  // itself — nesting a JSON.stringify()'d path *inside* an already-double-quoted `-e "..."`
  // string breaks out of bash's outer quoting the moment the path itself is unquoted
  // between the two halves, silently truncating the script (node then throws before ever
  // touching the file, node exits non-zero, but the wrapping `if` block still `exit 0`s —
  // so a write that never happened still reports success to the caller).
  const viewJs = "const fs=require('fs');const p=process.argv[1];const n=Number(process.argv[2]);" +
    "const issues=JSON.parse(fs.readFileSync(p,'utf8'));" +
    "process.stdout.write((issues.find(i=>i.number===n)||{}).body||'')";
  const closeJs = "const fs=require('fs');const p=process.argv[1];const n=Number(process.argv[2]);" +
    "const issues=JSON.parse(fs.readFileSync(p,'utf8'));const i=issues.find(x=>x.number===n);" +
    "if(i)i.state='CLOSED';fs.writeFileSync(p,JSON.stringify(issues))";
  // `issue create --title T --body-file F [--label L]…`: appended open, so the next list sees it.
  const createJs = "const fs=require('fs');const [p,...a]=process.argv.slice(1);" +
    "const issues=JSON.parse(fs.readFileSync(p,'utf8'));const v=(k)=>a[a.indexOf(k)+1];" +
    "const labels=a.flatMap((x,i)=>x==='--label'?[{name:a[i+1]}]:[]);" +
    "const number=Math.max(0,...issues.map(i=>i.number))+1;" +
    "issues.push({number,title:v('--title'),body:fs.readFileSync(v('--body-file'),'utf8'),labels,state:'OPEN'});" +
    "fs.writeFileSync(p,JSON.stringify(issues));process.stdout.write('https://github.com/o/r/issues/'+number+'\\n')";
  writeFileSync(
    join(stub, "gh"),
    [
      "#!/usr/bin/env bash",
      `echo "$@" >> ${JSON.stringify(log)}`,
      'if [ "$1" = "issue" ] && [ "$2" = "list" ]; then',
      `  cat ${JSON.stringify(issuesFile)}`,
      "  exit 0",
      "fi",
      'if [ "$1" = "issue" ] && [ "$2" = "view" ]; then',
      `  node -e ${JSON.stringify(viewJs)} ${JSON.stringify(issuesFile)} "$3"`,
      "  exit 0",
      "fi",
      'if [ "$1" = "issue" ] && [ "$2" = "create" ]; then',
      `  node -e ${JSON.stringify(createJs)} ${JSON.stringify(issuesFile)} "\${@:3}"`,
      "  exit 0",
      "fi",
      'if [ "$1" = "issue" ] && [ "$2" = "close" ]; then',
      `  node -e ${JSON.stringify(closeJs)} ${JSON.stringify(issuesFile)} "$3"`,
      "  exit 0",
      "fi",
      "exit 0",
      "",
    ].join("\n"),
  );
  chmodSync(join(stub, "gh"), 0o755);
  return { stub, log, issuesFile };
}

const GH_ALPHA = {
  number: 1,
  title: "alpha",
  body: "# alpha\n\n## Acceptance criteria\n\n- [x] alpha exists\n",
  labels: [{ name: "ready-for-agent" }],
  state: "OPEN",
};

const GH_PRD = {
  number: 9,
  title: "PRD: Demo",
  body: "# PRD\n\n- Export to CSV\n",
  labels: [],
  state: "OPEN",
};

test("plan resolves the github backend and lists a milestone issue instead of silently finding nothing", () => {
  const root = githubFixtureRepo();
  const { stub, log } = stubGh(root, [GH_ALPHA]);
  const r = sh("node", [MAIN, "plan", "--platform", "pi", "--feature-slug", "demo"], {
    cwd: root,
    env: { ...process.env, CREW_SCRIPTS: SCRIPTS, CREW_FAKE_DISPATCH: FAKE, PATH: `${stub}:${process.env.PATH}` },
  });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stdout, /dispatchable now \(1\):/);
  assert.match(r.stdout, /- alpha .*#1/);
  const calls = readFileSync(log, "utf8");
  assert.match(calls, /issue list .*--milestone demo/, "plan never called gh issue list at all");
});

test("a github-configured sprint dispatches, closes via gh, and stops finding work — the same live loop local runs through", () => {
  const root = githubFixtureRepo();
  const { stub, log } = stubGh(root, [GH_ALPHA]);
  const r = sh("node", [MAIN, "run", "--platform", "pi", "--feature-slug", "demo"], {
    cwd: root,
    env: {
      ...process.env,
      CREW_SCRIPTS: SCRIPTS,
      CREW_FAKE_DISPATCH: FAKE,
      CREW_FAKE_DIR: join(root, ".scratch/fake"),
      MAIN_ROOT: root,
      PATH: `${stub}:${process.env.PATH}`,
    },
  });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const calls = readFileSync(log, "utf8");
  assert.match(calls, /issue list .*--milestone demo/, "the dispatch loop never listed github issues");
  assert.match(calls, /issue close 1 /, "the issue was never closed via gh");
  assert.match(r.stdout, /NO MORE TASKS/);
});

test("github PRDAudit fix: the gaps issue, created ready-for-agent, is implemented in Phase 2", () => {
  // github has no parked state, so flush promotes nothing: the loop must go round on the
  // audit's own word, or the sprint ends stalled with the gaps issue open.
  // As to-prd publishes it: the milestone's open "PRD:" issue, and no local PRD.md.
  const root = githubFixtureRepo();
  const { stub, issuesFile } = stubGh(root, [GH_PRD, GH_ALPHA]);
  writeFileSync(join(root, ".scratch/fake/prd-audit.response"), AUDIT_WITH_GAP);
  const r = sh("node", [MAIN, "run", "--platform", "pi", "--feature-slug", "demo"], {
    cwd: root,
    env: {
      ...process.env,
      CREW_SCRIPTS: SCRIPTS,
      CREW_FAKE_DISPATCH: FAKE,
      CREW_FAKE_DIR: join(root, ".scratch/fake"),
      MAIN_ROOT: root,
      CREW_GITHUB_TRACKER_CLI: join(REPO, "orchestrator/lib/trackers/github.mjs"),
      PATH: `${stub}:${process.env.PATH}`,
    },
  });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const gaps = JSON.parse(readFileSync(issuesFile, "utf8")).find((i) => i.title === "Fix PRD gaps: demo");
  assert.ok(gaps, `defer-gaps never created the issue\n${traceLog(root)}`);
  assert.equal(gaps.state, "CLOSED", "the gaps issue was never implemented");
  assert.equal(traceLog(root).split("step=prd-audit").length - 1, 1, "one audit per sprint");
  assert.match(readFileSync(join(root, ".scratch/demo/prd-issue.md"), "utf8"), /Export to CSV/);
  assert.doesNotMatch(r.stdout, /Gaps not queued/);
});

test("a gaps issue that could not be created is named in the summary, not only the trace", () => {
  const root = githubFixtureRepo();
  const { stub } = stubGh(root, [GH_ALPHA]);
  mkdirSync(join(root, ".scratch/demo"), { recursive: true });
  writeFileSync(join(root, ".scratch/demo/PRD.md"), "# PRD\n\n- Export to CSV\n");
  writeFileSync(join(root, ".scratch/fake/prd-audit.response"), AUDIT_WITH_GAP);
  // No CREW_GITHUB_TRACKER_CLI and no install: defer-gaps cannot find github.mjs.
  const r = sh("node", [MAIN, "run", "--platform", "pi", "--feature-slug", "demo"], {
    cwd: root,
    env: {
      ...process.env,
      CREW_SCRIPTS: SCRIPTS,
      CREW_FAKE_DISPATCH: FAKE,
      CREW_FAKE_DIR: join(root, ".scratch/fake"),
      MAIN_ROOT: root,
      HOME: mkdtempSync(join(tmpdir(), "crew-home-")),
      CREW_GITHUB_TRACKER_CLI: "",
      PATH: `${stub}:${process.env.PATH}`,
    },
  });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stdout, /## PRD Audit/);
  assert.match(r.stdout, /\*\*Gaps not queued:\*\* 1 missing requirement\(s\), but the fix issue was not created: .*github\.mjs/);
});

// ─── eager dependency provisioning ───────────────────────────────────────────
//
// dep-install is failure-triggered, which is right for a human's direct solve-issue run.
// A sprint is the opposite case: every worktree is fresh, and one consumer of the deps is
// verify-worktree.sh — a gate, which cannot invoke a skill and has no recovery path when
// `npm test` dies on a missing module. So provisioning is mechanism, at two call sites,
// and what these tests pin is the *position* of those two calls in the recorded command
// order. Only a per-issue `DEPS: failed` changes a round's status: it stops that issue.

/** The effects log — one line per subprocess, in order. CREW_VERBOSE puts it on stderr. */
function commandLines(root, extra = [], { scripts = SCRIPTS, env = {}, platform = "pi" } = {}) {
  const r = sh("node", [MAIN, "run", "--platform", platform, "--feature-slug", "demo", ...extra], {
    cwd: root,
    env: {
      ...process.env,
      CREW_SCRIPTS: scripts,
      CREW_FAKE_DISPATCH: FAKE,
      CREW_FAKE_DIR: join(root, ".scratch/fake"),
      MAIN_ROOT: root,
      CREW_VERBOSE: "1",
      ...env,
    },
  });
  return { r, lines: r.stderr.split("\n").filter((l) => /^(RUN|SPAWN|DRY) /.test(l)) };
}

const SPRINT_LEVEL_DEPS = /ensure-deps\.sh --dir \S+$/;
const worktreeDepsFor = (slug) => new RegExp(`ensure-deps\\.sh --dir \\S+ --slug ${slug} --stem \\d+-${slug}$`);

test("deps are provisioned once per sprint and once per dispatched issue", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-beta.md");
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);

  // Once per sprint, against the main root: N parallel worktree installs must not be N
  // cold downloads, so the cache is warmed serially before any worker exists.
  assert.equal(lines.filter((l) => SPRINT_LEVEL_DEPS.test(l)).length, 1);
  // Once per dispatched issue, against that issue's worktree.
  assert.equal(lines.filter((l) => worktreeDepsFor("alpha").test(l)).length, 1);
  assert.equal(lines.filter((l) => worktreeDepsFor("beta").test(l)).length, 1);
});

test("the sprint-level call precedes every worker, and the worktree call precedes both its dispatch and its verify", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);

  const at = (re) => {
    const i = lines.findIndex((l) => re.test(l));
    assert.notEqual(i, -1, `no command matching ${re} in:\n${lines.join("\n")}`);
    return i;
  };
  const sprintDeps = at(SPRINT_LEVEL_DEPS);
  const worktreeDeps = at(worktreeDepsFor("alpha"));
  const worktreeAdd = at(/git .*worktree add/);
  const dispatch = at(/^SPAWN .*--agent crew-coder/);
  const verify = at(/verify-worktree\.sh --dir/);

  assert.ok(sprintDeps < worktreeAdd, "the sprint-level warm-up ran after a worktree existed");
  assert.ok(worktreeAdd < worktreeDeps, "the worktree was provisioned before it existed");
  assert.ok(worktreeDeps < dispatch, "the worker was dispatched into an unprovisioned worktree");
  assert.ok(
    worktreeDeps < verify,
    "verify-worktree.sh ran before deps — the gate has no recovery path of its own",
  );
});

test("a failed per-issue install stops the issue before the coder or verify runs", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const scripts = privateScripts();
  // Sprint-level warm-up (no --slug) succeeds; the issue's own worktree install fails.
  const real = join(scripts, "_real-ensure-deps.sh");
  cpSync(join(scripts, "ensure-deps.sh"), real);
  writeFileSync(
    join(scripts, "ensure-deps.sh"),
    ["#!/usr/bin/env bash", 'case " $* " in *" --slug "*) echo "DEPS: failed npm ci (exit 1)"; exit 0 ;; esac', `exec bash ${JSON.stringify(real)} "$@"`, ""].join("\n"),
  );

  const { r, lines } = commandLines(root, ["--max-rounds", "1"], { scripts });
  assert.equal(lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length, 0, "the coder ran on an unprovisioned worktree");
  assert.equal(lines.filter((l) => /verify-worktree\.sh --dir/.test(l)).length, 0, "verify ran on an unprovisioned worktree");
  assert.match(`${r.stdout}\n${r.stderr}`, /dependency install failed — failed npm ci \(exit 1\)/);
  assert.deepEqual(state(root).completed_slugs ?? [], []);
});

test("command discovery precedes the sprint-level deps call, so a discovered install override is on disk before ensure-deps.sh's first read", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);

  const at = (re) => {
    const i = lines.findIndex((l) => re.test(l));
    assert.notEqual(i, -1, `no command matching ${re} in:\n${lines.join("\n")}`);
    return i;
  };
  const discovery = at(/discover-commands\.sh$/);
  const cacheWrite = at(/write-commands-cache\.sh --response-file/);
  const sprintDeps = at(SPRINT_LEVEL_DEPS);

  assert.ok(discovery < sprintDeps, "the sprint-level deps call ran before commands were discovered");
  assert.ok(cacheWrite < sprintDeps, "the sprint-level deps call ran before the discovery cache was written");
});

test("a discovered install override is used by the sprint-level deps call, not host-install.sh's own guess", () => {
  // fixtureRepo()'s Makefile has no install/deps target and there is no package.json, so
  // without the discovered override this repo's own dependency step would be DEPS: none.
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(
    root,
    "commands.response",
    '{"test": "make test", "lint": "make lint", "typecheck": "make typecheck", "install": "mkdir -p .scratch && touch .scratch/install-ran.marker"}',
  );

  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);

  const cache = JSON.parse(readFileSync(join(root, ".coding-crew/dev-commands.json"), "utf8"));
  assert.equal(cache.install, "mkdir -p .scratch && touch .scratch/install-ran.marker");
  assert.equal(existsSync(join(root, ".scratch/install-ran.marker")), true, "the discovered install command never ran against MAIN_ROOT");
  assert.match(traceLog(root), /\[DEPS\].*installed.*touch \.scratch\/install-ran\.marker/);
});

test("Sprint.installDeps streams ensure-deps.sh's own live output, each line exactly once, then the DEPS summary exactly once", async () => {
  // ensure-deps.sh's own CACHED_INSTALL/docker paths now tee their child's output live (see
  // ensure-deps.sh/docker-install.sh), and installDeps() now streams that through the log
  // callback via spawnWithTimeout's onLine instead of capturing it wholesale and reporting
  // one summary line after the fact — this used to produce zero visible output for however
  // long a real install took. A fake effects.spawnWithTimeout stands in for the real
  // subprocess here, split across two chunks with a line broken mid-chunk, to exercise the
  // buffering logic the same way a real, arbitrarily-chunked stdout stream would.
  const logged = [];
  const fakeEffects = {
    mainRoot: "/fake/root",
    script: (name) => `/fake/scripts/${name}`,
    spawnWithTimeout: async (cmd, args, { onLine } = {}) => {
      onLine("installing-widget-a\ninstall");
      onLine("ing-widget-b\nDEPS: installed echo\n");
      return { code: 0, stdout: "installing-widget-a\ninstalling-widget-b\nDEPS: installed echo\n", stderr: "" };
    },
  };
  const sprint = new Sprint(fakeEffects, {});

  await sprint.installDeps((line) => logged.push(line));

  assert.deepEqual(logged, ["installing-widget-a", "installing-widget-b", "DEPS: installed echo"]);
});

test("the worktree call comes after .worktreeinclude is applied, so an inherited dep dir costs nothing", () => {
  // The presence guard is what makes a .worktreeinclude repo free, and it can only see a
  // linked node_modules if the include has already run.
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  writeFileSync(join(root, ".worktreeinclude"), "node_modules\n");
  writeFileSync(join(root, "package.json"), '{ "name": "fixture", "private": true }\n');
  mkdirSync(join(root, "node_modules"), { recursive: true });
  sh("git", ["-C", root, "add", "-A"]);
  sh("git", ["-C", root, "commit", "-q", "-m", "add package.json"]);

  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const include = lines.findIndex((l) => /worktreeinclude|rsync|cp -R/.test(l));
  const deps = lines.findIndex((l) => worktreeDepsFor("alpha").test(l));
  if (include !== -1) assert.ok(include < deps, "deps were provisioned before the include ran");
  assert.match(traceLog(root), /\[DEPS\].*present/);
});

test("--no-deps removes both invocations and nothing else", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const withDeps = commandLines(root);
  assert.equal(withDeps.r.code, 0, withDeps.r.stderr);

  const root2 = fixtureRepo();
  addIssue(root2, "01-alpha.md");
  const without = commandLines(root2, ["--no-deps"]);
  assert.equal(without.r.code, 0, `${without.r.stdout}\n${without.r.stderr}`);

  assert.equal(without.lines.filter((l) => /ensure-deps\.sh/.test(l)).length, 0);
  // Nothing else changes: the same sequence of scripts, minus the two deps calls.
  const names = (lines) =>
    lines
      .map((l) => (/([\w-]+\.sh)/.exec(l) ?? [])[1] ?? (/--agent (\S+)/.exec(l) ?? [])[1] ?? "git")
      .filter((n) => n !== "ensure-deps.sh");
  assert.deepEqual(names(without.lines), names(withDeps.lines));
});

test("a DEPS: failed outcome blocks the issue at that step, without crashing the sprint", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  // A manifest with no dep dir, plus a dep-install stub whose host install always fails.
  writeFileSync(join(root, "package.json"), '{ "name": "fixture", "private": true }\n');
  const stub = join(root, "stub-scripts");
  mkdirSync(stub, { recursive: true });
  writeFileSync(join(stub, "detect-mode.sh"), "#!/usr/bin/env bash\necho USE_HOST\n");
  writeFileSync(join(stub, "host-install.sh"), "#!/usr/bin/env bash\necho 'npm ERR! boom' >&2\nexit 3\n");
  sh("chmod", ["+x", join(stub, "detect-mode.sh"), join(stub, "host-install.sh")]);
  sh("git", ["-C", root, "add", "package.json"]);
  sh("git", ["-C", root, "commit", "-q", "-m", "add package.json"]);

  const r = sh("node", [MAIN, "run", "--platform", "pi", "--feature-slug", "demo"], {
    cwd: root,
    env: {
      ...process.env,
      CREW_SCRIPTS: SCRIPTS,
      CREW_FAKE_DISPATCH: FAKE,
      CREW_FAKE_DIR: join(root, ".scratch/fake"),
      MAIN_ROOT: root,
      CREW_DEP_INSTALL_SCRIPTS: stub,
    },
  });
  // Stalled (exit 2), not crashed: the issue is blocked with the install's own reason.
  assert.equal(r.code, 2, `${r.stdout}\n${r.stderr}`);
  assert.match(traceLog(root), /\[DEPS\].*failed/);
  const s = state(root);
  assert.deepEqual(s.completed_slugs ?? [], []);
  assert.deepEqual(s.merged_branches ?? [], []);
  assert.match(r.stdout, /Blocked \(1\): alpha/);
  assert.match(readFileSync(join(root, ".scratch/demo/issues/open/01-alpha.md"), "utf8"), /dependency install failed/);
});

test("the orchestrator prints one line per deps call — the DEPS: line itself, slug/round-tagged", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const { r } = commandLines(root);
  assert.equal(r.code, 0, r.stderr);
  const printed = r.stderr.split("\n").filter((l) => /\bDEPS:/.test(l));
  assert.equal(printed.length, 2, `expected one line per call, got:\n${printed.join("\n")}`);
  // The per-issue call (not the sprint-level bootstrap one) is slug/round-tagged, so it can
  // be attributed to the right issue and round when interleaved with other issues' output.
  assert.ok(
    printed.some((l) => /^slug=alpha round=1 DEPS:/.test(l)),
    `expected a slug/round-tagged DEPS: line, got:\n${printed.join("\n")}`,
  );
});

test("the orchestrator prints a [STEP] marker before each gate, slug/round-tagged", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const steps = r.stderr.split("\n").filter((l) => l.startsWith("[STEP]") && l.includes("slug=01-alpha"));
  // Every gate this clean issue passes through, in the order pipeline.mjs runs them,
  // with no dispatch-triage marker since verify never fails on this path.
  assert.deepEqual(
    steps.map((l) => /step=([\w-]+)/.exec(l)?.[1]),
    ["worktree", "deps", "dispatch-coder", "verify", "dispatch-review", "merge", "close"],
    steps.join("\n"),
  );
  for (const l of steps) assert.match(l, /^\[STEP\] slug=01-alpha round=1 step=[\w-]+( model=\S+ runtime=\S+)?$/, l);
});

test("a dispatch's throttled [TOOL] heartbeat stays off stderr unless CREW_VERBOSE, and is never re-logged", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.heartbeat", "");
  const r = runSprint(root, [], { CREW_VERBOSE: "" });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.doesNotMatch(r.stderr, /fake-heartbeat/, "a launcher agent reading stderr pays for every heartbeat");
  // The dispatcher already wrote its own lines to the trace log; the orchestrator adds none.
  assert.doesNotMatch(traceLog(root), /slug=01-alpha round=1 \[TOOL\]/);
});

test("CREW_VERBOSE puts the heartbeat on stderr, slug/round-tagged", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.heartbeat", "");
  const r = runSprint(root, [], { CREW_VERBOSE: "1" });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const heartbeats = r.stderr.split("\n").filter((l) => l.includes("fake-heartbeat"));
  assert.ok(heartbeats.length >= 1, `expected a heartbeat line reaching stderr:\n${r.stderr}`);
  for (const l of heartbeats) assert.match(l, /^slug=01-alpha round=1 \[TOOL\] agent=\S+ tool=fake-heartbeat/, l);
});

test("--no-deps and the help text are declared together, so the flag is discoverable", () => {
  const help = sh("node", [MAIN, "--help"], { cwd: REPO });
  assert.equal(help.code, 0, help.stderr);
  assert.match(help.stdout, /--no-deps/);
  const source = readFileSync(MAIN, "utf8");
  assert.match(source, /^ \*\s+--no-deps\s/m, "the header comment's option list omits --no-deps");
});

test("a dry run records both call sites without running either", () => {
  // Recorded, not run: --dry-run is the zero-token way to inspect the command sequence, so
  // the two positions have to be visible there too, not only on a live sprint.
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  // A dry run cannot create the sprint it inspects — session-init.sh is itself an effect.
  sh("bash", [join(SCRIPTS, "session-init.sh"), "--feature-slug", "demo"], {
    cwd: root,
    env: { ...process.env, MAIN_ROOT: root, CREW_SCRIPTS: SCRIPTS },
  });

  const r = sh("node", [MAIN, "run", "--dry-run", "--max-rounds", "1", "--platform", "pi", "--feature-slug", "demo"], {
    cwd: root,
    env: {
      ...process.env,
      CREW_SCRIPTS: SCRIPTS,
      CREW_FAKE_DISPATCH: FAKE,
      CREW_FAKE_DIR: join(root, ".scratch/fake"),
      MAIN_ROOT: root,
      CREW_VERBOSE: "1",
    },
  });
  const dry = r.stderr.split("\n").filter((l) => l.startsWith("DRY "));
  assert.equal(dry.filter((l) => SPRINT_LEVEL_DEPS.test(l)).length, 1, r.stderr);
  assert.equal(dry.filter((l) => worktreeDepsFor("alpha").test(l)).length, 1, r.stderr);
  // Recorded only: no install ran, so no marker and no dep dir appeared anywhere.
  assert.equal(existsSync(join(root, ".scratch/demo/dispatch/alpha.deps.ok")), false);
  assert.equal(existsSync(join(root, ".scratch/demo/dispatch/alpha.deps.skip")), false);
});

test("a worktree that starts with no node_modules is verified and merged, with no worker recovery", () => {
  // The failure this whole feature exists for, reproduced: verify-worktree.sh runs the
  // project's own check in the worktree, the check needs the dep dir, and the gate has no
  // way to install it. Before eager provisioning this round ended `verification-failed`
  // with the branch retained and nothing merged, however healthy the worker's report was.
  //
  // The fixture's dependency step is its own `make install`, which is the first thing
  // host-install.sh looks for — so this exercises the real detect-mode → host-install path
  // with no network and no package registry in the loop.
  const files = {
    Makefile: [
      "install:",
      "\t@mkdir -p node_modules && touch node_modules/.stamp",
      // The check *is* the assertion: it can only pass if something installed deps first.
      "test:",
      "\t@test -f node_modules/.stamp && echo ok",
      "lint:",
      "\t@echo ok",
      "typecheck:",
      "\t@echo ok",
      "",
    ].join("\n"),
    "package.json": '{ "name": "fixture", "version": "1.0.0", "private": true }\n',
    ".gitignore": ".scratch/\nnode_modules/\n",
  };
  const seed = (root) => {
    for (const [name, body] of Object.entries(files)) writeFileSync(join(root, name), body);
    sh("git", ["-C", root, "add", "-A"]);
    sh("git", ["-C", root, "commit", "-q", "-m", "add a dependency step"]);
  };

  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  seed(root);
  assert.equal(existsSync(join(root, "node_modules")), false, "the fixture must start bare");

  // Pinned to this source tree's own dep-install scripts, not whatever a contributor's local
  // .coding-crew self-install happens to have on disk (_find_dep_scripts prefers that over
  // skills/dep-install/scripts when neither is stubbed) — otherwise this test's outcome
  // depends on which release .coding-crew was last installed from, not on this source.
  const depScripts = { env: { CREW_DEP_INSTALL_SCRIPTS: join(REPO, "skills/dep-install/scripts") } };
  const r = commandLines(root, [], depScripts);
  assert.equal(r.r.code, 0, `${r.r.stdout}\n${r.r.stderr}`);
  const s = state(root);
  assert.deepEqual(s.completed_slugs, ["alpha"], "the branch did not merge — see the DEPS: line");
  assert.deepEqual(s.merged_branches, ["crew/demo/alpha"]);
  // Provisioned by the pipeline, not recovered from by the worker.
  assert.match(traceLog(root), /\[DEPS\].*installed.*make install/);
  assert.match(traceLog(root), /\[VERIFY\].*result=pass/);

  // And with --no-deps the same repo fails at the gate, which is what makes the above a
  // result of the two call sites rather than of anything else in the fixture.
  const root2 = fixtureRepo();
  addIssue(root2, "01-alpha.md");
  seed(root2);
  const off = commandLines(root2, ["--no-deps"], depScripts);
  assert.equal(off.r.code, 2, "without deps the issue never passes verify, so it spends both attempts and blocks");
  assert.deepEqual(state(root2).merged_branches ?? [], []);
  assert.equal(state(root2).retention.alpha.reason, "blocked — retry limit reached (2 attempts) — verification-failed");

  // The retry cap is per invocation, not permanent: crew-summary.sh tells a human to
  // "resolve blockers and re-run" for exactly this reason. Drop --no-deps (the "fix") and
  // re-run — a blocked issue must still be picked up and given a fresh attempt budget, not
  // skipped forever because a *prior* process already spent its two attempts.
  const retry = commandLines(root2, [], depScripts);
  assert.equal(retry.r.code, 0, `${retry.r.stdout}\n${retry.r.stderr}`);
  assert.deepEqual(state(root2).completed_slugs, ["alpha"]);
  assert.deepEqual(state(root2).blocked_slugs ?? [], []);
});

// ─── one-time command discovery ───────────────────────────────────────────────
//
// discover-commands.sh / write-commands-cache.sh mechanically build the prompt and persist
// the answer; the model call itself is faked here (fake-dispatch.sh's "commands-discovery"
// branch), exactly the seam the PRD audit already uses for the same reason.

test("command discovery writes .coding-crew/dev-commands.json from the repo's own Makefile", () => {
  const root = fixtureRepo(); // fixtureRepo() always seeds a Makefile with test/lint/typecheck
  addIssue(root, "01-alpha.md");

  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);

  const cacheFile = join(root, ".coding-crew/dev-commands.json");
  assert.equal(existsSync(cacheFile), true);
  const cache = JSON.parse(readFileSync(cacheFile, "utf8"));
  assert.equal(cache.test, "make test");
  assert.equal(cache.lint, "make lint");
  assert.equal(cache.typecheck, "make typecheck");
  assert.equal(cache.sourceHash, undefined, "the committed cache has no sourceHash field");
  assert.deepEqual(
    Object.keys(cache).sort(),
    ["coverage", "credential_target", "env", "install", "integration", "lint", "test", "typecheck"],
  );
});

test("a CLAUDE.md that happens to contain the word 'skipped' does not silently cancel discovery", () => {
  // Regression: commands.mjs used to test /skipped/i against discover-commands.sh's *entire*
  // stdout, which is the whole prompt plus every quoted candidate file's content, not just
  // discover-commands.sh's own one-line skip message. A real AGENTS.md/CLAUDE.md quoted in
  // full (one real repo's own docs said "...because I skipped this; don't repeat the mistake.")
  // made that regex match, so the step silently returned before ever calling the model —
  // no dispatch, no commands-response.md, no commands.json, and no log line to explain why,
  // because the short-circuit fires before any of the branches that do log.
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  writeFileSync(
    join(root, "CLAUDE.md"),
    "Typecheck: `make tsc`. PR #149 shipped a bug because I skipped this; don't repeat it.\n",
  );

  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(existsSync(join(root, ".coding-crew/dev-commands.json")), true, "the word 'skipped' inside a quoted file must not cancel discovery");
  assert.doesNotMatch(r.stderr, /Command discovery: skipped/);
});

test("command discovery's own log lines survive in the trace log, not just the live terminal", () => {
  // Runs once, unattended, before any worktree exists -- a bad model response or a dispatch
  // failure here was previously visible only in whatever captured the live process's stderr.
  // No artifact was left to diagnose it from afterwards, unlike every other pipeline step.
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");

  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stderr, /Command discovery:/);
  assert.match(traceLog(root), /Command discovery:/);
});

test("command discovery is skipped, at zero cost, when there is nothing to read", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  // discover-commands.sh reads the working directory, not git history — removing the
  // Makefile here does not affect the worktree verify-worktree.sh checks out from HEAD,
  // so this isolates the discovery step from the rest of the pipeline.
  unlinkSync(join(root, "Makefile"));

  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(existsSync(join(root, ".coding-crew/dev-commands.json")), false);
  assert.match(r.stderr, /Command discovery: skipped/);
});

test("a second sprint reuses the cached commands instead of discovering again (bootstrap-once, no staleness re-check)", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const first = runSprint(root);
  assert.equal(first.code, 0, `${first.stdout}\n${first.stderr}`);
  const cacheAfterFirst = readFileSync(join(root, ".coding-crew/dev-commands.json"), "utf8");

  // Even a source-doc change between sprints must not trigger re-discovery: once the
  // committed cache exists, only --refresh forces a rebuild.
  writeFileSync(join(root, "Makefile"), "test:\n\t@echo totally-different-now\n");

  addIssue(root, "02-beta.md");
  const second = runSprint(root);
  assert.equal(second.code, 0, `${second.stdout}\n${second.stderr}`);
  assert.match(second.stderr, /already cached/);
  assert.equal(readFileSync(join(root, ".coding-crew/dev-commands.json"), "utf8"), cacheAfterFirst);
});

test("CREW_COMMANDS_REFRESH=1 forces rediscovery and overwrites an existing cache", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const first = runSprint(root);
  assert.equal(first.code, 0, `${first.stdout}\n${first.stderr}`);
  const cacheAfterFirst = readFileSync(join(root, ".coding-crew/dev-commands.json"), "utf8");

  writeFileSync(join(root, "Makefile"), "totally-different-now:\n\t@echo ok\nlint2:\n\t@echo ok\ntc2:\n\t@echo ok\n");
  sh("git", ["-C", root, "add", "-A"]);
  sh("git", ["-C", root, "commit", "-q", "-m", "new makefile targets"]);
  fake(
    root,
    "commands.response",
    '{"test": "make totally-different-now", "lint": "make lint2", "typecheck": "make tc2"}',
  );

  addIssue(root, "02-beta.md");
  const second = sh("node", [MAIN, "run", "--platform", "pi", "--feature-slug", "demo"], {
    cwd: root,
    env: {
      ...process.env,
      CREW_SCRIPTS: SCRIPTS,
      CREW_FAKE_DISPATCH: FAKE,
      CREW_FAKE_DIR: join(root, ".scratch/fake"),
      MAIN_ROOT: root,
      CREW_COMMANDS_REFRESH: "1",
    },
  });
  assert.equal(second.code, 0, `${second.stdout}\n${second.stderr}`);
  assert.doesNotMatch(second.stderr, /already cached/);
  const cacheAfterSecond = readFileSync(join(root, ".coding-crew/dev-commands.json"), "utf8");
  assert.notEqual(cacheAfterSecond, cacheAfterFirst);
  assert.match(cacheAfterSecond, /make totally-different-now/);
});

test("--no-commands skips command discovery entirely", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");

  const r = runSprint(root, ["--no-commands"]);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(existsSync(join(root, ".coding-crew/dev-commands.json")), false);
  assert.doesNotMatch(r.stderr, /Command discovery/);
});

test("discover-commands.sh failing outright is surfaced and does not send a broken prompt onward", () => {
  // Regression: commands.mjs used to check only the model dispatch's exit code, not
  // discover-commands.sh's own — a crash there (e.g. a candidate file going unreadable
  // mid-run) fell through into dispatching whatever partial/garbage stdout survived, as if
  // it were a real prompt, with no error left anywhere to diagnose it from. CLAUDE.md is
  // untracked and lives only in the main checkout, so making it unreadable cannot also
  // break the worktree's own git status (unlike doing the same to the tracked Makefile).
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  writeFileSync(join(root, "CLAUDE.md"), "test: npm test\n");
  chmodSync(join(root, "CLAUDE.md"), 0o000);

  const r = runSprint(root);
  chmodSync(join(root, "CLAUDE.md"), 0o644); // restore before any cleanup touches it
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`); // advisory: never fails the sprint
  assert.equal(existsSync(join(root, ".coding-crew/dev-commands.json")), false);
  assert.match(r.stderr, /Command discovery: discover-commands\.sh failed/);
});

// Regression: a bare word that is neither a recognised flag nor a .scratch/ path used to
// be forwarded unexamined through Sprint.init into session-init.sh, then into
// feature-branch-setup.sh (--jira only), which died with a confusing "Unknown argument"
// two hops from where the mistake was made. It must now be rejected here, immediately,
// before any script even runs.
test("an unrecognized bare argument fails fast with the accepted forms, not two hops down", () => {
  const root = fixtureRepo();
  const r = sh("node", [MAIN, "run", "--platform", "pi", "qa-slo-emmission"], {
    cwd: root,
    env: { ...process.env, MAIN_ROOT: root },
  });
  assert.equal(r.code, 1);
  assert.match(r.stderr, /unrecognized argument: qa-slo-emmission/);
  assert.match(r.stderr, /Accepted forms: --feature-slug/);
  assert.doesNotMatch(r.stderr, /session-init\.sh/);
  assert.doesNotMatch(r.stderr, /Unknown argument/); // feature-branch-setup.sh's own message
});

test("an unrecognized argument close to an existing .scratch/<feature-slug> dir is suggested", () => {
  const root = fixtureRepo(); // fixtureRepo() already creates .scratch/demo/
  const r = sh("node", [MAIN, "run", "--platform", "pi", "deno"], {
    cwd: root,
    env: { ...process.env, MAIN_ROOT: root },
  });
  assert.equal(r.code, 1);
  assert.match(r.stderr, /Did you mean --feature-slug demo\?/);
});

test("free-form prose fails on the first unrecognized word, still with a helpful message", () => {
  const root = fixtureRepo();
  const r = sh("node", [MAIN, "run", "--platform", "pi", "on", "issues", "under", "qa-slo-emmission"], {
    cwd: root,
    env: { ...process.env, MAIN_ROOT: root },
  });
  assert.equal(r.code, 1);
  assert.match(r.stderr, /unrecognized arguments: on issues under qa-slo-emmission/);
});

test("a legitimate --jira value is not treated as an unrecognized argument", () => {
  const root = fixtureRepo();
  const r = sh("node", [MAIN, "plan", "--platform", "pi", "--jira", "ABC-123"], {
    cwd: root,
    env: { ...process.env, MAIN_ROOT: root },
  });
  assert.doesNotMatch(r.stderr, /unrecognized argument/);
});
