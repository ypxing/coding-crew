/**
 * contract.test.mjs — the report contracts in the agent definitions must be the ones
 * `report.mjs` parses.
 *
 * Both contracts were, until now, stated only in the prompts the orchestrator builds
 * (`lib/prompts.mjs`). That works — a live sprint confirmed it — but a contract that
 * exists only in a prompt is a contract the agent definition can silently contradict,
 * and the failure is not loud: a `checks` array where the parser wants an object reads
 * as three `not_run` categories, which demotes a clean branch to `partial` for "tests
 * not run". So the definition states it too, and this test is what keeps the two equal.
 *
 * Which coder definitions are held to it is read from `AFK_LAUNCHER_VARIANTS` in
 * tests/helpers/render.bash — the single list of platforms whose reports this parser
 * reads. That makes the next cutover fail here until that platform's contract is
 * migrated, which is the point: claude's variant still declares the prose
 * orchestrator's older shape (`checks` as an array of `{command, result}`).
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { CHECK_CATEGORIES, parseWorkerReport, parseReviewReport } from "../../orchestrator/lib/report.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = join(HERE, "../..");

/** The fields `fromStructured()` in report.mjs actually reads out of a worker report. */
const WORKER_FIELDS = ["status", "branch", "working_directory", "checks", "criteria", "progress", "notes"];

function launcherPlatforms() {
  const helper = readFileSync(join(REPO, "tests/helpers/render.bash"), "utf8");
  const m = /AFK_LAUNCHER_VARIANTS=\(([^)]*)\)/.exec(helper);
  assert.ok(m, "AFK_LAUNCHER_VARIANTS not found in tests/helpers/render.bash");
  return m[1].split(/\s+/).filter(Boolean);
}

function coderDefinition(platform) {
  const file = platform === "codex" ? "codex.agent.toml" : `${platform}.agent.md`;
  return readFileSync(join(REPO, "agents/crew-coder", file), "utf8");
}

test("every launcher platform's coder declares the parser's exact field list", () => {
  for (const platform of launcherPlatforms()) {
    const text = coderDefinition(platform);
    for (const field of WORKER_FIELDS) {
      assert.match(text, new RegExp(`"${field}"`), `${platform} coder never names "${field}"`);
    }
    for (const category of CHECK_CATEGORIES) {
      assert.match(text, new RegExp(`"${category}"`), `${platform} coder omits check category "${category}"`);
    }
    // The sidecar path is not half the contract but the primary one: a final message that
    // ends with a summary sentence parses as nothing, which cost a real claude sprint its
    // first round. The definition must ask for the file, as the last action.
    assert.match(text, /report\.json/, `${platform} coder never names the sidecar`);
    assert.match(text, /as your last action/, `${platform} coder does not ask for the sidecar write`);
    // And the shape must be the object the parser indexes, not the older array of
    // {command, result} pairs the prose orchestrators read.
    assert.doesNotMatch(
      text,
      /"checks"\s*:\s*\[/,
      `${platform} coder declares checks as an array — report.mjs indexes checks.test/lint/typecheck`,
    );
  }
});

test("the JSON a launcher coder is told to emit round-trips through the parser", () => {
  // Lifted from the definition itself rather than retyped, so a drifted example fails here
  // instead of at 2am in a sprint.
  const text = coderDefinition("pi");
  const block = /```json\s*\n([\s\S]*?)\n```/.exec(text);
  assert.ok(block, "pi coder has no ```json block");
  const template = block[1]
    .replace(/complete\|partial\|blocked/g, "complete")
    .replace(/pass\|fail\|not_run/g, "pass")
    .replace(/"<[^"]*>"/g, '"x"')
    .replace(/\$PROJECT_ROOT/g, "/wt/x")
    .replace(/<[^">]*>/g, "x");
  const parsedTemplate = JSON.parse(template);
  const report = parseWorkerReport(null, parsedTemplate);
  assert.equal(report.parsedFrom, "json");
  assert.equal(report.status, "complete");
  assert.deepEqual(report.checks, { test: "pass", lint: "pass", typecheck: "pass" });
  assert.notEqual(report.branch, null);
  assert.notEqual(report.workingDirectory, null);
});

test("the markdown fallback still works, so an un-migrated coder is not stranded", () => {
  const r = parseWorkerReport(
    ["## Issue: alpha", "Status: complete", "", "### Checks", "npm test: pass", "npx tsc: pass"].join("\n"),
  );
  assert.equal(r.parsedFrom, "markdown");
  assert.equal(r.status, "complete");
  assert.equal(r.checks.test, "pass");
});

test("the reviewer protocol states the FINDING line the parser promotes from", () => {
  const protocol = readFileSync(join(REPO, "agents/crew-code-reviewer/protocol.md"), "utf8");
  assert.match(protocol, /FINDING:\s*CRITICAL\s*\|\s*<path>:<line>\s*\|/);
  assert.match(protocol, /verifiable fix criterion/);
  // The verdict line it is printed beneath is the other half of the same contract.
  assert.match(protocol, /^AC: all-met/m);

  // And the shape the protocol shows is the shape the parser reads.
  const parsed = parseReviewReport(
    ["## Branch: crew/f/x (x)", "AC: all-met", "", "### Findings", "FINDING: CRITICAL | src/db.ts:7 | Parameterise the query", ""].join("\n"),
  );
  assert.equal(parsed.verdict, "all-met");
  assert.deepEqual(parsed.findings, [
    { severity: "CRITICAL", location: "src/db.ts:7", criterion: "Parameterise the query", explicit: true },
  ]);
});
