import { test } from "node:test";
import assert from "node:assert/strict";

import {
  applySchemaPrefilter,
  findingsAtOrAbove,
  parseReviewReport,
  parseVerifyChecks,
  parseWorkerReport,
} from "../../orchestrator/lib/report.mjs";
import { reviewPrompt } from "../../orchestrator/lib/prompts.mjs";

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

test("a fenced json block is read out of a markdown report", () => {
  const text = [
    "## Issue: thing",
    "Status: complete",
    "",
    "```json",
    '{"status":"partial","checks":{"test":"pass"},"progress":"half"}',
    "```",
  ].join("\n");
  const r = parseWorkerReport(text);
  assert.equal(r.parsedFrom, "json");
  assert.equal(r.status, "partial");
  assert.equal(r.progress, "half");
});

test("markdown fallback reads Status and check rows", () => {
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
  assert.equal(r.parsedFrom, "markdown");
  assert.equal(r.status, "complete");
  assert.deepEqual(r.checks, { test: "pass", lint: "fail", typecheck: "not_run" });
  assert.equal(r.workingDirectory, "/wt/thing");
});

test("an empty report is blocked, never complete", () => {
  const r = parseWorkerReport("");
  assert.equal(r.status, "blocked");
  assert.match(r.unparseable, /empty report/);
});

test("a report with no Status line is blocked, never complete", () => {
  const r = parseWorkerReport("I finished everything, all good!");
  assert.equal(r.status, "blocked");
  assert.match(r.unparseable, /no Status/);
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

test("review verdict is read, and a missing verdict is unmet", () => {
  assert.equal(parseReviewReport("## Branch: crew/f/x\nAC: all-met\n").verdict, "all-met");
  assert.equal(parseReviewReport("## Branch: crew/f/x\nAC: unmet — no tests\n").verdict, "unmet");
  const none = parseReviewReport("## Branch: crew/f/x\n\nLooks fine to me.\n");
  assert.equal(none.verdict, "unmet");
  assert.match(none.detail, /no verdict/);
});

test("an empty or skipped review fails closed and is not ok", () => {
  const empty = parseReviewReport("");
  assert.equal(empty.ok, false);
  assert.equal(empty.verdict, "unmet");
  const skipped = parseReviewReport("SKIPPED: empty diff\n");
  assert.equal(skipped.ok, false);
  assert.match(skipped.detail, /empty diff/);
});

test("explicit FINDING lines parse into severity, location and criterion", () => {
  const text = [
    "## Branch: crew/f/x",
    "AC: all-met",
    "FINDING: CRITICAL | src/auth.ts:42 | Reject unsigned tokens before use",
    "FINDING: HIGH | src/db.ts:7 | Parameterise the query",
    "FINDING: bogus | x | y",
  ].join("\n");
  const r = parseReviewReport(text);
  assert.equal(r.findings.length, 2);
  assert.deepEqual(r.findings[0], {
    severity: "CRITICAL",
    location: "src/auth.ts:42",
    criterion: "Reject unsigned tokens before use",
    explicit: true,
  });
  assert.deepEqual(findingsAtOrAbove(r.findings, "critical").map((f) => f.severity), ["CRITICAL"]);
  assert.deepEqual(findingsAtOrAbove(r.findings, "critical-high").map((f) => f.severity), [
    "CRITICAL",
    "HIGH",
  ]);
});

test("bracket severities are the fallback when no FINDING lines exist", () => {
  const text = "## Branch: crew/f/x\nAC: all-met\n\n### [CRITICAL] SQL injection in db.ts:7\n";
  const r = parseReviewReport(text);
  assert.equal(r.findings.length, 1);
  assert.equal(r.findings[0].severity, "CRITICAL");
  assert.equal(r.findings[0].explicit, false);
});

// ─── the reviewer is told what was already executed ──────────────────────────
//
// A real codex sprint stalled on this: the issue's third criterion was "a test covers it
// and `npm test` passes", verify-worktree.sh had already run the suite green in the
// worktree, and the read-only reviewer answered `AC: unmet — npm test was not executed in
// this inspection-only review`. Fail-closed is right; asking for evidence the reviewer is
// structurally unable to produce is not, and it retained the branch every round forever.

test("verify-worktree output is read back as the reviewer's check evidence", () => {
  const stdout = [
    "TYPECHECK: not_run — no command found",
    "LINT: not_run — no command found",
    "TEST: running: npm test",
    "TEST: pass",
    "Verification: success",
  ].join("\n");
  assert.deepEqual(parseVerifyChecks(stdout), { test: "pass", lint: "not_run", typecheck: "not_run" });
});

test("an unseen or failed check is never reported as evidence", () => {
  assert.deepEqual(parseVerifyChecks(""), { test: "not_run", lint: "not_run", typecheck: "not_run" });
  assert.equal(parseVerifyChecks("TEST: fail\n").test, "fail");
});

test("the review prompt states the checks and forbids unmet-for-lack-of-execution", () => {
  const p = reviewPrompt({
    branch: "crew/f/x",
    slug: "x",
    issuePath: "/i/01-x.md",
    criteria: "- [ ] tests pass",
    featureBranch: "feature/f",
    checks: { test: "pass", lint: "not_run", typecheck: "not_run" },
  });
  assert.match(p, /test=pass, lint=not_run, typecheck=not_run/);
  assert.match(p, /do not report a criterion unmet because you could not execute it/);
  // And it does not become a blanket pass: `not_run` stays worthless and the code half
  // of every criterion is still judged from the diff.
  assert.match(p, /`not_run` is not evidence of anything/);
  assert.match(p, /no file and line, no evidence, `unmet`/);
});

test("the review prompt still names the checks when none were discovered", () => {
  const p = reviewPrompt({ branch: "b", slug: "s", issuePath: "p", criteria: "", featureBranch: "f" });
  assert.match(p, /test=not_run, lint=not_run, typecheck=not_run/);
});
