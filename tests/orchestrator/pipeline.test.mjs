/**
 * pipeline.test.mjs — finishBlocked/finishPartial's worktree-removal guard.
 *
 * A herdr dispatch that settles with no sidecar (dispatchViaHerdr's "absent" case) or fails
 * to communicate at all reports herdrFailed on `worker.dispatch`, but herdr never confirmed
 * the underlying agent process actually exited — the pane is deliberately kept open for the
 * same reason. Before this guard, runHousekeeping's blocked/partial paths still force-removed
 * the worktree in that case, so a coder that was in fact still alive and working lost its
 * cwd out from under it, and the next round recreated a fresh checkout at the same path —
 * two workers, one worktree. See CLAUDE.md-adjacent bug writeup for the real-world incident.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";

import { Effects } from "../../orchestrator/lib/effects.mjs";
import { ensureWorktree } from "../../orchestrator/lib/worktree.mjs";
import { parseWorkerReport } from "../../orchestrator/lib/report.mjs";
import { runHousekeeping } from "../../orchestrator/lib/pipeline.mjs";

/** A real git repo with one commit, plus a real (non-dry-run) Effects — same as worktree.test.mjs. */
function gitRoot() {
  const mainRoot = mkdtempSync(join(tmpdir(), "pipeline-worktree-"));
  const git = (...args) => execFileSync("git", ["-C", mainRoot, ...args], { encoding: "utf8" });
  git("init", "-q", "-b", "main");
  git("config", "user.email", "test@example.com");
  git("config", "user.name", "Test");
  writeFileSync(join(mainRoot, "README.md"), "seed\n");
  git("add", "-A");
  git("commit", "-q", "-m", "seed");
  const effects = new Effects({ scriptsDir: mainRoot, mainRoot, dryRun: false });
  return { mainRoot, effects };
}

/** Just the Sprint methods the "no report.json" -> blocked path touches. */
function fakeSprint() {
  const calls = [];
  return {
    calls,
    coverageGap: (slug, categories) => calls.push(["coverageGap", slug, categories]),
    blocked: (slug, branch, reason) => calls.push(["blocked", slug, branch, reason]),
    markBlockedThisRun: (slug) => calls.push(["markBlockedThisRun", slug]),
  };
}

async function runBlockedScenario({ herdrFailed }) {
  const { mainRoot, effects } = gitRoot();
  const branch = "crew/demo/alpha";
  const wt = ensureWorktree(effects, { mainRoot, branch, base: "HEAD", expectReuse: false });
  assert.ok(existsSync(wt.path), "worktree must exist before the scenario runs");

  const sprint = fakeSprint();
  const ctx = { sprint, effects, options: {}, log: () => {} };
  const worker = {
    issue: { slug: "alpha", path: join(mainRoot, "no-such-issue.md") },
    branch,
    attempt: 1,
    worktree: wt.path,
    dispatch: { code: 0, timedOut: false, herdrFailed, herdrTabId: null },
    // The exact shape dispatchViaHerdr's "absent" case produces: code 0, empty text, so
    // parseWorkerReport falls through to missingReport — "no report.json — the worker
    // never wrote its result file".
    report: parseWorkerReport("", null),
  };

  const outcome = await runHousekeeping(ctx, worker);
  return { outcome, worktreePath: wt.path };
}

test("a herdr dispatch reported as failed (no confirmed process exit) keeps the worktree in place", async () => {
  const { outcome, worktreePath } = await runBlockedScenario({ herdrFailed: true });

  assert.equal(outcome.status, "blocked");
  assert.equal(existsSync(worktreePath), true, "worktree must survive — the process may still be running in it");
});

test("a dispatch confirmed dead (herdrFailed false/absent) still removes the worktree as before", async () => {
  const { outcome, worktreePath } = await runBlockedScenario({ herdrFailed: false });

  assert.equal(outcome.status, "blocked");
  assert.equal(existsSync(worktreePath), false, "no live-process risk here — the old cleanup behaviour is unchanged");
});
