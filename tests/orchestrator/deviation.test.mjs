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

