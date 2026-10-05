import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { prdPath } from "../../orchestrator/lib/prd.mjs";

const PRD = "# PRD: demo\n\n## Decisions\n\n- **D1** — Retries are bounded.\n";

function root({ prd, saved, github = false } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "prd-path-"));
  mkdirSync(join(dir, ".scratch/demo"), { recursive: true });
  if (prd !== undefined) writeFileSync(join(dir, ".scratch/demo/PRD.md"), prd);
  if (saved !== undefined) writeFileSync(join(dir, ".scratch/demo/prd-issue.md"), saved);
  if (github) {
    mkdirSync(join(dir, ".coding-crew/docs"), { recursive: true });
    writeFileSync(join(dir, ".coding-crew/docs/issue-tracker.md"), "---\ntracker: github\n---\n");
  }
  return dir;
}
function ctxFor(mainRoot, exec = () => ({ code: 0, stdout: "" })) {
  const logs = [];
  return { logs, sprint: { featureSlug: "demo" }, effects: { mainRoot, exec }, log: (m, level) => logs.push([level, m]) };
}

test("a local PRD.md is the PRD, with no fetch even under github", () => {
  let calls = 0;
  const dir = root({ prd: PRD, saved: "stale", github: true });
  assert.equal(prdPath(ctxFor(dir, () => (calls++, { code: 0, stdout: "x" }))), join(dir, ".scratch/demo/PRD.md"));
  assert.equal(calls, 0);
});

test("no PRD anywhere: null, and no fetch outside github", () => {
  let calls = 0;
  assert.equal(prdPath(ctxFor(root(), () => (calls++, { code: 0, stdout: "" }))), null);
  assert.equal(calls, 0);
});

test("another tracker: a saved prd-issue.md is the PRD", () => {
  const dir = root({ saved: PRD });
  assert.equal(prdPath(ctxFor(dir)), join(dir, ".scratch/demo/prd-issue.md"));
});

test("github with no local PRD: fetched once per sprint, saved as prd-issue.md", () => {
  const dir = root({ github: true });
  let calls = 0;
  const ctx = ctxFor(dir, (cmd, args) => {
    calls++;
    assert.ok(args.includes("prd") && args.includes("--feature-slug"));
    return { code: 0, stdout: `<!-- PRD issue #1: x -->\n${PRD}` };
  });
  for (let i = 0; i < 3; i++) assert.equal(prdPath(ctx), join(dir, ".scratch/demo/prd-issue.md"));
  assert.equal(calls, 1);
  assert.match(readFileSync(join(dir, ".scratch/demo/prd-issue.md"), "utf8"), /PRD issue #1/);
});

test("github: a stale prd-issue.md from an earlier run is replaced by the fetched body", () => {
  const dir = root({ github: true, saved: "stale\n" });
  prdPath(ctxFor(dir, () => ({ code: 0, stdout: PRD })));
  assert.equal(readFileSync(join(dir, ".scratch/demo/prd-issue.md"), "utf8"), PRD);
});

test("github: a failed fetch warns once and falls back to the saved prd-issue.md, else null", () => {
  const dir = root({ github: true, saved: "saved\n" });
  const ctx = ctxFor(dir, () => ({ code: 1, stdout: "", stderr: "gh down" }));
  assert.equal(prdPath(ctx), join(dir, ".scratch/demo/prd-issue.md"));
  assert.equal(prdPath(ctx), join(dir, ".scratch/demo/prd-issue.md"));
  assert.equal(ctx.logs.filter(([lvl]) => lvl === "warn").length, 1);
  assert.equal(readFileSync(join(dir, ".scratch/demo/prd-issue.md"), "utf8"), "saved\n");
  assert.equal(prdPath(ctxFor(root({ github: true }), () => ({ code: 1, stdout: "" }))), null);
});

test("github: a milestone with no PRD issue (exit 3) is silent and null", () => {
  const ctx = ctxFor(root({ github: true }), () => ({ code: 3, stdout: "" }));
  assert.equal(prdPath(ctx), null);
  assert.deepEqual(ctx.logs, []);
});
