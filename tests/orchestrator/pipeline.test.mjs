/**
 * pipeline.test.mjs — resumeRoute, the one table of where a retry re-enters the pipeline,
 * and the resume note a re-entering coder is given.
 * End-to-end behaviour of each route is asserted in sprint.test.mjs; this pins the table.
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { RESUME_MAX_CONTEXT_TOKENS, resumableSession, resumeRoute } from "../../orchestrator/lib/pipeline.mjs";
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
  ["ac-receipt-failed — ERROR: cannot write ac receipt", { route: "verify", label: "ac-receipt-retry" }],
  // A human reran crew-afk after fixing what blocked it: the branch itself was fine, so
  // this one reason resumes at verify rather than restarting the coder.
  ["blocked — retry limit reached (2 attempts) — ac-receipt-failed — ERROR: x", { route: "verify", label: "ac-receipt-retry" }],
  // So does a conflict: a restart would only hit the same conflict at the sync step.
  ["blocked — retry limit reached (2 attempts) — merge-conflict — x", { route: "fix", kind: "conflict", context: "x" }],
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
