import { test } from "node:test";
import assert from "node:assert/strict";

import {
  appendToSection,
  criteriaSection,
  extractBlockedByNumbers,
  isSourceGuarded,
  sectionBody,
  spliceSection,
  uncheckedCriteria,
} from "../../orchestrator/lib/trackers/body-format.mjs";

// These are the backend-agnostic markdown-body helpers, extracted verbatim out of the
// pre-split tracker.mjs — see tests/orchestrator/tracker.test.mjs for the equivalent
// section-parsing coverage exercised through the local backend/factory. This file only
// adds coverage for the pieces that are new to this module: criteriaSection's dual-case
// lookup, isSourceGuarded, and extractBlockedByNumbers.

test("sectionBody stops at the next same-level heading but keeps subheadings", () => {
  const text = "# T\n\n## Progress\n\nline one\n\n### Detail\n\nkept\n\n## Notes\n\nother\n";
  assert.equal(sectionBody(text, "Progress"), "line one\n\n### Detail\n\nkept");
  assert.equal(sectionBody(text, "Missing"), null);
});

test("spliceSection replaces in place and never creates a second heading", () => {
  const text = "# T\n\n## Progress\n\nold\n\n## Notes\n\nkeep\n";
  const next = spliceSection(text, "Progress", "new work remains");
  assert.equal((next.match(/^## Progress$/gm) || []).length, 1);
  assert.match(next, /new work remains/);
});

test("appendToSection adds a round line under an existing heading", () => {
  const text = "# T\n\n## Blocked\n\nRound 1: stuck on auth\n";
  const next = appendToSection(text, "Blocked", "Round 2: still stuck");
  assert.match(next, /Round 1: stuck on auth\nRound 2: still stuck/);
});

test("criteriaSection finds either heading case", () => {
  assert.equal(criteriaSection("## Acceptance criteria\n\n- [ ] a\n"), "- [ ] a");
  assert.equal(criteriaSection("## Acceptance Criteria\n\n- [ ] b\n"), "- [ ] b");
  assert.equal(criteriaSection("no such section\n"), "");
});

test("isSourceGuarded detects a Source: line regardless of bold markup", () => {
  assert.equal(isSourceGuarded("Source: crew/feat/thing review\n"), true);
  assert.equal(isSourceGuarded("**Source:** crew/feat/thing review\n"), true);
  assert.equal(isSourceGuarded("no source line here\n"), false);
});

test("uncheckedCriteria scans both the Acceptance criteria and Cross-cutting Requirements headings", () => {
  const text = [
    "## Acceptance criteria",
    "",
    "- [x] done one",
    "- [ ] still open",
    "",
    "## Cross-cutting Requirements",
    "",
    "- [ ] also open",
    "",
    "## Notes",
    "",
    "- [ ] not scoped, ignored",
  ].join("\n");
  assert.deepEqual(uncheckedCriteria(text), ["- [ ] still open", "- [ ] also open"]);
  assert.deepEqual(uncheckedCriteria("## Acceptance criteria\n\n- [x] all done\n"), []);
});

test("extractBlockedByNumbers matches 'Issue NN' references, with or without a #, zero-padded or not", () => {
  // Leading zeros are consumed by the match, not part of the captured group — callers
  // that need a zero-padded filename match back (local.mjs's resolveBlockedBy) re-add
  // `0*` flexibility themselves rather than expecting it preserved here.
  assert.deepEqual(extractBlockedByNumbers("- Issue 01\n- Issue #7\n- issue-03\n"), ["1", "7", "3"]);
  assert.deepEqual(extractBlockedByNumbers("- 01-first.md\n"), []);
});
