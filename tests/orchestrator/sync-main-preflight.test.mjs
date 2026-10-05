/**
 * syncFeatureBranch (preflight.mjs) — calls sync-feature-branch.sh once with the feature branch,
 * maps its exit to a status, honours --no-sync-main, and main.mjs stops on a conflict before the
 * baseline. Fake effects; the git behaviour is covered by tests/crew-afk-sync-feature-branch.bats.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { syncConflictMessage, syncFeatureBranch } from "../../orchestrator/lib/preflight.mjs";

const REPO = join(dirname(fileURLToPath(import.meta.url)), "../..");

function ctxWith(result, options = {}) {
  const calls = [];
  const logs = [];
  return {
    calls,
    logs,
    ctx: {
      sprint: { featureBranch: "feature/demo", childEnv: () => ({}) },
      effects: { bash: (name, args, opts) => (calls.push({ name, args, opts }), result) },
      options,
      log: (l) => logs.push(l),
    },
  };
}

test("merged: calls the script once with the feature branch and logs its SYNC line", () => {
  const { ctx, calls, logs } = ctxWith({ code: 0, stdout: "SYNC: merged origin/main (2 commit(s)) into feature/demo at abc\n", stderr: "" });
  const r = syncFeatureBranch(ctx);
  assert.equal(r.status, "merged");
  assert.deepEqual(calls.map((c) => [c.name, c.args]), [["sync-feature-branch.sh", ["feature/demo"]]]);
  assert.deepEqual(logs, ["SYNC: merged origin/main (2 commit(s)) into feature/demo at abc"]);
});

test("up to date: no output, no log line", () => {
  const { ctx, logs } = ctxWith({ code: 0, stdout: "", stderr: "" });
  assert.equal(syncFeatureBranch(ctx).status, "current");
  assert.deepEqual(logs, []);
});

test("conflict: exit 1 is a stop carrying the script's message", () => {
  const { ctx } = ctxWith({ code: 1, stdout: "", stderr: "SYNC: conflict merging origin/main into feature/demo — a.txt, b.txt\n" });
  const r = syncFeatureBranch(ctx);
  assert.equal(r.status, "conflict");
  const msg = syncConflictMessage("feature/demo", r.output);
  assert.match(msg, /a\.txt, b\.txt/);
  assert.match(msg, /--no-sync-main/);
});

test("--no-sync-main skips without calling the script; --dry-run passes --dry-run", () => {
  const off = ctxWith({ code: 0, stdout: "", stderr: "" }, { syncMain: false });
  assert.equal(syncFeatureBranch(off.ctx).status, "skipped");
  assert.equal(off.calls.length, 0);
  const dry = ctxWith({ code: 0, stdout: "SYNC: would merge origin/main (1 commit(s)) into feature/demo", stderr: "" }, { dryRun: true });
  assert.equal(syncFeatureBranch(dry.ctx).status, "would-merge");
  assert.deepEqual(dry.calls[0].args, ["--dry-run", "feature/demo"]);
});

test("main.mjs syncs after the dirty check and before the baseline, stopping with exit 1 on a conflict", () => {
  const src = readFileSync(join(REPO, "orchestrator/main.mjs"), "utf8");
  const at = (needle) => {
    const i = src.indexOf(needle);
    assert.notEqual(i, -1, needle);
    return i;
  };
  const dirty = at("const dirty = dirtyTrackedFiles(effects);\n      if (dirty.length)");
  const sync = at("syncFeatureBranch({ sprint");
  const baseline = at("runBaselineAsync(ctx)");
  assert.ok(dirty < sync && sync < baseline);
  assert.match(src.slice(sync, baseline), /sync\.status === "conflict"[\s\S]*?exitCode = 1/);
});
