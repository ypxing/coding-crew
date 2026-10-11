/**
 * contract.test.mjs — the report contracts in the agent definitions must be the ones
 * `report.mjs` parses. Each JSON example is lifted from its protocol and parsed; no test here
 * pins a protocol's wording.
 *
 * Both contracts were, until now, stated only in the prompts the orchestrator builds
 * (`lib/prompts.mjs`). That works — a live sprint confirmed it — but a contract that
 * exists only in a prompt is a contract the agent definition can silently contradict,
 * and the failure is not loud: a `checks` array where the parser wants an object reads
 * as three `not_run` categories, which demotes a clean branch to `partial` for "tests
 * not run". So the definition states it too, and this test is what keeps the two equal.
 *
 * Which coder definitions are held to it is read from orchestrator/platforms.json — the
 * single list of platforms whose reports this parser reads. That makes the next cutover fail here until that platform's contract is
 * migrated, which is the point: claude's variant still declares the prose
 * orchestrator's older shape (`checks` as an array of `{command, result}`).
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { parseWorkerReport, parseReviewReport, parseTriageReport } from "../../orchestrator/lib/report.mjs";
import { renderRolePrompt } from "../../orchestrator/lib/adapters/render.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = join(HERE, "../..");

function launcherPlatforms() {
  return Object.keys(JSON.parse(readFileSync(join(REPO, "orchestrator/platforms.json"), "utf8")));
}

/** The body of every ```json fence in `text`, in order. */
function jsonBlocks(text) {
  return [...text.matchAll(/```json\s*\n([\s\S]*?)\n```/g)].map((m) => m[1]);
}

function coderDefinition() {
  // No agent file: the protocol is the whole definition, rendered per dispatch.
  return readFileSync(join(REPO, "orchestrator/roles/coder.md"), "utf8");
}

test("the JSON a launcher coder is told to emit round-trips through the parser", () => {
  // Lifted from the definition itself rather than retyped, so a drifted example fails here
  // instead of at 2am in a sprint.
  const text = coderDefinition();
  const block = /```json\s*\n([\s\S]*?)\n```/.exec(text);
  assert.ok(block, "pi coder has no ```json block");
  const template = block[1]
    .replace(/complete\|partial\|blocked/g, "complete")
    .replace(/pass\|fail\|not_run\|deferred/g, "pass")
    .replace(/"<[^"]*>"/g, '"x"')
    .replace(/\$PROJECT_ROOT/g, "/wt/x")
    .replace(/<[^">]*>/g, "x");
  const parsedTemplate = JSON.parse(template);
  const report = parseWorkerReport(null, parsedTemplate);
  assert.equal(report.parsedFrom, "json");
  assert.equal(report.status, "complete");
  // "<category>" stands for each further dev-commands.json check the coder ran.
  assert.deepEqual(report.checks, { test: "pass", lint: "pass", typecheck: "pass", x: "pass" });
  assert.notEqual(report.branch, null);
  assert.notEqual(report.workingDirectory, null);
});

test("there is no markdown fallback — an un-migrated coder that never writes the sidecar is blocked, on purpose", () => {
  const r = parseWorkerReport(
    ["## Issue: alpha", "Status: complete", "", "### Checks", "npm test: pass", "npx tsc: pass"].join("\n"),
  );
  assert.equal(r.parsedFrom, "missing");
  assert.equal(r.status, "blocked");
});

test("the report object the reviewer protocol shows is the shape the parser reads", () => {
  // Lifted from the protocol rather than retyped, so a drifted shape fails here, not in a sprint.
  const [block] = jsonBlocks(readFileSync(join(REPO, "orchestrator/roles/reviewer.md"), "utf8"));
  assert.ok(block, "reviewer.md has no ```json block");
  const sidecar = JSON.parse(block.replace(/"<[^"]*>"/g, '"crew/f/x"'));
  const finding = { severity: "CRITICAL", location: "src/db.ts:7", issue: "unparameterised", criterion: "Parameterise the query" };
  const parsed = parseReviewReport("## Branch: crew/f/x (x)", { ...sidecar, findings: [finding] });
  assert.equal(parsed.verdict, "all-met");
  assert.deepEqual(parsed.findings, [{ ...finding, explicit: true }]);
});

test("every verdict example the triage protocol shows parses", () => {
  const examples = jsonBlocks(readFileSync(join(REPO, "orchestrator/roles/triage.md"), "utf8"))
    .filter((b) => /"fixable": "(yes|no)"/.test(b))
    .map((b) => JSON.parse(b));
  assert.ok(examples.length > 0, "triage.md shows no concrete verdict");
  for (const example of examples) {
    const parsed = parseTriageReport("", example);
    assert.equal(parsed.ok, true, JSON.stringify(example));
    assert.equal(parsed.fixable, example.fixable === "yes");
  }
});

test("every launcher platform has no agent file, and the triage protocol exists once", () => {
  for (const platform of launcherPlatforms()) {
    for (const file of [`${platform}.agent.md`, `${platform}.agent.toml`, `${platform}.md`]) {
      assert.ok(!existsSync(join(REPO, "agents/crew-triage", file)), `agents/crew-triage/${file} should not exist`);
    }
  }
  assert.ok(existsSync(join(REPO, "orchestrator/roles/triage.md")));
});

/** The `# ` heading a role file opens with: which file a rendered protocol included, not what it says. */
function heading(rel) {
  return readFileSync(join(REPO, rel), "utf8").match(/^# .+$/m)[0];
}

test("a per-branch review renders reviewer.md alone; a feature review renders the feature part as well", () => {
  const branch = renderRolePrompt("reviewer", "claude");
  const feature = renderRolePrompt("reviewer", "claude", { part: "feature" });
  const featureHeading = heading("orchestrator/roles/reviewer/feature.md");
  assert.ok(branch.includes(heading("orchestrator/roles/reviewer.md")));
  assert.ok(!branch.includes(featureHeading));
  assert.ok(feature.startsWith(branch.trimEnd()));
  assert.ok(feature.includes(featureHeading));
});
