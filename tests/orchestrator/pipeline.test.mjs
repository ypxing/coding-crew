/**
 * pipeline.test.mjs — resumeRoute, the one table of where a retry re-enters the pipeline.
 * End-to-end behaviour of each route is asserted in sprint.test.mjs; this pins the table.
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { resumeRoute } from "../../orchestrator/lib/pipeline.mjs";

// Every retention reason runHousekeeping and its gates hand to finishRetryOrBlock.
const CASES = [
  [null, { route: "restart" }],
  ["partial", { route: "restart" }],
  ["worker timed out after 45m", { route: "restart" }],
  ["worker process failed — see traces/", { route: "restart" }],
  ["verification-failed", { route: "restart" }],
  ["ac-receipt-failed", { route: "restart" }],
  ["merge-failed", { route: "merge" }],
  ["close-refused — issue already closed", { route: "merge" }],
  ["review-not-run", { route: "verify", label: "review-not-run" }],
  ["verification-failed:not-fixable — registry 503", { route: "verify", label: "not-fixable-recheck" }],
  ["verification-failed:fixable — lint: unused import", { route: "fix", kind: "verify", context: "lint: unused import" }],
  ["criteria-unmet — AC 2 has no test", { route: "fix", kind: "review", context: "AC 2 has no test" }],
];

for (const [reason, expected] of CASES) {
  test(`resumeRoute(${JSON.stringify(reason)}) → ${expected.route}`, () => {
    assert.deepEqual(resumeRoute(reason), expected);
  });
}
