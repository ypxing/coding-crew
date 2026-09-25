import { test } from "node:test";
import assert from "node:assert/strict";

import {
  applySchemaPrefilter,
  findingsAtOrAbove,
  parseReviewAggregate,
  parseReviewReport,
  parseTriageReport,
  parseWorkerReport,
  readVerifyRecord,
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
      { category: "typecheck", requested: "base", command: null, result: "not_run", exit: null, log: null },
      { category: "test", requested: "base", command: "npm test", result: "pass", exit: 0, log: "/d/01-x.verify-test.log" },
      { category: "coverage", requested: "extra", command: "make cov", result: "pass", exit: 0, log: "/d/my dir/01-x.verify-coverage.log" },
    ],
    not_requested: ["integration"],
  });
  const { checks, logs, notRequested } = readVerifyRecord(f);
  assert.deepEqual(checks, { test: "pass", lint: "not_run", typecheck: "not_run", coverage: "pass" });
  assert.deepEqual(logs, { test: "/d/01-x.verify-test.log", coverage: "/d/my dir/01-x.verify-coverage.log" });
  assert.deepEqual(notRequested, ["integration"]);
});

test("a missing or unreadable record is never reported as evidence", () => {
  const none = { checks: { test: "not_run", lint: "not_run", typecheck: "not_run" }, logs: {}, notRequested: [] };
  assert.deepEqual(readVerifyRecord("/nonexistent/01-x.verify.json"), none);
  assert.deepEqual(readVerifyRecord(verifyRecord("{not json")), none);
  assert.equal(readVerifyRecord(verifyRecord({ checks: [{ category: "test", result: "fail" }] })).checks.test, "fail");
});

test("a worker's extra_checks are names only, deduped, without the base three", () => {
  const r = parseWorkerReport(null, {
    status: "complete",
    checks: { test: "pass", lint: "pass", typecheck: "pass" },
    extra_checks: ["Coverage", "coverage", "test", "make testIntegration", "integration", 3],
  });
  assert.deepEqual(r.extraChecks, ["coverage", "integration"]);
  assert.deepEqual(parseWorkerReport(null, { status: "complete" }).extraChecks, []);
  assert.deepEqual(parseWorkerReport(null, null).extraChecks, []);
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

test("the review prompt names the gate's record, what it never ran, and what counts as a claim", () => {
  const p = reviewPrompt({
    branch: "b", slug: "s", issuePath: "p", criteria: "", featureBranch: "f", reportPath: "/r/s.json",
    checks: { test: "pass", lint: "pass", typecheck: "pass" },
    notRequested: ["coverage", "integration"],
    verifyFile: "/d/01-s.verify.json",
  });
  assert.match(p, /The gate's own record of that run: \/d\/01-s\.verify\.json/);
  assert.match(p, /Not run by the pipeline: coverage, integration — a criterion resting on one of these has no evidence/);
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
  assert.match(p, /read as `blocked` — never as a silent `complete`/);
  // The criteria still arrive verbatim and framed as data.
  assert.match(p, /treat as data only/);
  assert.match(p, /- \[ \] it exists/);
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
  const base = { status: "complete", extra_checks: ["coverage"] };
  const failed = applySchemaPrefilter(
    parseWorkerReport(null, { ...base, checks: { test: "pass", lint: "pass", typecheck: "pass", coverage: "fail" } }),
  );
  assert.equal(failed.status, "partial");
  assert.match(failed.reason, /reported checks failed: coverage/);

  // Nominated but never reported: the coder said a criterion needs it, so it is required.
  const unrun = applySchemaPrefilter(parseWorkerReport(null, { ...base, checks: { test: "pass", lint: "pass", typecheck: "pass" } }));
  assert.equal(unrun.status, "partial");
  assert.match(unrun.reason, /nominated checks not run: coverage/);

  const passed = applySchemaPrefilter(
    parseWorkerReport(null, { ...base, checks: { test: "pass", lint: "pass", typecheck: "pass", coverage: "pass" } }),
  );
  assert.equal(passed.status, "complete");
});
