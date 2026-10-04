import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { carryFindings, parseReviewBlocks } from "../../orchestrator/lib/report.mjs";
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

test("review-rollup folds a later indented retry over an earlier not_run stub, across files", () => {
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

test("review-rollup keeps the feature review's findings under `feature`", () => {
  const dir = mkdtempSync(join(tmpdir(), "review-rollup-"));
  const f = join(dir, "sprint-review-1.md");
  const finding = { severity: "MEDIUM", location: "src/a.js:3", criterion: "Name the two retry loops alike" };
  writeFileSync(
    f,
    [
      "```json", JSON.stringify({ branch: "crew/f/a", slug: "a", verdict: "all-met", findings: [] }), "```",
      "## Branch: feature (feature)",
      "```json", JSON.stringify({ branch: "feature", slug: "feature", verdict: "all-met", findings: [finding] }), "```",
    ].join("\n"),
  );
  const out = runRollup([f]);
  assert.deepEqual(out.branches.map((b) => b.branch), ["crew/f/a", "feature"]);
  assert.deepEqual(out.branches[1].findings.map((f) => f.criterion), [finding.criterion]);
});

test("review-rollup: fixtures without any carried field parse, and #191's earlier LOW is carried once a later block is written with carryFindings", () => {
  const dir = join(dirname(fileURLToPath(import.meta.url)), "../fixtures/review-carry");
  const files = readdirSync(dir).sort().map((n) => join(dir, n));
  const before = runRollup(files);
  const b191 = before.branches.find((b) => b.branch.includes("/191-"));
  assert.equal(b191.verdict, "all-met");
  assert.ok(b191.findings.every((f) => f.carried === undefined), "the fold is later-block-wins");

  // What runReview writes for a new all-met review of 191 that raises nothing.
  const earlier = files.flatMap((f) => parseReviewBlocks(readFileSync(f, "utf8"))).filter((r) => r.branch === b191.branch);
  const findings = carryFindings(earlier, []).map(({ explicit, ...f }) => f);
  const next = mkdtempSync(join(tmpdir(), "review-rollup-"));
  const nextFile = join(next, "sprint-review-99.md");
  writeFileSync(nextFile, `\`\`\`json\n${JSON.stringify({ branch: b191.branch, slug: b191.slug, verdict: "all-met", findings })}\n\`\`\`\n`);
  const after = runRollup([...files, nextFile]).branches.find((b) => b.branch === b191.branch);
  const low = after.findings.find((f) => f.severity === "LOW" && f.location.startsWith("orchestrator/lib/pipeline/feature-areas.mjs"));
  assert.equal(low?.carried, true);
});

test("review-rollup: a later not_run block keeps the earlier block's findings, carried", () => {
  const dir = mkdtempSync(join(tmpdir(), "review-rollup-"));
  const blk = (o) => `\`\`\`json\n${JSON.stringify({ branch: "b", slug: "s", ...o })}\n\`\`\`\n`;
  const f1 = join(dir, "sprint-review-1.md");
  const f2 = join(dir, "sprint-review-2.md");
  writeFileSync(f1, blk({ verdict: "unmet", findings: [{ severity: "LOW", location: "a:1", issue: "x", criterion: "c" }] }));
  writeFileSync(f2, blk({ verdict: "not_run", findings: [] }));
  const [b] = runRollup([f1, f2]).branches;
  assert.equal(b.verdict, "not_run");
  assert.deepEqual(b.findings.map((f) => f.carried), [true]);
});

test("review-rollup folds a duplicate into its target: higher severity, both locations, shown once", () => {
  const dir = mkdtempSync(join(tmpdir(), "review-rollup-"));
  const f = join(dir, "sprint-review-1.md");
  const findings = [
    { severity: "MEDIUM", location: "a.ts:1", criterion: "fix x", verdict: "debatable" },
    { severity: "HIGH", location: "b.ts:2", criterion: "fix x too", verdict: "actionable", duplicate_of: 0 },
  ];
  writeFileSync(f, ["```json", JSON.stringify({ branch: "feature", slug: "feature", verdict: "all-met", findings }), "```"].join("\n"));
  const out = runRollup([f]).branches[0].findings;
  assert.equal(out.length, 1);
  assert.equal(out[0].severity, "HIGH");
  assert.match(out[0].location, /a\.ts:1/);
  assert.match(out[0].location, /b\.ts:2/);
});
