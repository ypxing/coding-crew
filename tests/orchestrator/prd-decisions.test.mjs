import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { decisionsFor, implementedIds, loadPrdDecisions, loadPrdSection, parsePrdDecisions } from "../../orchestrator/lib/prd-decisions.mjs";
import { reviewPrompt } from "../../orchestrator/lib/prompts.mjs";

const FIX = join(import.meta.dirname, "../fixtures/prd-decisions");
const PRD = readFileSync(join(FIX, "PRD.md"), "utf8");
const ISSUE = readFileSync(join(FIX, "148-issue.md"), "utf8");

function root({ prd, github = false } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "prd-dec-"));
  mkdirSync(join(dir, ".scratch/demo"), { recursive: true });
  if (prd !== undefined) writeFileSync(join(dir, ".scratch/demo/PRD.md"), prd);
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

test("the parser returns the PRD's D and B lines by ID, verbatim", () => {
  const d = parsePrdDecisions(PRD);
  assert.deepEqual([...d.keys()].filter((k) => k[0] === "B"), ["B1", "B2", "B3", "B4", "B5", "B6", "B7"]);
  assert.ok(d.has("D1") && d.has("D21"));
  assert.match(d.get("D7"), /^- \*\*D7\*\* — \*\*Draft rule\.\*\*/);
  assert.equal(d.get("B4"), PRD.split("\n").find((l) => l.startsWith("- **B4**")));
});

test("the issue's Implements IDs are read, a parenthetical is a note", () => {
  assert.deepEqual(implementedIds(ISSUE), ["D7", "D8", "B3"]);
  assert.deepEqual(implementedIds("## Implements\n\nD7, B7 (part of D11) — verified at x\n"), ["D7", "B7"]);
  assert.deepEqual(implementedIds("## What\n\nnothing"), []);
});

test("decisionsFor selects the named lines; an unmatched ID warns and is dropped", () => {
  const ctx = ctxFor(root({ prd: PRD }));
  const lines = decisionsFor(ctx, "## Implements\n\nD2, D99\n", "alpha");
  assert.equal(lines.length, 1);
  assert.match(lines[0], /^- \*\*D2\*\* — \*\*Adapters\.\*\*/);
  assert.equal(ctx.logs.filter(([lvl, m]) => lvl === "warn" && /D99/.test(m)).length, 1);
});

test("no Implements, or no PRD: no decisions, no fetch", () => {
  let calls = 0;
  const ctx = ctxFor(root(), () => (calls++, { code: 0, stdout: "" }));
  assert.deepEqual(decisionsFor(ctx, "## Implements\n\nD2\n"), []);
  assert.deepEqual(decisionsFor(ctxFor(root({ prd: PRD })), "no section"), []);
  assert.equal(calls, 0);
});

test("the review prompt carries the block with the line verbatim, and none without", () => {
  const base = { branch: "b", slug: "s", issuePath: "p", criteria: "", featureBranch: "f", reportPath: "/r" };
  const line = parsePrdDecisions(PRD).get("D2");
  const p = reviewPrompt({ ...base, prdDecisions: [line] });
  assert.ok(p.includes(`PRD decisions this issue implements:\n---\n${line}\n---`));
  assert.doesNotMatch(reviewPrompt({ ...base, prdDecisions: [] }), /PRD decisions/);
  assert.doesNotMatch(reviewPrompt(base), /PRD decisions/);
});

test("github with no local PRD: fetched once per sprint, saved as prd-issue.md", () => {
  const dir = root({ github: true });
  let calls = 0;
  const ctx = ctxFor(dir, (cmd, args) => {
    calls++;
    assert.ok(args.includes("prd") && args.includes("--feature-slug"));
    return { code: 0, stdout: `<!-- PRD issue #1: x -->\n${PRD}` };
  });
  for (let i = 0; i < 3; i++) assert.ok(decisionsFor(ctx, "## Implements\n\nD2\n").length === 1);
  assert.equal(calls, 1);
  assert.match(readFileSync(join(dir, ".scratch/demo/prd-issue.md"), "utf8"), /PRD issue #1/);
});

test("a failed fetch warns once and the reviews proceed without decisions", () => {
  let calls = 0;
  const ctx = ctxFor(root({ github: true }), () => (calls++, { code: 1, stdout: "", stderr: "gh down" }));
  assert.deepEqual(decisionsFor(ctx, "## Implements\n\nD2\n"), []);
  assert.deepEqual(decisionsFor(ctx, "## Implements\n\nD2\n"), []);
  assert.equal(calls, 1);
  assert.equal(ctx.logs.filter(([lvl]) => lvl === "warn").length, 1);
  assert.equal(loadPrdDecisions(ctx).size, 0);
});

test("a milestone with no PRD issue (exit 3) is silent", () => {
  const ctx = ctxFor(root({ github: true }), () => ({ code: 3, stdout: "" }));
  assert.deepEqual(decisionsFor(ctx, "## Implements\n\nD2\n"), []);
  assert.deepEqual(ctx.logs, []);
});

test("github: a stale prd-issue.md from an earlier run is replaced by the fetched body", () => {
  const dir = root({ github: true });
  writeFileSync(join(dir, ".scratch/demo/prd-issue.md"), "- **D2** — stale\n");
  let calls = 0;
  const ctx = ctxFor(dir, () => (calls++, { code: 0, stdout: PRD }));
  const lines = decisionsFor(ctx, "## Implements\n\nD2\n");
  assert.equal(calls, 1);
  assert.match(lines[0], /\*\*Adapters\.\*\*/);
  assert.equal(readFileSync(join(dir, ".scratch/demo/prd-issue.md"), "utf8"), PRD);
});

test("github: a failed fetch falls back to the saved prd-issue.md", () => {
  const dir = root({ github: true });
  writeFileSync(join(dir, ".scratch/demo/prd-issue.md"), "- **D2** — saved\n");
  const ctx = ctxFor(dir, () => ({ code: 1, stdout: "" }));
  assert.deepEqual(decisionsFor(ctx, "## Implements\n\nD2\n"), ["- **D2** — saved"]);
});

test("loadPrdSection returns the section body verbatim; null without the section or without a PRD", () => {
  const body = "Old runs keep working.\n\n### Migration\n\n- re-run `install.sh`";
  const dir = root({ prd: `# PRD\n\n## Decisions\n\n- **D1** — x.\n\n## Compatibility & Migration\n\n${body}\n\n## Out of scope\n\nnope\n` });
  assert.equal(loadPrdSection(ctxFor(dir), "Compatibility & Migration"), body);
  assert.equal(loadPrdSection(ctxFor(root({ prd: "# PRD\n\n## Decisions\n\n- **D1** — x.\n" })), "Compatibility & Migration"), null);
  assert.equal(loadPrdSection(ctxFor(root()), "Compatibility & Migration"), null);
});

test("loadPrdSection ignores a # comment line inside a fenced block and runs to the next real heading", () => {
  const body = "Run:\n\n```sh\n# re-run the installer\n./install.sh --update\n```\n\nDone.";
  const dir = root({ prd: `# PRD\n\n## Compatibility & Migration\n\n${body}\n\n## Out of scope\n\nnope\n` });
  assert.equal(loadPrdSection(ctxFor(dir), "Compatibility & Migration"), body);
});
