/**
 * sprint.suite.mjs — the state machine end to end, with every model dispatch faked.
 *
 * These are the assertions the deleted prose used to make about itself: a clean issue
 * merges and closes, a failing check never merges, an unmet criteria verdict never
 * merges, a review that did not happen is a gap rather than a clean pass, and two dry
 * rounds stall instead of looping forever.
 *
 * Run through the sprint-<k>.test.mjs entry files, each of which runs every Nth test: these
 * tests are synchronous and each drives a whole faked sprint, so one file ran them one at a
 * time — 80s on Linux, ~20 minutes under Git Bash. `node --test` runs files in parallel.
 */

import { test as nodeTest, after } from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { chmodSync, cpSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync, existsSync, unlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { Sprint } from "../../orchestrator/lib/sprint.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = join(HERE, "../..");
const MAIN = join(REPO, "orchestrator/main.mjs");

// Resolved once: on macOS (and some Windows runners) os.tmpdir() is a symlink/short-name
// path (/var/folders/... -> /private/var/folders/...), but a child process's cwd is
// reported back canonicalized — `git rev-parse --show-toplevel` (main.mjs's gitRoot())
// returns the OS's resolved getcwd(), not the string a test passed as `cwd`. Building every
// fixture root from the already-resolved base keeps test-side path strings identical to
// what the orchestrator prints, instead of only matching on Linux where /tmp isn't a symlink.
const TMPDIR = realpathSync(tmpdir());

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
// The `.coding-crew/` an installed orchestrator would sit in (CREW_INSTALL_DIR): this source
// tree's orchestrator/ has no installed assets beside it, so every run points here instead.
const INSTALL_DIR = join(SCRIPTS_BASE, "install");
cpSync(join(REPO, "agents/crew-reviewer/assets"), join(INSTALL_DIR, "code-review"), { recursive: true });
cpSync(join(REPO, "skills/dep-install/scripts"), join(INSTALL_DIR, "dep-install/scripts"), { recursive: true });
cpSync(join(REPO, "skills/solve-issue/scripts"), join(INSTALL_DIR, "solve-issue/scripts"), { recursive: true });
const FAKE = join(HERE, "fixtures/fake-dispatch.sh");

// The slice this process runs, set by the entry file that imported this module; no slice
// runs everything. Round-robin, so neighbouring (similarly sized) tests spread out.
const [SLICE, SLICES] = (globalThis.SPRINT_SLICE ?? "1/1").split("/").map(Number);
let testSeq = 0;
function test(...args) {
  if (testSeq++ % SLICES === SLICE - 1) nodeTest(...args);
}

// Every call site below spreads process.env into its own `env` (or omits `env` and gets
// it by default); this test's own process inherits CREW_PANE_HOST, HERDR_ENV/HERDR_PANE_ID (or
// ORCA_ENV/ORCA_TERMINAL_HANDLE) whenever it runs inside a real herdr/orca pane, and
// main.mjs's notifyTriggeringPane sends the fixture sprint's outcome straight to that real
// pane if those leak through — stripped here, once, so no call site has to remember to.
//
// HOME likewise: a real ~/.coding-crew/config.json would retarget every fixture sprint's roles,
// so an inherited HOME is swapped for an empty one. A test that sets its own HOME keeps it.
const EMPTY_HOME = mkdtempSync(join(TMPDIR, "crew-sprint-home-"));
after(() => rmSync(EMPTY_HOME, { recursive: true, force: true }));
function sh(cmd, args, opts = {}) {
  const env = { ...(opts.env ?? process.env) };
  if (env.HOME === process.env.HOME) env.HOME = EMPTY_HOME;
  if (env.CREW_INSTALL_DIR === process.env.CREW_INSTALL_DIR) env.CREW_INSTALL_DIR = INSTALL_DIR;
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
  const root = mkdtempSync(join(TMPDIR, "crew-sprint-"));
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

// The baseline (preflight.mjs) runs the checks once more before any dispatch; the per-issue
// tests below count those calls, so the helpers leave it out unless a test asks for it.
const NO_BASELINE = ["--no-baseline"];

function runSprint(root, extra = [], env = {}, { baseline = false } = {}) {
  return sh("node", [MAIN, "run", "--platform", "pi", "--feature-slug", "demo", ...(baseline ? [] : NO_BASELINE), ...extra], {
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
  const home = mkdtempSync(join(TMPDIR, "crew-home-"));
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
  assert.equal(existsSync(join(root, ".scratch/demo/dispatch/01-alpha/verify.json")), true);
  assert.equal(existsSync(join(root, ".scratch/demo/dispatch/01-alpha/ac.ok")), true);
  assert.match(r.stdout, /NO MORE TASKS/);
  // The reviewer was handed the verification result, so a criterion that ends "and the
  // tests pass" is answerable by the read-only reviewer instead of stalling the branch.
  const reviewPromptText = readFileSync(join(root, ".scratch/demo/dispatch/01-alpha/review-prompt.md"), "utf8");
  assert.match(reviewPromptText, /Checks already run by the pipeline/);
  assert.match(reviewPromptText, /test=pass/);
  // The install this run resolved, once — the reviewer never searches for its assets.
  assert.ok(reviewPromptText.includes(`Review assets: ${join(INSTALL_DIR, "code-review")}\n`), reviewPromptText);
  // Nor the coder for the project's config, which its worktree does not hold.
  const coderPromptText = readFileSync(join(root, ".scratch/demo/dispatch/01-alpha/prompt.md"), "utf8");
  assert.ok(coderPromptText.includes(`Project config: ${join(root, ".coding-crew")} `), coderPromptText);
});

test("a run whose install is missing an asset stops before any dispatch, naming the path", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const partial = mkdtempSync(join(TMPDIR, "crew-install-"));
  FIXTURE_ROOTS.push(partial);
  cpSync(join(INSTALL_DIR, "dep-install"), join(partial, "dep-install"), { recursive: true });
  cpSync(join(INSTALL_DIR, "solve-issue"), join(partial, "solve-issue"), { recursive: true });
  const r = runSprint(root, [], { CREW_INSTALL_DIR: partial });
  assert.equal(r.code, 1, `${r.stdout}\n${r.stderr}`);
  assert.ok(r.stderr.includes(`reviewer: ${join(partial, "code-review/scripts/review-context.sh")}`), r.stderr);
  assert.match(r.stderr, /Re-run install\.sh/);
  assert.doesNotMatch(r.stderr, /depInstall:|solveIssue:/);
  assert.equal(existsSync(join(root, ".scratch/demo/dispatch")), false, "nothing was dispatched");
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
  const reviewPromptText = readFileSync(join(root, ".scratch/demo/dispatch/01-alpha/review-prompt.md"), "utf8");
  assert.match(reviewPromptText, /coverage=pass \(full output: [^)]*verify-coverage\.log, \d+ lines\)/);
  // The worker never mentioned coverage; the gate ran it from the cache anyway. integration is
  // `null` there, and the reviewer is told so rather than left to infer it from what is absent.
  assert.doesNotMatch(reviewPromptText, /integration=/);
  assert.match(reviewPromptText, /Not run by the pipeline, no command configured: integration/);
  assert.match(reviewPromptText, /The gate's own record of that run: \S+\/01-alpha\/verify\.json/);
  // The logs live beside the record, so they outlive the worktree.
  assert.match(reviewPromptText, /coverage=pass \(full output: \S+\/dispatch\/01-alpha\/verify-coverage\.log, \d+ lines\)/);
  assert.equal(existsSync(join(root, ".scratch/demo/dispatch/01-alpha/verify-coverage.log")), true);
});

const WORKER_LINT_NOT_RUN = [
  "## Issue: alpha", "Status: complete", "", "```json",
  '{"status":"complete","checks":{"test":"pass","lint":"not_run","typecheck":"pass"},"progress":""}', "```",
].join("\n");

test("a coder's own not_run is no coverage gap when verify ran every check clean", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.worker", WORKER_LINT_NOT_RUN);
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(state(root).coverage_gaps?.alpha, undefined);
});

test("a gap verify itself reports is recorded", () => {
  const root = fixtureRepo();
  mkdirSync(join(root, ".coding-crew"), { recursive: true });
  writeFileSync(
    join(root, ".coding-crew/dev-commands.json"),
    JSON.stringify({ test: "make test", lint: null, typecheck: "make typecheck", coverage: null, integration: null }),
  );
  sh("git", ["-C", root, "add", "-A"]);
  sh("git", ["-C", root, "commit", "-q", "-m", "cache"]);
  fake(root, "commands.response", '{"install": null, "env": null, "credential_target": null}');
  addIssue(root, "01-alpha.md");
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(state(root).coverage_gaps?.alpha, "LINT");
});

test("a clean verify clears a gap an earlier round recorded", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  mkdirSync(join(root, ".scratch/demo"), { recursive: true });
  writeFileSync(join(root, ".scratch/demo/sprint-state.json"), JSON.stringify({ coverage_gaps: { alpha: "lint" } }));
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(state(root).coverage_gaps?.alpha, undefined);
});

test("a worker-reported failing check with commits is overruled by verify, not retried", () => {
  // verify-worktree.sh runs every check itself; the coder's own report is a claim.
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(
    root,
    "alpha.worker",
    ['## Issue: alpha', 'Status: complete', '', '```json', '{"status":"complete","checks":{"test":"fail","lint":"pass","typecheck":"pass"},"progress":"tests red"}', '```'].join("\n"),
  );
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.deepEqual(state(root).completed_slugs, ["alpha"]);
  assert.match(traceLog(root), /\[PREFILTER-OVERRULED\] slug=alpha round=1 — the coder reported reported checks failed: test/);
  assert.equal(lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length, 1, "one coder dispatch — verify decided");
});

test("a worker-reported failing check with no commits is demoted and never merges", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.nocommit");
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
  // Nothing committed: a partial with commits is a claim the gates judge instead.
  fake(root, "alpha.nocommit");
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
  assert.equal(existsSync(join(root, ".scratch/demo/dispatch/01-alpha/ac.ok")), false);
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
  assert.match(traceLog(root), /\[SKIP-WORKER\] slug=alpha reason=review-not-run branch=\S+ — .*verify already passed at this commit — review only/);
  // The commit round 2 reviews is the one round 1 verified: its receipt stands.
  assert.equal(lines.filter((l) => /verify-worktree\.sh --dir/.test(l)).length, 1);
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
  const prompt = readFileSync(join(root, `.scratch/demo/dispatch/${loser === "alpha" ? "01" : "02"}-${loser}/prompt.md`), "utf8");
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
    const prompt = readFileSync(join(root, ".scratch/demo/dispatch/01-alpha/prompt.md"), "utf8");
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

const unmetReview = (extra = {}) =>
  `## Branch: crew/demo/alpha\n\`\`\`json\n${JSON.stringify({ branch: "crew/demo/alpha", slug: "alpha", verdict: "unmet", detail: "no test covers the criterion", findings: [], ...extra })}\n\`\`\`\n`;

test("a review fix round that commits nothing blocks without a second review", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.review", unmetReview());
  fake(root, "alpha.commit-once", "1");
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 2);
  assert.equal(lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length, 2);
  assert.equal(lines.filter((l) => /^SPAWN .*--agent crew-reviewer/.test(l)).length, 1, "the unchanged commit is not reviewed again");
  assert.match(state(root).retention.alpha.reason, /^blocked — criteria-unmet — the fix round made no commit, so crew\/demo\/alpha is still at [0-9a-f]{12}, already judged unmet: no test covers the criterion$/);
});

test("an unmet verdict the reviewer puts down to the environment blocks at once, and a re-run re-checks without the coder", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.review", unmetReview({ cause: "environment", detail: "LocalStack unreachable, specs skipped" }));
  const first = commandLines(root);
  assert.equal(first.r.code, 2);
  assert.equal(first.lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length, 1, "no coder round can fix the environment");
  assert.equal(state(root).retention.alpha.reason, "blocked — criteria-unmet:environment — LocalStack unreachable, specs skipped");

  // The human fixes the environment and re-runs: verify runs again (its pass was another
  // run's), review passes, and the branch merges — with no coder.
  unlinkSync(join(root, ".scratch/fake/alpha.review"));
  const second = commandLines(root);
  assert.equal(second.r.code, 0, `${second.r.stdout}\n${second.r.stderr}`);
  assert.equal(second.lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length, 0);
  assert.equal(second.lines.filter((l) => /verify-worktree\.sh --dir/.test(l)).length, 1);
  assert.deepEqual(state(root).merged_branches, ["crew/demo/alpha"]);
});

test("a verify pass from an earlier run is not reused: a re-run verifies the same commit again", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  // Both round-1 reviews leave no report, and --max-rounds 1 ends the run there.
  fake(root, "alpha.review-once", "2");
  const first = commandLines(root, ["--max-rounds", "1"]);
  assert.match(state(root).retention.alpha.reason, /^review-not-run/, `${first.r.stdout}\n${first.r.stderr}`);
  const second = commandLines(root);
  assert.equal(second.r.code, 0, `${second.r.stdout}\n${second.r.stderr}`);
  assert.equal(second.lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length, 0);
  assert.equal(second.lines.filter((l) => /verify-worktree\.sh --dir/.test(l)).length, 1);
  assert.doesNotMatch(traceLog(root), /verify already passed at this commit/);
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

// ─── a coder that stops short with commits: its report is a claim, the gates decide ───────

function workerReport(obj) {
  return ["## Issue", "", "```json", JSON.stringify(obj), "```"].join("\n");
}

function failingTests(root) {
  writeFileSync(join(root, "Makefile"), "test:\n\t@echo boom && exit 1\nlint:\n\t@echo ok\ntypecheck:\n\t@echo ok\n");
  sh("git", ["-C", root, "add", "-A"]);
  sh("git", ["-C", root, "commit", "-q", "-m", "make test always fail"]);
}

function triageVerdict(fixable, category, detail) {
  return ["```json", JSON.stringify({ fixable, category, detail }), "```"].join("\n");
}

const coderSpawns = (lines) => lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length;

test("partial with commits, verify fails, triage not-fixable: no second coder, blocked after the recheck", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  failingTests(root);
  fake(root, "alpha.worker", workerReport({ status: "partial", checks: { test: "fail" }, progress: "LocalStack license activation failed" }));
  fake(root, "alpha.triage", triageVerdict("no", "missing credential", "LOCALSTACK_AUTH_TOKEN is unset"));
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 2, `${r.stdout}\n${r.stderr}`);
  assert.equal(coderSpawns(lines), 1, "a not-fixable verdict must not re-dispatch the coder");
  assert.match(traceLog(root), /\[CODER-CLAIM\] slug=alpha round=1 — the coder reported partial/);
  assert.match(traceLog(root), /\[SKIP-WORKER\] slug=alpha reason=not-fixable-recheck/);
  assert.match(state(root).retention.alpha.reason, /^blocked — retry limit reached \(2 attempts\) — verification-failed:not-fixable — missing credential/);
});

test("blocked as not-fixable: every later re-run only re-checks, with no coder or triage", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  failingTests(root);
  fake(root, "alpha.worker", workerReport({ status: "partial", checks: { test: "fail" }, progress: "LocalStack license activation failed" }));
  fake(root, "alpha.triage", triageVerdict("no", "missing credential", "LOCALSTACK_AUTH_TOKEN is unset"));
  commandLines(root);
  // Two re-runs: the second catches a reason that nested the block prefix on the first.
  for (const run of [2, 3]) {
    const { r, lines } = commandLines(root);
    assert.equal(r.code, 2, `run ${run}:\n${r.stdout}\n${r.stderr}`);
    assert.equal(coderSpawns(lines), 0, `run ${run} must not re-dispatch the coder`);
    assert.equal(lines.filter((l) => /^SPAWN .*--agent crew-triage/.test(l)).length, 0, `run ${run} must not re-triage`);
    assert.match(
      state(root).retention.alpha.reason,
      /^blocked — retry limit reached \(2 attempts\) — verification-failed:not-fixable — missing credential/,
    );
  }
});

test("partial with commits, verify fails, triage fixable: the retry is a fix round told triage's detail", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  failingTests(root);
  fake(root, "alpha.worker", workerReport({ status: "partial", checks: { test: "fail" }, progress: "tests red" }));
  fake(root, "alpha.triage", triageVerdict("yes", "wrong host", "src/config.ts uses localhost:4566; the service is localstack:4566"));
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 2, `${r.stdout}\n${r.stderr}`);
  assert.equal(coderSpawns(lines), 2);
  const prompt = readFileSync(join(root, ".scratch/demo/dispatch/01-alpha/prompt.md"), "utf8");
  assert.match(prompt, /already judged acceptable — it only failed verification/);
  assert.match(prompt, /classified this failure as fixable: wrong host: src\/config\.ts uses localhost:4566/);
});

test("github tracker: a re-run after a fixable failure gets fixPrompt though Progress lives only in a comment", () => {
  // The issue body carries no ## Progress (writeProgress posts a comment), so hasProgress
  // and hasBlocked are false on every fetch; the retained branch is known from state alone.
  const root = githubFixtureRepo();
  failingTests(root); // before the stub: its gh.log must not be committed as a tracked file
  const { stub } = stubGh(root, [GH_ALPHA]);
  const env = { PATH: `${stub}:${process.env.PATH}` };
  fake(root, "alpha.worker", workerReport({ status: "partial", checks: { test: "fail" }, progress: "tests red" }));
  fake(root, "alpha.triage", triageVerdict("yes", "wrong host", "src/config.ts uses localhost:4566; the service is localstack:4566"));
  commandLines(root, [], { env });
  assert.match(state(root).retention.alpha.reason, /verification-failed:fixable/);
  const promptFile = join(root, ".scratch/demo/dispatch/1-alpha/prompt.md");
  rmSync(promptFile);
  // Triage now rules it out, so the re-run cannot reach a fix prompt through its own gate:
  // the only fixPrompt possible is the one the retained reason routed to.
  fake(root, "alpha.triage", triageVerdict("no", "x", "y"));
  const { lines } = commandLines(root, [], { env });
  const prompt = readFileSync(promptFile, "utf8");
  assert.match(prompt, /classified this failure as fixable: wrong host: src\/config\.ts uses localhost:4566/);
});

test("a verify fix round that commits nothing blocks without re-verifying or re-triaging", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  failingTests(root);
  fake(root, "alpha.worker", workerReport({ status: "partial", checks: { test: "fail" }, progress: "tests red" }));
  fake(root, "alpha.triage", triageVerdict("yes", "wrong host", "src/config.ts uses localhost:4566"));
  fake(root, "alpha.commit-once", "1");
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 2, `${r.stdout}\n${r.stderr}`);
  assert.equal(coderSpawns(lines), 2);
  assert.equal(lines.filter((l) => /verify-worktree\.sh --dir/.test(l)).length, 1, "the unchanged commit is not verified again");
  assert.equal(lines.filter((l) => /^SPAWN .*--agent crew-triage/.test(l)).length, 1, "nor triaged again");
  assert.match(
    state(root).retention.alpha.reason,
    /^blocked — verification-failed:fixable — the fix round made no commit, so crew\/demo\/alpha is still at [0-9a-f]{12}, where verify last failed; triage's unaddressed detail: wrong host: src\/config\.ts uses localhost:4566$/,
  );
});

test("partial with commits and a passing verify goes to review, and merges on all-met", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.worker", workerReport({ status: "partial", checks: { test: "pass", lint: "pass", typecheck: "pass" }, progress: "unsure about AC 2" }));
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(coderSpawns(lines), 1);
  assert.ok(lines.some((l) => /^SPAWN .*--agent crew-reviewer/.test(l)), "review ran");
  assert.deepEqual(state(root).merged_branches, ["crew/demo/alpha"]);
});

test("blocked on the environment with commits: verify, then triage, which is handed the coder's evidence", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  failingTests(root);
  fake(
    root,
    "alpha.worker",
    workerReport({
      status: "blocked",
      cause: "environment",
      evidence: { command: "make test-integration", exit: 1, output: "License activation failed" },
      notes: "LocalStack pro needs a token",
    }),
  );
  fake(root, "alpha.triage", triageVerdict("no", "missing credential", "no token"));
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 2, `${r.stdout}\n${r.stderr}`);
  assert.ok(lines.some((l) => /verify-worktree\.sh --dir/.test(l)), "verify ran");
  assert.ok(lines.some((l) => /^SPAWN .*--agent crew-triage/.test(l)), "triage ran");
  const triage = readFileSync(join(root, ".scratch/demo/dispatch/01-alpha/triage-prompt.md"), "utf8");
  assert.match(triage, /its own claim — check\nit against the diff/);
  assert.match(triage, /^cause: environment\ncommand: make test-integration\nexit: 1\noutput:\nLicense activation failed$/m);
});

test("blocked with no cause is a stop at once, with no verify, even with commits", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.worker", workerReport({ status: "blocked", notes: "the issue contradicts the PRD" }));
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 2, `${r.stdout}\n${r.stderr}`);
  assert.equal(lines.filter((l) => /verify-worktree\.sh --dir/.test(l)).length, 0);
  assert.equal(coderSpawns(lines), 1);
  assert.deepEqual(state(root).blocked_slugs, ["alpha"]);
});

test("a premise stop (blocked, cause code, nothing committed) reaches the issue's ## Blocked, with no retry", () => {
  // solve-issue §3's premise check: the issue contradicts the code, so the coder stops before
  // writing any. A human must see the contradiction itself, and no second coder may re-derive it.
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const notes = "BLOCKED: premise: issue assumes parseToken() in src/auth.ts — no such function; auth is in src/session.ts:42 verifySession()";
  fake(
    root,
    "alpha.worker",
    workerReport({
      status: "blocked",
      cause: "code",
      evidence: { command: "grep -rn parseToken src", exit: 1, output: "" },
      notes,
    }),
  );
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 2, `${r.stdout}\n${r.stderr}`);
  assert.equal(coderSpawns(lines), 1, "a premise stop is not retried");
  assert.equal(lines.filter((l) => /verify-worktree\.sh --dir/.test(l)).length, 0, "nothing to verify");
  assert.ok(!lines.some((l) => /^SPAWN .*--agent crew-triage/.test(l)), "no triage on a premise stop");
  assert.deepEqual(state(root).blocked_slugs, ["alpha"]);
  const issue = readFileSync(join(root, ".scratch/demo/issues/open/01-alpha.md"), "utf8");
  assert.match(issue, /## Blocked[\s\S]*BLOCKED: premise: issue assumes parseToken\(\)/, "the human sees the contradiction");
});

test("an issue the code already satisfies closes with no commits, and its dependent runs", () => {
  // solve-issue §3's "already met": nothing to build and nothing to add, so the branch has no
  // commits. The reviewer judges the criteria against the tree instead of an (empty) diff, and
  // the issue closes like any other — a dependent is not stranded behind a finished issue.
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-beta.md", { blockedBy: ["01-alpha.md"] });
  fake(root, "alpha.nocommit");
  fake(
    root,
    "alpha.worker",
    workerReport({
      status: "complete",
      checks: { test: "pass", lint: "pass", typecheck: "pass" },
      criteria: [{ text: "alpha exists", met: true }],
      notes: "already met: alpha exists at src/alpha.ts:1, pinned by src/alpha.test.ts:3",
    }),
  );
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(coderSpawns(lines), 2, "one coder for alpha, one for beta — no retry");
  assert.ok(existsSync(join(root, ".scratch/demo/issues/done/01-alpha.md")), "alpha closed");
  assert.ok(existsSync(join(root, ".scratch/demo/issues/done/02-beta.md")), "beta ran and closed");
  const review = readFileSync(join(root, ".scratch/demo/dispatch/01-alpha/review-prompt.md"), "utf8");
  assert.match(review, /^Diff scope: empty/m, "the reviewer is told to judge the tree, not the diff");
  const betaReview = readFileSync(join(root, ".scratch/demo/dispatch/02-beta/review-prompt.md"), "utf8");
  assert.doesNotMatch(betaReview, /^Diff scope: empty/m);
});

// ─── ## Requires: probed once in preflight, before any dispatch ───────────────────────

test("an issue whose ## Requires fails is blocked before any dispatch, with the command and its output", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md", { body: "## Requires\n\n- `echo License activation failed; exit 1`" });
  addIssue(root, "02-beta.md", { body: "## Requires\n\n- `true`" });
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 2, `${r.stdout}\n${r.stderr}`);
  assert.equal(lines.filter((l) => /check-requires\.sh/.test(l)).length, 1, "one probe for every issue");
  assert.ok(!lines.some((l) => /^SPAWN .*--agent crew-coder.*--slug 01-alpha/.test(l)), "alpha's coder never ran");
  assert.ok(lines.some((l) => /^SPAWN .*--agent crew-coder.*--slug 02-beta/.test(l)), "beta's requirement holds, so it runs");
  const s = state(root);
  assert.deepEqual(s.blocked_slugs, ["alpha"]);
  assert.deepEqual(s.merged_branches, ["crew/demo/beta"]);
  const text = readFileSync(join(root, ".scratch/demo/issues/open/01-alpha.md"), "utf8");
  assert.match(text, /## Blocked\n\nPreflight: requires-failed — `echo License activation failed; exit 1` exit 1/);
  assert.match(text, /License activation failed\n```/);
});

test("an issue waiting on a blocker has its ## Requires probed when it unblocks, not in preflight", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  // Holds only once alpha has landed: what a blocker that adds the target the command runs looks like.
  addIssue(root, "02-beta.md", {
    blockedBy: ["01-alpha.md"],
    body: "## Requires\n\n- `test -f .scratch/demo/issues/done/01-alpha.md`",
  });
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(lines.filter((l) => /check-requires\.sh/.test(l)).length, 1, "probed once, at claim");
  const s = state(root);
  assert.deepEqual(s.blocked_slugs ?? [], []);
  assert.deepEqual(s.merged_branches, ["crew/demo/alpha", "crew/demo/beta"]);
});

test("a ## Requires that holds on a re-run lets the issue dispatch", () => {
  const root = fixtureRepo();
  const flag = join(root, ".scratch/token-present");
  addIssue(root, "01-alpha.md", { body: `## Requires\n\n- \`test -f ${flag}\`` });
  const first = commandLines(root);
  assert.equal(coderSpawns(first.lines), 0);
  writeFileSync(flag, "");
  const second = commandLines(root);
  assert.equal(second.r.code, 0, `${second.r.stdout}\n${second.r.stderr}`);
  assert.equal(coderSpawns(second.lines), 1);
  assert.deepEqual(state(root).merged_branches, ["crew/demo/alpha"]);
});

// ─── afk.limits.<role>.usd: a dispatch that hits its dollar cap blocks, never retries ────

test("a coder that hits afk.limits.coder.usd is blocked at once, not retried", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  for (const a of ["crew-coder", "crew-reviewer", "crew-triage"]) {
    mkdirSync(join(root, ".claude/agents"), { recursive: true });
    writeFileSync(join(root, ".claude/agents", `${a}.md`), `---\nname: ${a}\n---\n`);
  }
  mkdirSync(join(root, ".coding-crew"), { recursive: true });
  writeFileSync(join(root, ".coding-crew/config.json"), JSON.stringify({ afk: { limits: { coder: { usd: 0.5 } } } }));
  // What claude 2.1.283 prints when --max-budget-usd is reached: exit 1, no result text.
  const stub = join(root, ".stub");
  mkdirSync(stub, { recursive: true });
  const argsLog = join(root, ".scratch/claude.args");
  writeFileSync(
    join(stub, "claude"),
    [
      "#!/usr/bin/env bash",
      `printf '%s\\n' "$*" >> ${JSON.stringify(argsLog)}`,
      `echo '{"type":"result","subtype":"error_max_budget_usd","is_error":true,"terminal_reason":"budget_exhausted","total_cost_usd":0.61,"result":null}'`,
      "exit 1",
      "",
    ].join("\n"),
  );
  chmodSync(join(stub, "claude"), 0o755);
  const r = sh("node", [MAIN, "run", "--platform", "claude", "--feature-slug", "demo", "--no-baseline", "--no-commands"], {
    cwd: root,
    env: { ...process.env, CREW_SCRIPTS: SCRIPTS, CREW_FAKE_DISPATCH: "", MAIN_ROOT: root, PATH: `${stub}:${process.env.PATH}` },
  });
  assert.equal(r.code, 2, `${r.stdout}\n${r.stderr}`);
  const calls = readFileSync(argsLog, "utf8").trim().split("\n").filter((l) => l.includes("--agent crew-coder"));
  assert.equal(calls.length, 1, "a capped coder is never dispatched again");
  assert.match(calls[0], /--max-budget-usd 0\.5 /);
  const s = state(root);
  assert.deepEqual(s.blocked_slugs, ["alpha"]);
  assert.match(s.retention.alpha.reason, /^blocked — limit-exceeded \(\$0\.5\) — the coder dispatch hit afk\.limits\.coder\.usd after \$0\.61$/);
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
  const prompt = readFileSync(join(root, ".scratch/demo/dispatch/01-alpha/prompt.md"), "utf8");
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
    fake(root, `${n}.nocommit`);
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
  fake(root, "alpha.nocommit");
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
  const r = runSprint(root, ["--squash"]);
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

test("a squash refused by a hook is reported in the summary, and the merged commits stay committed", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  // Refuses only the squash's own message, so the worker's commits and the merge still land.
  const hook = join(root, ".git/hooks/commit-msg");
  writeFileSync(hook, "#!/bin/sh\ngrep -q '^Demo:' \"$1\" && { echo 'commit-msg: rejected' >&2; exit 1; }\nexit 0\n");
  chmodSync(hook, 0o755);
  const r = runSprint(root, ["--squash"]);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stdout, /## Squash\n\n\*\*Failed:\*\* [\s\S]*commit-msg: rejected/);
  const git = (...args) => sh("git", ["-C", root, ...args]).stdout.trim();
  assert.equal(git("status", "--porcelain", "--untracked-files=no"), "");
  assert.match(git("log", "--format=%s", "main..HEAD"), /Merge/);
});

test("the review is written to the sprint's reviews dir, before the squash", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  runSprint(root, ["--squash"]);
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
  writeFileSync(join(root, "Makefile"), "test:\n\t@echo boom && exit 1\nlint:\n\t@echo ok\ntypecheck:\n\t@echo ok\n");
  sh("git", ["-C", root, "add", "-A"]);
  sh("git", ["-C", root, "commit", "-q", "-m", "make test always fail"]);
  runSprint(root);
  assert.deepEqual(reviewReports(root), []);
  assert.equal(existsSync(join(root, ".scratch/demo/dispatch/01-alpha/review.md")), false);
});

test("a retained branch survives cleanup, is named in the summary, and resumes next round", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.worker", '## Issue: alpha\nStatus: partial\n\n```json\n{"status":"partial","progress":"stuck"}\n```');
  // The partial's commits go to verify, which fails; triage leaves no verdict, so a restart.
  writeFileSync(join(root, "Makefile"), "test:\n\t@echo boom && exit 1\nlint:\n\t@echo ok\ntypecheck:\n\t@echo ok\n");
  sh("git", ["-C", root, "add", "-A"]);
  sh("git", ["-C", root, "commit", "-q", "-m", "make test always fail"]);
  const r = runSprint(root);
  assert.equal(r.code, 2);
  // Cleanup deletes merged branches only; a retained one keeps its committed WIP.
  const branches = sh("git", ["-C", root, "branch", "--list", "crew/demo/alpha"]).stdout.trim();
  assert.match(branches, /crew\/demo\/alpha/, "cleanup deleted a retained branch");
  assert.match(r.stdout, /## Retained Branches/);
  assert.match(r.stdout, /crew\/demo\/alpha: retained \(.*verification-failed\)/);
  // Round 2 was told to resume on that branch rather than start over — and that the
  // notes are context alongside the preserved code, not a substitute for it.
  const prompt = readFileSync(join(root, ".scratch/demo/dispatch/01-alpha/prompt.md"), "utf8");
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

test("the summary is kept in the trace log too, not only printed", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(traceLog(root), / INFO  \[SUMMARY\]\n  Rounds: \d+\n  Model: /);
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
  const home = mkdtempSync(join(TMPDIR, "crew-sprint-userhome-"));
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
  const r = runSprint(root, ["--squash"]);
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
  const root = mkdtempSync(join(TMPDIR, "crew-sprint-"));
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
  assert.match(traceLog(high.root), /slug=alpha round=\d+ promote: 1 finding\(s\) — HIGH/);

  // A MEDIUM is reported, never promoted, at the default — left open and attributed.
  const medium = sprintWith("MEDIUM");
  assert.deepEqual(state(medium.root).completed_slugs, ["alpha"], "no fix issue for a MEDIUM at the default");
  assert.match(medium.r.stdout, /## Next Step/);
  // The log states what was promoted, not the threshold: a MEDIUM-only review must never
  // read as promotable at "CRITICAL, HIGH".
  const mediumLog = traceLog(medium.root);
  assert.doesNotMatch(mediumLog, /promotable/);
  assert.match(mediumLog, /slug=alpha round=\d+ promote: none — findings \(MEDIUM\) are below the threshold \(CRITICAL, HIGH\)/);

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

test("by default the sprint is not squashed: each issue's merge stays its own commit", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.doesNotMatch(traceLog(root), /\[SQUASH\]/);
  const log = sh("git", ["-C", root, "log", "--format=%s", "main..HEAD"]).stdout;
  assert.match(log, /Merge/);
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
  const root = mkdtempSync(join(TMPDIR, "crew-sprint-gh-"));
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
  // close-issue.sh's github close is mark-issue-done.sh's label swap, installed beside it.
  cpSync(join(REPO, "scripts/tracker/mark-issue-done.sh"), join(root, ".coding-crew/scripts/mark-issue-done.sh"));
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
 * `gh-issues.json` (mutated by `issue edit --add-label/--remove-label` and by `issue close`,
 * so a second `listOpen` fetch sees the new labels/state the same way a real re-fetch
 * would), `issue view --json body --jq .body` echoing that same issue's body, `issue
 * comment`/`label create` as plain no-ops. Everything else exits 0 — this pins the wiring, not the full `gh` surface
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
  // `issue list [--label L] [--state open|closed|all]`: filtered as gh would.
  const listJs = "const fs=require('fs');const [p,...a]=process.argv.slice(1);const v=(k)=>a.includes(k)?a[a.indexOf(k)+1]:null;" +
    "let issues=JSON.parse(fs.readFileSync(p,'utf8'));const label=v('--label'),st=v('--state');" +
    "if(label)issues=issues.filter(i=>(i.labels||[]).some(l=>l.name===label));" +
    "if(st&&st!=='all')issues=issues.filter(i=>i.state===st.toUpperCase());" +
    "process.stdout.write(JSON.stringify(issues))";
  // `issue edit N [--add-label L] [--remove-label L]…`: the label swap close-issue.sh makes.
  const editJs = "const fs=require('fs');const [p,n,...a]=process.argv.slice(1);" +
    "const issues=JSON.parse(fs.readFileSync(p,'utf8'));const i=issues.find(x=>x.number===Number(n));" +
    "if(i){const names=new Set((i.labels||[]).map(l=>l.name));" +
    "a.forEach((x,k)=>{if(x==='--add-label')names.add(a[k+1]);if(x==='--remove-label')names.delete(a[k+1]);});" +
    "i.labels=[...names].map(name=>({name}));}fs.writeFileSync(p,JSON.stringify(issues))";
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
      `  node -e ${JSON.stringify(listJs)} ${JSON.stringify(issuesFile)} "\${@:3}"`,
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
      // open-pr.sh: no PR yet; `pr create` keeps the body it was given, for the test to read.
      // post-findings.sh runs after the create: the PR exists, its diff shows nothing (so every
      // finding goes in the review body), and the review posted is kept for the test to read.
      'if [ "$1" = "pr" ] && [ "$2" = "view" ]; then',
      '  [ -f ' + JSON.stringify(join(root, "pr-body.md")) + ' ] || exit 1',
      '  echo \'{"number":7,"url":"https://github.com/o/r/pull/7","state":"OPEN","body":""}\'; exit 0',
      "fi",
      'if [ "$1" = "repo" ] && [ "$2" = "view" ]; then echo o/r; exit 0; fi',
      'if [ "$1" = "pr" ] && [ "$2" = "diff" ]; then exit 0; fi',
      'if [ "$1" = "api" ]; then',
      '  case " $* " in',
      '    *" POST "*) while [ $# -gt 0 ]; do [ "$1" = "--input" ] && cp "$2" ' + JSON.stringify(join(root, "review-post.json")) + '; shift; done ;;',
      '    *) echo "[]" ;;',
      "  esac",
      "  exit 0",
      "fi",
      'if [ "$1" = "pr" ] && [ "$2" = "create" ]; then',
      '  while [ $# -gt 0 ]; do [ "$1" = "--body-file" ] && cp "$2" ' + JSON.stringify(join(root, "pr-body.md")) + '; shift; done',
      '  echo https://github.com/o/r/pull/7',
      "  exit 0",
      "fi",
      'if [ "$1" = "issue" ] && [ "$2" = "edit" ]; then',
      `  node -e ${JSON.stringify(editJs)} ${JSON.stringify(issuesFile)} "\${@:3}"`,
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

test("a github-configured sprint dispatches, marks the issue awaiting-merge without closing it, and stops finding work", () => {
  const root = githubFixtureRepo();
  const { stub, log, issuesFile } = stubGh(root, [GH_ALPHA]);
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
  assert.match(calls, /issue edit 1 --add-label awaiting-merge --remove-label ready-for-agent/, "the issue was never marked done via gh");
  assert.doesNotMatch(calls, /issue close/, "merged into the feature branch is not shipped — only the PR closes it");
  const alpha = JSON.parse(readFileSync(issuesFile, "utf8")).find((i) => i.number === 1);
  assert.equal(alpha.state, "OPEN");
  assert.match(r.stdout, /NO MORE TASKS/);
  assert.match(r.stdout, /## Pull Request[\s\S]*Closes #1/, "the summary never gave the PR its closing line");
});

test("github --open-pr: the sprint pushes the feature branch and opens a PR whose body closes the issue", () => {
  const root = githubFixtureRepo();
  const { stub, log } = stubGh(root, [GH_ALPHA]);
  const remote = join(root, ".scratch/remote.git");
  sh("git", ["init", "-q", "--bare", remote]);
  sh("git", ["-C", root, "remote", "add", "origin", remote]);
  fake(
    root,
    "alpha.review",
    `## Branch: crew/demo/alpha\n\`\`\`json\n${JSON.stringify({ branch: "crew/demo/alpha", slug: "alpha", verdict: "all-met", findings: [{ severity: "MEDIUM", location: "somewhere in alpha", criterion: "Rename the variable" }] })}\n\`\`\`\n`,
  );
  const r = sh("node", [MAIN, "run", "--platform", "pi", "--feature-slug", "demo", "--open-pr"], {
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
  assert.match(readFileSync(log, "utf8"), /pr create --head feature\/demo/);
  assert.match(readFileSync(join(root, "pr-body.md"), "utf8"), /^Closes #1$/m);
  assert.equal(sh("git", ["-C", remote, "rev-parse", "feature/demo"]).stdout.trim(), sh("git", ["-C", root, "rev-parse", "feature/demo"]).stdout.trim());
  assert.match(r.stdout, /## Pull Request\s+https:\/\/github.com\/o\/r\/pull\/7\s+1 finding\(s\) posted \(0 inline\)/);
  const review = JSON.parse(readFileSync(join(root, "review-post.json"), "utf8"));
  assert.equal(review.event, "COMMENT");
  assert.match(review.body, /### MEDIUM[\s\S]*Rename the variable[\s\S]*crew-finding:/);
  // The findings are on the PR, so the summary points there, not at /crew-address-findings.
  assert.match(r.stdout, /1 finding\(s\) posted to https:\/\/github.com\/o\/r\/pull\/7/);
  assert.doesNotMatch(r.stdout, /\/crew-address-findings/);
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
  assert.ok(gaps.labels.some((l) => l.name === "awaiting-merge"), "the gaps issue was never implemented");
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
      HOME: mkdtempSync(join(TMPDIR, "crew-home-")),
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
function commandLines(root, extra = [], { scripts = SCRIPTS, env = {}, platform = "pi", baseline = false } = {}) {
  const r = sh("node", [MAIN, "run", "--platform", platform, "--feature-slug", "demo", ...(baseline ? [] : NO_BASELINE), ...extra], {
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

test("a failed sprint-level docker install stops the run before any worktree or dispatch, even with the baseline on", () => {
  // In docker mode the sprint-level call is the only install: every worktree call only
  // checks it happened. Carrying on would send every coder, and the baseline, to an empty volume.
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const scripts = privateScripts();
  const real = join(scripts, "_real-ensure-deps.sh");
  cpSync(join(scripts, "ensure-deps.sh"), real);
  writeFileSync(
    join(scripts, "ensure-deps.sh"),
    [
      "#!/usr/bin/env bash",
      'case " $* " in *" --slug "*) exec bash ' + JSON.stringify(real) + ' "$@" ;; esac',
      'echo "make deps runs docker itself, but not through docker-compose.override.yml"',
      'echo "DEPS: docker-failed make deps (exit 5) (see .scratch/docker-install.log)"',
      "",
    ].join("\n"),
  );

  const { r, lines } = commandLines(root, [], { scripts, baseline: true });
  assert.equal(r.code, 1, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stderr, /not through docker-compose\.override\.yml/);
  assert.match(r.stderr, /dependencies could not be installed into the docker volume/);
  assert.match(r.stderr, /^  docker-failed make deps \(exit 5\)/m);
  assert.match(r.stderr, /--no-deps/);
  // The log outlives the scrollback: the stop is there too, as the one FATAL line.
  assert.match(traceLog(root), /^\S+Z FATAL \[ABORT\] .*dependencies could not be installed/m);
  assert.equal(lines.filter((l) => /worktree add/.test(l)).length, 0, "a worktree was created");
  assert.equal(lines.filter((l) => /^SPAWN .*--agent crew-/.test(l)).length, 0, "an agent was dispatched");
});

test("a failed sprint-level host install still stops nothing: every worktree installs again", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const scripts = privateScripts();
  const real = join(scripts, "_real-ensure-deps.sh");
  cpSync(join(scripts, "ensure-deps.sh"), real);
  writeFileSync(
    join(scripts, "ensure-deps.sh"),
    ["#!/usr/bin/env bash", 'case " $* " in *" --slug "*) exec bash ' + JSON.stringify(real) + ' "$@" ;; esac', 'echo "DEPS: failed npm ci (exit 1)"', ""].join("\n"),
  );

  const { r, lines } = commandLines(root, ["--max-rounds", "1"], { scripts });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length, 1);
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

  const r = sh("node", [MAIN, "run", "--platform", "pi", "--feature-slug", "demo", "--no-baseline"], {
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

test("stderr leaves out DEBUG lines by default; the trace log keeps them", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const r = runSprint(root, [], { CREW_VERBOSE: "", CREW_LOG_LEVEL: "" });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  // A script's own stdout, echoed after the script already traced its result line, is debug.
  const echo = /^slug=alpha round=1 DEPS: /m;
  assert.doesNotMatch(r.stderr, echo);
  assert.match(traceLog(root), /^\S+Z DEBUG slug=alpha round=1 DEPS: /m);
  // Progress stays: a launcher answers "how far along?" from [STEP] on stderr.
  assert.match(r.stderr, /^\[STEP\] slug=01-alpha round=1 step=verify$/m);
});

test("CREW_LOG_LEVEL=warn quiets stderr to what went wrong; the trace log is unchanged", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const r = runSprint(root, [], { CREW_LOG_LEVEL: "warn" });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.doesNotMatch(r.stderr, /\[STEP\]/);
  assert.match(traceLog(root), /^\S+Z INFO  \[STEP\] slug=01-alpha round=1 step=verify$/m);
});

test("CREW_LOG_LEVEL=debug puts the echoes and the heartbeat on stderr, like CREW_VERBOSE", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.heartbeat", "");
  const r = runSprint(root, [], { CREW_VERBOSE: "", CREW_LOG_LEVEL: "debug" });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stderr, /^slug=alpha round=1 DEPS: /m);
  assert.match(r.stderr, /fake-heartbeat/);
});

test("an unknown CREW_LOG_LEVEL warns once on stderr and runs at info", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const r = runSprint(root, [], { CREW_LOG_LEVEL: "loud" });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(r.stderr.split("\n").filter((l) => /CREW_LOG_LEVEL=loud/.test(l)).length, 1, r.stderr);
  assert.match(r.stderr, /^\[STEP\] /m);
});

test("an attempt ends in one [ATTEMPT-END] line; no === / --- banners", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const log = traceLog(root);
  // state.sh's own [ATTEMPT] line is the start; the orchestrator adds no second one.
  assert.equal(log.split("\n").filter((l) => /\[ATTEMPT\] slug=alpha n=1/.test(l)).length, 1, log);
  assert.match(log, /^\S+Z INFO  \[ATTEMPT-END\] slug=alpha attempt=1 status=complete$/m);
  assert.match(r.stderr, /^\[ATTEMPT-END\] slug=alpha attempt=1 status=complete$/m);
  assert.doesNotMatch(`${log}\n${r.stderr}`, /^(=== |--- )slug=/m);
});

test("a verify transcript goes to its own file; the log gets one line pointing at it", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const log = traceLog(root);
  const m = /^\S+Z DEBUG \[VERIFY-OUTPUT\] slug=alpha round=1 result=pass file=(\S+)$/m.exec(log);
  assert.ok(m, `no [VERIFY-OUTPUT] line:\n${log}`);
  assert.match(readFileSync(join(root, m[1]), "utf8"), /TEST: pass/);
  assert.doesNotMatch(log, /TEST: pass/, "the transcript itself stays out of the log");
});

test("a failed verify's pointer is an ERROR, next to the [VERIFY] result it explains", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  writeFileSync(join(root, "Makefile"), "test:\n\t@echo boom && exit 1\nlint:\n\t@echo ok\ntypecheck:\n\t@echo ok\n");
  sh("git", ["-C", root, "add", "-A"]);
  sh("git", ["-C", root, "commit", "-q", "-m", "make test always fail"]);
  const r = runSprint(root);
  assert.equal(r.code, 2, `${r.stdout}\n${r.stderr}`);
  const log = traceLog(root);
  const m = /^\S+Z ERROR \[VERIFY-OUTPUT\] slug=alpha round=1 result=fail file=(\S+)$/m.exec(log);
  assert.ok(m, `no failing [VERIFY-OUTPUT] line:\n${log}`);
  assert.match(readFileSync(join(root, m[1]), "utf8"), /TEST: fail/);
  // Each round keeps its own transcript.
  assert.match(log, /\[VERIFY-OUTPUT\] slug=alpha round=2 result=fail file=/);
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
  assert.equal(existsSync(join(root, ".scratch/demo/dispatch/01-alpha/deps.ok")), false);
  assert.equal(existsSync(join(root, ".scratch/demo/dispatch/01-alpha/deps.skip")), false);
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

test("command discovery's prompt goes to its own file; the log and stderr get one line naming it", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const log = traceLog(root);
  assert.doesNotMatch(`${log}\n${r.stderr}`, /command discovery prompt/);
  assert.match(log, /^\S+Z INFO  Command discovery: \d+ source file/m);
  const m = /^\S+Z DEBUG Command discovery: prompt kept at (\S+)$/m.exec(log);
  assert.ok(m, log);
  assert.match(readFileSync(join(root, m[1]), "utf8"), /command discovery prompt/);
});

test("a script's summary line echoed after its own trace line is debug; no pane host is not a warning", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const log = traceLog(root);
  assert.match(log, /^\S+Z DEBUG FLUSH: /m);
  assert.match(log, /^\S+Z DEBUG CLEANUP: /m);
  assert.doesNotMatch(r.stderr, /^(FLUSH|CLEANUP): /m);
  assert.match(log, /^\S+Z DEBUG \[MILESTONE-PUSH-SKIPPED\] 01-alpha: no pane host$/m);
  assert.doesNotMatch(r.stderr, /MILESTONE-PUSH-SKIPPED/);
});

test("command discovery is skipped, at zero cost, when there is nothing to read", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  // discover-commands.sh reads the working directory, not git history — removing the
  // Makefile here does not affect the worktree verify-worktree.sh checks out from HEAD,
  // so this isolates the discovery step from the rest of the pipeline.
  unlinkSync(join(root, "Makefile"));

  const r = runSprint(root, ["--allow-dirty"]);
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
  const second = runSprint(root, ["--allow-dirty"]);
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

// ─── preflight: a clean main checkout, and a green feature branch ─────────────────────

test("uncommitted changes to a tracked file stop the run before anything is dispatched", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  writeFileSync(join(root, "Makefile"), "test:\n\t@echo edited\nlint:\n\t@echo ok\ntypecheck:\n\t@echo ok\n");
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 1, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stderr, /the main checkout \(\S+\) has uncommitted changes to tracked files/);
  assert.match(r.stderr, /^  Makefile$/m);
  assert.equal(lines.filter((l) => /^SPAWN /.test(l)).length, 0);
  assert.equal(existsSync(join(root, ".scratch/demo/sprint-state.json")), false, "stopped before session-init");
});

test("--allow-dirty runs anyway, and crew-afk's own files never count as dirty", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  mkdirSync(join(root, ".coding-crew"), { recursive: true });
  writeFileSync(join(root, ".coding-crew/dev-commands.json"), '{"test": "make test"}');
  sh("git", ["-C", root, "add", "-A"]);
  sh("git", ["-C", root, "commit", "-q", "-m", "cache"]);
  writeFileSync(join(root, ".coding-crew/dev-commands.json"), '{"test": "make test", "lint": "make lint"}');
  assert.equal(runSprint(root).code, 0, "a rewritten commands cache is crew-afk's own write");

  // Unstaged, and in a file no branch touches. (A *staged* change would refuse every merge:
  // git will not record index changes unrelated to the merge in its commit.)
  const other = fixtureRepo();
  addIssue(other, "01-alpha.md");
  writeFileSync(join(other, "README.md"), "x\n");
  sh("git", ["-C", other, "add", "README.md"]);
  sh("git", ["-C", other, "commit", "-q", "-m", "readme"]);
  writeFileSync(join(other, "README.md"), "local edit\n");
  const r = runSprint(other, ["--allow-dirty"]);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
});

test("a run leaves no .worktreeinclude behind in a repo that had none", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  assert.equal(runSprint(root).code, 0);
  assert.equal(existsSync(join(root, ".worktreeinclude")), false);
});

test("plan names a dirty main checkout", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  writeFileSync(join(root, "Makefile"), "test:\n\t@echo edited\n");
  const r = sh("node", [MAIN, "plan", "--platform", "pi", "--feature-slug", "demo"], { cwd: root, env: { ...process.env, MAIN_ROOT: root } });
  assert.match(r.stdout, /main tree: 1 tracked file\(s\) with uncommitted changes .*Makefile/);
});

test("a feature branch that fails its own checks stops the run before any coder is dispatched", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  writeFileSync(join(root, "Makefile"), "test:\n\t@echo boom && exit 1\nlint:\n\t@echo ok\ntypecheck:\n\t@echo ok\n");
  sh("git", ["-C", root, "add", "-A"]);
  sh("git", ["-C", root, "commit", "-q", "-m", "red"]);
  const { r, lines } = commandLines(root, [], { baseline: true });
  assert.equal(r.code, 1, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stderr, /feature\/demo fails its own checks before any issue has touched it/);
  assert.match(traceLog(root), /^\S+Z FATAL \[ABORT\] .*feature\/demo fails its own checks/m);
  assert.match(traceLog(root), /^\S+Z ERROR \[VERIFY-OUTPUT\] step=baseline result=fail file=\S+\/_baseline\/verify\.out$/m);
  assert.match(r.stderr, /^  test: fail — \S+\/dispatch\/_baseline\/verify-test\.log$/m);
  assert.match(r.stderr, /--no-baseline/);
  assert.equal(lines.filter((l) => /^SPAWN .*--agent crew-/.test(l)).length, 0, "no coder, no reviewer");
  assert.equal(state(root).baseline.verdict, "fail");
  // The throwaway worktree and its branch are gone.
  assert.equal(sh("git", ["-C", root, "branch", "--list", "crew/demo/_baseline"]).stdout.trim(), "");
  assert.equal(existsSync(join(root, ".scratch/worktrees/crew/demo/_baseline")), false);
});

// A check command that is not installed exits 127: an environment problem, never the branch's.
function missingTool(root) {
  mkdirSync(join(root, ".coding-crew"), { recursive: true });
  writeFileSync(
    join(root, ".coding-crew/dev-commands.json"),
    JSON.stringify({ test: "crew-no-such-tool tests/*.bats", lint: "make lint", typecheck: "make typecheck", coverage: null, integration: null }),
  );
  sh("git", ["-C", root, "add", "-A"]);
  sh("git", ["-C", root, "commit", "-q", "-m", "cache"]);
  fake(root, "commands.response", '{"install": null, "env": null, "credential_target": null}');
}

test("a baseline check whose command is not installed is reported as the environment, not a red branch", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  missingTool(root);
  const { r, lines } = commandLines(root, [], { baseline: true });
  assert.equal(r.code, 1, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stderr, /feature\/demo's checks cannot run here: `crew-no-such-tool` is not installed — an environment problem, not a red branch/);
  assert.match(r.stderr, /^  test: fail — command not found: crew-no-such-tool — \S+\/dispatch\/_baseline\/verify-test\.log$/m);
  assert.match(r.stderr, /Install it where the checks run \(or give \.coding-crew\/dev-commands\.json an `install` command that does\), then re-run\./);
  assert.doesNotMatch(r.stderr, /Fix it on the feature branch/);
  assert.match(r.stderr, /--no-baseline/);
  assert.equal(lines.filter((l) => /^SPAWN .*--agent crew-/.test(l)).length, 0, "no coder, no reviewer");
});

test("an issue's verify failing on a command that is not installed skips triage and never re-dispatches the coder", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  missingTool(root);
  fake(root, "alpha.worker", workerReport({ status: "complete", checks: { test: "pass", lint: "pass", typecheck: "pass" }, progress: "" }));
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 2, `${r.stdout}\n${r.stderr}`);
  assert.equal(coderSpawns(lines), 1, "a missing command is not fixable by more code");
  assert.equal(lines.filter((l) => /^SPAWN .*--agent crew-triage/.test(l)).length, 0, "nothing for triage to judge");
  assert.match(traceLog(root), /\[SKIP-WORKER\] slug=alpha reason=not-fixable-recheck/);
  assert.match(
    state(root).retention.alpha.reason,
    /^blocked — retry limit reached \(2 attempts\) — verification-failed:not-fixable — missing command: crew-no-such-tool is not installed \(test\)/,
  );
});

test("a green baseline is run once per feature-branch commit, then reused", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const tip = sh("git", ["-C", root, "rev-parse", "feature/demo"]).stdout.trim();
  const first = commandLines(root, ["--max-rounds", "1"], { baseline: true });
  assert.equal(first.r.code, 0, `${first.r.stdout}\n${first.r.stderr}`);
  assert.equal(first.lines.filter((l) => /verify-worktree\.sh --dir \S+\/_baseline --stem _baseline/.test(l)).length, 1);
  assert.deepEqual({ commit: state(root).baseline.commit, verdict: state(root).baseline.verdict }, { commit: tip, verdict: "pass" });

  // Same tip, a second run (alpha's merge moved it, so pin the cache to the new tip first).
  addIssue(root, "02-beta.md");
  const again = sh("git", ["-C", root, "rev-parse", "feature/demo"]).stdout.trim();
  const sf = join(root, ".scratch/demo/sprint-state.json");
  writeFileSync(sf, JSON.stringify({ ...state(root), baseline: { commit: again, verdict: "pass" } }));
  const second = commandLines(root, [], { baseline: true });
  assert.equal(second.r.code, 0, `${second.r.stdout}\n${second.r.stderr}`);
  assert.equal(second.lines.filter((l) => /--stem _baseline/.test(l)).length, 0);
  assert.match(second.r.stderr, /BASELINE: pass \(cached/);
});

test("--no-baseline skips the baseline", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(lines.filter((l) => /--stem _baseline/.test(l)).length, 0);
});

// ─── a dirty main checkout at merge time ──────────────────────────────────────────────

test("a merge refused by uncommitted changes in the main checkout blocks at once, then resumes at merge", () => {
  const root = fixtureRepo();
  mkdirSync(join(root, "src"), { recursive: true });
  writeFileSync(join(root, "src/alpha.txt"), "// base\n");
  sh("git", ["-C", root, "add", "-A"]);
  sh("git", ["-C", root, "commit", "-q", "-m", "seed"]);
  addIssue(root, "01-alpha.md");
  // The fake coder appends to src/alpha.txt; the same file edited, uncommitted, here.
  writeFileSync(join(root, "src/alpha.txt"), "// someone's local edit\n");

  const first = commandLines(root, ["--allow-dirty"]);
  assert.equal(first.r.code, 2, `${first.r.stdout}\n${first.r.stderr}`);
  const s = state(root);
  assert.match(s.retention.alpha.reason, /^blocked — main-tree-dirty — uncommitted changes in \S+ would be overwritten: src\/alpha\.txt — commit or stash/);
  assert.equal(s.attempts.alpha, 1, "no retry: nothing a dispatch does can clean the checkout");
  assert.equal(first.lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length, 1);
  assert.match(first.r.stdout, /## Main Checkout Not Clean \(need a human\)/);
  assert.match(first.r.stdout, /- crew\/demo\/alpha: uncommitted changes in \S+ would be overwritten: src\/alpha\.txt/);

  // The human stashes the edit and re-runs: straight to merge, nothing re-dispatched.
  sh("git", ["-C", root, "checkout", "--", "src/alpha.txt"]);
  const second = commandLines(root);
  assert.equal(second.r.code, 0, `${second.r.stdout}\n${second.r.stderr}`);
  assert.deepEqual(state(root).completed_slugs, ["alpha"]);
  assert.equal(second.lines.filter((l) => /^SPAWN .*--agent crew-/.test(l)).length, 0);
  assert.equal(second.lines.filter((l) => /verify-worktree\.sh --dir/.test(l)).length, 0);
  assert.match(traceLog(root), /\[SKIP-TO-MERGE\] slug=alpha reason=blocked — main-tree-dirty/);
});

// ─── the per-dispatch cost ledger ─────────────────────────────────────────────────────

test("every dispatch is filed in this run's ledger with its slug, role and attempt", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.review-once", "2");
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const s = state(root);
  assert.ok(s.current_run, "run-start tagged the run");
  const rows = s.dispatches.map((d) => [d.role, d.attempt, d.run === s.current_run]);
  assert.deepEqual(rows, [
    ["coder", 1, true],
    ["reviewer", 1, true],
    ["reviewer", 1, true],
    ["reviewer", 2, true],
  ]);
  // The coder's entry keeps the tip it left: the commit verify then checked.
  const verified = JSON.parse(readFileSync(join(root, ".scratch/demo/dispatch/01-alpha/verify.json"), "utf8")).commit;
  assert.equal(s.dispatches[0].head, verified);
});
