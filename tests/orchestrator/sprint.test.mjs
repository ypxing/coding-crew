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
  // The reviewer was handed the verification result, so a criterion that ends "and the
  // tests pass" is answerable by the read-only reviewer instead of stalling the branch.
  const reviewPromptText = readFileSync(join(root, ".scratch/demo/dispatch/alpha.review-prompt.md"), "utf8");
  assert.match(reviewPromptText, /Checks already run by the pipeline/);
  assert.match(reviewPromptText, /test=pass/);
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

test("a review-not-run retry skips the coder dispatch and succeeds on the second review", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  // The review fails to produce a usable report on its first attempt (empty report, the
  // same shape a timeout or a dispatch crash leaves behind), then succeeds on the retry
  // — the worker itself never runs a second time.
  fake(root, "alpha.review-once", "");
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const s = state(root);
  assert.deepEqual(s.completed_slugs, ["alpha"]);
  assert.deepEqual(s.merged_branches, ["crew/demo/alpha"]);
  assert.equal(s.retention?.alpha, undefined, "the issue should have completed, not stayed retained");
  assert.ok(s.rounds >= 2, `expected at least 2 rounds, got ${s.rounds}`);
  // The coder ran exactly once — round 2 retried only the review, not the worker.
  assert.equal(lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length, 1);
  assert.match(traceLog(root), /\[SKIP-WORKER\] slug=alpha reason=review-not-run/);
});

test("a criteria-unmet retry still redispatches the full worker, not just review", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.review", "## Branch: crew/demo/alpha\nAC: unmet — no test covers the criterion\n");
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
  assert.equal(s.retention.alpha.reason, "verification-failed");
  assert.equal(
    lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length,
    2,
    "the coder must run again — a verification-failed branch needs its content fixed, not just a review retry",
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
  assert.equal(existsSync(join(root, ".scratch/demo/dispatch/alpha.review.md")), false);
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
  const prompt = readFileSync(join(root, ".scratch/demo/dispatch/alpha.prompt.md"), "utf8");
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

test("coverage validation is opt-in, and runs between the squash and cleanup", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  writeFileSync(join(root, ".scratch/demo/PRD.md"), "# PRD\n\n- The widget exists\n");

  // Without the flag it never runs, however much PRD there is to validate.
  const off = runSprint(root);
  assert.equal(off.code, 0, `${off.stdout}\n${off.stderr}`);
  assert.equal(existsSync(join(root, ".scratch/demo/coverage-report.md")), false);
  assert.doesNotMatch(off.stdout, /## Coverage Report/);

  const root2 = fixtureRepo();
  addIssue(root2, "01-alpha.md");
  writeFileSync(join(root2, ".scratch/demo/PRD.md"), "# PRD\n\n- The widget exists\n");
  const on = runSprint(root2, ["--coverage"]);
  assert.equal(on.code, 0, `${on.stdout}\n${on.stderr}`);
  assert.equal(existsSync(join(root2, ".scratch/demo/coverage-report.md")), true);
  assert.match(on.stdout, /## Coverage Report/);
  const log = traceLog(root2);
  assert.ok(markerAt(log, "SQUASH") < markerAt(log, "CLEANUP"), "cleanup must follow the squash");
});

test("a feature slug containing 'skipped' does not silently cancel coverage validation", () => {
  // Regression: loop.mjs used to test /skipped/i against coverage-validation.sh's *entire*
  // stdout, not just its one-line skip message. That stdout embeds $PRD_PATH (which embeds
  // $FEATURE_SLUG) on every non-skip line ("PRD found at .scratch/<slug>/PRD.md", "Extract
  // all requirements from ...", "Completed issues in .scratch/<slug>/issues/done/"), so a
  // feature slug that happens to contain the substring "skipped" — a perfectly ordinary name
  // for a feature about skip logic — made that regex match and cancelled a validation the
  // user explicitly asked for with --coverage. The same bug as command discovery's, just
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

  const r = runSprint(root, ["--coverage", "--feature-slug", "skipped-flow"]);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(
    existsSync(join(root, ".scratch/skipped-flow/coverage-report.md")),
    true,
    "a feature slug containing 'skipped' must not cancel a requested coverage validation",
  );
  assert.match(r.stdout, /## Coverage Report/);
});

// ─── what the last prose bodies used to assert about themselves ──────────────
//
// The copilot cutover emptied AFK_PROSE_VARIANTS, so the bats suites that looped over it
// stopped having a subject. Three of those assertions had no direct code equivalent, only
// an adjacent one, and are written here before they are deleted there: the promotion
// threshold has one source, the sprint reports once and last, and a review gap is named in
// the summary rather than merely counted in the state file.

test("the promotion threshold has one source: --promote reaches findingsAtOrAbove", () => {
  const reviewWithHigh = [
    "## Branch: crew/demo/alpha",
    "AC: all-met",
    "FINDING: HIGH | src/alpha.txt:1 | Move the trust boundary check before the write",
  ].join("\n");

  // Default: CRITICAL only. A HIGH is reported, never promoted — so the sprint ends after
  // the one issue, with the finding left open and attributed.
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.review", reviewWithHigh);
  const off = runSprint(root);
  assert.equal(off.code, 0, `${off.stdout}\n${off.stderr}`);
  assert.deepEqual(state(root).completed_slugs, ["alpha"], "no fix issue at the default threshold");
  assert.equal(existsSync(join(root, ".scratch/demo/reviews/alpha.criteria.md")), false);
  // An unpromoted severity is never subtracted from the reminder.
  assert.match(off.stdout, /## Next Step/);
  assert.match(off.stdout, /--promote critical-high/);

  // With the flag, the same finding becomes a Phase 2 fix issue. The threshold is read
  // from sprint.env (CREW_PROMOTE), not restated anywhere.
  const root2 = fixtureRepo();
  addIssue(root2, "01-alpha.md");
  fake(root2, "alpha.review", reviewWithHigh);
  const on = runSprint(root2, ["--promote", "critical-high"]);
  assert.equal(on.code, 0, `${on.stdout}\n${on.stderr}`);
  assert.equal(state(root2).completed_slugs.length, 2, "the HIGH should have run as its own fix issue");
  const criteria = readFileSync(join(root2, ".scratch/demo/reviews/alpha.criteria.md"), "utf8");
  assert.match(criteria, /\[HIGH\] Move the trust boundary check before the write/);
  assert.match(readFileSync(join(root2, ".scratch/demo/sprint.env"), "utf8"), /CREW_PROMOTE="critical-high"/);
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
  // promote-findings.sh mark-not-run and surfaced under its own heading.
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.review", "");
  const r = runSprint(root);
  assert.match(r.stdout, /## Unreviewed Branches/);
  assert.match(r.stdout, /crew\/demo\/alpha/);
  assert.equal(state(root).retention.alpha.reason, "review-not-run");
});

// ─── eager dependency provisioning ───────────────────────────────────────────
//
// dep-install is failure-triggered, which is right for a human's direct solve-issue run.
// A sprint is the opposite case: every worktree is fresh, and one consumer of the deps is
// verify-worktree.sh — a gate, which cannot invoke a skill and has no recovery path when
// `npm test` dies on a missing module. So provisioning is mechanism, at two call sites,
// and what these tests pin is the *position* of those two calls in the recorded command
// order. A DEPS: outcome never changes a round's status.

/** The effects log — one line per subprocess, in order. CREW_VERBOSE puts it on stderr. */
function commandLines(root, extra = []) {
  const r = sh("node", [MAIN, "run", "--platform", "pi", "--feature-slug", "demo", ...extra], {
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
  return { r, lines: r.stderr.split("\n").filter((l) => /^(RUN|SPAWN|DRY) /.test(l)) };
}

const SPRINT_LEVEL_DEPS = /ensure-deps\.sh --dir \S+$/;
const worktreeDepsFor = (slug) => new RegExp(`ensure-deps\\.sh --dir \\S+ --slug ${slug}$`);

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
    '{"test": "make test", "lint": "make lint", "typecheck": "make typecheck", "install": "touch .scratch/install-ran.marker"}',
  );

  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);

  const cache = JSON.parse(readFileSync(join(root, ".scratch/commands.json"), "utf8"));
  assert.equal(cache.install, "touch .scratch/install-ran.marker");
  assert.equal(existsSync(join(root, ".scratch/install-ran.marker")), true, "the discovered install command never ran against MAIN_ROOT");
  assert.match(traceLog(root), /\[DEPS\].*installed.*touch \.scratch\/install-ran\.marker/);
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

test("a DEPS: failed outcome does not demote the issue or change the round summary", () => {
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
  assert.equal(r.code, 0, `a failed install must not stall the sprint:\n${r.stdout}\n${r.stderr}`);
  assert.match(traceLog(root), /\[DEPS\].*failed/);
  const s = state(root);
  assert.deepEqual(s.completed_slugs, ["alpha"]);
  assert.deepEqual(s.merged_branches, ["crew/demo/alpha"]);
  assert.equal(s.retention?.alpha, undefined, "a DEPS: failure demoted the issue by itself");
});

test("the orchestrator prints one line per deps call — the DEPS: line itself", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const { r } = commandLines(root);
  assert.equal(r.code, 0, r.stderr);
  const printed = r.stderr.split("\n").filter((l) => l.startsWith("DEPS:"));
  assert.equal(printed.length, 2, `expected one line per call, got:\n${printed.join("\n")}`);
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

  const r = commandLines(root);
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
  const off = commandLines(root2, ["--no-deps"]);
  assert.equal(off.r.code, 2, "without deps the round should stall, not merge");
  assert.deepEqual(state(root2).merged_branches ?? [], []);
  assert.equal(state(root2).retention.alpha.reason, "verification-failed");
});

// ─── one-time command discovery ───────────────────────────────────────────────
//
// discover-commands.sh / write-commands-cache.sh mechanically build the prompt and persist
// the answer; the model call itself is faked here (fake-dispatch.sh's "commands-discovery"
// branch), exactly the seam coverage validation already uses for the same reason.

test("command discovery writes .scratch/commands.json from the repo's own Makefile", () => {
  const root = fixtureRepo(); // fixtureRepo() always seeds a Makefile with test/lint/typecheck
  addIssue(root, "01-alpha.md");

  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);

  const cacheFile = join(root, ".scratch/commands.json");
  assert.equal(existsSync(cacheFile), true);
  const cache = JSON.parse(readFileSync(cacheFile, "utf8"));
  assert.equal(cache.test, "make test");
  assert.equal(cache.lint, "make lint");
  assert.equal(cache.typecheck, "make typecheck");
  assert.ok(cache.sourceHash);
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
  assert.equal(existsSync(join(root, ".scratch/commands.json")), true, "the word 'skipped' inside a quoted file must not cancel discovery");
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
  assert.equal(existsSync(join(root, ".scratch/commands.json")), false);
  assert.match(r.stderr, /Command discovery: skipped/);
});

test("a second sprint reuses the cached commands instead of discovering again", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const first = runSprint(root);
  assert.equal(first.code, 0, `${first.stdout}\n${first.stderr}`);
  const cacheAfterFirst = readFileSync(join(root, ".scratch/commands.json"), "utf8");

  addIssue(root, "02-beta.md");
  const second = runSprint(root);
  assert.equal(second.code, 0, `${second.stdout}\n${second.stderr}`);
  assert.match(second.stderr, /cache is fresh/);
  assert.equal(readFileSync(join(root, ".scratch/commands.json"), "utf8"), cacheAfterFirst);
});

test("--no-commands skips command discovery entirely", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");

  const r = runSprint(root, ["--no-commands"]);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(existsSync(join(root, ".scratch/commands.json")), false);
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
  assert.equal(existsSync(join(root, ".scratch/commands.json")), false);
  assert.match(r.stderr, /Command discovery: discover-commands\.sh failed/);
});
