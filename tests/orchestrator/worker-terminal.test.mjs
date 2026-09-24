/**
 * worker-terminal.test.mjs — a headless dispatch hosted in a pane-host terminal
 * (orchestrator/lib/pane-host/worker-terminal.mjs), and the spawnDispatch seam that picks it.
 *
 * The fake terminal runs the typed command in a real detached bash, the way orca's login
 * shell would, so run.sh itself is what's under test. Closing it kills the process group,
 * the way a PTY hangup would.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { spawnInWorkerTerminal } from "../../orchestrator/lib/pane-host/worker-terminal.mjs";
import { spawnDispatch } from "../../orchestrator/lib/pane-host/index.mjs";

const FAST = { pollMs: 50, startTimeoutMs: 1500, exitGraceMs: 300 };

function fixture() {
  const root = mkdtempSync(join(tmpdir(), "crew-worker-terminal-"));
  return { root, stem: join(root, "coder.out") };
}

function fakeTerminal({ run = true, openFailure = null } = {}) {
  const terminals = new Map();
  const adapter = {
    opened: [],
    closed: [],
    async openWorkerTerminal(_effects, { title, command }) {
      adapter.opened.push({ title, command });
      if (openFailure) return { failure: openFailure };
      const handle = `term_${adapter.opened.length}`;
      if (run) {
        const child = spawn("bash", ["-c", command], { detached: true, stdio: "ignore", env: { ...process.env, ORCA_TERMINAL_HANDLE: handle } });
        child.unref();
        terminals.set(handle, child);
      }
      return { handle };
    },
    async closeWorkerTerminal(_effects, handle) {
      adapter.closed.push(handle);
      hangUp(terminals.get(handle));
    },
    hangUp: (handle) => hangUp(terminals.get(handle)),
  };
  return adapter;
}

function hangUp(child) {
  try {
    if (child) process.kill(-child.pid, "SIGKILL");
  } catch {
    /* already gone */
  }
}

function effects(extra = {}) {
  const logs = [];
  return {
    env: {},
    recorded: [],
    log: (l) => logs.push(l),
    _logs: logs,
    spawnWithTimeout: async (...a) => ({ headless: a, code: 0, stdout: "", stderr: "", timedOut: false }),
    ...extra,
  };
}

const alive = (pid) => spawnSync("kill", ["-0", String(pid)]).status === 0;

test("returns the child's exit code, stdout and stderr, streams stdout to onLine, and cleans up on success", async () => {
  const { root, stem } = fixture();
  const term = fakeTerminal();
  const chunks = [];
  const r = await spawnInWorkerTerminal(effects(), term, "bash", ["-c", "echo one; sleep 0.2; echo two; echo oops >&2"], {
    cwd: root, stem, title: "alpha crew-coder", onLine: (c) => chunks.push(c), timing: FAST,
  });
  assert.deepEqual(r, { code: 0, stdout: "one\ntwo\n", stderr: "oops\n", timedOut: false });
  assert.equal(chunks.join(""), "one\ntwo\n");
  assert.equal(term.opened[0].title, "alpha crew-coder");
  assert.deepEqual(term.closed, ["term_1"], "the worker's terminal is closed once it finishes");
  assert.equal(existsSync(`${stem}.term`), false);
});

test("runs in cwd, and a non-zero exit keeps the run dir for inspection, minus the env", async () => {
  const { root, stem } = fixture();
  const r = await spawnInWorkerTerminal(effects(), fakeTerminal(), "bash", ["-c", "pwd; exit 3"], { cwd: root, stem, title: "t", timing: FAST });
  assert.equal(r.code, 3);
  assert.equal(r.stdout.trim(), spawnSync("bash", ["-c", "pwd -P"], { cwd: root, encoding: "utf8" }).stdout.trim());
  assert.equal(existsSync(join(`${stem}.term`, "run.sh")), true);
  assert.equal(existsSync(join(`${stem}.term`, "env.sh")), false, "env.sh can hold credentials");
});

test("the child sees crew-afk's env, and the terminal keeps its own ambient ids", async () => {
  const { root, stem } = fixture();
  const prior = process.env.ORCA_TERMINAL_HANDLE;
  process.env.ORCA_TERMINAL_HANDLE = "term_triggering";
  try {
    const r = await spawnInWorkerTerminal(
      effects({ env: { FROM_EFFECTS: "e 'quoted'" } }),
      fakeTerminal(),
      "bash",
      ["-c", 'echo "$FROM_EFFECTS|$FROM_SPEC|$CLEARED|$ORCA_TERMINAL_HANDLE"'],
      { cwd: root, stem, title: "t", env: { FROM_SPEC: "s", CLEARED: "" }, timing: FAST },
    );
    assert.equal(r.stdout, "e 'quoted'|s||term_1\n");
  } finally {
    if (prior === undefined) delete process.env.ORCA_TERMINAL_HANDLE;
    else process.env.ORCA_TERMINAL_HANDLE = prior;
  }
});

test("a timeout SIGKILLs the child and reports 124, as spawnWithTimeout does", async () => {
  const { root, stem } = fixture();
  const r = await spawnInWorkerTerminal(effects(), fakeTerminal(), "sleep", ["30"], { cwd: root, stem, title: "t", timeoutMs: 400, timing: FAST });
  assert.equal(r.code, 124);
  assert.equal(r.timedOut, true);
  const pid = Number(readFileSync(join(`${stem}.term`, "pid"), "utf8"));
  assert.equal(alive(pid), false);
});

test("a terminal closed under a running worker is a failure, not a hang", async () => {
  const { root, stem } = fixture();
  const term = fakeTerminal();
  const pending = spawnInWorkerTerminal(effects(), term, "sleep", ["30"], { cwd: root, stem, title: "t", timing: FAST });
  await new Promise((r) => setTimeout(r, 400));
  term.hangUp("term_1");
  const r = await pending;
  assert.equal(r.code, 1);
  assert.match(r.stderr, /exited without an exit code/);
});

test("a terminal that never runs the command fails with 127 and is closed", async () => {
  const { root, stem } = fixture();
  const term = fakeTerminal({ run: false });
  const r = await spawnInWorkerTerminal(effects(), term, "true", [], { cwd: root, stem, title: "t", timing: FAST });
  assert.equal(r.code, 127);
  assert.match(r.stderr, /never started run\.sh/);
  assert.deepEqual(term.closed, ["term_1"]);
});

test("a terminal that can't be opened falls back to a headless spawn", async () => {
  const { root, stem } = fixture();
  const e = effects();
  const r = await spawnInWorkerTerminal(e, fakeTerminal({ openFailure: "orca unreachable" }), "claude", ["-p"], { cwd: root, stem, title: "t", timeoutMs: 9 });
  assert.deepEqual(r.headless.slice(0, 2), ["claude", ["-p"]]);
  assert.equal(r.headless[2].timeoutMs, 9);
  assert.ok(e._logs.some((l) => /SPAWN-TERMINAL-FALLBACK orca unreachable/.test(l)));
});

test("the terminal shows a claude event stream as trace lines, not raw JSON", () => {
  const { root } = fixture();
  const out = join(root, "out");
  const rc = join(root, "rc");
  writeFileSync(out, [
    JSON.stringify({ type: "assistant", message: { content: [{ type: "text", text: "Reading the issue." }] } }),
    JSON.stringify({ type: "assistant", message: { content: [{ type: "tool_use", name: "Read", input: { file_path: "a.md" } }] } }),
    JSON.stringify({ type: "result", result: "done" }),
  ].join("\n") + "\n");
  writeFileSync(rc, "0\n");
  const follower = new URL("../../orchestrator/lib/pane-host/follow-output.mjs", import.meta.url).pathname;
  const r = spawnSync(process.execPath, [follower, out, rc, "claude", "crew-coder"], { encoding: "utf8" });
  assert.equal(r.status, 0, r.stderr);
  const lines = r.stdout.trim().split("\n");
  assert.equal(lines[0], "Reading the issue.");
  assert.match(lines[1], /^\[TOOL\] agent=crew-coder tool=Read /);
  assert.equal(lines.length, 2);
});

// ─── spawnDispatch: which path a dispatch takes ─────────────────────────────────────────

test("spawnDispatch stays headless with no pane host, under herdr, and under --dry-run", async () => {
  for (const extra of [{ paneHost: null }, { paneHost: "herdr" }, { paneHost: "orca", dryRun: true }]) {
    const r = await spawnDispatch(effects(extra), "claude", ["-p"], {});
    assert.ok(r.headless, JSON.stringify(extra));
  }
});

test("spawnDispatch under orca opens one terminal in the main checkout, running run.sh", async () => {
  const { root, stem } = fixture();
  const calls = [];
  const e = effects({
    paneHost: "orca",
    mainRoot: root,
    spawnWithTimeout: async (cmd, args) => {
      calls.push([cmd, ...args]);
      return { code: 1, stdout: "", stderr: "stop here" };
    },
  });
  await spawnDispatch(e, "claude", ["-p"], { cwd: root, stem, title: "alpha crew-coder" });
  const create = calls[0];
  assert.deepEqual(create.slice(0, 3), ["orca", "terminal", "create"]);
  assert.equal(create[create.indexOf("--worktree") + 1], `path:${root}`);
  assert.equal(create[create.indexOf("--title") + 1], "alpha crew-coder");
  assert.match(create[create.indexOf("--command") + 1], /^bash '.*coder\.out\.term\/run\.sh'$/);
  assert.deepEqual(calls[1], ["claude", "-p"], "a failed create falls back to the headless spawn");
});
