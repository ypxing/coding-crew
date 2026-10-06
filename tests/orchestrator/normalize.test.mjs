/**
 * normalize.test.mjs — every adapter maps its CLI's events to one shape (PRD D12), and the trace
 * lines are formatted once from that shape. Each fixture under fixtures/events/ holds a shell
 * call, a file read, a failed tool, assistant text and an agent error, in the CLI's own schema.
 */

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { ADAPTERS, normalizeLine } from "../../orchestrator/lib/adapters/index.mjs";
import { formatJsonTraceLine } from "../../orchestrator/lib/adapters/trace.mjs";

const fixture = (platform) =>
  readFileSync(new URL(`./fixtures/events/${platform}.jsonl`, import.meta.url), "utf8").split("\n").filter(Boolean);
const normalized = (platform) => fixture(platform).map((l) => normalizeLine(platform, l)).filter(Boolean);

const KINDS = new Set(["tool", "tool-error", "agent-error", "text"]);
const FIELDS = new Set(["kind", "tool", "command", "path", "args", "id", "detail"]);

test("every adapter exports normalize, and every platform has a recorded fixture", () => {
  for (const [platform, adapter] of Object.entries(ADAPTERS)) assert.equal(typeof adapter.normalize, "function", platform);
  const recorded = readdirSync(new URL("./fixtures/events/", import.meta.url)).map((f) => f.replace(/\.jsonl$/, ""));
  assert.deepEqual(recorded.sort(), Object.keys(ADAPTERS).sort());
});

test("every normalized event has the documented shape", () => {
  for (const platform of Object.keys(ADAPTERS)) {
    for (const evt of normalized(platform)) {
      assert.ok(KINDS.has(evt.kind), `${platform}: ${JSON.stringify(evt)}`);
      for (const k of Object.keys(evt)) assert.ok(FIELDS.has(k), `${platform}: unknown field ${k}`);
      for (const k of ["tool", "command", "path", "id", "detail"]) {
        if (k in evt) assert.equal(typeof evt[k], "string", `${platform}: ${k}`);
      }
    }
  }
});

test("each fixture normalizes to a shell call, a file read, a failed tool, assistant text and an agent error", () => {
  const strip = ({ args, ...rest }) => rest; // args is the raw input, checked by the trace tests
  assert.deepEqual(normalized("claude").map(strip), [
    { kind: "tool", tool: "Bash", command: "npm test", id: "toolu_1" },
    { kind: "tool", tool: "Read", path: "/repo/src/a.js", id: "toolu_2" },
    { kind: "tool-error", id: "toolu_1", detail: "tool_use_id=toolu_1" },
    { kind: "text", detail: "One test fails; fixing it." },
    { kind: "agent-error", detail: 'error="API Error: 500 overloaded"' },
  ]);
  assert.deepEqual(normalized("codex").map(strip), [
    { kind: "tool", tool: "shell", command: "bash -lc 'npm test'", id: "item_1" },
    { kind: "tool-error", tool: "shell", command: "bash -lc 'npm test'", id: "item_1", detail: "exit=1" },
    { kind: "tool", tool: "shell", command: "bash -lc 'cat src/a.js'", id: "item_2" },
    { kind: "text", detail: "One test fails; fixing it." },
    { kind: "agent-error", detail: 'type=turn.failed error="stream disconnected"' },
  ]);
  assert.deepEqual(normalized("copilot").map(strip), [
    { kind: "tool", tool: "bash", command: "npm test", id: "call_1" },
    { kind: "tool", tool: "view", path: "/repo/src/a.js", id: "call_2" },
    { kind: "tool-error", id: "call_1", detail: 'toolCallId=call_1 error="exit 1"' },
    { kind: "text", detail: "One test fails; fixing it." },
    { kind: "agent-error", detail: 'type=quota error="over quota"' },
  ]);
  assert.deepEqual(normalized("pi").map(strip), [
    { kind: "tool", tool: "bash", command: "npm test", id: "call_1" },
    { kind: "tool", tool: "read", path: "/repo/src/a.js", id: "call_2" },
    { kind: "tool-error", tool: "bash", id: "call_1" },
    { kind: "text", detail: "One test fails; fixing it." },
    { kind: "agent-error", detail: 'error="429 rate limited"' },
  ]);
});

test("one formatter turns each platform's fixture into [TOOL]/[TOOL-ERROR]/[AGENT-ERROR] lines, and text into none", () => {
  const trace = (platform) => fixture(platform).map((l) => formatJsonTraceLine(platform, "crew-coder", l)).filter(Boolean);
  assert.deepEqual(trace("claude"), [
    "[TOOL] agent=crew-coder tool=Bash $ npm test",
    "[TOOL] agent=crew-coder tool=Read /repo/src/a.js",
    "[TOOL-ERROR] agent=crew-coder tool_use_id=toolu_1",
    '[AGENT-ERROR] agent=crew-coder error="API Error: 500 overloaded"',
  ]);
  assert.deepEqual(trace("codex"), [
    "[TOOL] agent=crew-coder tool=shell $ bash -lc 'npm test'",
    "[TOOL-ERROR] agent=crew-coder tool=shell exit=1",
    "[TOOL] agent=crew-coder tool=shell $ bash -lc 'cat src/a.js'",
    '[AGENT-ERROR] agent=crew-coder type=turn.failed error="stream disconnected"',
  ]);
  assert.deepEqual(trace("copilot"), [
    "[TOOL] agent=crew-coder tool=bash $ npm test",
    "[TOOL] agent=crew-coder tool=view /repo/src/a.js",
    '[TOOL-ERROR] agent=crew-coder toolCallId=call_1 error="exit 1"',
    '[AGENT-ERROR] agent=crew-coder type=quota error="over quota"',
  ]);
  assert.deepEqual(trace("pi"), [
    "[TOOL] agent=crew-coder tool=bash $ npm test",
    "[TOOL] agent=crew-coder tool=read /repo/src/a.js",
    "[TOOL-ERROR] agent=crew-coder tool=bash",
    '[AGENT-ERROR] agent=crew-coder error="429 rate limited"',
  ]);
});

test("an unknown platform, an unparseable line and a non-object event normalize to null", () => {
  assert.equal(normalizeLine("nope", "{}"), null);
  assert.equal(normalizeLine("claude", "not json"), null);
  for (const platform of Object.keys(ADAPTERS)) assert.equal(normalizeLine(platform, "42"), null, platform);
});

test("only claude declares liveText: the one adapter whose assistant text a pane shows", () => {
  assert.deepEqual(
    Object.entries(ADAPTERS).filter(([, a]) => a.liveText).map(([p]) => p),
    ["claude"],
  );
});
