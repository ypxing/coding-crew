import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

import { getTracker } from "../../orchestrator/lib/tracker.mjs";
import * as local from "../../orchestrator/lib/trackers/local.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const GITHUB_BACKEND_PATH = join(HERE, "..", "..", "orchestrator", "lib", "trackers", "github.mjs");

test("github.mjs does not exist on disk yet (issue 04+ adds it)", () => {
  // Load-bearing precondition for the next test: it only proves anything about the
  // dynamic-import requirement if there is really nothing to statically import here.
  assert.equal(existsSync(GITHUB_BACKEND_PATH), false);
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
