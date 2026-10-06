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
  assert.deepEqual(fullSuiteRuns(f, "bats tests/*.bats", "claude"), ["bats tests/*.bats"]);
});

test("the cached command with explicit test-file arguments is a targeted run, not the suite", () => {
  const { f } = events("pytest tests/test_x.py", "npm test -- a.test.js", "pytest -q", "npm test 2>&1 | tail -5", "npm test -- --watch=false");
  assert.deepEqual(fullSuiteRuns(f, "pytest", "claude"), ["pytest -q"]);
  assert.deepEqual(fullSuiteRuns(f, "npm test", "claude"), ["npm test 2>&1 | tail -5", "npm test -- --watch=false"]);
});

test("a redirection target or a flag's value is not a test-file argument", () => {
  const { f } = events("npm test > /tmp/out.log 2>&1", "npm test -- --maxWorkers 2", "npm test 2> err.txt", "npm test -- a.test.js > /tmp/t.log");
  assert.deepEqual(fullSuiteRuns(f, "npm test", "claude"), ["npm test > /tmp/out.log 2>&1", "npm test -- --maxWorkers 2", "npm test 2> err.txt"]);
  const p = events("pytest >out.txt", "pytest -n 4", "pytest -n 4 tests/test_x.py").f;
  assert.deepEqual(fullSuiteRuns(p, "pytest", "claude"), ["pytest >out.txt", "pytest -n 4"]);
});

test("the cached command's leading env assignments are not part of what is matched", () => {
  const { f } = events("bats tests/*.bats", "ORCHESTRATOR_PREFETCH=1 bats tests/*.bats", "bats tests/one.bats");
  assert.deepEqual(fullSuiteRuns(f, "ORCHESTRATOR_PREFETCH=1 bats tests/*.bats", "claude"), ["bats tests/*.bats", "ORCHESTRATOR_PREFETCH=1 bats tests/*.bats"]);
});

test("a subshell or a quoted shell wrapper around the full suite is a full run", () => {
  const { f } = events("(npm test)", "bash -lc 'npm test'", 'sh -c "npm test"', "bash -lc 'npm test -- a.test.js'");
  assert.deepEqual(fullSuiteRuns(f, "npm test", "claude"), ["(npm test)", "bash -lc 'npm test'", 'sh -c "npm test"']);
});

test("a longer target or program that merely starts with the test command is not it", () => {
  const { f } = events("make test-unit", "make tests", "xmake test", "make test");
  assert.deepEqual(fullSuiteRuns(f, "make test", "claude"), ["make test"]);
});

test("a codex command reported at its start and its (failed) end counts once", () => {
  const dir = mkdtempSync(join(tmpdir(), "dev-"));
  const f = join(dir, "report.md.events.jsonl");
  const item = (type, id, exit_code) => JSON.stringify({ type, item: { id, type: "command_execution", command: "npm test", exit_code } });
  writeFileSync(f, [item("item.started", "item_7", null), item("item.completed", "item_7", 1), item("item.started", "item_9", null), item("item.completed", "item_9", 0)].join("\n") + "\n");
  assert.deepEqual(fullSuiteRuns(f, "npm test", "codex"), ["npm test", "npm test"]);
});

test("a whole-suite run is found in each platform's recorded events, once per tool call", () => {
  const fixture = (p) => new URL(`./fixtures/events/${p}.jsonl`, import.meta.url).pathname;
  assert.deepEqual(fullSuiteRuns(fixture("claude"), "npm test", "claude"), ["npm test"]);
  assert.deepEqual(fullSuiteRuns(fixture("copilot"), "npm test", "copilot"), ["npm test"]);
  assert.deepEqual(fullSuiteRuns(fixture("pi"), "npm test", "pi"), ["npm test"]);
  assert.deepEqual(fullSuiteRuns(fixture("codex"), "npm test", "codex"), ["bash -lc 'npm test'"]);
});

test("a command field outside a tool call is not a run, and an unknown platform finds none", () => {
  const dir = mkdtempSync(join(tmpdir(), "dev-"));
  const f = join(dir, "report.md.events.jsonl");
  writeFileSync(f, JSON.stringify({ type: "system", hook: { command: "npm test" } }) + "\n" + bash("npm test") + "\n");
  assert.deepEqual(fullSuiteRuns(f, "npm test", "claude"), ["npm test"]);
  assert.deepEqual(fullSuiteRuns(f, "npm test", "nope"), []);
});

test("no test command or no events file means no deviation", () => {
  assert.deepEqual(fullSuiteRuns("/nonexistent", "bats", "claude"), []);
  assert.deepEqual(fullSuiteRuns(events("bats x").f, null, "claude"), []);
});

test("flagFullSuiteRuns logs [DEVIATION], records it, and does not throw", () => {
  const { dir, outFile } = events("npm test", "npm test");
  const main = mkdtempSync(join(tmpdir(), "main-"));
  writeFileSync(join(main, "x"), "");
  const logs = [], recorded = [];
  mkdirSync(join(main, ".coding-crew"));
  writeFileSync(join(main, ".coding-crew", "dev-commands.json"), '{"test":"npm test"}');
  const ctx = { log: (m, l) => logs.push([m, l]), effects: { mainRoot: main }, sprint: { deviation: (s, r) => recorded.push([s, r]) } };
  assert.equal(flagFullSuiteRuns(ctx, { slug: "a", attempt: 1, outFile, platform: "claude" }), 2);
  assert.match(logs[0][0], /^\[DEVIATION\] slug=a round=1 /);
  assert.equal(recorded[0][0], "a");
  void dir;
});

