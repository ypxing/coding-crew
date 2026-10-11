/**
 * Sprint suite — feature-review findings across runs: the per-feature promotion cap, report-only findings and the draft PR.
 * Shared helpers: ./helpers/sprint.mjs.
 */

import assert from "node:assert/strict";
import { draftMarker, isGreen } from "../../orchestrator/lib/loop.mjs";
import { cpSync, mkdirSync, rmSync, readFileSync, readdirSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { REPO, MAIN, SCRIPTS, FAKE, sh, fixtureRepo, addIssue, traceLog, state, fake, triageVerdict, githubFixtureRepo, stubGh, GH_ALPHA, commandLines, featureReviewFile, crossIssue, sprintReport, redWhenMerged, featureReviews, featureFixes, scriptsWithFakeOpenPr, test } from "./helpers/sprint.mjs";

// The cap counts per feature (sprint-state.json's feature_review.promotions), not per run.
const nextRunReviews = (root, first, later = first) => {
  rmSync(join(root, ".scratch/fake/feature.review.calls"), { force: true });
  fake(root, "feature.review", featureReviewFile(first));
  fake(root, "feature.review-later", featureReviewFile(later));
};

test("a run after the feature's fix issue is report-only: no fix issue, its would-be promotions keep the PR a draft", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "feature.review", featureReviewFile([crossIssue("HIGH", "Share one retry helper")]));
  fake(root, "feature.review-later", featureReviewFile([]));
  const first = commandLines(root);
  assert.equal(first.r.code, 0, `${first.r.stdout}\n${first.r.stderr}`);
  assert.equal(featureFixes(root).length, 1);
  assert.equal(state(root).feature_review.promotions, 1);

  addIssue(root, "02-beta.md");
  nextRunReviews(root, [{ severity: "HIGH", location: "src/beta.txt:9", criterion: "Cap the beta retries" }]);
  const second = commandLines(root, ["--open-pr"], { scripts: scriptsWithFakeOpenPr(root) });
  assert.equal(second.r.code, 0, `${second.r.stdout}\n${second.r.stderr}`);
  assert.equal(featureReviews(second.lines), 1);
  assert.equal(featureFixes(root).length, 1, "no fix issue in the second run");
  assert.match(second.r.stdout, /report-only \(past the promotion cap\)/);
  assert.doesNotMatch(second.r.stdout, /went to Phase 2/);
  assert.match(readFileSync(join(root, "open-pr.args"), "utf8"), /--draft/);
  assert.match(readFileSync(join(root, ".scratch/demo/pr-note.md"), "utf8"), /past the promotion cap[^\n]*src\/beta\.txt:9 \(HIGH\)/);
});

test("an earlier version's feature_review.promotions of 2 reads as capped: no fix issue", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  assert.equal(commandLines(root).r.code, 0);
  const sf = join(root, ".scratch/demo/sprint-state.json");
  writeFileSync(sf, JSON.stringify({ ...state(root), feature_review: { ...state(root).feature_review, promotions: 2 } }));

  addIssue(root, "02-beta.md");
  nextRunReviews(root, [crossIssue("HIGH", "Share one retry helper")]);
  const next = commandLines(root);
  assert.equal(next.r.code, 0, `${next.r.stdout}\n${next.r.stderr}`);
  assert.equal(featureReviews(next.lines), 1);
  assert.equal(featureFixes(root).length, 0);
  assert.match(next.r.stdout, /report-only \(past the promotion cap\)/);
  assert.equal(state(root).feature_review.promotions, 2);
});

test("a review with nothing promotable leaves promotions at 0; a later run's promotable finding makes the feature's fix issue", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const first = commandLines(root);
  assert.equal(first.r.code, 0, `${first.r.stdout}\n${first.r.stderr}`);
  assert.equal(featureReviews(first.lines), 1);
  assert.equal(state(root).feature_review.promotions ?? 0, 0, "a clean review creates no fix issue, so it does not count");

  addIssue(root, "02-beta.md");
  nextRunReviews(root, [crossIssue("HIGH", "Share one retry helper")], []);
  const next = commandLines(root);
  assert.equal(next.r.code, 0, `${next.r.stdout}\n${next.r.stderr}`);
  assert.equal(featureReviews(next.lines), 2, "the review, and the closing review over the merged fix issue");
  assert.equal(featureFixes(root).length, 1);
  assert.match(next.r.stdout, /The commits since the last review were reviewed: 1 finding\(s\); 1 Actionable went to Phase 2/);
  assert.equal(state(root).feature_review.promotions, 1);
});

/** A copy of the crew-afk scripts whose open-pr.sh records its arguments instead of touching a remote. */
/** Two runs: the first's finding makes the feature's fix issue, the second's (on beta) is report-only. Returns the second. */
const laterRun = (root, args = [], opts = {}) => {
  addIssue(root, "01-alpha.md");
  fake(root, "feature.review", featureReviewFile([crossIssue("HIGH", "Share one retry helper")]));
  fake(root, "feature.review-later", featureReviewFile([]));
  const first = commandLines(root, args, opts);
  assert.equal(first.r.code, 0, `${first.r.stdout}\n${first.r.stderr}`);
  addIssue(root, "02-beta.md");
  nextRunReviews(root, [{ severity: "HIGH", location: "src/beta.txt:9", criterion: "Bound the retry loop" }]);
  return commandLines(root, args, opts);
};

test("a later --open-pr run that merges nothing still passes --draft and names the report-only finding from the report on disk", () => {
  const root = fixtureRepo();
  const scripts = scriptsWithFakeOpenPr(root);
  const first = laterRun(root, ["--open-pr"], { scripts });
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
  fake(root, "feature.review", featureReviewFile([crossIssue("HIGH", "Share one retry helper")]));
  const { r } = commandLines(root, ["--open-pr", "--fix-findings", "none"], { scripts: scriptsWithFakeOpenPr(root) });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.doesNotMatch(r.stdout, /promotion cap/);
  const noteFile = join(root, ".scratch/demo/pr-note.md");
  assert.doesNotMatch(existsSync(noteFile) ? readFileSync(noteFile, "utf8") : "", /promotion cap/);
});

test("a finding repeated at a shifted line across runs appears once in the feature block", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "feature.review", featureReviewFile([{ severity: "HIGH", location: "src/alpha.txt:1", issue: "Retry loop is unbounded", criterion: "Bound it" }]));
  assert.equal(commandLines(root).r.code, 0);
  addIssue(root, "02-beta.md");
  nextRunReviews(root, [{ severity: "HIGH", location: "src/alpha.txt:7", issue: "Retry loop is unbounded", criterion: "Bound it" }]);
  const { r } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const report = sprintReport(root);
  const last = [...report.matchAll(/## Branch: feature \(feature\)\n\n?```json\n(.*)\n```/g)].at(-1);
  const findings = JSON.parse(last[1]).findings;
  assert.equal(findings.length, 1, JSON.stringify(findings));
  assert.equal(findings[0].location, "src/alpha.txt:7");
});

test("a later run's report-only finding stays open for promote-findings open/remind despite earlier promoted bullets", () => {
  const root = fixtureRepo();
  const { r } = laterRun(root);
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
  assert.match(sprintReport(root), /^## Branch: feature \(feature\)$/m);
  assert.match(r.stdout, /- feature: not-reviewed/);
  assert.match(traceLog(root), /FEATURE-REVIEW: feature not run — /);
});
