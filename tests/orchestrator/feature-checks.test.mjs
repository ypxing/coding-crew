/** runFeatureChecks when the throwaway worktree cannot be created, and the green predicate. */

import assert from "node:assert/strict";
import test from "node:test";

import { isGreen } from "../../orchestrator/lib/loop.mjs";
import { integrationSection, runFeatureChecks } from "../../orchestrator/lib/preflight.mjs";
import { worktreePath } from "../../orchestrator/lib/worktree.mjs";

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

function cacheCtx(state, { tree = "tree1", worktreeFails = true } = {}) {
  const calls = [];
  const effects = {
    mainRoot: "/nonexistent-main",
    gitRead: (args) => ({ code: 0, stdout: args[1].endsWith("^{tree}") ? `${tree}\n` : "abcdef0123456789\n", stderr: "" }),
    git: (args) => {
      calls.push(args.join(" "));
      return args[0] === "worktree" && args[1] === "add" ? { code: 128, stdout: "", stderr: "boom" } : { code: 0, stdout: "", stderr: "" };
    },
  };
  const recorded = [];
  const sprint = { featureBranch: "feature/demo", featureSlug: "demo", readState: () => state, state: (a) => recorded.push(a) };
  return { ctx: { sprint, effects, options: {}, log: () => {} }, calls, recorded };
}

test("a tree a per-issue verify, a baseline or an integration check passed reads cached and runs nothing", () => {
  for (const state of [
    { passing_trees: ["tree1"] },
    { baseline: { commit: "old", tree: "tree1", verdict: "pass" } },
    { integration: { commit: "old", tree: "tree1", verdict: "pass" } },
  ]) {
    const { ctx, calls, recorded } = cacheCtx(state);
    for (const stem of ["_integration", "_baseline"]) {
      assert.equal(runFeatureChecks(ctx, { stem }).status, "cached");
    }
    assert.deepEqual(calls, [], "no worktree, no checks");
    assert.equal(recorded.length, 2, "each slot records the pass");
  }
});

test("a tree that only failed, was never checked, or sits in an older state file without trees runs the checks", () => {
  for (const state of [
    { baseline: { commit: "old", tree: "tree1", verdict: "fail" } },
    { passing_trees: ["other"] },
    { baseline: { commit: "old", verdict: "pass" }, integration: { commit: "old", verdict: "pass" } },
    {},
  ]) {
    const { ctx, calls } = cacheCtx(state);
    assert.notEqual(runFeatureChecks(ctx, { stem: "_integration" }).status, "cached");
    assert.ok(calls.some((c) => c.startsWith("worktree add")));
  }
});

test("under orca the baseline and integration worktrees are named as children of _feature", async () => {
  for (const stem of ["_baseline", "_integration"]) {
    const orca = [];
    const effects = {
      mainRoot: "/nonexistent-main",
      featureRoot: "/nonexistent-main/_feature",
      paneHost: "orca",
      gitRead: () => ({ code: 0, stdout: "abcdef0123456789\n", stderr: "" }),
      git: () => ({ code: 0, stdout: "", stderr: "" }),
      bash: () => {
        throw new Error("checks stop here");
      },
      spawnWithTimeout: async (cmd, args) => (orca.push(args), { code: 0, stdout: "{}", stderr: "" }),
    };
    const sprint = { featureBranch: "feature/demo", featureSlug: "demo", readState: () => ({}), childEnv: () => ({}) };
    assert.throws(() => runFeatureChecks({ sprint, effects, options: { installDeps: false }, log: () => {} }, { stem }), /checks stop here/);
    await effects._paneAdoptions?.values().next().value;
    const set = orca.find((a) => a[0] === "worktree" && a[1] === "set");
    assert.ok(set, `${stem}: ${JSON.stringify(orca)}`);
    assert.equal(set[set.indexOf("--worktree") + 1], `path:${worktreePath("/nonexistent-main", `crew/demo/${stem}`)}`, stem);
    assert.equal(set[set.indexOf("--parent-worktree") + 1], "path:/nonexistent-main/_feature", stem);
    assert.ok(!set.includes("--issue"), stem);
  }
});
