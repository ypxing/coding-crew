import { test } from "node:test";
import assert from "node:assert/strict";
import { chmodSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { renderReviewContext, sprintReviewContext } from "../../orchestrator/lib/review-context.mjs";
import { reviewPrompt } from "../../orchestrator/lib/prompts.mjs";

function assets({ script } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "rc-"));
  mkdirSync(join(dir, "references"));
  mkdirSync(join(dir, "scripts"));
  writeFileSync(join(dir, "references/quality.md"), "QUALITY-CHECKLIST\n");
  writeFileSync(join(dir, "references/react.md"), "REACT-CHECKLIST\n");
  if (script !== undefined) {
    writeFileSync(join(dir, "scripts/review-context.sh"), script);
    chmodSync(join(dir, "scripts/review-context.sh"), 0o755);
  }
  return dir;
}

/** An effects double that really runs nothing: counts calls and returns a canned result. */
function fakeEffects(result) {
  const calls = [];
  return { calls, exec: (cmd, args) => (calls.push([cmd, ...args]), result) };
}

const base = { branch: "b", slug: "s", issuePath: "p", criteria: "", featureBranch: "f", reportPath: "/r" };

test("the prompt carries the STACK line and the full text of each named checklist", () => {
  const dir = assets({ script: "" });
  const out = `STACK: react\nREFERENCE: ${dir}/references/quality.md\nREFERENCE: ${dir}/references/react.md\n`;
  const ctx = sprintReviewContext({}, fakeEffects({ code: 0, stdout: out }), dir, "/root");
  const p = reviewPrompt({ ...base, reviewContext: ctx });
  assert.match(p, /^STACK: react$/m);
  assert.match(p, /QUALITY-CHECKLIST/);
  assert.match(p, /REACT-CHECKLIST/);
  assert.doesNotMatch(p, /every checklist in/);
});

test("review-context.sh runs once for N reviews of a sprint", () => {
  const dir = assets({ script: "" });
  const eff = fakeEffects({ code: 0, stdout: `STACK: generic\nREFERENCE: ${dir}/references/quality.md\n` });
  const sprint = {};
  for (let i = 0; i < 4; i++) sprintReviewContext(sprint, eff, dir, "/root");
  assert.equal(eff.calls.length, 1);
});

test("a failing script falls back to every reference and the prompt says so", () => {
  const dir = assets({ script: "" });
  const ctx = sprintReviewContext({}, fakeEffects({ code: 3, stdout: "" }), dir, "/root");
  const p = reviewPrompt({ ...base, reviewContext: ctx });
  assert.match(p, /review-context\.sh failed \(exit 3\); every checklist in .*references is included instead/);
  assert.match(p, /QUALITY-CHECKLIST/);
  assert.match(p, /REACT-CHECKLIST/);
});

test("a missing script falls back without running anything", () => {
  const dir = assets();
  const eff = fakeEffects({ code: 0, stdout: "" });
  const ctx = sprintReviewContext({}, eff, dir, "/root");
  assert.equal(eff.calls.length, 0);
  assert.match(renderReviewContext(ctx).join("\n"), /review-context\.sh is missing/);
  assert.equal(ctx.files.length, 2);
});

test("both review schemas carry each finding's `issue`, where reviewer.md puts the design-standard marker", async () => {
  const { featureReviewPrompt } = await import("../../orchestrator/lib/prompts.mjs");
  const fr = featureReviewPrompt({ featureBranch: "f", base: "b", reportPath: "/r" });
  for (const p of [reviewPrompt(base), fr]) {
    const json = JSON.parse(p.match(/```json\n([\s\S]*?)\n```/)[1]);
    assert.deepEqual(Object.keys(json.findings[0]), ["severity", "location", "issue", "criterion"]);
    assert.match(json.findings[0].issue, /Design standard \(criterion <n>\):/);
  }
});
