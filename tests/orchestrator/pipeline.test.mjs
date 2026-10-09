/**
 * pipeline.test.mjs — resumeRoute, the one table of where a retry re-enters the pipeline,
 * and the resume note a re-entering coder is given.
 * End-to-end behaviour of each route is asserted in the sprint-<topic>.test.mjs files; this pins the table.
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { issueFingerprint } from "../../tracker/body-format.mjs";
import { CONFLICT_ROLE, RESUME_MAX_CONTEXT_TOKENS, mayResumeCoderSession, resumableSession, resumeRoute } from "../../orchestrator/lib/pipeline.mjs";
import { Sprint } from "../../orchestrator/lib/sprint.mjs";
import { isTestPath } from "../../orchestrator/lib/pipeline/review.mjs";
import { resumeNote } from "../../orchestrator/lib/prompts.mjs";

// Every retention reason runHousekeeping and its gates hand to finishRetryOrBlock.
const CASES = [
  [null, { route: "restart" }],
  ["partial", { route: "restart" }],
  ["worker timed out after 45m", { route: "restart" }],
  ["worker process failed — see traces/", { route: "restart" }],
  ["verification-failed", { route: "restart" }],
  ["ac-receipt-failed", { route: "verify", label: "ac-receipt-retry" }],
  ["merge-failed", { route: "merge" }],
  // A conflict needs code, not another merge attempt.
  ["merge-conflict — 'feature/x' gained commits that conflict with 'crew/x/a'", { route: "fix", kind: "conflict", context: "'feature/x' gained commits that conflict with 'crew/x/a'" }],
  ["close-refused — issue already closed", { route: "merge" }],
  // Blocked at once, never retried in-run; a human's re-run goes straight back to the merge.
  ["blocked — main-tree-dirty — uncommitted changes in /r would be overwritten: a.ts — commit or stash them", { route: "merge" }],
  ["main-tree-dirty — x", { route: "merge" }],
  ["review-not-run", { route: "verify", label: "review-not-run" }],
  ["review-not-run — review dispatch timed out", { route: "verify", label: "review-not-run" }],
  ["verification-failed:not-fixable — registry 503", { route: "verify", label: "not-fixable-recheck" }],
  ["verification-failed:fixable — lint: unused import", { route: "fix", kind: "verify", context: "lint: unused import" }],
  ["criteria-unmet — AC 2 has no test", { route: "fix", kind: "review", context: "AC 2 has no test" }],
  // The reviewer blamed the environment: blocked at once; a human's re-run re-checks, no coder.
  ["blocked — criteria-unmet:environment — LocalStack unreachable, specs skipped", { route: "verify", label: "environment-recheck" }],
  ["ac-receipt-failed — ERROR: cannot write ac receipt", { route: "verify", label: "ac-receipt-retry" }],
  // A human reran crew-afk after fixing what blocked it: the branch itself was fine, so
  // this one reason resumes at verify rather than restarting the coder.
  ["blocked — retry limit reached (2 attempts) — ac-receipt-failed — ERROR: x", { route: "verify", label: "ac-receipt-retry" }],
  // So does a conflict: a restart would only hit the same conflict at the sync step.
  ["blocked — retry limit reached (2 attempts) — merge-conflict — x", { route: "fix", kind: "conflict", context: "x" }],
  // So does a not-fixable verdict: triage already ruled out recoding, so only re-check.
  ["blocked — retry limit reached (2 attempts) — verification-failed:not-fixable — LocalStack unreachable", { route: "verify", label: "not-fixable-recheck" }],
  // So do the two fix reasons: a restart would throw away what the gate told the coder.
  ["blocked — retry limit reached (2 attempts) — verification-failed:fixable — lint: x", { route: "fix", kind: "verify", context: "lint: x" }],
  ["blocked — retry limit reached (2 attempts) — criteria-unmet — AC 2", { route: "fix", kind: "review", context: "AC 2" }],
  // Blocked in preflight on a failing ## Requires: re-probed first, then a fresh start.
  // Every other blocked reason still restarts, as before.
  ["blocked — retry limit reached (2 attempts) — merge-failed", { route: "restart" }],
  ["blocked — retry limit reached (2 attempts) — review-not-run", { route: "restart" }],
];

for (const [reason, expected] of CASES) {
  test(`resumeRoute(${JSON.stringify(reason)}) → ${expected.route}`, () => {
    assert.deepEqual(resumeRoute(reason), expected);
  });
}

// ─── resumeNote for a blocked issue whose branch was retained ──────────────────────────

test("a blocked issue resumed on its retained branch is told the commits are there", () => {
  const note = resumeNote({ priorBranch: "crew/demo/alpha", hasProgress: false, hasBlocked: true });
  assert.match(note, /## Blocked/);
  assert.match(note, /preserved on branch `crew\/demo\/alpha`/);
});

test("the blocked note names no branch when none was retained, or when ## Progress already does", () => {
  assert.doesNotMatch(resumeNote({ priorBranch: null, hasProgress: false, hasBlocked: true }), /branch/);
  const both = resumeNote({ priorBranch: "crew/demo/alpha", hasProgress: true, hasBlocked: true });
  assert.equal((both.match(/crew\/demo\/alpha/g) ?? []).length, 1);
});

// ─── resumableSession: when a fix round may continue the coder's own session ───────────

test("a fix round resumes the session that left the branch exactly where it is", () => {
  assert.deepEqual(resumableSession({ session_id: "s1", head: "abc", context_tokens: 40_000 }, "abc"), { sessionId: "s1" });
});

test("a session is not resumed once the branch has moved, when it is too big, or when there is none", () => {
  assert.match(resumableSession({ session_id: "s1", head: "abc", context_tokens: 10 }, "def").reason, /moved/);
  assert.match(resumableSession({ session_id: "s1", head: "abc", context_tokens: RESUME_MAX_CONTEXT_TOKENS + 1 }, "abc").reason, /over 100k/);
  assert.match(resumableSession(null, "abc").reason, /no earlier coder session/);
  assert.match(resumableSession({ session_id: null, head: "abc" }, "abc").reason, /no earlier coder session/);
  assert.match(resumableSession({ session_id: null, head: "abc", context_tokens: 40_000 }, "abc").reason, /no earlier coder session/);
});

// ─── isTestPath: what makes a diff test-only for the reviewer ─────────────────────────

test("isTestPath recognises test files by name and by directory", () => {
  for (const p of ["src/a.spec.ts", "src/a.test.js", "test/integration/x.ts", "pkg/__tests__/y.tsx", "x_test.go", "tests/test_a.py", "spec/b_spec.rb", "tests/a.bats", "test/fixtures/data.json"]) {
    assert.equal(isTestPath(p), true, p);
  }
  for (const p of ["src/a.ts", "src/latest.ts", "src/contest/x.ts", "README.md", "package.json"]) {
    assert.equal(isTestPath(p), false, p);
  }
});

// ─── an edited issue restarts instead of fixing ────────────────────────────────────────

test("an edited issue restarts on workerPrompt for fix, conflict and verify routes", () => {
  for (const reason of [
    "criteria-unmet — AC 2",
    "verification-failed:fixable — lint: x",
    "review-not-run",
    "verification-failed:not-fixable — x",
    "merge-conflict — x",
    "blocked — retry limit reached (2 attempts) — merge-conflict — x",
  ]) {
    assert.deepEqual(resumeRoute(reason, { edited: true }), { route: "restart", edited: true }, reason);
  }
});

test("an edited issue leaves the merge route alone", () => {
  assert.deepEqual(resumeRoute("merge-failed", { edited: true }), { route: "merge" });
});

test("an unedited issue takes today's route", () => {
  assert.deepEqual(resumeRoute("criteria-unmet — AC 2", { edited: false }), { route: "fix", kind: "review", context: "AC 2" });
});

const ISSUE = "Status: ready-for-agent\n\n## What to build\n\nA thing.\n\n## Acceptance criteria\n\n- [ ] one\n- [ ] two\n\n## Blocked by\n\nNone\n";

test("the fingerprint ignores crew-afk's own writes", () => {
  const fp = issueFingerprint(ISSUE);
  const own = ISSUE.replace("ready-for-agent", "in-progress").replace("- [ ] one", "- [x] one") + "\n## Progress\n\nRound 1\n\n## Blocked\n\nwhy\n";
  assert.equal(issueFingerprint(own), fp);
});

test("the fingerprint changes when What to build or a criterion is edited", () => {
  const fp = issueFingerprint(ISSUE);
  assert.notEqual(issueFingerprint(ISSUE.replace("two", "three")), fp);
  assert.notEqual(issueFingerprint(ISSUE.replace("A thing.", "Another thing.")), fp);
  assert.notEqual(issueFingerprint(ISSUE.replace("- [ ] two\n", "- [ ] two\n- [ ] new\n")), fp);
});

test("a fix round never resumes a session after a conflict dispatch ran in the same attempt", () => {
  const base = { enabled: true, route: "fix", runtime: "claude", conflictDispatched: false };
  assert.equal(mayResumeCoderSession(base), true);
  assert.equal(mayResumeCoderSession({ ...base, conflictDispatched: true }), false);
  assert.equal(mayResumeCoderSession({ ...base, enabled: false }), false);
  assert.equal(mayResumeCoderSession({ ...base, route: "restart" }), false);
  assert.equal(mayResumeCoderSession({ ...base, runtime: "pi" }), false);
});

test("a conflict dispatch's session is recorded under its own role, so a fix round at the same tip starts fresh", () => {
  const ledger = [
    { slug: "alpha", role: "coder", session_id: "s-coder", head: "old", context_tokens: 10 },
    { slug: "alpha", role: CONFLICT_ROLE, session_id: "s-conflict", head: "merged", context_tokens: 10 },
  ];
  const sprint = { readState: () => ({ dispatches: ledger }), lastDispatch: Sprint.prototype.lastDispatch };
  assert.notEqual(CONFLICT_ROLE, "coder");
  const pick = resumableSession(sprint.lastDispatch("alpha", "coder"), "merged");
  assert.equal(pick.sessionId, undefined, "the conflict session is not resumable");
  assert.match(pick.reason, /moved/);
  const only = { readState: () => ({ dispatches: ledger.slice(1) }), lastDispatch: Sprint.prototype.lastDispatch };
  assert.match(resumableSession(only.lastDispatch("alpha", "coder"), "merged").reason, /no earlier coder session/);
});

test("a fix round resumes only on a runtime whose adapter has resume", () => {
  const adapters = { full: { resume: (id) => ["--resume", id] }, bare: {} };
  const base = { enabled: true, route: "fix", conflictDispatched: false };
  assert.equal(mayResumeCoderSession({ ...base, runtime: "full" }, adapters), true);
  assert.equal(mayResumeCoderSession({ ...base, runtime: "bare" }, adapters), false);
});
