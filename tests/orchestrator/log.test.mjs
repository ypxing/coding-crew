import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { LINE_RE, formatLine, levelFor, writeLog } from "../../orchestrator/lib/log.mjs";

const AT = new Date("2026-09-22T04:28:54.123Z");

test("a line is `<ISO date> <LEVEL padded to 5> <message>`", () => {
  assert.equal(formatLine("info", "[SESSION] feature=x", AT), "2026-09-22T04:28:54Z INFO  [SESSION] feature=x");
  assert.equal(formatLine("error", "[DISPATCH-FAIL] code=1", AT), "2026-09-22T04:28:54Z ERROR [DISPATCH-FAIL] code=1");
  assert.match(formatLine("warn", "x", AT), LINE_RE);
});

test("a multi-line message keeps one header line; the rest are indented and blank lines dropped", () => {
  const out = formatLine("info", "[SUMMARY]\nRounds: 2\n\nModel: sonnet\n", AT);
  assert.equal(out, "2026-09-22T04:28:54Z INFO  [SUMMARY]\n  Rounds: 2\n  Model: sonnet");
});

test("the level comes from the first marker, whatever precedes it", () => {
  assert.equal(levelFor("[STEP] slug=a round=1 step=deps"), "debug");
  assert.equal(levelFor("[TOOL] agent=crew-coder tool=Bash"), "debug");
  assert.equal(levelFor("[TOOL-ERROR] agent=crew-coder tool=Bash"), "warn");
  assert.equal(levelFor("[STALE-BRANCH] slug=a"), "warn");
  assert.equal(levelFor("[DISPATCH-FAIL] agent=crew-coder"), "error");
  assert.equal(levelFor("slug=a [SIDECAR-MISSING] x"), "error");
});

test("any *-FAIL / *-FAILED marker is an error, even one the table does not name", () => {
  assert.equal(levelFor("[HERDR-FAILED] slug=a"), "error");
  assert.equal(levelFor("[SOMETHING-FAIL] x"), "error");
});

test("an unmarked or unknown line is info", () => {
  assert.equal(levelFor("=== slug=a attempt=1 — dispatching"), "info");
  assert.equal(levelFor("[SESSION] feature=x"), "info");
});

test("writeLog appends one formatted line, with the level derived unless given", () => {
  const f = join(mkdtempSync(join(tmpdir(), "log-")), "traces", "orchestrator.log");
  writeLog(f, "[STEP] slug=a step=deps");
  writeLog(f, "[BASELINE] red", "fatal");
  const lines = readFileSync(f, "utf8").trimEnd().split("\n");
  assert.equal(lines.length, 2);
  assert.match(lines[0], /^\S+Z DEBUG \[STEP\] slug=a step=deps$/);
  assert.match(lines[1], /^\S+Z FATAL \[BASELINE\] red$/);
});

test("an unknown level is refused, not written as garbage", () => {
  assert.throws(() => formatLine("verbose", "x", AT), /unknown log level/);
});
