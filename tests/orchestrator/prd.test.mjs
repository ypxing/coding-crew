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

const DECIDED = "# One slice\n\nStatus: ready-for-agent\n\n## What to build\n\nx\n\n## Decisions\n\n- **D1** — Bounded.\n\n## Implements\n\nD1\n";
const PLAIN = "# Other\n\nStatus: ready-for-agent\n\n## What to build\n\ny\n";
function withIssues(dir, files) {
  for (const [rel, text] of Object.entries(files)) {
    mkdirSync(join(dir, ".scratch/demo/issues", rel.split("/")[0]), { recursive: true });
    writeFileSync(join(dir, ".scratch/demo/issues", rel), text);
  }
  return dir;
}

test("local, no PRD: the one issue with ## Decisions is the intent, in open/ or done/", () => {
  const open = withIssues(root(), { "open/01-a.md": DECIDED, "open/02-b.md": PLAIN });
  assert.equal(prdPath(ctxFor(open)), join(open, ".scratch/demo/issues/open/01-a.md"));
  const done = withIssues(root(), { "done/01-a.md": DECIDED, "open/02-b.md": PLAIN });
  assert.equal(prdPath(ctxFor(done)), join(done, ".scratch/demo/issues/done/01-a.md"));
});

test("local, no PRD: no issue with ## Decisions is null and silent", () => {
  const ctx = ctxFor(withIssues(root(), { "open/01-b.md": PLAIN }));
  assert.equal(prdPath(ctx), null);
  assert.deepEqual(ctx.logs, []);
});

test("local, no PRD: two issues with ## Decisions are null with one [WARN] naming them", () => {
  const ctx = ctxFor(withIssues(root(), { "open/01-a.md": DECIDED, "done/02-b.md": DECIDED }));
  assert.equal(prdPath(ctx), null);
  const warns = ctx.logs.filter(([lvl]) => lvl === "warn");
  assert.equal(warns.length, 1);
  assert.match(warns[0][1], /01-a\.md/);
  assert.match(warns[0][1], /02-b\.md/);
});

test("a local PRD.md still wins over an issue carrying ## Decisions", () => {
  const dir = withIssues(root({ prd: PRD }), { "open/01-a.md": DECIDED });
  assert.equal(prdPath(ctxFor(dir)), join(dir, ".scratch/demo/PRD.md"));
});

// A stub exec: `prd` exits 3 (no PRD issue); `known` writes the given files into --out.
function knownExec(files, knownCode = 0) {
  return (cmd, args) => {
    if (args.includes("prd")) return { code: 3, stdout: "" };
    if (knownCode) return { code: knownCode, stdout: "", stderr: "gh down" };
    const out = args[args.indexOf("--out") + 1];
    for (const [name, text] of Object.entries(files)) writeFileSync(join(out, name), text);
    return { code: 0, stdout: "" };
  };
}

test("github, no PRD issue: the one known issue with ## Decisions is saved as intent-issue.md", () => {
  const dir = root({ github: true });
  const p = prdPath(ctxFor(dir, knownExec({ "7-one-slice.md": DECIDED, "8-other.md": PLAIN })));
  assert.equal(p, join(dir, ".scratch/demo/intent-issue.md"));
  assert.equal(readFileSync(p, "utf8"), DECIDED);
});

test("github: a PRD issue wins over a known issue with ## Decisions", () => {
  const dir = root({ github: true });
  const exec = (cmd, args) => (args.includes("prd") ? { code: 0, stdout: PRD } : knownExec({ "7-a.md": DECIDED })(cmd, args));
  assert.equal(prdPath(ctxFor(dir, exec)), join(dir, ".scratch/demo/prd-issue.md"));
});

test("github: no known issue with ## Decisions is null; two are null with a [WARN]", () => {
  assert.equal(prdPath(ctxFor(root({ github: true }), knownExec({ "8-other.md": PLAIN }))), null);
  const ctx = ctxFor(root({ github: true }), knownExec({ "7-a.md": DECIDED, "9-b.md": DECIDED }));
  assert.equal(prdPath(ctx), null);
  assert.equal(ctx.logs.filter(([lvl]) => lvl === "warn").length, 1);
});

test("github: known failing returns a saved intent-issue.md, else null, with a [WARN] either way", () => {
  const dir = root({ github: true });
  writeFileSync(join(dir, ".scratch/demo/intent-issue.md"), DECIDED);
  const ctx = ctxFor(dir, knownExec({}, 1));
  assert.equal(prdPath(ctx), join(dir, ".scratch/demo/intent-issue.md"));
  assert.equal(ctx.logs.filter(([lvl]) => lvl === "warn").length, 1);
  const bare = ctxFor(root({ github: true }), knownExec({}, 1));
  assert.equal(prdPath(bare), null);
  assert.equal(bare.logs.filter(([lvl]) => lvl === "warn").length, 1);
});
