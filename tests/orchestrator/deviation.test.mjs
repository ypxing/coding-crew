import test from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fullSuiteRuns, flagFullSuiteRuns } from "../../orchestrator/lib/pipeline/deviation.mjs";

const bash = (command) => JSON.stringify({ type: "assistant", message: { content: [{ type: "tool_use", name: "Bash", input: { command } }] } });

function events(...cmds) {
  const dir = mkdtempSync(join(tmpdir(), "dev-"));
  const f = join(dir, "report.md.events.jsonl");
  writeFileSync(f, cmds.map(bash).join("\n") + "\n");
  return { dir, outFile: join(dir, "report.md"), f };
}

test("a full test command in the trace is found; targeted runs are not", () => {
  const { f } = events("bats tests/*.bats", "bats tests/one.bats", "bash x/run-checks.sh --targeted -- bats tests/*.bats");
  assert.deepEqual(fullSuiteRuns(f, "bats tests/*.bats"), ["bats tests/*.bats"]);
});

test("the cached command with explicit test-file arguments is a targeted run, not the suite", () => {
  const { f } = events("pytest tests/test_x.py", "npm test -- a.test.js", "pytest -q", "npm test 2>&1 | tail -5", "npm test -- --watch=false");
  assert.deepEqual(fullSuiteRuns(f, "pytest"), ["pytest -q"]);
  assert.deepEqual(fullSuiteRuns(f, "npm test"), ["npm test 2>&1 | tail -5", "npm test -- --watch=false"]);
});

test("a redirection target or a flag's value is not a test-file argument", () => {
  const { f } = events("npm test > /tmp/out.log 2>&1", "npm test -- --maxWorkers 2", "npm test 2> err.txt", "npm test -- a.test.js > /tmp/t.log");
  assert.deepEqual(fullSuiteRuns(f, "npm test"), ["npm test > /tmp/out.log 2>&1", "npm test -- --maxWorkers 2", "npm test 2> err.txt"]);
  const p = events("pytest >out.txt", "pytest -n 4", "pytest -n 4 tests/test_x.py").f;
  assert.deepEqual(fullSuiteRuns(p, "pytest"), ["pytest >out.txt", "pytest -n 4"]);
});

test("the cached command's leading env assignments are not part of what is matched", () => {
  const { f } = events("bats tests/*.bats", "ORCHESTRATOR_PREFETCH=1 bats tests/*.bats", "bats tests/one.bats");
  assert.deepEqual(fullSuiteRuns(f, "ORCHESTRATOR_PREFETCH=1 bats tests/*.bats"), ["bats tests/*.bats", "ORCHESTRATOR_PREFETCH=1 bats tests/*.bats"]);
});

test("a longer target or program that merely starts with the test command is not it", () => {
  const { f } = events("make test-unit", "make tests", "xmake test", "make test");
  assert.deepEqual(fullSuiteRuns(f, "make test"), ["make test"]);
});

test("one tool call reported at its start and its end counts once", () => {
  const dir = mkdtempSync(join(tmpdir(), "dev-"));
  const f = join(dir, "report.md.events.jsonl");
  const item = (type) => JSON.stringify({ type, item: { id: "item_7", type: "command_execution", command: "npm test" } });
  writeFileSync(f, [item("item.started"), item("item.completed"), JSON.stringify({ type: "item.started", item: { id: "item_9", type: "command_execution", command: "npm test" } })].join("\n") + "\n");
  assert.deepEqual(fullSuiteRuns(f, "npm test"), ["npm test", "npm test"]);
});

test("no test command or no events file means no deviation", () => {
  assert.deepEqual(fullSuiteRuns("/nonexistent", "bats"), []);
  assert.deepEqual(fullSuiteRuns(events("bats x").f, null), []);
});

test("flagFullSuiteRuns logs [DEVIATION], records it, and does not throw", () => {
  const { dir, outFile } = events("npm test", "npm test");
  const main = mkdtempSync(join(tmpdir(), "main-"));
  writeFileSync(join(main, "x"), "");
  const logs = [], recorded = [];
  mkdirSync(join(main, ".coding-crew"));
  writeFileSync(join(main, ".coding-crew", "dev-commands.json"), '{"test":"npm test"}');
  const ctx = { log: (m, l) => logs.push([m, l]), effects: { mainRoot: main }, sprint: { deviation: (s, r) => recorded.push([s, r]) } };
  assert.equal(flagFullSuiteRuns(ctx, { slug: "a", attempt: 1, outFile }), 2);
  assert.match(logs[0][0], /^\[DEVIATION\] slug=a round=1 /);
  assert.equal(recorded[0][0], "a");
  void dir;
});

