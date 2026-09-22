import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { readTrackerConfig } from "../../orchestrator/lib/tracker-config.mjs";

function repo() {
  return mkdtempSync(join(tmpdir(), "crew-tracker-config-"));
}

function writeDoc(root, contents) {
  const dir = join(root, ".coding-crew", "docs");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "issue-tracker.md"), contents);
}

test("readTrackerConfig defaults to local with no repo when the doc is absent entirely", () => {
  const root = repo();
  assert.deepEqual(readTrackerConfig(root), { tracker: "local", repo: null });
});

test("readTrackerConfig defaults to local when the doc exists with no front matter", () => {
  const root = repo();
  writeDoc(root, "# Issue tracker: Local Markdown\n\nIssues live in `.scratch/`.\n");
  assert.deepEqual(readTrackerConfig(root), { tracker: "local", repo: null });
});

test("readTrackerConfig reads tracker: local from front matter", () => {
  const root = repo();
  writeDoc(root, "---\ntracker: local\n---\n\n# Issue tracker\n");
  assert.deepEqual(readTrackerConfig(root), { tracker: "local", repo: null });
});

test("readTrackerConfig reads tracker: github with a repo override", () => {
  const root = repo();
  writeDoc(root, "---\ntracker: github\nrepo: owner/name\n---\n\n# Issue tracker\n");
  assert.deepEqual(readTrackerConfig(root), { tracker: "github", repo: "owner/name" });
});

test("readTrackerConfig reads tracker: github with no repo line as repo: null", () => {
  const root = repo();
  writeDoc(root, "---\ntracker: github\n---\n\n# Issue tracker\n");
  assert.deepEqual(readTrackerConfig(root), { tracker: "github", repo: null });
});
