/**
 * sprint-herdr-reuse.test.mjs — the in-memory bookkeeping that bounds a herdr coder's pane
 * reuse to exactly one retry per issue (see pipeline.mjs's handleVerificationFailure/
 * runWorker). Pure Sprint-instance state, no sprint.env or state.sh involved — sprint.test.mjs
 * covers the full state-machine integration; this covers just these three methods in
 * isolation.
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { Sprint } from "../../orchestrator/lib/sprint.mjs";

function sprint() {
  return new Sprint({}, {});
}

test("herdrReuseState is 'none' for a slug that was never queued", () => {
  assert.equal(sprint().herdrReuseState("alpha"), "none");
});

test("markHerdrReusePending queues exactly one reuse, consumed once by consumeHerdrReusePending", () => {
  const s = sprint();
  s.markHerdrReusePending("alpha", { tabId: "w1:t1", paneId: "w1:p1" });
  assert.equal(s.herdrReuseState("alpha"), "pending");

  const consumed = s.consumeHerdrReusePending("alpha");
  assert.deepEqual(consumed, { tabId: "w1:t1", paneId: "w1:p1" });
  assert.equal(s.herdrReuseState("alpha"), "used", "spending the one reuse leaves the slug permanently 'used'");
});

test("consumeHerdrReusePending returns null and changes nothing for a slug with nothing queued", () => {
  const s = sprint();
  assert.equal(s.consumeHerdrReusePending("alpha"), null);
  assert.equal(s.herdrReuseState("alpha"), "none");
});

test("consumeHerdrReusePending never hands back the same reuse twice — a second call after 'used' is null", () => {
  const s = sprint();
  s.markHerdrReusePending("alpha", { tabId: "w1:t1", paneId: "w1:p1" });
  s.consumeHerdrReusePending("alpha");
  assert.equal(s.consumeHerdrReusePending("alpha"), null, "the one retry is already spent");
});

test("herdr-reuse bookkeeping is per-slug — one issue's queued reuse never leaks into another's", () => {
  const s = sprint();
  s.markHerdrReusePending("alpha", { tabId: "w1:t1", paneId: "w1:p1" });
  assert.equal(s.herdrReuseState("beta"), "none");
  assert.equal(s.consumeHerdrReusePending("beta"), null);
  assert.equal(s.herdrReuseState("alpha"), "pending", "alpha's own queued reuse is untouched by querying beta");
});

test("pendingHerdrReuses lists every slug still queued, worktree included, for the end-of-run sweep", () => {
  const s = sprint();
  s.markHerdrReusePending("alpha", { tabId: "w1:t1", paneId: "w1:p1", worktree: "/scratch/worktrees/alpha" });
  s.markHerdrReusePending("beta", { tabId: "w1:t2", paneId: "w1:p2", worktree: "/scratch/worktrees/beta" });
  assert.deepEqual(s.pendingHerdrReuses(), [
    { slug: "alpha", tabId: "w1:t1", paneId: "w1:p1", worktree: "/scratch/worktrees/alpha" },
    { slug: "beta", tabId: "w1:t2", paneId: "w1:p2", worktree: "/scratch/worktrees/beta" },
  ]);
});

test("pendingHerdrReuses omits a slug once its one reuse is consumed", () => {
  const s = sprint();
  s.markHerdrReusePending("alpha", { tabId: "w1:t1", paneId: "w1:p1", worktree: "/scratch/worktrees/alpha" });
  s.consumeHerdrReusePending("alpha");
  assert.deepEqual(s.pendingHerdrReuses(), []);
});

test("pendingHerdrReuses is empty when nothing was ever queued", () => {
  assert.deepEqual(sprint().pendingHerdrReuses(), []);
});
