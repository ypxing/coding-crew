import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { checksLine, extractBody, extractTitle, prdTitle } from "../../orchestrator/lib/pipeline/pr-body.mjs";
import { prBodyPrompt } from "../../orchestrator/lib/prompts.mjs";

test("extractBody: keeps the answer from its first ## Summary line, dropping a preamble", () => {
  assert.equal(extractBody("Here is the body.\n\n## Summary\n\nX\n\n## Evidence\n\nY\n\n"), "## Summary\n\nX\n\n## Evidence\n\nY\n");
});

test("extractBody: an answer with no ## Summary has no body", () => {
  assert.equal(extractBody("I could not read the diff."), null);
  assert.equal(extractBody("### Summary\n\nX"), null);
  assert.equal(extractBody(undefined), null);
});

test("prdTitle: the PRD's first # heading, without a PRD: prefix", () => {
  const dir = mkdtempSync(join(tmpdir(), "pr-body-"));
  try {
    writeFileSync(join(dir, "a.md"), "# PRD: Single full check\n\n## Problem\n");
    writeFileSync(join(dir, "b.md"), "Intro\n\n# Faster verify\n");
    writeFileSync(join(dir, "c.md"), "## Only subheadings\n");
    assert.equal(prdTitle(join(dir, "a.md")), "Single full check");
    assert.equal(prdTitle(join(dir, "b.md")), "Faster verify");
    assert.equal(prdTitle(join(dir, "c.md")), null);
    assert.equal(prdTitle(null), null);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("prBodyPrompt: points at write-pr's SKILL.md and the range, and asks for the body as the final message only", () => {
  const p = prBodyPrompt({
    skillFile: "/i/write-pr/SKILL.md",
    featureBranch: "feature/demo",
    base: "abc123",
    prd: "/r/.scratch/demo/PRD.md",
    reviewReport: "/r/review.md",
    checks: "test pass, lint pass",
  });
  assert.match(p, /Read \/i\/write-pr\/SKILL\.md first and follow it/);
  assert.match(p, /^Range: abc123\.\.feature\/demo$/m);
  assert.match(p, /^PRD \(the feature's intent\): \/r\/\.scratch\/demo\/PRD\.md$/m);
  assert.match(p, /\/r\/review\.md/);
  assert.match(p, /^Checks on the merged branch: test pass, lint pass$/m);
  assert.match(p, /final message/);
  assert.match(p, /Do not write files, commit, push or call `gh`/);
});

test("prBodyPrompt: no PRD, no report, no checks — says not run and names neither", () => {
  const p = prBodyPrompt({ skillFile: "/s", featureBranch: "f", base: "b", prd: null, reviewReport: null, checks: null });
  assert.doesNotMatch(p, /PRD/);
  assert.doesNotMatch(p, /Review report/);
  assert.match(p, /^Checks on the merged branch: not run$/m);
});

test("extractTitle: the last # line before ## Summary; none without one", () => {
  assert.equal(extractTitle("Sure.\n\n# Run the full suite once per branch\n\n## Summary\n\nX\n# not this"), "Run the full suite once per branch");
  assert.equal(extractTitle("## Summary\n\nX"), null);
  assert.equal(extractTitle("# A title\n\nno summary"), null);
});

test("checksLine: a cached integration result reads as a pass, not `not run`", () => {
  assert.equal(checksLine({ dispatchDir: "/nonexistent" }, { status: "cached", failed: [] }), "pass (cached)");
  assert.equal(checksLine({ dispatchDir: "/nonexistent" }, null), null);
});
