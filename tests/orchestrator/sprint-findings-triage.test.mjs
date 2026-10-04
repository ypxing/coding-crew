/**
 * Sprint suite — fixFindings actionable: crew-triage judges each finding.
 * Shared helpers: ./helpers/sprint.mjs.
 */

import assert from "node:assert/strict";
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { REPO, SCRIPTS, sh, fixtureRepo, addIssue, traceLog, state, fake, commandLines, featureReviewFile, crossIssue, sprintReport, privateScripts, failFirstCall, test } from "./helpers/sprint.mjs";

// ─── fixFindings actionable (the default): crew-triage judges each finding, whatever its severity ──

const reviewOf = (findings, slug = "alpha") =>
  `## Branch: crew/demo/${slug}\n\`\`\`json\n${JSON.stringify({ branch: `crew/demo/${slug}`, slug, verdict: "all-met", detail: "", findings })}\n\`\`\`\n`;
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
  fake(root, "alpha.review", reviewOf([retryHigh, retryLow]));
  fake(
    root,
    "alpha-findings.triage",
    findingVerdicts([
      { verdict: "debatable", rationale: "the fix changes the public retry contract" },
      { verdict: "actionable", rationale: "one local rename" },
    ]),
  );
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(state(root).completed_slugs.length, 2, "the LOW ran as a Phase 2 fix issue");
  const criteria = readFileSync(join(root, ".scratch/demo/reviews/alpha.criteria.md"), "utf8");
  assert.match(criteria, /\[LOW\] Name the retry constant/);
  assert.doesNotMatch(criteria, /HIGH/, "a Debatable HIGH is left for a human");
  // A dispatch of its own, to crew-triage, over the whole review's findings; none for the fix issue.
  assert.equal(findingsTriageSpawns(lines), 1);
  const prompt = readFileSync(join(root, ".scratch/demo/dispatch/01-alpha/findings-triage-prompt.md"), "utf8");
  assert.match(prompt, /^Findings mode: /m);
  assert.match(prompt, /^0 — HIGH — src\/alpha\.txt:1 — Redesign the retry contract$/m);
  assert.match(prompt, /^1 — LOW — src\/alpha\.txt:2 — Name the retry constant$/m);
  assert.match(traceLog(root), /FINDINGS-TRIAGE: alpha: 1 actionable, 1 debatable/);
  assert.ok(state(root).dispatches.some((d) => d.slug === "alpha" && d.role === "triage"), "its cost is in the ledger");
  // Each finding carries its verdict and rationale in the review report.
  const report = sprintReport(root);
  assert.match(report, /"verdict":"debatable","rationale":"the fix changes the public retry contract"/);
  assert.match(report, /"verdict":"actionable","rationale":"one local rename"/);
  assert.match(report, /^- crew\/demo\/alpha: actionable → /m);
  // remind: the promoted Actionable is handled; the Debatable leads what is left.
  const remind = remindOf(root);
  assert.match(remind, /^FINDINGS: open=1 \(HIGH=1\)$/m);
  assert.match(remind, /^DEBATABLE: 1 \(decide these first\)$/m);
  assert.match(remind, /^debatable: crew\/demo\/alpha \[HIGH\] src\/alpha\.txt:1 — Redesign the retry contract — why: the fix changes the public retry contract$/m);
  assert.ok(remind.indexOf("DEBATABLE:") < remind.indexOf("report:"), "Debatable leads");
  assert.match(r.stdout, /1 Debatable — decide these first/);
});

test("actionable: a finding triage marks duplicate_of is folded into its target: promoted once, shown once", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.review", reviewOf([retryLow, retryHigh]));
  fake(
    root,
    "alpha-findings.triage",
    findingVerdicts([
      { verdict: "actionable", rationale: "one rename" },
      { verdict: "actionable", rationale: "same defect", duplicate_of: 0 },
    ]),
  );
  const { r } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const criteria = readFileSync(join(root, ".scratch/demo/reviews/alpha.criteria.md"), "utf8");
  assert.equal((criteria.match(/^- \[ \]/gm) ?? []).length, 1);
  assert.match(criteria, /\[HIGH\]/);
  assert.match(criteria, /src\/alpha\.txt:2/);
  assert.match(criteria, /src\/alpha\.txt:1/);
  assert.match(sprintReport(root), /"duplicate_of":0/);
  assert.match(remindOf(root), /^FINDINGS: none$/m);
});

test("actionable: a duplicate_of pair at a report-only feature drain leaves its target report_only, open and not green", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const target = { severity: "MEDIUM", location: "src/alpha.txt:1", issue: "Retry loop is unbounded", criterion: "Bound the retry loop" };
  const dup = { severity: "HIGH", location: "src/beta.txt:9", issue: "Beta retries forever", criterion: "Bound beta's retry" };
  fake(root, "feature.review", featureReviewFile([target, dup]));
  fake(root, "feature.review-later", featureReviewFile([target, dup]));
  fake(root, "feature-findings.triage", findingVerdicts([
    { verdict: "actionable", rationale: "one fix" },
    { verdict: "actionable", rationale: "same defect", duplicate_of: 0 },
  ]));
  const { r } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(traceLog(root), /FEATURE-REVIEW: 1 finding\(s\) the rule would promote are report-only/);
  const blocks = sprintReport(root).split("## Branch: feature (feature)").pop();
  const last = JSON.parse(/```json\n([\s\S]*?)\n```/.exec(blocks)[1]).findings;
  assert.equal(last.find((f) => f.issue === target.issue).report_only, true);
  assert.match(remindOf(root), /^FINDINGS: open=1 \(HIGH=1\)$/m);
  assert.match(r.stdout, /Drain 3: .*report-only \(past the promotion cap\)/);
});

test("actionable: an actionable duplicate_of a debatable target at a report-only feature drain is report_only and not green", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const target = { severity: "MEDIUM", location: "src/alpha.txt:1", issue: "Retry contract is unclear", criterion: "Clarify the retry contract" };
  const dup = { severity: "HIGH", location: "src/beta.txt:9", issue: "Beta retries forever", criterion: "Bound beta's retry" };
  fake(root, "feature.review", featureReviewFile([target, dup]));
  fake(root, "feature.review-later", featureReviewFile([target, dup]));
  fake(root, "feature-findings.triage", findingVerdicts([
    { verdict: "debatable", rationale: "changes the public contract" },
    { verdict: "actionable", rationale: "same area", duplicate_of: 0 },
  ]));
  const { r } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(traceLog(root), /FEATURE-REVIEW: 1 finding\(s\) the rule would promote are report-only/);
  const blocks = sprintReport(root).split("## Branch: feature (feature)").pop();
  const last = JSON.parse(/```json\n([\s\S]*?)\n```/.exec(blocks)[1]).findings;
  assert.equal(last.find((f) => f.issue === dup.issue).report_only, true);
  assert.notEqual(last.find((f) => f.issue === target.issue).report_only, true);
  assert.match(r.stdout, /Drain 3: .*report-only \(past the promotion cap\)/);
});

test("actionable: a dismiss verdict is remapped to actionable and promoted to a fix issue", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.review", reviewOf([retryLow]));
  fake(root, "alpha-findings.triage", findingVerdicts([{ verdict: "dismiss", rationale: "already guarded two lines above" }]));
  const { r } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.doesNotMatch(remindOf(root), /^DISMISSED:/m);
  assert.match(traceLog(root), /FINDINGS-TRIAGE: alpha: 1 actionable, 0 debatable/);
});

test("actionable: a finding that contradicts an ADR, or whose fix touches a protected path, is Debatable whatever triage says", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(
    root,
    "alpha.review",
    reviewOf([
      { severity: "HIGH", location: "src/alpha.txt:1", criterion: "Replace the tracker abstraction with direct gh calls" },
      { severity: "MEDIUM", location: ".github/workflows/ci.yml:12", criterion: "Pin the action to a commit" },
      { severity: "LOW", location: "src/alpha.txt:3", criterion: "Name the retry constant" },
    ]),
  );
  fake(
    root,
    "alpha-findings.triage",
    findingVerdicts([
      { verdict: "actionable", rationale: "simple", adr: true },
      { verdict: "actionable", rationale: "one line" },
      { verdict: "actionable", rationale: "one local rename" },
    ]),
  );
  const { r } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const criteria = readFileSync(join(root, ".scratch/demo/reviews/alpha.criteria.md"), "utf8");
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
  fake(root, "feature.review-later", featureReviewFile([])); // the Phase 2 drain's increment review
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
    fake(root, "alpha.review", reviewOf([retryHigh, retryLow]));
    if (body) fake(root, "alpha-findings.triage", body);
    const { r } = commandLines(root);
    assert.equal(r.code, 0, `${what}: ${r.stdout}\n${r.stderr}`);
    assert.equal(state(root).completed_slugs.length, 2, `${what}: the HIGH was promoted by the high rule`);
    const criteria = readFileSync(join(root, ".scratch/demo/reviews/alpha.criteria.md"), "utf8");
    assert.match(criteria, /\[HIGH\]/, what);
    assert.doesNotMatch(criteria, /LOW/, what);
    assert.match(traceLog(root), /FINDINGS-TRIAGE: alpha: no usable verdict — .*; the high rule applies/, what);
    assert.match(r.stdout, /## Findings Triage\s+\*\*Triage left no usable verdict, so the `high` rule applied\*\*/, what);
    assert.match(r.stdout, /- alpha: /, what);
    // What it promoted is recorded as severities, so the HIGH is not read as an unjudged open finding.
    assert.match(sprintReport(root), /^- crew\/demo\/alpha: CRITICAL, HIGH → /m, what);
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

test("actionable: findings on a fix issue's own branch are never promoted, and never triaged", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.review", reviewOf([retryLow]));
  fake(root, "alpha-findings.triage", findingVerdicts([{ verdict: "actionable", rationale: "one local rename" }]));
  fake(root, "fix-findings-alpha.review", reviewOf([retryLow, retryHigh], "fix-findings-alpha"));
  fake(
    root,
    "fix-findings-alpha-findings.triage",
    findingVerdicts([
      { verdict: "actionable", rationale: "x" },
      { verdict: "actionable", rationale: "y" },
    ]),
  );
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(state(root).completed_slugs.length, 2, "one fix issue, and no fix of the fix");
  assert.equal(findingsTriageSpawns(lines), 1, "the fix branch's findings are report-only: nothing to judge");
  assert.match(traceLog(root), /slug=fix-findings-alpha round=\d+ guard: skip — source-guarded/);
});

test("a severity level triages nothing: --fix-findings high promotes by severity with no crew-triage dispatch", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.review", reviewOf([retryHigh, retryLow]));
  const { r, lines } = commandLines(root, ["--fix-findings", "high"]);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(findingsTriageSpawns(lines), 0);
  assert.equal(lines.filter((l) => /--agent crew-triage/.test(l)).length, 0);
  const criteria = readFileSync(join(root, ".scratch/demo/reviews/alpha.criteria.md"), "utf8");
  assert.match(criteria, /\[HIGH\]/);
  assert.doesNotMatch(criteria, /LOW/);
  assert.match(sprintReport(root), /^- crew\/demo\/alpha: CRITICAL, HIGH → /m);
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

// ─── promotion follows the merge and the close, never precedes them ──

const deferCalls = (lines) => lines.map((l, i) => [l, i]).filter(([l]) => /promote-findings\.sh.* defer /.test(l));

test("a conflicted-looking merge failure promotes nothing: no defer call, no fix issue", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.review", reviewOf([retryHigh]));
  fake(root, "alpha-findings.triage", findingVerdicts([{ verdict: "actionable", rationale: "local" }]));
  const scripts = privateScripts();
  failFirstCall(scripts, "merge-branches.sh", join(root, ".scratch/merge-fail.marker"), "MERGE: forced failure for test");
  const { r, lines } = commandLines(root, ["--max-rounds", "1"], { scripts });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(deferCalls(lines).length, 0);
  assert.equal(existsSync(join(root, ".scratch/demo/reviews/alpha.criteria.md")), false);
});

test("a refused close promotes nothing", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.review", reviewOf([retryHigh]));
  fake(root, "alpha-findings.triage", findingVerdicts([{ verdict: "actionable", rationale: "local" }]));
  const scripts = privateScripts();
  failFirstCall(scripts, "close-issue.sh", join(root, ".scratch/close-fail.marker"), "ERROR: forced close failure for test");
  const { r, lines } = commandLines(root, ["--max-rounds", "1"], { scripts });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(deferCalls(lines).length, 0);
});

test("a refused close whose retry closes via the merge route promotes exactly once, after the successful close", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.review", reviewOf([retryHigh]));
  fake(root, "alpha-findings.triage", findingVerdicts([{ verdict: "actionable", rationale: "local" }]));
  const scripts = privateScripts();
  failFirstCall(scripts, "close-issue.sh", join(root, ".scratch/close-fail.marker"), "ERROR: forced close failure for test");
  const { r, lines } = commandLines(root, ["--max-rounds", "2"], { scripts });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const defers = deferCalls(lines);
  assert.equal(defers.length, 1);
  const closesBefore = lines.slice(0, defers[0][1]).filter((l) => /close-issue\.sh/.test(l));
  assert.equal(closesBefore.length, 2, "defer comes after the refused close and the successful retry");
});

test("a merged-and-closed branch is promoted exactly once, after the close", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.review", reviewOf([retryHigh]));
  fake(root, "alpha-findings.triage", findingVerdicts([{ verdict: "actionable", rationale: "local" }]));
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const defers = deferCalls(lines);
  assert.equal(defers.length, 1);
  const closeAt = lines.findIndex((l) => /close-issue\.sh/.test(l));
  assert.ok(closeAt >= 0 && closeAt < defers[0][1], "defer comes after close-issue.sh");
  const prompt = readFileSync(join(root, ".scratch/demo/dispatch/01-alpha/findings-triage-prompt.md"), "utf8");
  assert.match(prompt, /which has merged\./);
  assert.doesNotMatch(prompt, /has not merged/);
  // The change triage is pointed at is the branch's own, not the merged feature branch against it.
  const change = /the change with (git diff \S+\^1\.\.\.crew\/demo\/alpha)\./.exec(prompt)?.[1];
  assert.ok(change, prompt);
  // The sprint's cleanup has since deleted the branch, so read the range through the merge's second parent.
  const git = (args) => sh("git", ["-C", root, ...args]).stdout.trim();
  const merge = change.split(" ")[2].replace(/\^1\.\.\..*$/, "");
  assert.equal(git(["log", "-1", "--format=%s", merge]), "Merge branch 'crew/demo/alpha'");
  assert.equal(git(["diff", "--name-only", `${merge}^1...${merge}^2`]), "src/alpha.txt", "only the branch's own change");
});

test("savedAllMetReview: a branch an earlier run already promoted (pre-merge) is not promoted again", async () => {
  const { savedAllMetReview } = await import("../../orchestrator/lib/pipeline/review.mjs");
  const root = fixtureRepo();
  const reviewDir = join(root, ".scratch/demo/reviews");
  mkdirSync(reviewDir, { recursive: true });
  const report = join(reviewDir, "sprint-review-00000000T000000.md");
  writeFileSync(report, reviewOf([retryHigh]));
  assert.equal(savedAllMetReview({ reviewDir }, "crew/demo/alpha")?.parsed.verdict, "all-met");
  writeFileSync(report, `${reviewOf([retryHigh])}\n## Promoted Findings\n\n- crew/demo/alpha: actionable → 02-fix\n`);
  assert.equal(savedAllMetReview({ reviewDir }, "crew/demo/alpha"), null);
  assert.equal(savedAllMetReview({ reviewDir }, "crew/demo/alph"), null, "no block for that branch");
});

// ─── findings an earlier review raised and the latest dropped are carried forward ──

test("carry: an earlier run's unmet finding the all-met review drops is written carried, and remind labels it", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const earlier = { branch: "crew/demo/alpha", slug: "alpha", verdict: "unmet", detail: "", findings: [retryLow, { ...retryHigh, issue: "Same  problem" }] };
  mkdirSync(join(root, ".scratch/demo/reviews"), { recursive: true });
  writeFileSync(
    join(root, ".scratch/demo/reviews/sprint-review-00000000T000000.md"),
    `## Branch: crew/demo/alpha (alpha)\n\n\`\`\`json\n${JSON.stringify(earlier)}\n\`\`\`\n`,
  );
  // The latest review repeats the HIGH (other line, same issue text) and drops the LOW.
  fake(root, "alpha.review", reviewOf([{ ...retryHigh, location: "src/alpha.txt:99", issue: "same problem" }]));
  const { r } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const written = readdirSync(join(root, ".scratch/demo/reviews"))
    .filter((n) => n.startsWith("sprint-review-") && n !== "sprint-review-00000000T000000.md")
    .map((n) => readFileSync(join(root, ".scratch/demo/reviews", n), "utf8"))
    .join("\n");
  assert.equal((written.match(/"carried":true/g) ?? []).length, 1, "only the dropped LOW is carried");
  assert.match(written, /"severity":"LOW"[^}]*"carried":true/);
  assert.match(remindOf(root), /^earlier: crew\/demo\/alpha \[LOW\] src\/alpha\.txt:2 — Name the retry constant \(earlier review\)$/m);
});
