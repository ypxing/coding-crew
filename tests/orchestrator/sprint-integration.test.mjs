/**
 * Sprint suite — the integration check, the feature review, and triaging a red integration check.
 * Shared helpers: ./helpers/sprint.mjs.
 */

import assert from "node:assert/strict";
import { isGreen } from "../../orchestrator/lib/loop.mjs";
import { cpSync, mkdirSync, rmSync, readFileSync, readdirSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { REPO, MAIN, SCRIPTS, FAKE, sh, fixtureRepo, addIssue, traceLog, state, fake, triageVerdict, githubFixtureRepo, stubGh, GH_ALPHA, commandLines, featureReviewFile, crossIssue, sprintReport, test } from "./helpers/sprint.mjs";

// ─── the integration check: the merged feature branch, at every drain ─────────────────

/** A `test` target that is red only when alpha's and beta's files are both present — so each
 * branch is green alone and the merge of the two is not. Committed to the feature branch. */
function redWhenMerged(root) {
  writeFileSync(
    join(root, "Makefile"),
    "test:\n\t@if [ -f src/alpha.txt ] && [ -f src/beta.txt ]; then echo 'alpha and beta clash' >&2; exit 1; fi\nlint:\n\t@echo ok\ntypecheck:\n\t@echo ok\n",
  );
  sh("git", ["-C", root, "add", "-A"]);
  sh("git", ["-C", root, "commit", "-q", "-m", "red when merged"]);
}

const integrationRuns = (lines) => lines.filter((l) => /verify-worktree\.sh --dir \S+\/_integration --stem _integration/.test(l)).length;

test("two branches green alone and red merged: the summary reports a failed ## Integration check naming the check", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-beta.md");
  redWhenMerged(root);
  // Triage calls it not fixable: this test is about the report, not the fix issue.
  fake(root, "_integration.triage", triageVerdict("no", "clashing changes", "nothing a coder can do here"));
  const { r, lines } = commandLines(root, [], { integration: true });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  for (const f of ["alpha", "beta"]) {
    assert.equal(sh("git", ["-C", root, "cat-file", "-e", `feature/demo:src/${f}.txt`]).code, 0, `${f} passed its own verify and merged`);
  }
  assert.match(r.stdout, /## Integration check\s+\*\*Failed\*\* on feature\/demo at [0-9a-f]{12}/);
  assert.match(r.stdout, /- `test`: fail/);
  assert.match(r.stdout, /alpha and beta clash/, "the output tail is quoted");
  assert.equal(integrationRuns(lines), 1);
  assert.equal(state(root).integration.verdict, "fail");
  const log = traceLog(root);
  assert.match(log, /\[STEP\] step=integration branch=feature\/demo/);
  assert.match(log, /^\S+Z ERROR \[VERIFY-OUTPUT\] step=integration result=fail file=\S+\/_integration\/verify\.out$/m);
  assert.match(log, /^\S+Z ERROR INTEGRATION: fail — test \(feature\/demo at [0-9a-f]{12}\)$/m);
  // The throwaway worktree and its branch are gone.
  assert.equal(sh("git", ["-C", root, "branch", "--list", "crew/demo/_integration"]).stdout.trim(), "");
  assert.equal(existsSync(join(root, ".scratch/worktrees/crew/demo/_integration")), false);
  assert.equal(existsSync(join(root, ".scratch/demo/dispatch/_integration/verify.json")), true);
});

test("a green merged feature branch is reported passed, and a second drain at the same commit reuses the pass", () => {
  const root = fixtureRepo();
  // Two issues: a lone one merges to the very tree its verify passed, which reads cached.
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-beta.md");
  const first = commandLines(root, [], { integration: true });
  assert.equal(first.r.code, 0, `${first.r.stdout}\n${first.r.stderr}`);
  assert.match(first.r.stdout, /## Integration check\s+Passed on feature\/demo at [0-9a-f]{12}\./);
  assert.equal(integrationRuns(first.lines), 1);
  const tip = sh("git", ["-C", root, "rev-parse", "feature/demo"]).stdout.trim();
  assert.deepEqual({ commit: state(root).integration.commit, verdict: state(root).integration.verdict }, { commit: tip, verdict: "pass" });
  assert.equal(state(root).baseline, undefined, "its cache is not the baseline's");

  // Drained again with the branch untouched: nothing is re-run.
  const second = commandLines(root, [], { integration: true });
  assert.equal(second.r.code, 0, `${second.r.stdout}\n${second.r.stderr}`);
  assert.equal(integrationRuns(second.lines), 0);
  assert.match(second.r.stderr, /INTEGRATION: pass \(cached/);
  assert.match(second.r.stdout, /## Integration check\s+Passed on feature\/demo at [0-9a-f]{12} \(cached/);
});

test("a verify that passed on a worktree with uncommitted files does not stand in for the integration check", () => {
  // The committed tree lacks what the worktree had on disk, so the pass says nothing about it.
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.untracked", "");
  const { r, lines } = commandLines(root, [], { integration: true });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(integrationRuns(lines), 1, "the merged tree is checked, not read as cached");
  assert.match(traceLog(root), /\[TREE-NOT-CACHED\] slug=alpha/);
});

test("a drain with nothing merged runs no integration check", () => {
  const root = fixtureRepo();
  const { r, lines } = commandLines(root, [], { integration: true });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(integrationRuns(lines), 0);
  assert.doesNotMatch(r.stdout, /## Integration check/);
});

test("a red final integration check keeps --open-pr from opening the PR, and the summary says why", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-beta.md");
  redWhenMerged(root);
  // Triage calls it not fixable: this test is about the report, not the fix issue.
  fake(root, "_integration.triage", triageVerdict("no", "clashing changes", "nothing a coder can do here"));
  const { r, lines } = commandLines(root, ["--open-pr"], { integration: true });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  // Only the no-push call that turns an already-open PR into a draft (there is none here).
  assert.deepEqual(lines.filter((l) => /open-pr\.sh/.test(l)).map((l) => /--no-push/.test(l)), [true], "nothing was pushed");
  assert.match(r.stdout, /## Pull Request\s+\*\*Not opened:\*\* the integration check failed on feature\/demo — see ## Integration check above\./);
});

test("--no-integration-check and integrationCheck: false skip it; --no-baseline alone does not", () => {
  const off = fixtureRepo();
  addIssue(off, "01-alpha.md");
  const flag = commandLines(off, [], {});
  assert.equal(flag.r.code, 0, `${flag.r.stdout}\n${flag.r.stderr}`);
  assert.equal(integrationRuns(flag.lines), 0);
  assert.doesNotMatch(flag.r.stdout, /## Integration check/);

  const configured = fixtureRepo();
  addIssue(configured, "01-alpha.md");
  mkdirSync(join(configured, ".coding-crew"), { recursive: true });
  writeFileSync(join(configured, ".coding-crew/config.json"), JSON.stringify({ afk: { integrationCheck: false } }));
  sh("git", ["-C", configured, "add", "-A"]);
  sh("git", ["-C", configured, "commit", "-q", "-m", "config"]);
  const viaConfig = commandLines(configured, [], { integration: true });
  assert.equal(viaConfig.r.code, 0, `${viaConfig.r.stdout}\n${viaConfig.r.stderr}`);
  assert.equal(integrationRuns(viaConfig.lines), 0);

  const noBaseline = fixtureRepo();
  addIssue(noBaseline, "01-alpha.md");
  addIssue(noBaseline, "02-beta.md");
  const r = commandLines(noBaseline, ["--no-baseline"], { integration: true });
  assert.equal(r.r.code, 0, `${r.r.stdout}\n${r.r.stderr}`);
  assert.equal(integrationRuns(r.lines), 1, "--no-baseline does not turn the integration check off");
});

test("a baseline check is unchanged by the integration check: same stem, same cache, same stop", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  writeFileSync(join(root, "Makefile"), "test:\n\t@echo boom && exit 1\nlint:\n\t@echo ok\ntypecheck:\n\t@echo ok\n");
  sh("git", ["-C", root, "add", "-A"]);
  sh("git", ["-C", root, "commit", "-q", "-m", "red"]);
  const { r, lines } = commandLines(root, [], { baseline: true, integration: true });
  assert.equal(r.code, 1, `${r.stdout}\n${r.stderr}`);
  assert.equal(integrationRuns(lines), 0, "the run stopped before any drain");
  assert.equal(state(root).baseline.verdict, "fail");
  assert.equal(state(root).integration, undefined);
});

test("plan shows the integration check", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const plan = (extra) => sh("node", [MAIN, "plan", "--platform", "pi", "--feature-slug", "demo", ...extra], { cwd: root, env: { ...process.env, MAIN_ROOT: root } }).stdout;
  assert.match(plan([]), /^integration: the checks run on the merged feature branch each time the queue drains/m);
  assert.match(plan(["--no-integration-check"]), /^integration: disabled \(--no-integration-check\)$/m);
});

// ─── the feature review: crew-reviewer over the feature diff at each drain ──

const featureReviews = (lines) => lines.filter((l) => /^SPAWN .*--agent crew-reviewer.* --slug feature-\d+( |$)/.test(l)).length;

test("the queue's first drain runs one feature review over the whole feature diff, attributed to `feature`", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-beta.md");
  const base = sh("git", ["-C", root, "rev-parse", "HEAD"]).stdout.trim();
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(featureReviews(lines), 1);
  // The prompt: the whole diff from the merge-base with the (local) default branch, and no criteria.
  const prompt = readFileSync(join(root, ".scratch/demo/dispatch/feature-d1-1/review-prompt.md"), "utf8");
  assert.ok(prompt.includes(`Gather the diff: git diff ${base}..feature/demo`), prompt);
  assert.ok(prompt.includes(`Base: ${base}`));
  assert.match(prompt, /^Feature review: /m);
  assert.doesNotMatch(prompt, /Acceptance criteria:/);
  // Its result is a block of the sprint review report, under `feature`.
  assert.match(sprintReport(root), /^## Branch: feature \(feature\)$/m);
  assert.match(r.stdout, /## Feature Review\s+The feature was reviewed in 1 area\(s\): 0 finding\(s\)/);
  assert.match(r.stdout, /- feature: all-met \(C:0 H:0 M:0 L:0\)/);
  assert.match(traceLog(root), /\[STEP\] step=feature-review /);
});

test("the feature review records the tip it reviewed; a rerun on the same tip dispatches no reviewer", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const first = commandLines(root);
  assert.equal(first.r.code, 0, `${first.r.stdout}\n${first.r.stderr}`);
  assert.equal(featureReviews(first.lines), 1);
  const tip = sh("git", ["-C", root, "rev-parse", "feature/demo"]).stdout.trim();
  assert.equal(state(root).feature_review.reviewed_tip, tip);
  const again = commandLines(root);
  assert.equal(again.r.code, 0, `${again.r.stdout}\n${again.r.stderr}`);
  assert.equal(featureReviews(again.lines), 0);
  assert.match(traceLog(root), new RegExp(`FEATURE-REVIEW: skipped — nothing new since ${tip}`));
  assert.match(again.r.stdout, /## Feature Review\s+\*\*Not run:\*\* nothing new since/);
});

test("feature findings at or above fixFindings become a Phase 2 fix issue; the rest are counted by remind", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "feature.review", featureReviewFile([crossIssue("HIGH"), crossIssue("LOW", "Name the two retry loops alike")]));
  fake(root, "feature.review-later", featureReviewFile([])); // the Phase 2 drain's increment review
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const files = readdirSync(join(root, ".scratch/demo/issues/done"));
  assert.ok(files.some((f) => /fix-findings-feature\.md$/.test(f)), `the fix issue was implemented in Phase 2: ${files}`);
  assert.equal(state(root).completed_slugs.length, 2);
  const criteria = readFileSync(join(root, ".scratch/demo/reviews/feature.criteria.md"), "utf8");
  assert.match(criteria, /\[HIGH\] Share one retry helper between alpha and beta \(src\/alpha\.txt:1\)/);
  assert.doesNotMatch(criteria, /LOW/);
  // Re-run at the Phase 2 drain, over the commits since the first review.
  assert.equal(featureReviews(lines), 2);
  // The LOW is below the threshold: still open, so remind counts it (the HIGH is covered by the fix issue).
  const remind = sh("bash", [join(SCRIPTS, "promote-findings.sh"), "remind", "--feature-slug", "demo"], {
    cwd: root,
    env: { ...process.env, MAIN_ROOT: root, CREW_REVIEW_ROLLUP: join(REPO, "orchestrator/review-rollup.mjs") },
  });
  assert.match(remind.stdout, /^FINDINGS: open=1 \(LOW=1\)$/m);
});

test("the second drain's findings become a second fix issue; a third drain's are report-only and keep the run from green", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "feature.review", featureReviewFile([crossIssue("HIGH", "Share one retry helper")]));
  fake(root, "feature.review-later", featureReviewFile([crossIssue("HIGH", "Bound the retry loop")]));
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(featureReviews(lines), 3);
  const fixes = readdirSync(join(root, ".scratch/demo/issues/done")).filter((f) => /fix-findings-feature/.test(f));
  assert.equal(fixes.length, 2, `two fix issues, no third: ${fixes}`);
  assert.match(r.stdout, /Drain 1: The feature was reviewed in 1 area\(s\): 1 finding\(s\); 1 Actionable went to Phase 2/);
  assert.match(r.stdout, /Drain 2: The commits since the last review were reviewed in 1 area\(s\): 1 finding\(s\); 1 Actionable went to Phase 2/);
  assert.match(r.stdout, /Drain 3: .*1 finding\(s\); report-only \(past the promotion cap\)/);
  assert.match(traceLog(root), /FEATURE-REVIEW: 1 finding\(s\) the rule would promote are report-only/);
  assert.match(sprintReport(root), /Bound the retry loop/);
});

/** A copy of the crew-afk scripts whose open-pr.sh records its arguments instead of touching a remote. */
function scriptsWithFakeOpenPr(root) {
  const dir = join(root, ".scratch/scripts-fake-pr");
  cpSync(SCRIPTS, dir, { recursive: true });
  writeFileSync(join(dir, "open-pr.sh"), `#!/usr/bin/env bash\necho "$@" >> "${root}/open-pr.args"\necho "PR: http://x/1"\n`, { mode: 0o755 });
  return dir;
}

const thirdDrain = (root) => {
  fake(root, "feature.review", featureReviewFile([crossIssue("HIGH", "Share one retry helper")]));
  fake(root, "feature.review-later", featureReviewFile([{ severity: "HIGH", location: "src/beta.txt:9", criterion: "Bound the retry loop" }]));
};

test("--open-pr with a third-drain report-only finding: open-pr.sh gets --draft and the note names the finding", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  thirdDrain(root);
  const { r } = commandLines(root, ["--open-pr"], { scripts: scriptsWithFakeOpenPr(root) });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(readFileSync(join(root, "open-pr.args"), "utf8"), /--draft/);
  const note = readFileSync(join(root, ".scratch/demo/pr-note.md"), "utf8");
  assert.match(note, /past the promotion cap[^\n]*src\/beta\.txt:9 \(HIGH\)/);
});

test("a later --open-pr run that merges nothing still passes --draft and names the report-only finding from the report on disk", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  thirdDrain(root);
  const scripts = scriptsWithFakeOpenPr(root);
  const first = commandLines(root, ["--open-pr"], { scripts });
  assert.equal(first.r.code, 0, `${first.r.stdout}\n${first.r.stderr}`);
  rmSync(join(root, "open-pr.args"), { force: true });
  const second = commandLines(root, ["--open-pr"], { scripts });
  assert.equal(second.r.code, 0, `${second.r.stdout}\n${second.r.stderr}`);
  assert.equal(featureReviews(second.lines), 0, "nothing merged, no review");
  assert.match(readFileSync(join(root, "open-pr.args"), "utf8"), /--draft/);
  assert.match(readFileSync(join(root, ".scratch/demo/pr-note.md"), "utf8"), /past the promotion cap[^\n]*src\/beta\.txt:9 \(HIGH\)/);
});

test("--fix-findings none: no promotion-cap reason reaches the PR", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  thirdDrain(root);
  const { r } = commandLines(root, ["--open-pr", "--fix-findings", "none"], { scripts: scriptsWithFakeOpenPr(root) });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.doesNotMatch(r.stdout, /promotion cap/);
  const noteFile = join(root, ".scratch/demo/pr-note.md");
  assert.doesNotMatch(existsSync(noteFile) ? readFileSync(noteFile, "utf8") : "", /promotion cap/);
});

test("a finding repeated at a shifted line across drains appears once in the feature block", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "feature.review", featureReviewFile([{ severity: "HIGH", location: "src/alpha.txt:1", issue: "Retry loop is unbounded", criterion: "Bound it" }]));
  fake(root, "feature.review-later", featureReviewFile([{ severity: "HIGH", location: "src/alpha.txt:7", issue: "Retry loop is unbounded", criterion: "Bound it" }]));
  const { r } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const report = sprintReport(root);
  const last = [...report.matchAll(/## Branch: feature \(feature\)\n\n?```json\n(.*)\n```/g)].at(-1);
  const findings = JSON.parse(last[1]).findings;
  assert.equal(findings.length, 1, JSON.stringify(findings));
  assert.equal(findings[0].location, "src/alpha.txt:7");
});

test("a third-drain report-only finding stays open for promote-findings open/remind despite earlier promoted bullets", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  thirdDrain(root);
  const { r } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const env = { ...process.env, MAIN_ROOT: root, CREW_REVIEW_ROLLUP: join(REPO, "orchestrator/review-rollup.mjs") };
  const open = JSON.parse(sh("bash", [join(SCRIPTS, "promote-findings.sh"), "open", "--feature-slug", "demo"], { cwd: root, env }).stdout);
  assert.deepEqual(open.map((f) => f.criterion), ["Bound the retry loop"]);
  const remind = sh("bash", [join(SCRIPTS, "promote-findings.sh"), "remind", "--feature-slug", "demo"], { cwd: root, env });
  assert.match(remind.stdout, /^FINDINGS: open=1 \(HIGH=1\)$/m);
});

test("notGreenReasons: report-only feature findings make the run not green and are named", () => {
  assert.equal(isGreen({ integration: { status: "pass" }, unfixedFindings: [] }), true);
  assert.equal(isGreen({ integration: { status: "pass" }, unfixedFindings: [{ severity: "HIGH", location: "src/a.js:1" }] }), false);
});

test("a feature review with nothing at the threshold queues nothing, and --fix-findings none queues nothing at all", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "feature.review", featureReviewFile([crossIssue("MEDIUM")]));
  const { r } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.deepEqual(state(root).completed_slugs, ["alpha"]);
  assert.match(r.stdout, /1 finding\(s\) \(see /);

  const none = fixtureRepo();
  addIssue(none, "01-alpha.md");
  fake(none, "feature.review", featureReviewFile([crossIssue("CRITICAL")]));
  const off = commandLines(none, ["--fix-findings", "none"]);
  assert.equal(off.r.code, 0, `${off.r.stdout}\n${off.r.stderr}`);
  assert.deepEqual(state(none).completed_slugs, ["alpha"]);
});

test("nothing merged: no feature review", () => {
  const root = fixtureRepo();
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(featureReviews(lines), 0);
  assert.doesNotMatch(r.stdout, /## Feature Review/);
});

test("a red integration check skips the feature review, and the summary says so", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-beta.md");
  redWhenMerged(root);
  fake(root, "_integration.triage", triageVerdict("no", "clashing changes", "nothing a coder can do here"));
  const { r, lines } = commandLines(root, [], { integration: true });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(featureReviews(lines), 0);
  assert.match(r.stdout, /## Feature Review\s+\*\*Not run:\*\* the integration check is red/);
});

test("a feature review that never reports is recorded as not run, and does not fail the sprint", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "feature.review", ""); // no report.json: the dispatch left no verdict
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(featureReviews(lines), 1);
  assert.deepEqual(state(root).completed_slugs, ["alpha"]);
  assert.match(r.stdout, /## Feature Review\s+\*\*Not run:\*\* no report\.json/);
  assert.match(sprintReport(root), /^## Branch: feature-1 \(feature-1\)$/m);
  assert.match(r.stdout, /- feature-1: not-reviewed/);
  assert.match(traceLog(root), /FEATURE-REVIEW: feature-1 not run — /);
});

test("a feature review that times out is not run, not a failure; the reviewer's own timeout applies", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "feature.review-sleep", "3");
  const { r } = commandLines(root, ["--reviewer-timeout", "0.02"]);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stdout, /## Feature Review\s+\*\*Not run:\*\* review dispatch timed out/);
});

// ─── a red integration check is triaged, and a fixable one becomes a Phase 2 fix issue ───

/** Red while alpha's and beta's files are both present and no integration fix has landed (a fix
 * issue's slug starts `fix-integration`, and the fake coder commits src/<slug>.txt). Each branch
 * is green alone, and the fix branch — which has the fix file — is green too. */
function redUntilFixed(root) {
  writeFileSync(
    join(root, "Makefile"),
    "test:\n\t@if [ -f src/alpha.txt ] && [ -f src/beta.txt ] && ! ls src/fix-integration-* >/dev/null 2>&1; then echo 'alpha and beta clash' >&2; exit 1; fi\nlint:\n\t@echo ok\ntypecheck:\n\t@echo ok\n",
  );
  sh("git", ["-C", root, "add", "-A"]);
  sh("git", ["-C", root, "commit", "-q", "-m", "red until fixed"]);
}

const triageSpawns = (lines) => lines.filter((l) => /^SPAWN .*--agent crew-triage/.test(l)).length;
const integrationFixFiles = (root, dir) => {
  const d = join(root, ".scratch/demo/issues", dir);
  return existsSync(d) ? readdirSync(d).filter((f) => /fix-integration/.test(f)) : [];
};

test("a fixable red integration check becomes a fix issue, implemented in Phase 2, and the next drain passes", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-beta.md");
  redUntilFixed(root);
  fake(root, "_integration.triage", triageVerdict("yes", "clashing changes", "alpha.txt and beta.txt cannot both exist without src/fix-integration-*"));
  const { r, lines } = commandLines(root, [], { integration: true });
  assert.equal(r.code, 0, `the run is not stalled\n${r.stdout}\n${r.stderr}`);
  assert.equal(triageSpawns(lines), 1);
  assert.equal(integrationRuns(lines), 1, "red once; the fix branch merges to the tree its own verify passed, so the re-check is cached");
  assert.match(r.stderr, /INTEGRATION: pass \(cached/);
  assert.deepEqual(integrationFixFiles(root, "open"), []);
  assert.deepEqual(integrationFixFiles(root, "done"), ["03-fix-integration-1.md"]);
  assert.deepEqual(state(root).completed_slugs.sort(), ["alpha", "beta", "fix-integration-1"]);
  assert.equal(state(root).integration.verdict, "pass");
  assert.match(r.stdout, /## Integration check\s+Passed on feature\/demo at [0-9a-f]{12} \(cached/);
  assert.match(r.stdout, /Fix issue\(s\) from earlier red drain\(s\) this run: \S+03-fix-integration-1\.md/);
  assert.doesNotMatch(r.stdout, /STALLED/);
  // The fix issue: a source-guarded issue whose criterion is the checks, with triage's detail and the output tail.
  const issue = readFileSync(join(root, ".scratch/demo/issues/done/03-fix-integration-1.md"), "utf8");
  assert.match(issue, /^Source: .*dispatch\/_integration\/verify\.out \(integration\)$/m);
  assert.match(issue, /^- \[.\] The project's checks pass on the merged feature branch \(`feature\/demo`\)$/m);
  assert.match(issue, /Triage: clashing changes — alpha\.txt and beta\.txt cannot both exist/);
  assert.match(issue, /alpha and beta clash/);
  // Triage was a dispatch of its own, given the failing output, and logged with its verdict.
  const prompt = readFileSync(join(root, ".scratch/demo/dispatch/_integration/triage-prompt.md"), "utf8");
  assert.match(prompt, /merged feature branch/);
  assert.match(prompt, /alpha and beta clash/);
  assert.match(traceLog(root), /\[INTEGRATION-TRIAGE\] commit=[0-9a-f]{12} fixable=yes category=clashing changes/);
  assert.match(traceLog(root), /\[STEP\] slug=_integration round=1 step=dispatch-triage/);
  assert.ok(state(root).dispatches.some((d) => d.slug === "_integration" && d.role === "triage"), "its cost is in the ledger");
  // Findings on the fix branch are never promoted again: it carries a Source: line.
  assert.deepEqual(integrationFixFiles(root, "open"), []);
});

test("a missing command on a red integration check is not fixable: no triage, no fix issue, the summary says why", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-beta.md");
  // The tool is only reached once both branches are merged, so each passes its own verify.
  mkdirSync(join(root, ".coding-crew"), { recursive: true });
  writeFileSync(
    join(root, ".coding-crew/dev-commands.json"),
    JSON.stringify({ test: "if [ -f src/alpha.txt ] && [ -f src/beta.txt ]; then crew-no-such-tool; fi", lint: "make lint", typecheck: "make typecheck", coverage: null, integration: null }),
  );
  sh("git", ["-C", root, "add", "-A"]);
  sh("git", ["-C", root, "commit", "-q", "-m", "cache"]);
  fake(root, "commands.response", '{"install": null, "env": null, "credential_target": null}');
  const { r, lines } = commandLines(root, [], { integration: true });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(triageSpawns(lines), 0);
  assert.deepEqual([...integrationFixFiles(root, "open"), ...integrationFixFiles(root, "done")], []);
  assert.match(r.stdout, /## Integration check\s+\*\*Failed\*\*/);
  assert.match(r.stdout, /\*\*Not fixable by a code change, no fix issue queued:\*\* missing command: crew-no-such-tool is not installed \(test\)\./);
  assert.match(traceLog(root), /\[INTEGRATION-TRIAGE\] commit=[0-9a-f]{12} verdict=not-fixable — missing command: crew-no-such-tool is not installed \(test\); triage skipped/);
});

test("triage calling a red integration check not fixable queues nothing, skips the PRD audit, and says so", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-beta.md");
  redUntilFixed(root);
  fake(root, "_integration.triage", triageVerdict("no", "service down", "the database the integration tests use is not reachable"));
  const { r, lines } = commandLines(root, [], { integration: true });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(triageSpawns(lines), 1);
  assert.deepEqual([...integrationFixFiles(root, "open"), ...integrationFixFiles(root, "done")], []);
  assert.match(r.stdout, /\*\*Not fixable by a code change, no fix issue queued:\*\* service down: the database the integration tests use is not reachable\./);
  assert.match(r.stdout, /The rest of the drain-time checks \(the PRD audit\) were skipped\./);
  assert.match(r.stdout, /## PRD Audit\s+\*\*Not run:\*\* the integration check failed/);
  assert.equal(traceLog(root).split("step=prd-audit").length - 1, 0, "the audit never ran");
  assert.match(traceLog(root), /fixable=no category=service down/);
});

test("a triage dispatch that fails is treated as fixable once: a fix issue, and a coder attempt on it", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-beta.md");
  redUntilFixed(root);
  // No _integration.triage fixture: the fake leaves no sidecar, as a dead triage dispatch would.
  const { r, lines } = commandLines(root, [], { integration: true });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(triageSpawns(lines), 1);
  assert.deepEqual(integrationFixFiles(root, "done"), ["03-fix-integration-1.md"]);
  assert.match(traceLog(root), /fixable=failed→yes category=triage did not complete/);
  assert.match(r.stdout, /Fix issue\(s\) from earlier red drain\(s\) this run/);
});

test("a fix issue that passes its own verify makes the merged tree a passed tree: the next drain is cached, not re-run", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-beta.md");
  // Red only in the integration worktree, whatever any fix does. The fix issue passes its own
  // verify and merges to exactly that tree, so no second integration run is paid for.
  writeFileSync(join(root, "Makefile"), "test:\n\t@case \"$$PWD\" in *_integration) echo 'alpha and beta clash' >&2; exit 1;; esac\nlint:\n\t@echo ok\ntypecheck:\n\t@echo ok\n");
  sh("git", ["-C", root, "add", "-A"]);
  sh("git", ["-C", root, "commit", "-q", "-m", "always red when merged"]);
  fake(root, "_integration.triage", triageVerdict("yes", "clashing changes", "reconcile alpha and beta"));
  const { r, lines } = commandLines(root, [], { integration: true });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(triageSpawns(lines), 1);
  assert.equal(integrationRuns(lines), 1);
  assert.deepEqual(integrationFixFiles(root, "done"), ["03-fix-integration-1.md"]);
  assert.match(r.stderr, /INTEGRATION: pass \(cached/);
});

test("a fix issue whose coder blocks leaves the same commit red: no second triage, no second fix issue", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-beta.md");
  redUntilFixed(root);
  fake(root, "_integration.triage", triageVerdict("yes", "clashing changes", "reconcile alpha and beta"));
  fake(root, "fix-integration-1.exit", "1");
  const { r, lines } = commandLines(root, [], { integration: true });
  assert.equal(r.code, 2, `${r.stdout}\n${r.stderr}`);
  assert.equal(triageSpawns(lines), 1);
  assert.deepEqual(integrationFixFiles(root, "open"), ["03-fix-integration-1.md"]);
  assert.match(r.stdout, /\*\*Fix issue \S+03-fix-integration-1\.md was queued for this commit and has not landed\*\*/);
});

test("fix issues whose merged tree differs from their verified tree stay red: the cap stalls the run with no further fix issue", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-beta.md");
  // Red in the integration worktree whatever any fix does. While a fix issue is verified, the
  // feature branch moves (a sibling commit), so the fix merges to a tree its verify never saw
  // and the integration check must really run again instead of reading cached.
  const bump = [
    "m=$$(cd $$(git rev-parse --git-common-dir)/.. && pwd)",
    "f=$$(basename $$PWD)",
    "echo x > $$m/bump-$$f.txt",
    "git -C $$m add bump-$$f.txt",
    "git -C $$m commit -q -m bump-$$f",
  ].join("; ");
  writeFileSync(
    join(root, "Makefile"),
    `test:\n\t@case "$$PWD" in *_integration) echo 'alpha and beta clash' >&2; exit 1;; *fix-integration-*) ${bump};; esac\nlint:\n\t@echo ok\ntypecheck:\n\t@echo ok\n`,
  );
  sh("git", ["-C", root, "add", "-A"]);
  sh("git", ["-C", root, "commit", "-q", "-m", "red when merged; fixes move the branch"]);
  fake(root, "_integration.triage", triageVerdict("yes", "clashing changes", "reconcile alpha and beta"));
  const { r, lines } = commandLines(root, [], { integration: true });
  assert.equal(r.code, 2, `${r.stdout}\n${r.stderr}`);
  assert.equal(triageSpawns(lines), 2, "two fix issues were triaged; the third red drain is capped before triage");
  assert.deepEqual(integrationFixFiles(root, "done"), ["03-fix-integration-1.md", "04-fix-integration-2.md"]);
  assert.deepEqual(integrationFixFiles(root, "open"), [], "no third fix issue");
  assert.equal(integrationRuns(lines), 3, "every drain's merged tree was new, so none was cached");
  assert.match(r.stdout, /2 integration fix issues were already implemented this run .* no further fix issue/);
  assert.match(traceLog(root), /\[INTEGRATION-TRIAGE\] commit=[0-9a-f]{12} verdict=limit/);
});

test("github: a fixable red integration check creates the fix issue in the milestone, ready-for-agent, and implements it", () => {
  const root = githubFixtureRepo();
  const GH_BETA = { ...GH_ALPHA, number: 2, title: "beta", body: "# beta\n\n## Acceptance criteria\n\n- [x] beta exists\n" };
  const { stub, issuesFile } = stubGh(root, [GH_ALPHA, GH_BETA]);
  redUntilFixed(root);
  // The stub's own files are untracked; keep the tree clean for the merge gate.
  fake(root, "_integration.triage", triageVerdict("yes", "clashing changes", "reconcile alpha and beta"));
  const r = sh("node", [MAIN, "run", "--platform", "pi", "--feature-slug", "demo", "--no-baseline"], {
    cwd: root,
    env: {
      ...process.env,
      CREW_SCRIPTS: SCRIPTS,
      CREW_FAKE_DISPATCH: FAKE,
      CREW_FAKE_DIR: join(root, ".scratch/fake"),
      MAIN_ROOT: root,
      CREW_GITHUB_TRACKER_CLI: join(REPO, "orchestrator/lib/trackers/github.mjs"),
      GH_LIST_LAG_MS: "3000",
      PATH: `${stub}:${process.env.PATH}`,
    },
  });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const fix = JSON.parse(readFileSync(issuesFile, "utf8")).find((i) => /^Fix integration check: demo \(at [0-9a-f]{12}\)$/.test(i.title));
  assert.ok(fix, `the integration fix issue was never created\n${traceLog(root)}`);
  assert.match(fix.body, /^Source: integration check \(integration\)$/m);
  assert.doesNotMatch(fix.body, /\.scratch\//);
  assert.match(fix.body, /^- \[ \] The project's checks pass on the merged feature branch/m);
  assert.ok(fix.labels.some((l) => l.name === "ready-for-agent" || l.name === "awaiting-merge"));
  assert.ok(fix.labels.some((l) => l.name === "awaiting-merge"), `the fix issue was never implemented\n${traceLog(root)}`);
  assert.match(traceLog(root), /fix issue\(s\) listed after \d+ poll/);
  assert.match(r.stdout, /## Integration check\s+Passed/);
  assert.doesNotMatch(r.stdout, /Fix issues not implemented/);
});

// ─── reviewer, triage and feature review are mechanically read-only ──

test("a reviewer that commits to the issue branch is not-run, logged [READONLY-VIOLATION], and never merged", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.misbehave", "commit");
  const { r } = commandLines(root, ["--max-rounds", "1"]);
  assert.match(traceLog(root), /\[READONLY-VIOLATION\] reviewer alpha: changed refs\/heads\/crew\/demo\/alpha/, `${r.stdout}\n${r.stderr}`);
  assert.match(state(root).retention.alpha.reason, /^review-not-run/);
  assert.deepEqual(state(root).merged_branches ?? [], []);
});

test("a feature review that leaves an uncommitted edit in the main checkout is recorded not-run", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "feature.misbehave", "edit");
  const { r } = commandLines(root);
  assert.match(traceLog(root), /\[READONLY-VIOLATION\] feature-1: changed uncommitted changes in the main checkout/, `${r.stdout}\n${r.stderr}`);
  assert.match(traceLog(root), /FEATURE-REVIEW: feature-1 not run/);
});

test("a triage that edits the main checkout is not-run with the same log line", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  // A real verify failure (the worker commits; the check is red) routes to triage.
  writeFileSync(join(root, "Makefile"), "test:\n\t@echo boom && exit 1\nlint:\n\t@echo ok\ntypecheck:\n\t@echo ok\n");
  sh("git", ["-C", root, "add", "-A"]);
  sh("git", ["-C", root, "commit", "-q", "-m", "make test always fail"]);
  fake(root, "alpha.misbehave", "edit");
  const { r } = commandLines(root, ["--max-rounds", "1"]);
  assert.match(traceLog(root), /\[READONLY-VIOLATION\] triage alpha/, `${r.stdout}\n${r.stderr}`);
});

test("a reviewer that changes nothing proceeds as before, and the AC receipt names the reviewed sha", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const { r } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.doesNotMatch(traceLog(root), /READONLY-VIOLATION/);
  assert.deepEqual(state(root).merged_branches, ["crew/demo/alpha"]);
});
