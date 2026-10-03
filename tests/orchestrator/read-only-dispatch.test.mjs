import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Effects } from "../../orchestrator/lib/effects.mjs";
import { readOnlyDispatch } from "../../orchestrator/lib/pipeline/shared.mjs";

// A main checkout on feature/demo with two issue branches, alpha and beta, each in its worktree.
function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), "readonly-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const main = join(root, "main");
  const git = (args, cwd = main) => execFileSync("git", ["-C", cwd, ...args], { encoding: "utf8" }).trim();
  execFileSync("git", ["init", "-q", "-b", "feature/demo", main]);
  git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "base"]);
  for (const s of ["alpha", "beta"]) git(["worktree", "add", "-q", "-b", `crew/demo/${s}`, join(root, s)]);
  const logs = [];
  const effects = new Effects({ scriptsDir: join(root, "scripts"), mainRoot: main });
  const ctx = { sprint: { featureSlug: "demo", featureBranch: "feature/demo" }, effects, log: (m) => logs.push(m) };
  const commit = (cwd) => git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "x"], cwd);
  return { root, main, git, commit, ctx, effects, logs };
}

const ALPHA = { label: "reviewer alpha", branches: ["crew/demo/alpha"] };

test("a reviewer that moves a sibling issue branch is a violation naming that ref", async (t) => {
  const { root, commit, ctx, logs } = fixture(t);
  const r = await readOnlyDispatch(ctx, ALPHA, async () => commit(join(root, "beta")));
  assert.match(r.violation ?? "", /refs\/heads\/crew\/demo\/beta/);
  assert.match(logs.join("\n"), /\[READONLY-VIOLATION\] reviewer alpha/);
});

test("a sibling's own worker committing meanwhile is not the reviewer's doing", async (t) => {
  const { root, commit, ctx, effects } = fixture(t);
  const r = await readOnlyDispatch(ctx, ALPHA, () => effects.inWorktree(join(root, "beta"), async () => commit(join(root, "beta"))));
  assert.equal(r.violation, undefined);
});

test("a reviewer that moves the feature branch is a violation, a concurrent merge is not", async (t) => {
  const { main, commit, ctx, effects } = fixture(t);
  const moved = await readOnlyDispatch(ctx, ALPHA, async () => commit(main));
  assert.match(moved.violation ?? "", /refs\/heads\/feature\/demo/);
  const merged = await readOnlyDispatch(ctx, ALPHA, async () => {
    effects.noteRefActivity("bash", ["/x/merge-branches.sh"], main);
    commit(main);
  });
  assert.equal(merged.violation, undefined);
});

test("a reviewer that switches the main checkout's branch at the same commit is a violation", async (t) => {
  const { git, ctx } = fixture(t);
  const r = await readOnlyDispatch(ctx, ALPHA, async () => git(["checkout", "-q", "-b", "tmp"]));
  assert.match(r.violation ?? "", /HEAD/);
});

test("a main-checkout edit is a violation even when another worker's effect ran meanwhile", async (t) => {
  const { main, ctx, effects } = fixture(t);
  const r = await readOnlyDispatch(ctx, ALPHA, async () => {
    effects.noteRefActivity("bash", ["/x/merge-branches.sh"], main);
    writeFileSync(join(main, "file.txt"), "x");
  });
  assert.match(r.violation ?? "", /uncommitted changes in the main checkout/);
});

test("a violation still hands back the dispatch's result, so its cost is recorded", async (t) => {
  const { main, ctx } = fixture(t);
  const r = await readOnlyDispatch(ctx, ALPHA, async () => {
    writeFileSync(join(main, "file.txt"), "x");
    return { costUsd: 1.5 };
  });
  assert.ok(r.violation);
  assert.deepEqual(r.result, { costUsd: 1.5 });
});

test("no change is not a violation", async (t) => {
  const { ctx } = fixture(t);
  const r = await readOnlyDispatch(ctx, ALPHA, async () => "ok");
  assert.deepEqual(r, { result: "ok" });
});

test("a git that moves no ref (worktree remove, status) excuses nothing", async (t) => {
  const { main, commit, ctx, effects } = fixture(t);
  const r = await readOnlyDispatch(ctx, ALPHA, async () => {
    effects.noteRefActivity("git", ["-C", main, "worktree", "prune"], main);
    commit(main);
  });
  assert.match(r.violation ?? "", /refs\/heads\/feature\/demo/);
});

test("a worktree add from the main checkout excuses a new crew branch, not a move of the feature branch", async (t) => {
  const { root, main, git, commit, ctx, effects } = fixture(t);
  const r = await readOnlyDispatch(ctx, ALPHA, async () => {
    effects.noteRefActivity("git", ["-C", main, "worktree", "add", "-B", "crew/demo/gamma", join(root, "gamma")], main);
    git(["worktree", "add", "-q", "-b", "crew/demo/gamma", join(root, "gamma")]);
    commit(main);
  });
  assert.match(r.violation ?? "", /refs\/heads\/feature\/demo/);
  assert.doesNotMatch(r.violation, /gamma/);
});

test("a worker in a worktree reached through a symlink is still its own branch's mover", async (t) => {
  const { root, commit, ctx, effects } = fixture(t);
  const { symlinkSync } = await import("node:fs");
  const link = join(root, "link");
  symlinkSync(root, link);
  const r = await readOnlyDispatch(ctx, ALPHA, () => effects.inWorktree(join(link, "beta"), async () => commit(join(root, "beta"))));
  assert.equal(r.violation, undefined);
});
