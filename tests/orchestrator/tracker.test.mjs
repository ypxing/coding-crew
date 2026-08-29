import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  appendToSection,
  blockers,
  branchFor,
  issueSlug,
  listOpenIssueFiles,
  parseIssue,
  sectionBody,
  selectDispatchable,
  spliceSection,
} from "../../orchestrator/lib/tracker.mjs";

function repo() {
  return mkdtempSync(join(tmpdir(), "crew-tracker-"));
}

function issue(root, feature, name, body, { dir = "open" } = {}) {
  const d = join(root, ".scratch", feature, "issues", dir);
  mkdirSync(d, { recursive: true });
  const p = join(d, name);
  writeFileSync(p, body);
  return p;
}

test("issueSlug strips leading digits and extension like receipts.sh", () => {
  assert.equal(issueSlug("/x/01-add-widget.md"), "add-widget");
  assert.equal(issueSlug("/x/12_add_widget.md"), "add_widget");
  assert.equal(issueSlug("/x/add-widget.md"), "add-widget");
  assert.equal(branchFor("feat", issueSlug("07-thing.md")), "crew/feat/thing");
});

test("parseIssue reads status, criteria, blockers and section presence", () => {
  const root = repo();
  const p = issue(
    root,
    "feat",
    "02-second.md",
    [
      "# Second thing",
      "",
      "Status: ready-for-agent",
      "",
      "## Blocked by",
      "",
      "- 01-first.md",
      "",
      "## Acceptance criteria",
      "",
      "- [ ] does the thing",
      "- [x] already done",
      "",
      "## Progress",
      "",
      "Round 1: started",
      "",
    ].join("\n"),
  );
  const i = parseIssue(p);
  assert.equal(i.status, "ready-for-agent");
  assert.equal(i.slug, "second");
  assert.equal(i.title, "Second thing");
  assert.deepEqual(i.blockedBy, ["01-first.md"]);
  assert.match(i.criteria, /does the thing/);
  assert.equal(i.hasProgress, true);
  assert.equal(i.hasBlocked, false);
  assert.equal(i.sourceGuarded, false);
});

test("parseIssue detects a Source: line (the promotion depth bound)", () => {
  const root = repo();
  const p = issue(root, "feat", "09-fix.md", "# Fix\n\nStatus: deferred-findings\nSource: crew/feat/thing review\n");
  assert.equal(parseIssue(p).sourceGuarded, true);
});

test("blockers only counts issues absent from done/", () => {
  const root = repo();
  const p = issue(
    root,
    "feat",
    "02-second.md",
    "# S\n\nStatus: ready-for-agent\n\n## Blocked by\n\n- 01-first.md\n- 00-zero.md\n",
  );
  issue(root, "feat", "01-first.md", "# F\n\nStatus: done\n", { dir: "done" });
  const i = parseIssue(p);
  assert.deepEqual(blockers(i), ["00-zero.md"]);
});

test("selectDispatchable keeps ready+unblocked and skips every other status", () => {
  const root = repo();
  issue(root, "feat", "01-ready.md", "# A\n\nStatus: ready-for-agent\n");
  issue(root, "feat", "02-parked.md", "# B\n\nStatus: deferred-findings\n");
  issue(root, "feat", "03-triage.md", "# C\n\nStatus: needs-triage\n");
  issue(
    root,
    "feat",
    "04-blocked.md",
    "# D\n\nStatus: ready-for-agent\n\n## Blocked by\n\n- 01-ready.md\n",
  );
  const picked = selectDispatchable(root).map((i) => i.slug);
  assert.deepEqual(picked, ["ready"]);
});

test("listOpenIssueFiles spans feature dirs and is sorted", () => {
  const root = repo();
  issue(root, "zeta", "01-z.md", "# Z\n\nStatus: ready-for-agent\n");
  issue(root, "alpha", "01-a.md", "# A\n\nStatus: ready-for-agent\n");
  const files = listOpenIssueFiles(root).map((f) => f.split("/").slice(-4, -3)[0]);
  assert.deepEqual(files, ["alpha", "zeta"]);
});

test("listOpenIssueFiles scopes to one feature dir when given a featureSlug", () => {
  const root = repo();
  issue(root, "zeta", "01-z.md", "# Z\n\nStatus: ready-for-agent\n");
  issue(root, "alpha", "01-a.md", "# A\n\nStatus: ready-for-agent\n");
  const files = listOpenIssueFiles(root, { featureSlug: "alpha" });
  assert.equal(files.length, 1);
  assert.match(files[0], /alpha\/issues\/open\/01-a\.md$/);
});

test("listOpenIssueFiles returns nothing for a featureSlug with no issues/open dir", () => {
  const root = repo();
  issue(root, "zeta", "01-z.md", "# Z\n\nStatus: ready-for-agent\n");
  assert.deepEqual(listOpenIssueFiles(root, { featureSlug: "missing" }), []);
});

test("selectDispatchable with featureSlug never dispatches another feature's ready issue", () => {
  // Regression: a sprint scoped to one feature must not pick up a ready-for-agent issue
  // that merely happens to live in a different .scratch/<feature>/ dir — that issue would
  // be dispatched, merged, and closed against the wrong feature branch.
  const root = repo();
  issue(root, "qa-slo-emission-test", "01-qa-slo-emission-test.md", "# QA SLO\n\nStatus: ready-for-agent\n");
  issue(root, "xkcd-comic", "01-component-with-mock.md", "# Component with mock\n\nStatus: ready-for-agent\n");
  const picked = selectDispatchable(root, { featureSlug: "qa-slo-emission-test" }).map((i) => i.slug);
  assert.deepEqual(picked, ["qa-slo-emission-test"]);
});

test("sectionBody stops at the next same-level heading but keeps subheadings", () => {
  const text = "# T\n\n## Progress\n\nline one\n\n### Detail\n\nkept\n\n## Notes\n\nother\n";
  assert.equal(sectionBody(text, "Progress"), "line one\n\n### Detail\n\nkept");
  assert.equal(sectionBody(text, "Missing"), null);
});

test("spliceSection replaces in place and never creates a second heading", () => {
  const text = "# T\n\nStatus: ready-for-agent\n\n## Progress\n\nold\n\n## Notes\n\nkeep\n";
  const next = spliceSection(text, "Progress", "new work remains");
  assert.equal((next.match(/^## Progress$/gm) || []).length, 1);
  assert.match(next, /new work remains/);
  assert.doesNotMatch(next, /old/);
  assert.match(next, /## Notes\n\nkeep/);
});

test("spliceSection appends when the section is absent", () => {
  const next = spliceSection("# T\n\nStatus: ready-for-agent\n", "Progress", "first note");
  assert.match(next, /## Progress\n\nfirst note/);
});

test("appendToSection adds a round line under an existing heading", () => {
  const text = "# T\n\n## Blocked\n\nRound 1: stuck on auth\n";
  const next = appendToSection(text, "Blocked", "Round 2: still stuck");
  assert.equal((next.match(/^## Blocked$/gm) || []).length, 1);
  assert.match(next, /Round 1: stuck on auth\nRound 2: still stuck/);
});
