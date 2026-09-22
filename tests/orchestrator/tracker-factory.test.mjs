import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { getTracker } from "../../orchestrator/lib/tracker.mjs";
import * as local from "../../orchestrator/lib/trackers/local.mjs";
import * as github from "../../orchestrator/lib/trackers/github.mjs";

function writeTrackerConfig(root, contents) {
  const dir = join(root, ".coding-crew", "docs");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "issue-tracker.md"), contents);
}

test("getTracker resolves to the github backend module under `tracker: github` (issue 04 adds github.mjs)", async () => {
  const root = mkdtempSync(join(tmpdir(), "crew-tracker-factory-"));
  writeTrackerConfig(root, "---\ntracker: github\n---\n");
  const tracker = await getTracker(root);
  assert.equal(tracker, github);
  assert.equal(typeof tracker.selectDispatchable, "function");
});

test("getTracker resolves to the local backend under `tracker: local` (the default) without throwing", async () => {
  const mainRoot = mkdtempSync(join(tmpdir(), "crew-tracker-factory-"));
  // No .coding-crew/docs/issue-tracker.md at all — readTrackerConfig's zero-config default.
  const tracker = await getTracker(mainRoot);
  assert.equal(tracker, local);
  assert.equal(typeof tracker.selectDispatchable, "function");
});

test("getTracker never attempts to import github.mjs when the config says local", async () => {
  const mainRoot = mkdtempSync(join(tmpdir(), "crew-tracker-factory-"));
  // Would throw (module not found) if getTracker's dynamic import ran unconditionally
  // instead of only inside the `tracker: github` branch.
  await assert.doesNotReject(() => getTracker(mainRoot));
});
