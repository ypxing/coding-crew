import { test } from "node:test";
import assert from "node:assert/strict";

import {
  sectionBody,
  spliceSection,
  uncheckedCriteria,
} from "../../lib/tracker/body-format.mjs";

// These are the backend-agnostic markdown-body helpers, extracted verbatim out of the
// pre-split tracker.mjs — see tests/tracker/tracker.test.mjs for the equivalent
// section-parsing coverage exercised through the local backend/factory. This file only
// adds coverage for the pieces that are new to this module: uncheckedCriteria and fences.

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

test("sectionBody closes a fence on an indented closing fence line", () => {
  const body = "## What to build\n\n1. x:\n   ```sh\n   y\n   ```\n\n## Blocked by\n\n- #12\n";
  assert.equal(sectionBody(body, "Blocked by"), "- #12");
});

test("a shorter or different-mark fence line does not close a fence", () => {
  const body = "## A\n\n````\n```\n~~~\n# not heading\n````\n\n## B\nb\n";
  assert.equal(sectionBody(body, "A"), "````\n```\n~~~\n# not heading\n````");
});

test("spliceSection does not end the section at a heading inside a fence", () => {
  const out = spliceSection("## Progress\n\n```sh\n# step\nrun\n```\n- a\n\n## Next\nn\n", "Progress", "- b");
  assert.equal(out, "## Progress\n\n- b\n\n## Next\nn\n");
});
