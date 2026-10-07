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
} from "../../tracker/body-format.mjs";

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

test("isSourceGuarded counts Source: only at column 0 outside a code fence", () => {
  const cases = [
    ["# t\n\nSource: r (b)\n", true],
    ["# t\n\n```\nSource: r (b)\n```\n", false],
    ["# t\n\n~~~\nSource: r (b)\n~~~\n", false],
    ["# t\n\n```\nx\n```\n\nSource: r (b)\n", true],
    ["# t\n\n  Source: r (b)\n", false],
    ["# t\n\n**Source:** r (b)\n", false],
    ["no source line here\n", false],
    ["Source: integration check (integration-check)\n\n## Context\n", true],
  ];
  for (const [body, want] of cases) assert.equal(isSourceGuarded(body), want, JSON.stringify(body));
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

test("sectionBody closes a fence on an indented closing fence line", () => {
  const body = "## What to build\n\n1. x:\n   ```sh\n   y\n   ```\n\n## Blocked by\n\n- #12\n";
  assert.equal(sectionBody(body, "Blocked by"), "- #12");
});

test("a shorter or different-mark fence line does not close a fence", () => {
  const body = "## A\n\n````\n```\n~~~\n# not heading\n````\n\n## B\nb\n";
  assert.equal(sectionBody(body, "A"), "````\n```\n~~~\n# not heading\n````");
});

test("appendToSection does not end the section at a heading inside a fence", () => {
  const out = appendToSection("## Progress\n\n```sh\n# step\nrun\n```\n- a\n\n## Next\nn\n", "Progress", "- b");
  assert.equal(out.split("# step").length - 1, 1);
  assert.ok(out.endsWith("## Next\nn\n"));
  assert.ok(out.includes("- a\n- b"));
});
