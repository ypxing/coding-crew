/**
 * Sprint suite — fixFindings actionable: crew-triage judges each finding.
 * Shared helpers: ./helpers/sprint.mjs.
 */

import assert from "node:assert/strict";
import { mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { REPO, SCRIPTS, sh, fixtureRepo, addIssue, traceLog, state, fake, commandLines, featureReviewFile, crossIssue, sprintReport, test } from "./helpers/sprint.mjs";
import { reportOnlyFeatureFindings } from "../../orchestrator/lib/pipeline/feature-review.mjs";

// ─── fixFindings actionable (the default): crew-triage judges each finding, whatever its severity ──

// Findings come from the feature review alone, once per run.
const featureFindings = (root, findings) => fake(root, "feature.review", featureReviewFile(findings));
const findingVerdicts = (list) => ["```json", JSON.stringify({ findings: list.map((f, index) => ({ index, ...f })) }), "```"].join("\n");
const findingsTriageSpawns = (lines) => lines.filter((l) => /^SPAWN .*--agent crew-triage.* --slug \S*-findings( |$)/.test(l)).length;
const remindOf = (root) =>
  sh("bash", [join(SCRIPTS, "promote-findings.sh"), "remind", "--feature-slug", "demo"], {
    cwd: root,
    env: { ...process.env, MAIN_ROOT: root, CREW_REVIEW_ROLLUP: join(REPO, "orchestrator/review-rollup.mjs") },
  }).stdout;
const retryHigh = { severity: "HIGH", location: "src/alpha.txt:1", criterion: "Redesign the retry contract" };
const retryLow = { severity: "LOW", location: "src/alpha.txt:2", criterion: "Name the retry constant" };

test("actionable: an Actionable LOW is fixed in Phase 2, a Debatable HIGH is not, and the verdicts are in the report", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  featureFindings(root, ([retryHigh, retryLow]));
  fake(
    root,
    "feature-findings.triage",
    findingVerdicts([
      { verdict: "debatable", rationale: "the fix changes the public retry contract" },
      { verdict: "actionable", rationale: "one local rename" },
    ]),
  );
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(state(root).completed_slugs.length, 2, "the LOW ran as a Phase 2 fix issue");
  const criteria = readFileSync(join(root, ".scratch/demo/reviews/feature.criteria.md"), "utf8");
  assert.match(criteria, /\[LOW\] Name the retry constant/);
  assert.doesNotMatch(criteria, /HIGH/, "a Debatable HIGH is left for a human");
  // A dispatch of its own, to crew-triage, over the whole review's findings; none for the fix issue.
  assert.equal(findingsTriageSpawns(lines), 1);
  const prompt = readFileSync(join(root, ".scratch/demo/dispatch/feature-d1/findings-triage-prompt.md"), "utf8");
  assert.match(prompt, /^Findings mode: /m);
  assert.match(prompt, /^0 — HIGH — src\/alpha\.txt:1 — Redesign the retry contract$/m);
  assert.match(prompt, /^1 — LOW — src\/alpha\.txt:2 — Name the retry constant$/m);
  assert.match(traceLog(root), /FINDINGS-TRIAGE: feature: 1 actionable, 1 debatable/);
  assert.ok(state(root).dispatches.some((d) => d.slug === "feature" && d.role === "triage"), "its cost is in the ledger");
  // Each finding carries its verdict and rationale in the review report.
  const report = sprintReport(root);
  assert.match(report, /"verdict":"debatable","rationale":"the fix changes the public retry contract"/);
  assert.match(report, /"verdict":"actionable","rationale":"one local rename"/);
  assert.match(report, /^- feature: actionable → /m);
  // remind: the promoted Actionable is handled; the Debatable leads what is left.
  const remind = remindOf(root);
  assert.match(remind, /^FINDINGS: open=1 \(HIGH=1\)$/m);
  assert.match(remind, /^DEBATABLE: 1 \(decide these first\)$/m);
  assert.match(remind, /^debatable: feature \[HIGH\] src\/alpha\.txt:1 — Redesign the retry contract — why: the fix changes the public retry contract$/m);
  assert.ok(remind.indexOf("DEBATABLE:") < remind.indexOf("report:"), "Debatable leads");
  assert.match(r.stdout, /1 Debatable — decide these first/);
});

test("actionable: a finding triage marks duplicate_of is folded into its target: promoted once, shown once", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  featureFindings(root, ([retryLow, retryHigh]));
  fake(
    root,
    "feature-findings.triage",
    findingVerdicts([
      { verdict: "actionable", rationale: "one rename" },
      { verdict: "actionable", rationale: "same defect", duplicate_of: 0 },
    ]),
  );
  const { r } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const criteria = readFileSync(join(root, ".scratch/demo/reviews/feature.criteria.md"), "utf8");
  assert.equal((criteria.match(/^- \[ \]/gm) ?? []).length, 1);
  assert.match(criteria, /\[HIGH\]/);
  assert.match(criteria, /src\/alpha\.txt:2/);
  assert.match(criteria, /src\/alpha\.txt:1/);
  assert.match(sprintReport(root), /"duplicate_of":0/);
  assert.match(remindOf(root), /^FINDINGS: none$/m);
});

test("a first feature review with 11 promotable findings: one fix issue with the 8 most severe, CRITICAL→LOW; the other 3 report_only and open", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const at = (severity, n) => ({ severity, location: `src/alpha.txt:${n}`, issue: `Defect ${n}`, criterion: `Fix defect ${n}` });
  const eleven = [at("LOW", 1), at("MEDIUM", 2), at("HIGH", 3), at("CRITICAL", 4), at("LOW", 5), at("MEDIUM", 6), at("HIGH", 7), at("LOW", 8), at("MEDIUM", 9), at("LOW", 10), at("CRITICAL", 11)];
  fake(root, "feature.review", featureReviewFile(eleven));
  fake(root, "feature-findings.triage", findingVerdicts(eleven.map(() => ({ verdict: "actionable", rationale: "a real defect" }))));
  const { r } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const fixes = readdirSync(join(root, ".scratch/demo/issues/done")).filter((f) => /fix-findings-feature/.test(f));
  assert.equal(fixes.length, 1, `one fix issue: ${fixes}`);
  const criteria = readFileSync(join(root, ".scratch/demo/reviews/feature.criteria.md"), "utf8");
  const listed = [...criteria.matchAll(/^- \[ \] \[(\w+)\] Fix defect (\d+)/gm)].map((m) => `${m[1]}:${m[2]}`);
  assert.deepEqual(listed, ["CRITICAL:4", "CRITICAL:11", "HIGH:3", "HIGH:7", "MEDIUM:2", "MEDIUM:6", "MEDIUM:9", "LOW:1"]);
  const env = { ...process.env, MAIN_ROOT: root, CREW_REVIEW_ROLLUP: join(REPO, "orchestrator/review-rollup.mjs") };
  const open = JSON.parse(sh("bash", [join(SCRIPTS, "promote-findings.sh"), "open", "--feature-slug", "demo"], { cwd: root, env }).stdout);
  assert.deepEqual(open.map((f) => f.criterion).sort(), ["Fix defect 10", "Fix defect 5", "Fix defect 8"]);
  // Open only because they are report_only: the fix issue's bullet covers the feature's Actionable findings.
  assert.deepEqual(reportOnlyFeatureFindings(join(root, ".scratch/demo/reviews")).map((f) => f.criterion).sort(), ["Fix defect 10", "Fix defect 5", "Fix defect 8"]);
  assert.match(r.stdout, /The feature was reviewed: 11 finding\(s\); 8 Actionable went to Phase 2, 3 more report-only \(past the fix issue's limit\)/);
});

test("a duplicate_of a finding past the fix issue's 8 stays open, folded into its report_only target", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const at = (severity, n) => ({ severity, location: `src/alpha.txt:${n}`, issue: `Defect ${n}`, criterion: `Fix defect ${n}` });
  // 8 HIGHs fill the fix issue; LOW 9 overflows, and LOW 10 is triage's duplicate of it.
  const ten = [...Array.from({ length: 8 }, (_, i) => at("HIGH", i + 1)), at("LOW", 9), at("LOW", 10)];
  fake(root, "feature.review", featureReviewFile(ten));
  fake(root, "feature-findings.triage", findingVerdicts(ten.map((_, i) => (i === 9
    ? { verdict: "actionable", rationale: "same defect", duplicate_of: 8 }
    : { verdict: "actionable", rationale: "a real defect" }))));
  const { r } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const criteria = readFileSync(join(root, ".scratch/demo/reviews/feature.criteria.md"), "utf8");
  assert.doesNotMatch(criteria, /defect (9|10)\b/);
  const env = { ...process.env, MAIN_ROOT: root, CREW_REVIEW_ROLLUP: join(REPO, "orchestrator/review-rollup.mjs") };
  const open = JSON.parse(sh("bash", [join(SCRIPTS, "promote-findings.sh"), "open", "--feature-slug", "demo"], { cwd: root, env }).stdout);
  assert.deepEqual(open.map((f) => [f.criterion, f.location]), [["Fix defect 9 (also at src/alpha.txt:10)", "src/alpha.txt:9, src/alpha.txt:10"]]);
});

test("actionable: a duplicate_of pair at a report-only feature review (a later run) leaves its target report_only, open and not green", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const target = { severity: "MEDIUM", location: "src/alpha.txt:1", issue: "Retry loop is unbounded", criterion: "Bound the retry loop" };
  const dup = { severity: "HIGH", location: "src/beta.txt:9", issue: "Beta retries forever", criterion: "Bound beta's retry" };
  fake(root, "feature.review", featureReviewFile([target, dup]));
  fake(root, "feature-findings.triage", findingVerdicts([
    { verdict: "actionable", rationale: "one fix" },
    { verdict: "actionable", rationale: "same defect", duplicate_of: 0 },
  ]));
  assert.equal(commandLines(root).r.code, 0); // the feature's fix issue
  addIssue(root, "02-beta.md");
  const { r } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(traceLog(root), /FEATURE-REVIEW: 1 finding\(s\) the rule would promote are report-only/);
  const blocks = sprintReport(root).split("## Branch: feature (feature)").pop();
  const last = JSON.parse(/```json\n([\s\S]*?)\n```/.exec(blocks)[1]).findings;
  assert.equal(last.find((f) => f.issue === target.issue).report_only, true);
  // reportOnlyFeatureFindings is what notGreenReasons' unfixedFindings is read from: the run is not green.
  assert.deepEqual(reportOnlyFeatureFindings(join(root, ".scratch/demo/reviews")).map((f) => [f.location, f.severity]), [["src/alpha.txt:1", "MEDIUM"]]);
  assert.match(remindOf(root), /^FINDINGS: open=1 \(HIGH=1\)$/m);
  assert.match(r.stdout, /report-only \(past the promotion cap\)/);
});

test("actionable: an actionable duplicate_of a debatable target at a report-only feature review (a later run) is report_only and not green", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const target = { severity: "MEDIUM", location: "src/alpha.txt:1", issue: "Retry contract is unclear", criterion: "Clarify the retry contract" };
  const dup = { severity: "HIGH", location: "src/beta.txt:9", issue: "Beta retries forever", criterion: "Bound beta's retry" };
  fake(root, "feature.review", featureReviewFile([target, dup]));
  fake(root, "feature-findings.triage", findingVerdicts([
    { verdict: "debatable", rationale: "changes the public contract" },
    { verdict: "actionable", rationale: "same area", duplicate_of: 0 },
  ]));
  assert.equal(commandLines(root).r.code, 0); // the feature's fix issue
  addIssue(root, "02-beta.md");
  const { r } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(traceLog(root), /FEATURE-REVIEW: 1 finding\(s\) the rule would promote are report-only/);
  const blocks = sprintReport(root).split("## Branch: feature (feature)").pop();
  const last = JSON.parse(/```json\n([\s\S]*?)\n```/.exec(blocks)[1]).findings;
  assert.equal(last.find((f) => f.issue === dup.issue).report_only, true);
  assert.notEqual(last.find((f) => f.issue === target.issue).report_only, true);
  assert.match(r.stdout, /report-only \(past the promotion cap\)/);
});

test("actionable: a dismiss verdict is remapped to actionable and promoted to a fix issue", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  featureFindings(root, ([retryLow]));
  fake(root, "feature-findings.triage", findingVerdicts([{ verdict: "dismiss", rationale: "already guarded two lines above" }]));
  const { r } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.doesNotMatch(remindOf(root), /^DISMISSED:/m);
  assert.match(traceLog(root), /FINDINGS-TRIAGE: feature: 1 actionable, 0 debatable/);
});

test("actionable: a finding that contradicts an ADR, or whose fix touches a protected path, is Debatable whatever triage says", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  featureFindings(
    root,
    ([
      { severity: "HIGH", location: "src/alpha.txt:1", criterion: "Replace the tracker abstraction with direct gh calls" },
      { severity: "MEDIUM", location: ".github/workflows/ci.yml:12", criterion: "Pin the action to a commit" },
      { severity: "LOW", location: "src/alpha.txt:3", criterion: "Name the retry constant" },
    ]),
  );
  fake(
    root,
    "feature-findings.triage",
    findingVerdicts([
      { verdict: "actionable", rationale: "simple", adr: true },
      { verdict: "actionable", rationale: "one line" },
      { verdict: "actionable", rationale: "one local rename" },
    ]),
  );
  const { r } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const criteria = readFileSync(join(root, ".scratch/demo/reviews/feature.criteria.md"), "utf8");
  assert.doesNotMatch(criteria, /tracker abstraction|Pin the action/, "neither forced-Debatable finding is promoted");
  assert.match(criteria, /\[LOW\] Name the retry constant/);
  const report = sprintReport(root);
  assert.match(report, /"rationale":"simple \[forced Debatable: contradicts a documented decision \(ADR \/ CONTEXT\.md\)\]"/);
  assert.match(report, /"rationale":"one line \[forced Debatable: its fix touches a protected path/);
  assert.match(remindOf(root), /^DEBATABLE: 2 /m);
});

test("actionable: the feature review's findings are triaged and promoted the same way", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "feature.review", featureReviewFile([crossIssue("LOW", "Name the two retry loops alike"), crossIssue("HIGH", "Merge the retry helpers into a new public module")]));
  fake(
    root,
    "feature-findings.triage",
    findingVerdicts([
      { verdict: "actionable", rationale: "a local rename" },
      { verdict: "debatable", rationale: "adds a public module" },
    ]),
  );
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(findingsTriageSpawns(lines), 1);
  const files = readdirSync(join(root, ".scratch/demo/issues/done"));
  assert.ok(files.some((f) => /fix-findings-feature\.md$/.test(f)), `the feature fix issue ran in Phase 2: ${files}`);
  const criteria = readFileSync(join(root, ".scratch/demo/reviews/feature.criteria.md"), "utf8");
  assert.match(criteria, /\[LOW\] Name the two retry loops alike/);
  assert.doesNotMatch(criteria, /public module/);
  assert.match(sprintReport(root), /"verdict":"debatable","rationale":"adds a public module"/);
  assert.match(r.stdout, /1 Actionable went to Phase 2/);
  assert.match(remindOf(root), /^DEBATABLE: 1 /m);
});

test("actionable: a triage that leaves no usable verdict falls back to the high rule, and the summary says so", () => {
  // No fixture, a verdict file that does not parse, and one that leaves a finding unjudged.
  const cases = [
    ["no verdict file", null],
    ["not json", "I could not decide."],
    ["a finding left unjudged", findingVerdicts([{ verdict: "actionable", rationale: "x" }])],
  ];
  for (const [what, body] of cases) {
    const root = fixtureRepo();
    addIssue(root, "01-alpha.md");
    featureFindings(root, ([retryHigh, retryLow]));
    if (body) fake(root, "feature-findings.triage", body);
    const { r } = commandLines(root);
    assert.equal(r.code, 0, `${what}: ${r.stdout}\n${r.stderr}`);
    assert.equal(state(root).completed_slugs.length, 2, `${what}: the HIGH was promoted by the high rule`);
    const criteria = readFileSync(join(root, ".scratch/demo/reviews/feature.criteria.md"), "utf8");
    assert.match(criteria, /\[HIGH\]/, what);
    assert.doesNotMatch(criteria, /LOW/, what);
    assert.match(traceLog(root), /FINDINGS-TRIAGE: feature: no usable verdict — .*; the high rule applies/, what);
    assert.match(r.stdout, /## Findings Triage\s+\*\*Triage left no usable verdict, so the `high` rule applied\*\*/, what);
    assert.match(r.stdout, /- feature: /, what);
    // What it promoted is recorded as severities, so the HIGH is not read as an unjudged open finding.
    assert.match(sprintReport(root), /^- feature: CRITICAL, HIGH → /m, what);
    assert.match(remindOf(root), /^FINDINGS: open=1 \(LOW=1\)$/m, what);
  }
});

test("actionable: a feature review whose triage fails falls back to the high rule too", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "feature.review", featureReviewFile([crossIssue("HIGH"), crossIssue("LOW", "Name the two retry loops alike")]));
  const { r } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const criteria = readFileSync(join(root, ".scratch/demo/reviews/feature.criteria.md"), "utf8");
  assert.match(criteria, /\[HIGH\]/);
  assert.doesNotMatch(criteria, /LOW/);
  assert.match(r.stdout, /## Findings Triage[\s\S]*- feature: /);
});

test("a severity level triages nothing: --fix-findings high promotes by severity with no crew-triage dispatch", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  featureFindings(root, ([retryHigh, retryLow]));
  const { r, lines } = commandLines(root, ["--fix-findings", "high"]);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(findingsTriageSpawns(lines), 0);
  assert.equal(lines.filter((l) => /--agent crew-triage/.test(l)).length, 0);
  const criteria = readFileSync(join(root, ".scratch/demo/reviews/feature.criteria.md"), "utf8");
  assert.match(criteria, /\[HIGH\]/);
  assert.doesNotMatch(criteria, /LOW/);
  assert.match(sprintReport(root), /^- feature: CRITICAL, HIGH → /m);
  assert.doesNotMatch(r.stdout, /## Findings Triage/);
});

test("actionable: a review with no findings dispatches no triage", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(findingsTriageSpawns(lines), 0);
  assert.doesNotMatch(r.stdout, /## Findings Triage/);
});

test("a pre-upgrade report's branch finding stays open after the branch is re-reviewed all-met, and nothing defers it", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  // Run 1, by an earlier version (under the fake reviewer's branch name): the branch was unmet and its review raised a HIGH finding.
  mkdirSync(join(root, ".scratch/demo/reviews"), { recursive: true });
  writeFileSync(
    join(root, ".scratch/demo/reviews/sprint-review-00000000-000000.md"),
    `## Branch: crew/x/alpha (alpha)\n\n\`\`\`json\n${JSON.stringify({ branch: "crew/x/alpha", slug: "alpha", verdict: "unmet", detail: "alpha exists: missing", findings: [retryHigh] })}\n\`\`\`\n`,
  );
  // Run 2: the same branch is re-reviewed all-met, with no findings (the fake's default).
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.ok(!lines.some((l) => /promote-findings\.sh defer( |$)/.test(l)), "no defer runs for it");
  assert.equal(state(root).completed_slugs.length, 1, "no fix issue");
  const open = JSON.parse(
    sh("bash", [join(SCRIPTS, "promote-findings.sh"), "open", "--feature-slug", "demo"], {
      cwd: root,
      env: { ...process.env, MAIN_ROOT: root, CREW_REVIEW_ROLLUP: join(REPO, "orchestrator/review-rollup.mjs") },
    }).stdout,
  );
  const alpha = open.filter((f) => f.branch === "crew/x/alpha");
  assert.equal(alpha.length, 1, JSON.stringify(open));
  assert.equal(alpha[0].severity, "HIGH");
  assert.equal(alpha[0].carried, true);
});

test("a pre-upgrade report's branch finding stays open past a not_run stub and an all-met re-review", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  // Run 1, by an earlier version: unmet with a HIGH finding; a later dispatch left no review, so mark-not-run wrote a stub.
  mkdirSync(join(root, ".scratch/demo/reviews"), { recursive: true });
  const block = (obj) => `## Branch: crew/x/alpha (alpha)\n\n\`\`\`json\n${JSON.stringify(obj)}\n\`\`\`\n`;
  writeFileSync(
    join(root, ".scratch/demo/reviews/sprint-review-00000000-000000.md"),
    `${block({ branch: "crew/x/alpha", slug: "alpha", verdict: "unmet", detail: "alpha exists: missing", findings: [retryHigh] })}\n` +
      block({ branch: "crew/x/alpha", slug: "alpha", verdict: "not_run", detail: "no report.json", findings: [] }),
  );
  // Run 2: the same branch is re-reviewed all-met, with no findings.
  const { r } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const open = JSON.parse(
    sh("bash", [join(SCRIPTS, "promote-findings.sh"), "open", "--feature-slug", "demo"], {
      cwd: root,
      env: { ...process.env, MAIN_ROOT: root, CREW_REVIEW_ROLLUP: join(REPO, "orchestrator/review-rollup.mjs") },
    }).stdout,
  );
  const alpha = open.filter((f) => f.branch === "crew/x/alpha");
  assert.equal(alpha.length, 1, JSON.stringify(open));
  assert.equal(alpha[0].severity, "HIGH");
  assert.equal(alpha[0].carried, true);
});

test("a pre-upgrade report's actionable branch finding a fix issue took stays covered after the branch is re-reviewed all-met", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  // Run 1, by an earlier version: the branch's review raised a finding triage judged Actionable, and defer promoted it.
  mkdirSync(join(root, ".scratch/demo/reviews"), { recursive: true });
  const promotedHigh = { ...retryHigh, verdict: "actionable", rationale: "one local change" };
  writeFileSync(
    join(root, ".scratch/demo/reviews/sprint-review-00000000-000000.md"),
    `## Branch: crew/x/alpha (alpha)\n\n\`\`\`json\n${JSON.stringify({ branch: "crew/x/alpha", slug: "alpha", verdict: "unmet", detail: "alpha exists: missing", findings: [promotedHigh] })}\n\`\`\`\n\n## Promoted Findings\n\n- crew/x/alpha: actionable → .scratch/demo/issues/open/09-fix-alpha.md (1 finding(s))\n`,
  );
  // Run 2: the same branch is re-reviewed all-met; the carried finding keeps the verdict its promotion was decided on.
  const { r } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const open = JSON.parse(
    sh("bash", [join(SCRIPTS, "promote-findings.sh"), "open", "--feature-slug", "demo"], {
      cwd: root,
      env: { ...process.env, MAIN_ROOT: root, CREW_REVIEW_ROLLUP: join(REPO, "orchestrator/review-rollup.mjs") },
    }).stdout,
  );
  assert.deepEqual(open.filter((f) => f.branch === "crew/x/alpha"), [], JSON.stringify(open));
});
