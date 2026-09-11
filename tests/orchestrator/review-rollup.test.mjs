import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { main } from "../../orchestrator/review-rollup.mjs";

function runRollup(files) {
  const chunks = [];
  const real = process.stdout.write;
  process.stdout.write = (s) => chunks.push(s);
  try {
    main(files);
  } finally {
    process.stdout.write = real;
  }
  return JSON.parse(chunks.join(""));
}

test("review-rollup folds a later herdr-indented retry over an earlier not_run stub, across files", () => {
  const dir = mkdtempSync(join(tmpdir(), "review-rollup-"));
  const f1 = join(dir, "sprint-review-1.md");
  const f2 = join(dir, "sprint-review-2.md");
  writeFileSync(
    f1,
    [
      "## Branch: crew/calc/a (a)",
      "```json",
      JSON.stringify({ branch: "crew/calc/a", slug: "a", verdict: "not_run", detail: "reviewer dispatch timed out", findings: [] }),
      "```",
    ].join("\n"),
  );
  writeFileSync(
    f2,
    [
      "  Branch: crew/calc/a (a)",
      "  ```json",
      '  {"branch": "crew/calc/a", "slug": "a", "verdict": "all-met", "findings": [{"severity": "HIGH", "location": "x.ts:1", "criterion": "fix it"}]}',
      "  ```",
    ].join("\n"),
  );

  const out = runRollup([f1, f2]);
  assert.equal(out.branches.length, 1);
  assert.equal(out.branches[0].branch, "crew/calc/a");
  assert.equal(out.branches[0].verdict, "all-met");
  assert.equal(out.branches[0].findings.length, 1);
});

test("review-rollup skips files that do not exist and returns no branches for none", () => {
  const out = runRollup(["/no/such/file.md"]);
  assert.deepEqual(out.branches, []);
});

test("review-rollup keeps distinct branches from the same file separate", () => {
  const dir = mkdtempSync(join(tmpdir(), "review-rollup-"));
  const f = join(dir, "sprint-review-1.md");
  writeFileSync(
    f,
    [
      "```json", JSON.stringify({ branch: "crew/f/a", slug: "a", verdict: "all-met", findings: [] }), "```",
      "```json", JSON.stringify({ branch: "crew/f/b", slug: "b", verdict: "unmet", findings: [] }), "```",
    ].join("\n"),
  );
  const out = runRollup([f]);
  assert.deepEqual(out.branches.map((b) => b.branch), ["crew/f/a", "crew/f/b"]);
});
