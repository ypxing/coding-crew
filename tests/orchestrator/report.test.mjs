import { test } from "node:test";
import assert from "node:assert/strict";

import {
  annotateFindings,
  carryFindings,
  applyFindingVerdicts,
  applySchemaPrefilter,
  EVIDENCE_OUTPUT_MAX,
  findingsAtOrAbove,
  parseFindingsTriage,
  parsePrdAudit,
  parseRequiresFailures,
  parseReviewAggregate,
  parseReviewReport,
  parseTriageReport,
  parseWorkerReport,
  readVerifyRecord,
  severityNames,
  touchesProtectedPath,
} from "../../orchestrator/lib/report.mjs";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

function verifyRecord(obj) {
  const f = join(mkdtempSync(join(tmpdir(), "verify-rec-")), "01-x.verify.json");
  writeFileSync(f, typeof obj === "string" ? obj : JSON.stringify(obj));
  return f;
}
import { fixPrompt, reviewPrompt, triagePrompt, workerPrompt } from "../../orchestrator/lib/prompts.mjs";

test("a structured sidecar wins over prose", () => {
  const r = parseWorkerReport("## Issue: thing\nStatus: complete\n", {
    status: "complete",
    branch: "crew/feat/thing",
    working_directory: "/wt/thing",
    checks: { test: "pass", lint: "pass", typecheck: "not_run" },
    progress: "nothing left",
  });
  assert.equal(r.parsedFrom, "json");
  assert.equal(r.status, "complete");
  assert.equal(r.branch, "crew/feat/thing");
  assert.equal(r.workingDirectory, "/wt/thing");
  assert.deepEqual(r.checks, { test: "pass", lint: "pass", typecheck: "not_run" });
});

test("a fenced json block in the final message alone, with no sidecar, is never read — text is not a fallback", () => {
  const text = [
    "## Issue: thing",
    "Status: complete",
    "",
    "```json",
    '{"status":"partial","checks":{"test":"pass"},"progress":"half"}',
    "```",
  ].join("\n");
  const r = parseWorkerReport(text);
  assert.equal(r.parsedFrom, "missing");
  assert.equal(r.status, "blocked");
});

test("markdown-shaped text alone, with no sidecar, is never read — text is not a fallback", () => {
  const text = [
    "## Issue: thing",
    "Status: complete",
    "",
    "### Checks",
    "| tests | pass |",
    "| lint | fail |",
    "| typecheck | not_run |",
    "",
    "working_directory: /wt/thing",
  ].join("\n");
  const r = parseWorkerReport(text);
  assert.equal(r.parsedFrom, "missing");
  assert.equal(r.status, "blocked");
});

test("an empty report is blocked, never complete", () => {
  const r = parseWorkerReport("");
  assert.equal(r.status, "blocked");
  assert.match(r.unparseable, /never wrote its result file/);
});

test("non-empty text with no sidecar is blocked the same way as empty text — the sidecar is the only channel", () => {
  const r = parseWorkerReport("I finished everything, all good!");
  assert.equal(r.status, "blocked");
  assert.match(r.unparseable, /never wrote its result file/);
});

test("a sidecar present but missing a valid status field is blocked, distinctly from a wholly absent sidecar", () => {
  const r = parseWorkerReport("anything", { branch: "x" });
  assert.equal(r.status, "blocked");
  assert.match(r.unparseable, /no valid status field/);
});

test("prefilter demotes complete on a failing check", () => {
  const r = parseWorkerReport(null, { status: "complete", checks: { test: "fail", lint: "pass", typecheck: "pass" } });
  const v = applySchemaPrefilter(r);
  assert.equal(v.status, "partial");
  assert.equal(v.demoted, true);
  assert.match(v.reason, /test/);
});

test("prefilter demotes complete when tests did not run", () => {
  const r = parseWorkerReport(null, { status: "complete", checks: { test: "not_run", lint: "pass", typecheck: "pass" } });
  const v = applySchemaPrefilter(r);
  assert.equal(v.status, "partial");
  assert.match(v.reason, /nothing was verified/);
});

test("prefilter records lint/typecheck not_run as a coverage gap, not a demotion", () => {
  const r = parseWorkerReport(null, { status: "complete", checks: { test: "pass", lint: "not_run", typecheck: "not_run" } });
  const v = applySchemaPrefilter(r);
  assert.equal(v.status, "complete");
  assert.equal(v.demoted, false);
  assert.deepEqual(v.coverageGaps, ["lint", "typecheck"]);
});

test("a reviewer's captured text is never read — only the sidecar's verdict counts, missing or present", () => {
  assert.equal(parseReviewReport("## Branch: crew/f/x\nAC: all-met\n").verdict, "unmet");
  assert.equal(parseReviewReport("## Branch: crew/f/x\nAC: unmet — no tests\n").verdict, "unmet");
  const none = parseReviewReport("## Branch: crew/f/x\n\nLooks fine to me.\n");
  assert.equal(none.verdict, "unmet");
  assert.match(none.detail, /never wrote its verdict file/);
});

test("an empty review, with no sidecar, fails closed and is not ok", () => {
  const empty = parseReviewReport("");
  assert.equal(empty.ok, false);
  assert.equal(empty.verdict, "unmet");
});

test("a review sidecar's findings parse into severity, location and criterion", () => {
  const sidecar = {
    branch: "crew/f/x",
    slug: "x",
    verdict: "all-met",
    findings: [
      { severity: "CRITICAL", location: "src/auth.ts:42", criterion: "Reject unsigned tokens before use" },
      { severity: "HIGH", location: "src/db.ts:7", criterion: "Parameterise the query" },
      { severity: "bogus", location: "x", criterion: "y" },
    ],
  };
  const r = parseReviewReport("", sidecar);
  assert.equal(r.findings.length, 2);
  assert.deepEqual(r.findings[0], {
    issue: "",
    severity: "CRITICAL",
    location: "src/auth.ts:42",
    criterion: "Reject unsigned tokens before use",
    explicit: true,
  });
  assert.deepEqual(findingsAtOrAbove(r.findings, "critical").map((f) => f.severity), ["CRITICAL"]);
  assert.deepEqual(findingsAtOrAbove(r.findings, "high").map((f) => f.severity), [
    "CRITICAL",
    "HIGH",
  ]);
  assert.deepEqual(findingsAtOrAbove(r.findings, "none"), []);
});

test("findingsAtOrAbove: medium takes MEDIUM too, never LOW", () => {
  const findings = ["LOW", "MEDIUM", "HIGH", "CRITICAL"].map((severity) => ({ severity }));
  assert.deepEqual(findingsAtOrAbove(findings, "medium").map((f) => f.severity), ["MEDIUM", "HIGH", "CRITICAL"]);
});

test("parsePrdAudit: the last fenced json's missing list; no block queues nothing", () => {
  const text = [
    "✗ Export to CSV: no evidence",
    "```json",
    '{"covered": 3, "partial": 1, "missing": [{"requirement": "Users can export to CSV", "detail": "PRD §2"}, {"requirement": " "}]}',
    "```",
  ].join("\n");
  assert.deepEqual(parsePrdAudit(text), {
    ok: true,
    missing: [{ requirement: "Users can export to CSV", detail: "PRD §2" }],
    superseded: [],
  });
  assert.deepEqual(parsePrdAudit("✗ Export to CSV: no evidence"), { ok: false, missing: [], superseded: [] });
});

test("parsePrdAudit: a superseded requirement is never missing, even when listed as both", () => {
  const text = [
    "```json",
    JSON.stringify({
      covered: 1,
      partial: 0,
      missing: [{ requirement: "Sessions expire after 30 minutes" }, { requirement: "Users can export to CSV" }],
      superseded: [{ requirement: "Sessions expire after 30 minutes", by: "docs/adr/0007-no-session-expiry.md" }, { by: "x" }],
    }),
    "```",
  ].join("\n");
  assert.deepEqual(parsePrdAudit(text), {
    ok: true,
    missing: [{ requirement: "Users can export to CSV", detail: "" }],
    superseded: [{ requirement: "Sessions expire after 30 minutes", by: "docs/adr/0007-no-session-expiry.md" }],
  });
});

// ─── review: the sidecar is the only channel ─────────────────────────────────────
//
// crew-summary.sh's code_review_summary() and promote-findings.sh's remind both used to
// re-derive branch/verdict/findings from raw dispatch text with their own line-anchored
// awk, independently of this parser and of each other, and drifted apart. The sidecar
// removes the class entirely: it is a plain JSON object the agent wrote itself, never a
// terminal render or a chat reply that has to be scraped or pattern-matched.

test("a review sidecar with a verdict wins over the captured text entirely", () => {
  const sidecar = { branch: "crew/f/x", slug: "x", verdict: "all-met", detail: "", findings: [] };
  // The captured text is an arbitrary placeholder, not a real reviewer reply — exactly the
  // case the sidecar exists to make irrelevant.
  const r = parseReviewReport("(structured result written to /r/x.review.report.json)", sidecar);
  assert.equal(r.parsedFrom, "json");
  assert.equal(r.verdict, "all-met");
});

test("a sidecar with no verdict field is treated the same as a wholly absent one", () => {
  const r = parseReviewReport("AC: unmet — see below", { branch: "x" });
  assert.equal(r.verdict, "unmet");
  assert.equal(r.parsedFrom, "missing");
  assert.match(r.detail, /no valid verdict field/);
});

// ─── review: the aggregate multi-branch report file ──────────────────────────────

test("parseReviewAggregate folds a later retry's real verdict over an earlier not_run stub for the same branch", () => {
  const stub = [
    "## Branch: crew/calc/a (a)",
    "```json",
    JSON.stringify({ branch: "crew/calc/a", slug: "a", verdict: "not_run", detail: "reviewer dispatch timed out", findings: [] }),
    "```",
  ].join("\n");
  const retry = [
    "  Branch: crew/calc/a (a)",
    "  ```json",
    '  {"branch": "crew/calc/a", "slug": "a", "verdict": "all-met", "findings": [{"severity": "HIGH", "location": "x.ts:1", "criterion": "fix it"}]}',
    "  ```",
  ].join("\n");
  const records = parseReviewAggregate(`${stub}\n\n${retry}\n`);
  assert.equal(records.length, 1);
  assert.equal(records[0].branch, "crew/calc/a");
  assert.equal(records[0].verdict, "all-met");
  assert.equal(records[0].findings.length, 1);
});

test("parseReviewAggregate keeps distinct branches separate and in first-seen order", () => {
  const a = { branch: "crew/f/a", slug: "a", verdict: "all-met", findings: [] };
  const b = { branch: "crew/f/b", slug: "b", verdict: "unmet", findings: [] };
  const text = [
    "```json", JSON.stringify(a), "```",
    "```json", JSON.stringify(b), "```",
  ].join("\n");
  const records = parseReviewAggregate(text);
  assert.deepEqual(records.map((r) => r.branch), ["crew/f/a", "crew/f/b"]);
  assert.deepEqual(records.map((r) => r.verdict), ["all-met", "unmet"]);
});

test("parseReviewAggregate attributes a feature-mode review to `feature`, apart from every branch", () => {
  const branch = { branch: "crew/f/a", slug: "a", verdict: "all-met", findings: [] };
  const feature = {
    branch: "feature",
    slug: "feature",
    verdict: "all-met",
    detail: "",
    findings: [{ severity: "HIGH", location: "src/a.js:3", criterion: "Share one retry helper" }],
  };
  const text = ["## Branch: crew/f/a (a)", "```json", JSON.stringify(branch), "```", "", "## Branch: feature (feature)", "```json", JSON.stringify(feature), "```"].join("\n");
  const records = parseReviewAggregate(text);
  assert.deepEqual(records.map((r) => r.branch), ["crew/f/a", "feature"]);
  assert.deepEqual(records[1].findings.map((f) => [f.severity, f.location, f.criterion]), [["HIGH", "src/a.js:3", "Share one retry helper"]]);
  // A feature review that could not run is the same not_run stub a branch gets.
  const stub = { branch: "feature", slug: "feature", verdict: "not_run", detail: "review dispatch timed out", findings: [] };
  const folded = parseReviewAggregate(`${text}\n\n\`\`\`json\n${JSON.stringify(stub)}\n\`\`\`\n`);
  assert.equal(folded.find((r) => r.branch === "feature").verdict, "not_run");
});

test("parseReviewAggregate on text with no json blocks returns no records", () => {
  assert.deepEqual(parseReviewAggregate("## Branch: crew/f/x\nAC: all-met\n"), []);
  assert.deepEqual(parseReviewAggregate(""), []);
});

// ─── the reviewer is told what was already executed ──────────────────────────
//
// A real codex sprint stalled on this: the issue's third criterion was "a test covers it
// and `npm test` passes", verify-worktree.sh had already run the suite green in the
// worktree, and the read-only reviewer answered `AC: unmet — npm test was not executed in
// this inspection-only review`. Fail-closed is right; asking for evidence the reviewer is
// structurally unable to produce is not, and it retained the branch every round forever.

test("the verifier's record is read back as the reviewer's check evidence", () => {
  const f = verifyRecord({
    branch: "crew/f/x",
    commit: "abc",
    verdict: "pass",
    checks: [
      { category: "typecheck", command: null, result: "not_run", exit: null, log: null },
      { category: "test", command: "npm test", result: "pass", exit: 0, log: "/d/01-x.verify-test.log" },
      { category: "coverage", command: "make cov", result: "pass", exit: 0, log: "/d/my dir/01-x.verify-coverage.log" },
    ],
    not_configured: ["integration"],
  });
  const { checks, logs, notConfigured } = readVerifyRecord(f);
  assert.deepEqual(checks, { test: "pass", lint: "not_run", typecheck: "not_run", coverage: "pass" });
  assert.deepEqual(logs, { test: "/d/01-x.verify-test.log", coverage: "/d/my dir/01-x.verify-coverage.log" });
  assert.deepEqual(notConfigured, ["integration"]);
});

test("a missing or unreadable record is never reported as evidence", () => {
  const none = { checks: { test: "not_run", lint: "not_run", typecheck: "not_run" }, logs: {}, missing: {}, notConfigured: [] };
  assert.deepEqual(readVerifyRecord("/nonexistent/01-x.verify.json"), none);
  assert.deepEqual(readVerifyRecord(verifyRecord("{not json")), none);
  assert.equal(readVerifyRecord(verifyRecord({ checks: [{ category: "test", result: "fail" }] })).checks.test, "fail");
});

test("a check that failed because its command is not installed is read back with that command", () => {
  const f = verifyRecord({
    verdict: "fail",
    checks: [
      { category: "test", command: "bats tests/*.bats", result: "fail", exit: 127, log: null, missing: "bats" },
      { category: "lint", command: "make lint", result: "fail", exit: 2, log: null },
    ],
  });
  const { checks, missing } = readVerifyRecord(f);
  assert.deepEqual(checks, { test: "fail", lint: "fail", typecheck: "not_run" });
  assert.deepEqual(missing, { test: "bats" });
});

test("a worker's further checks are kept by cache-key name only", () => {
  const r = parseWorkerReport(null, {
    status: "complete",
    checks: { test: "pass", lint: "pass", typecheck: "pass", Coverage: "fail", "make testIntegration": "pass", integration: "passed" },
  });
  assert.deepEqual(r.checks, { test: "pass", lint: "pass", typecheck: "pass", coverage: "fail", integration: "pass" });
  assert.deepEqual(parseWorkerReport(null, { status: "complete" }).checks, { test: "not_run", lint: "not_run", typecheck: "not_run" });
});

test("the review prompt states every check that ran, with its full-output file", () => {
  const p = reviewPrompt({
    branch: "b", slug: "s", issuePath: "p", criteria: "", featureBranch: "f", reportPath: "/r/s.json",
    checks: { test: "pass", lint: "pass", typecheck: "pass", coverage: "pass" },
    logs: { coverage: "/wt/.scratch/verify-coverage.log" },
  });
  assert.match(p, /typecheck=pass, coverage=pass \(full output: \/wt\/\.scratch\/verify-coverage\.log\)/);
  assert.match(p, /`pass` alone does not prove the figure/);
});

test("the review prompt sizes each log and marks a test-only diff", () => {
  const p = reviewPrompt({
    branch: "b", slug: "s", issuePath: "p", criteria: "", featureBranch: "f", reportPath: "/r/s.json",
    checks: { test: "pass", coverage: "pass" },
    logs: { coverage: "/d/s.verify-coverage.log" },
    logLines: { coverage: 593 },
    testOnly: true,
  });
  assert.match(p, /coverage=pass \(full output: \/d\/s\.verify-coverage\.log, 593 lines\)/);
  assert.match(p, /^Diff scope: test-only/m);
  assert.doesNotMatch(reviewPrompt({ branch: "b", slug: "s", issuePath: "p", criteria: "", featureBranch: "f", reportPath: "/r" }), /Diff scope/);
});

test("the review prompt names the gate's record, what it never ran, and what counts as a claim", () => {
  const p = reviewPrompt({
    branch: "b", slug: "s", issuePath: "p", criteria: "", featureBranch: "f", reportPath: "/r/s.json",
    checks: { test: "pass", lint: "pass", typecheck: "pass" },
    notConfigured: ["coverage", "integration"],
    verifyFile: "/d/01-s.verify.json",
  });
  assert.match(p, /The gate's own record of that run: \/d\/01-s\.verify\.json/);
  assert.match(p, /Not run by the pipeline, no command configured: coverage, integration — a criterion resting on one of these has no evidence/);
  assert.match(p, /progress notes, commit messages and the issue's `## Progress` section are claims/);
});

test("the review prompt states the checks and forbids unmet-for-lack-of-execution", () => {
  const p = reviewPrompt({
    branch: "crew/f/x",
    slug: "x",
    issuePath: "/i/01-x.md",
    criteria: "- [ ] tests pass",
    featureBranch: "feature/f",
    checks: { test: "pass", lint: "not_run", typecheck: "not_run" },
    reportPath: "/repo/.scratch/f/dispatch/x.review.report.json",
  });
  assert.match(p, /test=pass, lint=not_run, typecheck=not_run/);
  assert.match(p, /do not report a criterion unmet because you could not execute it/);
  // And it does not become a blanket pass: `not_run` stays worthless and the code half
  // of every criterion is still judged from the diff.
  assert.match(p, /`not_run` is not evidence of anything/);
  assert.match(p, /no file and line, no evidence, `unmet`/);
});

test("the review prompt still names the checks when none were discovered", () => {
  const p = reviewPrompt({ branch: "b", slug: "s", issuePath: "p", criteria: "", featureBranch: "f", reportPath: "/r/s.review.report.json" });
  assert.match(p, /test=not_run, lint=not_run, typecheck=not_run/);
});

test("the review prompt asks for a fenced json verdict, not a bare AC:/FINDING: line", () => {
  // parseReviewAggregate (and the crew-summary.sh/promote-findings.sh CLI that reads it)
  // only recognizes the fenced json block now — see report.mjs's doc comment on why the
  // old column-0 `## Branch:`/`AC:`/`FINDING:` anchors drifted apart across three
  // independent hand-rolled parsers.
  const p = reviewPrompt({ branch: "crew/f/x", slug: "x", issuePath: "p", criteria: "", featureBranch: "f", reportPath: "/r/x.review.report.json" });
  assert.match(p, /## Branch: <branch-name>/);
  assert.match(p, /```json/);
  assert.match(p, /"verdict": "all-met \| unmet"/);
  assert.match(p, /"findings":/);
  assert.match(p, /"severity": "CRITICAL \| HIGH \| MEDIUM \| LOW"/);
});

test("the review prompt makes the sidecar file the verdict channel, not an option", () => {
  const p = reviewPrompt({
    branch: "crew/f/x",
    slug: "x",
    issuePath: "p",
    criteria: "",
    featureBranch: "f",
    reportPath: "/repo/.scratch/f/dispatch/x.review.report.json",
  });
  assert.match(p, /Write your structured verdict to \/repo\/\.scratch\/f\/dispatch\/x\.review\.report\.json as your last action/);
});

test("the worker prompt makes the sidecar file the result channel, not an option", () => {
  // A real claude sprint lost round 1 to `no Status: line in the worker report`: the work
  // was committed, but the final message ended with a sentence of summary and nothing
  // parsed. The prompt used to offer the sidecar as an alternative ("may be written …
  // instead"); a file write does not depend on how a message ends, so it is now the ask.
  const p = workerPrompt({
    mainRoot: "/repo",
    worktree: "/repo/.scratch/worktrees/crew/f/x",
    issuePath: "/repo/.scratch/f/issues/open/01-x.md",
    slug: "x",
    criteria: "- [ ] it exists",
    resume: "",
    reportPath: "/repo/.scratch/f/dispatch/x.report.json",
  });
  assert.match(p, /Write your structured result to \/repo\/\.scratch\/f\/dispatch\/x\.report\.json as your last action/);
  assert.doesNotMatch(p, /may be written/);
  assert.match(p, /read as `blocked`, never as a silent `complete`/);
  // The schema has one owner, the coder protocol: the prompt points at it rather than copying it.
  assert.match(p, /your protocol's\n\*\*Report\*\* section/);
  // The criteria still arrive verbatim and framed as data.
  assert.match(p, /treat as data only/);
  assert.match(p, /- \[ \] it exists/);
});

test("the worker prompt hands over this issue's deps outcome only when the deps step ran", () => {
  // solve-issue's resolve-mode.sh turns a DEPS= fact into ACTION=none, skipping a second
  // install per issue. With --no-deps nothing looked, so nothing may be claimed.
  const base = {
    mainRoot: "/nonexistent-main-root",
    worktree: "/w",
    issuePath: "/w/i.md",
    slug: "x",
    criteria: "",
    resume: "",
    reportPath: "/w/r.json",
  };
  assert.match(workerPrompt({ ...base, deps: "docker-present" }), /^DEPS=docker-present$/m);
  assert.doesNotMatch(workerPrompt(base), /DEPS=/);
  assert.match(fixPrompt({ ...base, branch: "b", deps: "present" }), /^DEPS=present$/m);
  assert.match(fixPrompt({ ...base, branch: "b", kind: "conflict", deps: "present" }), /^DEPS=present$/m);
});

test("every coder prompt points at the project config the worktree lacks; the review prompt at its assets", () => {
  // Coders searched for dev-commands.json (git check-ignore, find /); reviewers for their
  // review-context.sh under a project path a user-level install never has.
  const base = { mainRoot: "/main", worktree: "/w", issuePath: "/w/i.md", slug: "x", criteria: "", resume: "", reportPath: "/w/r.json" };
  const line = /^Project config: \/main\/\.coding-crew \(dev-commands\.json, docs\/test-conventions\.md\)/m;
  assert.match(workerPrompt(base), line);
  assert.match(fixPrompt({ ...base, branch: "b" }), line);
  assert.match(fixPrompt({ ...base, branch: "b", kind: "review" }), line);
  assert.match(fixPrompt({ ...base, branch: "b", kind: "conflict", conflictFiles: ["a"] }), line);
  const review = { branch: "b", slug: "s", issuePath: "p", criteria: "", featureBranch: "f", reportPath: "/r" };
  assert.match(reviewPrompt({ ...review, reviewAssets: "/home/u/.coding-crew/code-review" }), /^Review assets: \/home\/u\/\.coding-crew\/code-review$/m);
  assert.doesNotMatch(reviewPrompt(review), /Review assets:/);
});

// ─── the coder's own cause + evidence: a claim, carried to triage ─────────────────

test("a coder report's cause and evidence are parsed when present", () => {
  const r = parseWorkerReport(null, {
    status: "blocked",
    cause: "Environment",
    evidence: { command: "make test-integration", exit: "1", output: "License activation failed" },
  });
  assert.equal(r.cause, "environment");
  assert.deepEqual(r.evidence, { command: "make test-integration", exit: 1, output: "License activation failed", truncated: false });
});

test("an absent or unrecognised cause, and absent or empty evidence, are null", () => {
  assert.equal(parseWorkerReport(null, { status: "partial" }).cause, null);
  assert.equal(parseWorkerReport(null, { status: "partial" }).evidence, null);
  assert.equal(parseWorkerReport(null, { status: "blocked", cause: "gremlins" }).cause, null);
  assert.equal(parseWorkerReport(null, { status: "blocked", cause: "code" }).cause, "code");
  assert.equal(parseWorkerReport(null, { status: "blocked", evidence: { command: "", output: "  " } }).evidence, null);
  assert.equal(parseWorkerReport(null, { status: "blocked", evidence: "see notes" }).evidence, null);
  assert.equal(parseWorkerReport(null, { status: "blocked", evidence: { command: "x", exit: "n/a" } }).evidence.exit, null);
  // No sidecar at all: the blocked shape still has both fields.
  const missing = parseWorkerReport("");
  assert.equal(missing.cause, null);
  assert.equal(missing.evidence, null);
});

test("oversized evidence output keeps only its tail", () => {
  const output = `HEAD-${"x".repeat(EVIDENCE_OUTPUT_MAX)}-TAIL`;
  const e = parseWorkerReport(null, { status: "blocked", evidence: { command: "c", exit: 2, output } }).evidence;
  assert.equal(e.output.length, EVIDENCE_OUTPUT_MAX);
  assert.ok(e.output.endsWith("-TAIL"));
  assert.ok(!e.output.includes("HEAD-"));
  assert.equal(e.truncated, true);
});

test("the triage prompt carries the coder's evidence only as its own claim, and only when given", () => {
  const base = { branch: "b", slug: "x", issuePath: "p", featureBranch: "f", checkOutput: "TEST: fail", reportPath: "/r" };
  const p = triagePrompt({ ...base, coderEvidence: { cause: "environment", command: "make it", exit: 1, output: "boom", truncated: true } });
  assert.match(p, /This is its own claim — check\nit against the diff before believing it/);
  assert.match(p, /^cause: environment\ncommand: make it\nexit: 1\noutput \(tail\):\nboom\n---$/m);
  assert.doesNotMatch(triagePrompt(base), /its own claim/);
  assert.doesNotMatch(triagePrompt({ ...base, coderEvidence: { cause: null } }), /its own claim/);
});

test("check-requires.sh failures are read per issue file, matched on the paths given", () => {
  const out = [
    "REQUIRE: pass /r/my issues/01-a.md true",
    "REQUIRE: fail /r/my issues/01-a.md test -n \"$TOKEN\"",
    "  exit 1",
    "REQUIRE: fail /r/my issues/02-b.md make start svc",
    "  timed out after 300s",
    "  | starting svc",
    "  | ",
    "  | still waiting",
  ].join("\n");
  const m = parseRequiresFailures(out, ["/r/my issues/01-a.md", "/r/my issues/02-b.md"]);
  assert.deepEqual(m.get("/r/my issues/01-a.md"), [{ command: 'test -n "$TOKEN"', status: "exit 1", output: "" }]);
  assert.deepEqual(m.get("/r/my issues/02-b.md"), [{ command: "make start svc", status: "timed out after 300s", output: "starting svc\n\nstill waiting" }]);
  assert.equal(parseRequiresFailures("REQUIRE: pass /x.md true", ["/x.md"]).size, 0);
});

// ─── triage: parseTriageReport ────────────────────────────────────────────────

test("a fixable triage sidecar parses category and detail", () => {
  const sidecar = {
    fixable: "yes",
    category: "wrong dependency version",
    detail: "package.json pins @scope/pkg@1.4.19, which does not exist on the registry.",
  };
  const r = parseTriageReport("", sidecar);
  assert.equal(r.ok, true);
  assert.equal(r.fixable, true);
  assert.equal(r.category, "wrong dependency version");
  assert.match(r.detail, /does not exist on the registry/);
});

test("a not-fixable triage sidecar parses the same way", () => {
  const sidecar = {
    fixable: "no",
    category: "registry unreachable",
    detail: "the private registry returned 404 for every package, not just this diff's.",
  };
  const r = parseTriageReport("", sidecar);
  assert.equal(r.ok, true);
  assert.equal(r.fixable, false);
  assert.equal(r.category, "registry unreachable");
});

test("a triage sidecar with a fixable field wins over the captured text entirely", () => {
  const sidecar = { fixable: "no", category: "registry unreachable", detail: "404 for every package" };
  const r = parseTriageReport("(structured result written to /r/x.triage.report.json)", sidecar);
  assert.equal(r.parsedFrom, "json");
  assert.equal(r.fixable, false);
  assert.equal(r.category, "registry unreachable");
});

test("an empty or missing-verdict triage report fails closed toward fixable, and is not ok", () => {
  const empty = parseTriageReport("");
  assert.equal(empty.ok, false);
  assert.equal(empty.fixable, true);
  assert.match(empty.detail, /never wrote its verdict file/);

  const noVerdict = parseTriageReport("anything", { category: "something", detail: "something else" });
  assert.equal(noVerdict.ok, false);
  assert.equal(noVerdict.fixable, true);
  assert.match(noVerdict.detail, /no valid fixable field/);
});

test("the triage prompt states the failing check output and asks for a fenced json verdict", () => {
  const p = triagePrompt({
    branch: "crew/f/x",
    slug: "x",
    issuePath: "/repo/.scratch/f/issues/open/01-x.md",
    featureBranch: "feature/f",
    checkOutput: "TEST: fail\nyarn install ... 404 Not Found",
    reportPath: "/repo/.scratch/f/dispatch/x.triage.report.json",
  });
  assert.match(p, /404 Not Found/);
  assert.match(p, /```json/);
  assert.match(p, /"fixable": "yes \| no"/);
  assert.match(p, /"category":/);
  assert.match(p, /"detail":/);
  // Never asks the coder that wrote the branch to grade its own failure.
  assert.doesNotMatch(p, /crew-coder/);
});

test("the triage prompt makes the sidecar file the verdict channel, not an option", () => {
  const p = triagePrompt({
    branch: "crew/f/x",
    slug: "x",
    issuePath: "/repo/.scratch/f/issues/open/01-x.md",
    featureBranch: "feature/f",
    checkOutput: "",
    reportPath: "/repo/.scratch/f/dispatch/x.triage.report.json",
  });
  assert.match(p, /Write your structured verdict to \/repo\/\.scratch\/f\/dispatch\/x\.triage\.report\.json as your last action/);
});

test("the fix prompt carries the triage verdict forward and forbids redoing finished work", () => {
  const p = fixPrompt({
    mainRoot: "/repo",
    worktree: "/repo/.scratch/worktrees/crew/f/x",
    issuePath: "/repo/.scratch/f/issues/open/01-x.md",
    slug: "x",
    branch: "crew/f/x",
    context: "wrong dependency version: package.json pins a version that 404s",
    checkOutput: "TEST: fail\nyarn install ... 404 Not Found",
    reportPath: "/repo/.scratch/f/dispatch/x.report.json",
  });
  assert.match(p, /wrong dependency version/);
  assert.match(p, /404 Not Found/);
  assert.match(p, /already judged acceptable/);
  assert.match(p, /do not redo or restructure/i);
  // Same result contract as workerPrompt — report.mjs must parse either the same way.
  assert.match(p, /Write your structured result to \/repo\/\.scratch\/f\/dispatch\/x\.report\.json as your last action/);
});


test("a coder-admitted extra-check failure stops the issue before any gate runs", () => {
  const base = { status: "complete" };
  const failed = applySchemaPrefilter(
    parseWorkerReport(null, { ...base, checks: { test: "pass", lint: "pass", typecheck: "pass", coverage: "fail" } }),
  );
  assert.equal(failed.status, "partial");
  assert.match(failed.reason, /reported checks failed: coverage/);

  // Never reported: left to verify-worktree.sh, which runs every cached check anyway.
  const unrun = applySchemaPrefilter(
    parseWorkerReport(null, { ...base, checks: { test: "pass", lint: "pass", typecheck: "pass", coverage: "not_run" } }),
  );
  assert.equal(unrun.status, "complete");

  const passed = applySchemaPrefilter(
    parseWorkerReport(null, { ...base, checks: { test: "pass", lint: "pass", typecheck: "pass", coverage: "pass" } }),
  );
  assert.equal(passed.status, "complete");
});

test("a review's cause is `environment` only when it says so; anything else is the code's", () => {
  const verdict = (cause) => parseReviewReport("", { branch: "b", slug: "s", verdict: "unmet", detail: "d", cause, findings: [] }).cause;
  assert.equal(verdict("environment"), "environment");
  assert.equal(verdict(" Environment "), "environment");
  assert.equal(verdict("code"), null);
  assert.equal(verdict(undefined), null);
  assert.equal(verdict("infra"), null);
});

// ─── findings triage (crew-triage's findings mode) ───────────────────────────

test("parseFindingsTriage reads one verdict per finding, by index, in any order", () => {
  const r = parseFindingsTriage(
    { findings: [{ index: 1, verdict: "Dismiss", rationale: " noise " }, { index: 0, verdict: "actionable", rationale: "local", adr: "true" }] },
    2,
  );
  assert.equal(r.ok, true);
  assert.deepEqual(r.verdicts[0], { verdict: "actionable", rationale: "local", adr: true, protected: false });
  assert.deepEqual(r.verdicts[1], { verdict: "dismiss", rationale: "noise", adr: false, protected: false });
});

test("parseFindingsTriage is all-or-nothing: a missing, unknown, duplicate or stray entry is no verdict", () => {
  const ok = { index: 0, verdict: "actionable" };
  assert.match(parseFindingsTriage(null, 1).detail, /no report\.json/);
  assert.match(parseFindingsTriage({}, 1).detail, /no findings array/);
  assert.match(parseFindingsTriage({ findings: [ok] }, 2).detail, /leaves finding 1 unjudged/);
  assert.match(parseFindingsTriage({ findings: [{ index: 0, verdict: "maybe" }] }, 1).detail, /the verdict "maybe"/);
  assert.match(parseFindingsTriage({ findings: [ok, ok] }, 1).detail, /judges finding 0 twice/);
  assert.match(parseFindingsTriage({ findings: [{ index: 3, verdict: "actionable" }] }, 1).detail, /outside 0\.\.0/);
  for (const bad of [null, {}, { findings: [ok] }]) assert.equal(parseFindingsTriage(bad, 2).ok, false);
});

test("touchesProtectedPath: CI config, auth, deploy and .env, by the finding's location", () => {
  for (const p of [".github/workflows/ci.yml:3", ".gitlab-ci.yml", "Jenkinsfile:1", "app/.env.production:2", "src/auth/login.ts:10", "src/auth.ts:1", "scripts/deploy.sh:4", "infra/deploy/prod.yml"]) {
    assert.equal(touchesProtectedPath(p), true, p);
  }
  for (const p of ["src/alpha.txt:1", "src/author.ts:2", "src/oauthish.ts", "src/deployer.ts", "", undefined]) {
    assert.equal(touchesProtectedPath(p), false, String(p));
  }
});

test("applyFindingVerdicts: an ADR clash or a protected path forces Debatable over triage's verdict", () => {
  const findings = [
    { severity: "HIGH", location: "src/a.ts:1", criterion: "a" },
    { severity: "LOW", location: ".github/workflows/ci.yml:9", criterion: "b" },
    { severity: "LOW", location: "src/c.ts:3", criterion: "c" },
    { severity: "LOW", location: "src/d.ts:3", criterion: "d" },
  ];
  const out = applyFindingVerdicts(findings, [
    { verdict: "actionable", rationale: "ok", adr: true, protected: false },
    { verdict: "actionable", rationale: "ok", adr: false, protected: false },
    { verdict: "actionable", rationale: "ok", adr: false, protected: true },
    { verdict: "dismiss", rationale: "noise", adr: false, protected: false },
  ]);
  assert.deepEqual(out.map((f) => f.verdict), ["debatable", "debatable", "debatable", "actionable"]);
  assert.match(out[0].rationale, /^ok \[forced Debatable: contradicts a documented decision/);
  assert.match(out[1].rationale, /protected path/);
  assert.match(out[3].rationale, /^noise \[remapped dismiss → actionable/, "auto never dismisses");
});

test("applyFindingVerdicts: a dismiss on a protected path or with adr still ends up Debatable", () => {
  const out = applyFindingVerdicts(
    [
      { severity: "LOW", location: ".github/workflows/ci.yml:9", criterion: "a" },
      { severity: "LOW", location: "src/b.ts:1", criterion: "b" },
    ],
    [
      { verdict: "dismiss", rationale: "noise", adr: false, protected: false },
      { verdict: "dismiss", rationale: "noise", adr: true, protected: false },
    ],
  );
  assert.deepEqual(out.map((f) => f.verdict), ["debatable", "debatable"]);
});

test("annotateFindings writes verdicts beside the sidecar's findings, skipping entries the parser drops", () => {
  const sidecar = { branch: "b", verdict: "all-met", findings: [{ severity: "bogus", criterion: "x" }, { severity: "HIGH", criterion: "y" }, { severity: "LOW", criterion: "z", extra: 1 }] };
  const out = annotateFindings(sidecar, [
    { severity: "HIGH", verdict: "debatable", rationale: "r1" },
    { severity: "LOW", verdict: "actionable", rationale: "r2" },
  ]);
  assert.deepEqual(out.findings[0], sidecar.findings[0]);
  assert.equal(out.findings[1].verdict, "debatable");
  assert.equal(out.findings[2].rationale, "r2");
  assert.equal(out.findings[2].extra, 1);
  // And the aggregate parser hands them back: a review report round-trips its verdicts.
  const [rec] = parseReviewAggregate(`## Branch: b\n\`\`\`json\n${JSON.stringify(out)}\n\`\`\`\n`);
  assert.deepEqual(rec.findings.map((f) => [f.severity, f.verdict, f.rationale]), [["HIGH", "debatable", "r1"], ["LOW", "actionable", "r2"]]);
});

test("a finding with no (or an unknown) verdict carries none", () => {
  const [rec] = parseReviewAggregate('## Branch: b\n```json\n{"branch":"b","verdict":"all-met","findings":[{"severity":"HIGH","criterion":"x","verdict":"nope"},{"severity":"LOW","criterion":"y"}]}\n```\n');
  assert.ok(rec.findings.every((f) => !("verdict" in f)));
});

test("severityNames: the severities a level promotes, as defer records them", () => {
  assert.equal(severityNames("high"), "CRITICAL, HIGH");
  assert.equal(severityNames("critical"), "CRITICAL");
  assert.equal(severityNames("medium"), "CRITICAL, HIGH, MEDIUM");
  assert.equal(severityNames("none"), "");
  assert.equal(severityNames("actionable"), "");
});

test("a deferred test check parses and does not demote complete", () => {
  const r = parseWorkerReport(null, { status: "complete", checks: { test: "deferred", lint: "pass", typecheck: "pass" } });
  assert.equal(r.checks.test, "deferred");
  const v = applySchemaPrefilter(r);
  assert.equal(v.status, "complete");
  assert.equal(v.demoted, false);
});

test("review findings carry issue, or an empty string when absent", () => {
  const r = parseReviewReport("", {
    verdict: "unmet",
    findings: [
      { severity: "HIGH", location: "a.ts:1", issue: " leaks the handle ", criterion: "closes it" },
      { severity: "LOW", location: "b.ts:2", criterion: "renames x" },
    ],
  });
  assert.equal(r.findings[0].issue, "leaks the handle");
  assert.equal(r.findings[1].issue, "");
});

test("findingsTriagePrompt lists issue before criterion", async () => {
  const { findingsTriagePrompt } = await import("../../orchestrator/lib/prompts.mjs");
  const out = findingsTriagePrompt({
    scope: "s", ref: "r", change: "git diff c", reportPath: "/p",
    findings: [{ severity: "HIGH", location: "a.ts:1", issue: "PROBLEM-TEXT", criterion: "FIX-TEXT" }],
  });
  assert.ok(out.indexOf("PROBLEM-TEXT") > -1 && out.indexOf("PROBLEM-TEXT") < out.indexOf("FIX-TEXT"));
  assert.ok(!out.includes("what the reviewer wants"));
});

test("findingsTriagePrompt does not offer dismiss", async () => {
  const { findingsTriagePrompt } = await import("../../orchestrator/lib/prompts.mjs");
  const out = findingsTriagePrompt({ scope: "s", ref: "r", change: "git diff c", findings: [{ severity: "LOW", location: "a:1", criterion: "x" }], reportPath: "/p" });
  assert.match(out, /"actionable \| debatable"/);
  assert.doesNotMatch(out, /dismiss \|?"|\| dismiss/);
});

// ─── carrying findings forward ────────────────────────────────────────────────

const F = (severity, location, issue, extra = {}) => ({ severity, location, issue, criterion: "c", ...extra });

test("carryFindings: a repeat (line ignored, text normalised) appears once uncarried; an unrepeated earlier finding is carried once", () => {
  const latest = [F("HIGH", "a.js:10", "Bad  thing")];
  const earlier = [
    { findings: [F("HIGH", "a.js:3-5", "bad thing"), F("LOW", "b.js#L4", "nit", { verdict: "actionable", rationale: "x" })] },
    { findings: [F("LOW", "b.js:9", "NIT")] },
  ];
  const out = carryFindings(earlier, latest);
  assert.equal(out.length, 2);
  assert.equal(out[0].carried, undefined);
  assert.deepEqual(out[1], { severity: "LOW", location: "b.js#L4", issue: "nit", criterion: "c", carried: true });
});

test("parseReviewAggregate: a not_run block keeps the previous findings, carried, under the not_run verdict", () => {
  const blk = (o) => `\`\`\`json\n${JSON.stringify({ branch: "b", slug: "s", ...o })}\n\`\`\`\n`;
  const [rec] = parseReviewAggregate(blk({ verdict: "unmet", findings: [F("LOW", "a:1", "x")] }) + blk({ verdict: "not_run", findings: [] }));
  assert.equal(rec.verdict, "not_run");
  assert.equal(rec.findings.length, 1);
  assert.equal(rec.findings[0].carried, true);
  assert.equal(parseReviewAggregate(blk({ verdict: "all-met", findings: [{ severity: "LOW", carried: true, issue: "x" }] }))[0].findings[0].carried, true);
});
