/** runFeatureChecks when the throwaway worktree cannot be created, and the green predicate. */

import assert from "node:assert/strict";
import test from "node:test";

import { isGreen } from "../../orchestrator/lib/loop.mjs";
import { integrationSection, runFeatureChecks } from "../../orchestrator/lib/preflight.mjs";

function ctxWith() {
  const effects = {
    mainRoot: "/nonexistent-main",
    gitRead: () => ({ code: 0, stdout: "abcdef0123456789\n", stderr: "" }),
    git: (args) => (args[0] === "worktree" && args[1] === "add" ? { code: 128, stdout: "", stderr: "fatal: boom" } : { code: 0, stdout: "", stderr: "" }),
    exec: () => ({ code: 0, stdout: "", stderr: "" }),
  };
  const sprint = { featureBranch: "feature/demo", featureSlug: "demo", readState: () => ({}) };
  return { sprint, effects, options: {}, log: () => {} };
}

test("an integration worktree that cannot be created is skipped; a baseline one still lets the run proceed", () => {
  const integration = runFeatureChecks(ctxWith(), { stem: "_integration" });
  assert.equal(integration.status, "skipped");
  assert.match(integrationSection("/x", "feature/demo", integration), /\*\*Skipped:\*\* worktree add failed/);
  assert.equal(runFeatureChecks(ctxWith(), { stem: "_baseline" }).status, "pass");
});

test("isGreen: exit 0, nothing blocked, integration pass or cached", () => {
  const ok = { exitCode: 0, blocked: [], integration: { status: "pass" } };
  assert.equal(isGreen(ok), true);
  assert.equal(isGreen({ ...ok, integration: { status: "cached" } }), true);
  assert.equal(isGreen({ ...ok, integration: { status: "skipped" } }), false);
  assert.equal(isGreen({ ...ok, integration: { status: "fail" } }), false);
  assert.equal(isGreen({ ...ok, exitCode: 2 }), false);
  assert.equal(isGreen({ ...ok, blocked: ["a"] }), false);
  assert.equal(isGreen({ ...ok, capped: true }), false);
});
