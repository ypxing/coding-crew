import { test } from "node:test";
import assert from "node:assert/strict";

import {
  applySchemaPrefilter,
  findingsAtOrAbove,
  parseReviewAggregate,
  parseReviewReport,
  parseTriageReport,
  parseVerifyChecks,
  parseWorkerReport,
} from "../../orchestrator/lib/report.mjs";
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

// ─── review: a fenced json block is preferred over the markdown shape ────────────
//
// crew-summary.sh's code_review_summary() and promote-findings.sh's remind both used
// to re-derive branch/verdict/findings from the same raw text with their own
// line-anchored awk, independently of this parser and of each other — and drifted:
// a herdr-captured retry report that landed indented and without "##" matched neither
// awk's `^## Branch:`/`^AC:`/`^FINDING:` anchors, so a genuinely successful, all-met
// review was silently reported as not-reviewed even though the merge had already gone
// through on this parser's (correct, whitespace-tolerant) read of the same text. The
// fenced json block sidesteps the whole class: JSON treats whitespace between tokens
// as insignificant, so an indented block still parses.

test("a fenced json review block is preferred over the markdown AC:/FINDING: shape", () => {
  const text = [
    "## Branch: crew/f/x (x)",
    "",
    "```json",
    JSON.stringify({
      branch: "crew/f/x",
      slug: "x",
      verdict: "all-met",
      findings: [{ severity: "HIGH", location: "src/db.ts:7", criterion: "Parameterise the query" }],
    }),
    "```",
    "",
    "### Findings",
    "[HIGH] prose the machine-line-only shape never carried",
  ].join("\n");
  const r = parseReviewReport(text);
  assert.equal(r.parsedFrom, "json");
  assert.equal(r.branch, "crew/f/x");
  assert.equal(r.verdict, "all-met");
  assert.deepEqual(r.findings, [{ severity: "HIGH", location: "src/db.ts:7", criterion: "Parameterise the query", explicit: true }]);
});

test("a herdr-indented, no-## json review block still parses — whitespace between JSON tokens is insignificant", () => {
  const text = [
    "  Branch: crew/f/x (x)",
    "  ```json",
    '  {"branch": "crew/f/x", "slug": "x", "verdict": "all-met", "findings": []}',
    "  ```",
  ].join("\n");
  const r = parseReviewReport(text);
  assert.equal(r.parsedFrom, "json");
  assert.equal(r.verdict, "all-met");
});

test("a review sidecar with a verdict wins over the captured text entirely, same policy as the worker's sidecar", () => {
  const sidecar = { branch: "crew/f/x", slug: "x", verdict: "all-met", detail: "", findings: [] };
  // The captured text is a herdr empty-reply diagnostic string, not a real reviewer reply —
  // exactly the case the sidecar exists to make irrelevant.
  const r = parseReviewReport("(structured result written to /r/x.review.report.json)", sidecar);
  assert.equal(r.parsedFrom, "json");
  assert.equal(r.verdict, "all-met");
});

test("a sidecar with no verdict field is ignored, same as parseWorkerReport ignoring a statusless sidecar", () => {
  const r = parseReviewReport("AC: unmet — see below", { branch: "x" });
  assert.equal(r.verdict, "unmet");
  assert.equal(r.parsedFrom, "markdown");
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

test("a fixable triage verdict parses category and detail", () => {
  const r = parseTriageReport(
    [
      "FIXABLE: yes",
      "CATEGORY: wrong dependency version",
      "DETAIL: package.json pins @scope/pkg@1.4.19, which does not exist on the registry.",
    ].join("\n"),
  );
  assert.equal(r.ok, true);
  assert.equal(r.fixable, true);
  assert.equal(r.category, "wrong dependency version");
  assert.match(r.detail, /does not exist on the registry/);
});

test("a not-fixable triage verdict parses the same way", () => {
  const r = parseTriageReport(
    ["FIXABLE: no", "CATEGORY: registry unreachable", "DETAIL: the private registry returned 404 for every package, not just this diff's."].join(
      "\n",
    ),
  );
  assert.equal(r.ok, true);
  assert.equal(r.fixable, false);
  assert.equal(r.category, "registry unreachable");
});

test("a fenced json triage block is preferred over the markdown FIXABLE:/CATEGORY:/DETAIL: shape", () => {
  const text = [
    "  FIXABLE: no",
    "  ```json",
    '  {"fixable": "yes", "category": "flaky network", "detail": "registry timed out, unrelated to this diff"}',
    "  ```",
  ].join("\n");
  const r = parseTriageReport(text);
  assert.equal(r.parsedFrom, "json");
  assert.equal(r.fixable, true);
  assert.equal(r.category, "flaky network");
});

test("a triage sidecar with a fixable field wins over the captured text entirely, same policy as review and worker sidecars", () => {
  const sidecar = { fixable: "no", category: "registry unreachable", detail: "404 for every package" };
  const r = parseTriageReport("(structured result written to /r/x.triage.report.json)", sidecar);
  assert.equal(r.parsedFrom, "json");
  assert.equal(r.fixable, false);
  assert.equal(r.category, "registry unreachable");
});

test("an empty or unparseable triage report fails closed toward fixable, and is not ok", () => {
  const empty = parseTriageReport("");
  assert.equal(empty.ok, false);
  assert.equal(empty.fixable, true);

  const noVerdict = parseTriageReport("CATEGORY: something\nDETAIL: something else");
  assert.equal(noVerdict.ok, false);
  assert.equal(noVerdict.fixable, true);
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

