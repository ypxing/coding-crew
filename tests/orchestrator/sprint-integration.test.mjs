/**
 * Sprint suite — the integration check, the feature review, and triaging a red integration check.
 * Shared helpers: ./helpers/sprint.mjs.
 */

import assert from "node:assert/strict";
import { mkdirSync, readFileSync, readdirSync, writeFileSync, existsSync } from "node:fs";
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
  addIssue(root, "01-alpha.md");
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
  assert.equal(lines.filter((l) => /open-pr\.sh/.test(l)).length, 0, "nothing was pushed");
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

// ─── the feature review: crew-reviewer over the whole feature diff, once, at the first drain ──

const featureReviews = (lines) => lines.filter((l) => /^SPAWN .*--agent crew-reviewer.* --slug feature( |$)/.test(l)).length;

test("the queue's first drain runs one feature review over the whole feature diff, attributed to `feature`", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-beta.md");
  const base = sh("git", ["-C", root, "rev-parse", "HEAD"]).stdout.trim();
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(featureReviews(lines), 1);
  // The prompt: the whole diff from the base commit the sprint state recorded, and no criteria.
  const prompt = readFileSync(join(root, ".scratch/demo/dispatch/feature/review-prompt.md"), "utf8");
  assert.ok(prompt.includes(`Gather the diff: git diff ${base}..feature/demo`), prompt);
  assert.ok(prompt.includes(`Base: ${base}`));
  assert.match(prompt, /^Feature review: /m);
  assert.doesNotMatch(prompt, /Acceptance criteria:/);
  // Its result is a block of the sprint review report, under `feature`.
  assert.match(sprintReport(root), /^## Branch: feature \(feature\)$/m);
  assert.match(r.stdout, /## Feature Review\s+The whole feature diff was reviewed once: 0 finding\(s\)/);
  assert.match(r.stdout, /- feature: all-met \(C:0 H:0 M:0 L:0\)/);
  assert.match(traceLog(root), /\[STEP\] step=feature-review /);
});

test("feature findings at or above fixFindings become a Phase 2 fix issue; the rest are counted by remind", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "feature.review", featureReviewFile([crossIssue("HIGH"), crossIssue("LOW", "Name the two retry loops alike")]));
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const files = readdirSync(join(root, ".scratch/demo/issues/done"));
  assert.ok(files.some((f) => /fix-findings-feature\.md$/.test(f)), `the fix issue was implemented in Phase 2: ${files}`);
  assert.equal(state(root).completed_slugs.length, 2);
  const criteria = readFileSync(join(root, ".scratch/demo/reviews/feature.criteria.md"), "utf8");
  assert.match(criteria, /\[HIGH\] Share one retry helper between alpha and beta \(src\/alpha\.txt:1\)/);
  assert.doesNotMatch(criteria, /LOW/);
  // Not re-run after Phase 2, whose own fix issue was reviewed on its own diff.
  assert.equal(featureReviews(lines), 1);
  // The LOW is below the threshold: still open, so remind counts it (the HIGH is covered by the fix issue).
  const remind = sh("bash", [join(SCRIPTS, "promote-findings.sh"), "remind", "--feature-slug", "demo"], {
    cwd: root,
    env: { ...process.env, MAIN_ROOT: root, CREW_REVIEW_ROLLUP: join(REPO, "orchestrator/review-rollup.mjs") },
  });
  assert.match(remind.stdout, /^FINDINGS: open=1 \(LOW=1\)$/m);
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
  assert.match(traceLog(root), /FEATURE-REVIEW: not run — /);
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
  assert.equal(integrationRuns(lines), 2, "red, then re-checked after the fix");
  assert.deepEqual(integrationFixFiles(root, "open"), []);
  assert.deepEqual(integrationFixFiles(root, "done"), ["03-fix-integration-1.md"]);
  assert.deepEqual(state(root).completed_slugs.sort(), ["alpha", "beta", "fix-integration-1"]);
  assert.equal(state(root).integration.verdict, "pass");
  assert.match(r.stdout, /## Integration check\s+Passed on feature\/demo at [0-9a-f]{12}\./);
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

test("the third red drain in a run is reported, ends the run stalled, and creates no third fix issue", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-beta.md");
  // Red only in the integration worktree, whatever any fix does: each fix issue passes its own
  // verify and merges, and the merged branch is red again.
  writeFileSync(join(root, "Makefile"), "test:\n\t@case \"$$PWD\" in *_integration) echo 'alpha and beta clash' >&2; exit 1;; esac\nlint:\n\t@echo ok\ntypecheck:\n\t@echo ok\n");
  sh("git", ["-C", root, "add", "-A"]);
  sh("git", ["-C", root, "commit", "-q", "-m", "always red when merged"]);
  fake(root, "_integration.triage", triageVerdict("yes", "clashing changes", "reconcile alpha and beta"));
  const { r, lines } = commandLines(root, [], { integration: true });
  assert.equal(r.code, 2, `stalled\n${r.stdout}\n${r.stderr}`);
  assert.equal(triageSpawns(lines), 2, "no triage for the capped drain");
  assert.equal(integrationRuns(lines), 3);
  assert.deepEqual(integrationFixFiles(root, "done"), ["03-fix-integration-1.md", "04-fix-integration-2.md"]);
  assert.deepEqual(integrationFixFiles(root, "open"), []);
  assert.match(r.stdout, /\*\*Not fixed:\*\* 2 integration fix issues were already implemented this run and the merged feature branch is still red — no further fix issue\./);
  assert.match(r.stdout, /STALLED/);
  assert.match(traceLog(root), /\[INTEGRATION-TRIAGE\] commit=[0-9a-f]{12} verdict=limit/);
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
  assert.match(fix.body, /^Source: .*verify\.out \(integration\)$/m);
  assert.match(fix.body, /^- \[ \] The project's checks pass on the merged feature branch/m);
  assert.ok(fix.labels.some((l) => l.name === "ready-for-agent" || l.name === "awaiting-merge"));
  assert.ok(fix.labels.some((l) => l.name === "awaiting-merge"), `the fix issue was never implemented\n${traceLog(root)}`);
  assert.match(traceLog(root), /fix issue\(s\) listed after \d+ poll/);
  assert.match(r.stdout, /## Integration check\s+Passed/);
  assert.doesNotMatch(r.stdout, /Fix issues not implemented/);
});
