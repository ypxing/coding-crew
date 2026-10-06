/**
 * dispatch.test.mjs — the adapter contract, per platform.
 *
 * These assertions used to be prose in each platform's fragment set: which dispatcher
 * script runs, that the worker is pinned to its worktree, that the reviewer runs from the
 * main checkout, that `--model inherit` means "pass no model", and that a missing agent
 * definition is caught once, before round 1, with the install command that fixes it.
 *
 * The codex cutover deleted `fragments/codex/`, so the assertions move here — the same
 * discipline the pi cutover used: nothing is deleted before its code equivalent exists.
 * The claude cutover adds its own section at the bottom, for the same reason.
 */

import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Point HOME at an empty directory for the whole file, so a real per-user install never leaks
// into an assertion below, and restore it once these tests are done.
const isolatedHome = mkdtempSync(join(tmpdir(), "crew-dispatch-home-"));
const realHome = process.env.HOME;

before(() => {
  process.env.HOME = isolatedHome;
});
after(() => {
  if (realHome === undefined) delete process.env.HOME;
  else process.env.HOME = realHome;
});

import {
  buildDispatch,
  dispatch,
  dispatchPlain,
  extractFinalText,
  extractResultMeta,
  preflight,
  DEFAULT_PARALLEL,
} from "../../orchestrator/lib/dispatch.mjs";
import { formatJsonTraceLine } from "../../orchestrator/lib/adapters/trace.mjs";
import { Effects } from "../../orchestrator/lib/effects.mjs";

const SCRIPTS = "skills/crew-afk/scripts";

function fixture() {
  const root = mkdtempSync(join(tmpdir(), "crew-dispatch-"));
  const promptFile = join(root, "p.md");
  writeFileSync(promptFile, "prompt body");
  return { root, promptFile };
}

function spec(root, promptFile, over = {}) {
  return {
    agent: "crew-coder",
    cwd: join(root, "worktree"),
    promptFile,
    outFile: join(root, "dispatch/alpha.report.md"),
    model: null,
    mainRoot: root,
    logFile: join(root, "trace.log"),
    scriptsDir: SCRIPTS,
    ...over,
  };
}

test("pi and codex dispatch their own CLI directly: no bash dispatcher, no agent file", () => {
  const { root, promptFile } = fixture();
  const pi = buildDispatch("pi", spec(root, promptFile));
  const codex = buildDispatch("codex", spec(root, promptFile));
  assert.equal(pi.cmd, "pi");
  assert.equal(codex.cmd, "codex");
  for (const b of [pi, codex]) {
    assert.equal(b.capture, "stdout");
    assert.equal(b.cwd, join(root, "worktree"));
    assert.equal(b.env.CREW_ORCHESTRATED, "1");
    assert.equal(b.env.MAIN_ROOT, root);
    assert.doesNotMatch(b.args.join(" "), /dispatch-.*agent\.sh/);
  }
});

test("pi carries the role's tools and its rendered protocol as the system prompt, the prompt last", () => {
  const { root, promptFile } = fixture();
  const coder = buildDispatch("pi", spec(root, promptFile)).args;
  assert.deepEqual(coder.slice(0, 5), ["-p", "-n", "crew-coder: p", "--mode", "json"]);
  assert.equal(coder[coder.indexOf("--tools") + 1], "read,bash,edit,write");
  assert.match(coder[coder.indexOf("--append-system-prompt") + 1], /^# Coder/);
  assert.equal(coder.at(-1), "prompt body");
  const reviewer = buildDispatch("pi", spec(root, promptFile, { agent: "crew-reviewer" })).args;
  assert.equal(reviewer[reviewer.indexOf("--tools") + 1], "read,bash");
});

test("codex carries the role's reasoning effort from role config", () => {
  const { root, promptFile } = fixture();
  const effort = (agent) => {
    const a = buildDispatch("codex", spec(root, promptFile, { agent })).args;
    return a[a.indexOf('model_reasoning_effort="' + "medium" + '"') - 1] === "-c" ? "medium" : a.find((x) => /^model_reasoning_effort=/.test(x));
  };
  assert.equal(effort("crew-coder"), "medium");
  assert.equal(effort("crew-reviewer"), 'model_reasoning_effort="high"');
  assert.equal(effort("crew-triage"), 'model_reasoning_effort="high"');
});

test("codex: the coder is workspace-write with network and the git dirs writable; protocol then prompt go on stdin", () => {
  const { root, promptFile } = fixture();
  const wt = join(root, "worktree");
  mkdirSync(wt, { recursive: true });
  const b = buildDispatch("codex", spec(root, promptFile));
  const a = b.args;
  assert.deepEqual(a.slice(0, 7), ["exec", "--cd", wt, "--sandbox", "workspace-write", "--json", "-c"]);
  assert.ok(a.includes("sandbox_workspace_write.network_access=true"));
  assert.deepEqual(a.slice(a.indexOf("--add-dir"), a.indexOf("--add-dir") + 2), ["--add-dir", root]);
  assert.equal(a.at(-1), "-", "codex reads the prompt from stdin");
  assert.match(b.input, /^# Coder[\s\S]*# Task\n\nprompt body$/);
  assert.equal(a.at(a.indexOf("--output-last-message") + 1), join(root, "dispatch/alpha.report.md"));
});

test("codex: a read-only role runs workspace-write rooted at its result file's directory", () => {
  const { root, promptFile } = fixture();
  const out = join(root, "dispatch/alpha.review.md");
  const b = buildDispatch("codex", spec(root, promptFile, { agent: "crew-reviewer", cwd: root, outFile: out }));
  const a = b.args;
  const resultDir = join(realpathSync(root), "dispatch");
  assert.deepEqual(a.slice(0, 5), ["exec", "--cd", resultDir, "--sandbox", "workspace-write"]);
  assert.ok(a.includes("sandbox_workspace_write.exclude_slash_tmp=true"));
  assert.equal(a.includes("sandbox_workspace_write.network_access=true"), false);
  assert.equal(a.includes("--add-dir"), false);
  assert.match(b.input, /Your shell starts in .*dispatch, the only writable directory[\s\S]*prompt body$/);
});

test("no model resolves to no --model flag (what `--model inherit` means)", () => {
  const { root, promptFile } = fixture();
  for (const platform of ["codex", "pi"]) {
    const argv = buildDispatch(platform, spec(root, promptFile, { model: null })).args.join(" ");
    assert.doesNotMatch(argv, /--model/, `${platform} invented a model`);
    assert.doesNotMatch(buildDispatch(platform, spec(root, promptFile, { model: "inherit" })).args.join(" "), /--model/);
  }
  assert.match(buildDispatch("codex", spec(root, promptFile, { model: "gpt-5" })).args.join(" "), /--model gpt-5/);
  assert.match(buildDispatch("pi", spec(root, promptFile, { model: "gpt-5" })).args.join(" "), /--model gpt-5/);
});

test("pi's trace lines and final text match what the bash dispatcher produced for the same stream", () => {
  const stream = [
    { type: "tool_execution_start", toolName: "bash", args: { command: "ls -la" } },
    { type: "tool_execution_start", toolName: "read", args: { path: "/a/b.js" } },
    { type: "tool_execution_start", toolName: "mcp", args: { q: "x" } },
    { type: "tool_execution_end", toolName: "bash", isError: true },
    { type: "tool_execution_end", toolName: "bash", isError: false },
    { type: "message_end", message: { role: "assistant", content: [{ type: "text", text: "first" }] } },
    { type: "message_end", message: { role: "assistant", content: [{ type: "text", text: "do" }, { type: "thinking", text: "x" }, { type: "text", text: "ne" }] } },
    { type: "message_end", message: { role: "user", content: [{ type: "text", text: "ignored" }] } },
  ].map((e) => JSON.stringify(e));
  assert.deepEqual(
    stream.map((l) => formatJsonTraceLine("pi", "crew-coder", l)).filter(Boolean),
    [
      "[TOOL] agent=crew-coder tool=bash $ ls -la",
      "[TOOL] agent=crew-coder tool=read /a/b.js",
      '[TOOL] agent=crew-coder tool=mcp args={"q":"x"}',
      "[TOOL-ERROR] agent=crew-coder tool=bash",
    ],
  );
  assert.equal(extractFinalText("pi", stream), "done");
  assert.equal(extractFinalText("pi", []), "");
});

test("codex's trace lines and final text match what the bash dispatcher produced for the same stream", () => {
  const stream = [
    { type: "item.started", item: { type: "reasoning" } },
    { type: "item.started", item: { type: "command_execution", command: "npm test" } },
    { type: "item.started", item: { type: "file_change", path: "src/a.js" } },
    { type: "item.started", item: { type: "mcp_tool_call", server: "s" } },
    { type: "item.completed", item: { type: "command_execution", exit_code: 2 } },
    { type: "item.completed", item: { type: "command_execution", exit_code: 0 } },
    { type: "item.completed", item: { type: "agent_message", text: "all done" } },
    { type: "turn.failed" },
    { type: "error" },
  ].map((e) => JSON.stringify(e));
  assert.deepEqual(
    stream.map((l) => formatJsonTraceLine("codex", "crew-coder", l)).filter(Boolean),
    [
      "[TOOL] agent=crew-coder tool=shell $ npm test",
      "[TOOL] agent=crew-coder tool=file_change src/a.js",
      '[TOOL] agent=crew-coder tool=mcp_tool_call args={"type":"mcp_tool_call","server":"s"}',
      "[TOOL-ERROR] agent=crew-coder tool=shell exit=2",
      "[AGENT-ERROR] agent=crew-coder type=turn.failed",
      "[AGENT-ERROR] agent=crew-coder type=error",
    ],
  );
  assert.equal(extractFinalText("codex", stream), "all done");
});

test("a codex dispatch falls back to the final message codex wrote itself (-o) when the stream has none", async () => {
  const { root, promptFile } = fixture();
  const outFile = join(root, "dispatch", "alpha.report.md");
  const fakeEffects = {
    spawnWithTimeout: async (cmd, args) => {
      writeFileSync(args[args.indexOf("--output-last-message") + 1], "from -o");
      return { code: 0, stdout: "", stderr: "", timedOut: false, dryRun: false };
    },
  };
  const r = await dispatch(fakeEffects, "codex", { agent: "crew-coder", cwd: root, promptFile, outFile, model: null, mainRoot: root }, {});
  assert.equal(r.text, "from -o");
});

test("a missing pi or codex CLI fails the dispatch with 127 and a message naming it", async () => {
  const { root, promptFile } = fixture();
  const real = new Effects({ scriptsDir: SCRIPTS, mainRoot: root });
  const prevPath = process.env.PATH;
  process.env.PATH = join(root, "empty-bin");
  try {
    for (const platform of ["pi", "codex"]) {
      const r = await dispatch(real, platform, { agent: "crew-coder", cwd: root, promptFile, outFile: join(root, `${platform}.out`), model: null, mainRoot: root }, {});
      assert.equal(r.code, 127);
      assert.match(r.stderr, new RegExp(platform));
    }
  } finally {
    process.env.PATH = prevPath;
  }
});

test("a CLI missing from PATH is a preflight failure, not a first-dispatch failure", () => {
  const { root } = fixture();
  const effects = { exec: () => ({ code: 1, stdout: "", stderr: "" }) };
  for (const platform of ["pi", "codex"]) {
    assert.deepEqual(preflight(effects, platform), [`${platform} CLI not found on PATH`]);
  }
});

test("pi and codex preflight needs no agent definition", () => {
  const { root } = fixture();
  const effects = { exec: () => ({ code: 0, stdout: "/usr/bin/x", stderr: "" }) };
  for (const platform of ["pi", "codex"]) assert.deepEqual(preflight(effects, platform), []);
});

// ─── claude ──────────────────────────────────────────────────────────────────
//
// The claude cutover deleted the prose body that used to carry these: "dispatch in
// batches of 3", "call the Agent tool with isolation: worktree", and the permission
// paragraph. They are adapter facts now, so they are asserted on the adapter.

test("claude's concurrency is a number, not a prose batch size", () => {
  // "dispatch in batches of 3, wait for all 3" was the only concurrency control the
  // claude body had, and nothing enforced it. It is --max-parallel now, defaulted here.
  assert.equal(DEFAULT_PARALLEL.claude, 3);
});

test("claude passes a model through, and no model means no --model", () => {
  const { root, promptFile } = fixture();
  assert.doesNotMatch(buildDispatch("claude", spec(root, promptFile, { model: null })).args.join(" "), /--model/);
  assert.match(
    buildDispatch("claude", spec(root, promptFile, { model: "opus" })).args.join(" "),
    /--model opus/,
  );
});

// A claude worker dispatched from inside a Claude Code session (crew-afk itself running
// under claude, or a nested pi/codex sprint invoked from one) otherwise inherits the
// parent's own CLAUDE_CODE_SESSION_ID/CLAUDE_CODE_CHILD_SESSION and attaches to its hook
// chain — a global UserPromptSubmit hook firing on the child's prompt can rewrite or swallow
// it before the agent ever sees it. Command discovery's dispatchPlain probe hit exactly this
// (see the matching test below); buildDispatch clears the same two vars for every claude
// dispatch, not just the agent-less ones.
test("a claude worker's session id is cleared, not inherited from the orchestrator's own", () => {
  const { root, promptFile } = fixture();
  const b = buildDispatch("claude", spec(root, promptFile));
  assert.equal(b.env.CLAUDE_CODE_SESSION_ID, "");
  assert.equal(b.env.CLAUDE_CODE_CHILD_SESSION, "");
});

test("pi and codex dispatches carry no claude-only session env vars", () => {
  const { root, promptFile } = fixture();
  for (const platform of ["pi", "codex"]) {
    const b = buildDispatch(platform, spec(root, promptFile));
    assert.equal("CLAUDE_CODE_SESSION_ID" in b.env, false);
    assert.equal("CLAUDE_CODE_CHILD_SESSION" in b.env, false);
  }
});

// ─── copilot ─────────────────────────────────────────────────────────────────
//
// The copilot cutover deleted `fragments/copilot/`, whose prose carried: dispatch with the
// `task` tool (never `#runSubagent`), the agent locations Copilot scans, `Unknown agent_type`
// is a reported failure and never a licence to self-implement, plan-tier batching, and
// "--model is accepted but ignored". Every one of those is an adapter fact now, so they are
// asserted on the adapter — where a wrong one fails a test instead of a sprint.
//
// Probed against Copilot CLI 1.0.79: `--agent <name>` loads `.github/agents/<name>.agent.md`,
// exits 1 with `No such agent: <name>, available: …` on an unknown name, enforces the
// definition's `tools:` list even under --allow-all-tools — and resolves that directory
// relative to its own cwd, with no upward walk.

const ROLE_AGENT = { coder: "crew-coder", reviewer: "crew-reviewer", triage: "crew-triage" };

test("claude: every role dispatches with no agent file present, protocol via --append-system-prompt-file", () => {
  const { root, promptFile } = fixture();
  for (const role of Object.keys(ROLE_AGENT)) {
    const b = buildDispatch("claude", spec(root, promptFile, { agent: ROLE_AGENT[role], outFile: join(root, `dispatch/${role}.md`) }));
    assert.equal(b.cmd, "claude");
    assert.equal(b.args[0], "-p");
    assert.equal(b.args[1], "prompt body");
    assert.doesNotMatch(b.args.join(" "), /--agent /);
    const f = b.args[b.args.indexOf("--append-system-prompt-file") + 1];
    assert.ok(existsSync(f), `${role}: the rendered protocol is on disk`);
    assert.doesNotMatch(readFileSync(f, "utf8"), /\{\{[A-Z]/, `${role}: nothing left unexpanded`);
  }
  assert.ok(!existsSync(join(root, ".claude/agents")));
});

test("claude: the coder denies sub-agents; reviewer and triage deny file edits and sub-agents", () => {
  const { root, promptFile } = fixture();
  const coder = buildDispatch("claude", spec(root, promptFile)).args;
  assert.equal(coder[coder.indexOf("--disallowedTools") + 1], "Agent");
  for (const agent of ["crew-reviewer", "crew-triage"]) {
    const a = buildDispatch("claude", spec(root, promptFile, { agent })).args;
    const denied = a.slice(a.indexOf("--disallowedTools") + 1, a.indexOf("--disallowedTools") + 5);
    assert.deepEqual(denied, ["Edit", "Write", "NotebookEdit", "Agent"], agent);
  }
});

test("copilot: reviewer and triage deny write tools; the coder does not", () => {
  const { root, promptFile } = fixture();
  for (const agent of ["crew-reviewer", "crew-triage"]) {
    const a = buildDispatch("copilot", spec(root, promptFile, { agent })).args;
    assert.equal(a[a.indexOf("--deny-tool") + 1], "write", agent);
  }
  assert.ok(!buildDispatch("copilot", spec(root, promptFile)).args.includes("--deny-tool"));
});

test("copilot: every role dispatches with the protocol prepended and no agent file", () => {
  const { root, promptFile } = fixture();
  for (const role of Object.keys(ROLE_AGENT)) {
    const b = buildDispatch("copilot", spec(root, promptFile, { agent: ROLE_AGENT[role] }));
    assert.equal(b.cmd, "copilot");
    assert.doesNotMatch(b.args.join(" "), /--agent /);
    assert.match(b.args[1], /prompt body$/);
    assert.ok(b.args[1].length > "prompt body".length + 500, "the protocol precedes the prompt");
    assert.doesNotMatch(b.args[1], /\{\{[A-Z]/);
  }
  const b = buildDispatch("copilot", spec(root, promptFile));
  assert.match(b.args.join(" "), new RegExp(`-C ${join(root, "worktree")}`));
  assert.match(b.args.join(" "), /--allow-all-tools/);
  assert.match(b.args.join(" "), /--output-format json/);
  assert.equal(b.jsonEvents, "copilot");
});

test("claude and copilot preflight needs no agent file, and no committed-agent check runs", () => {
  const { root } = fixture();
  for (const platform of ["claude", "copilot"]) {
    const effects = {
      exec: () => ({ code: 0, stdout: "/usr/bin/x", stderr: "" }),
      gitRead: () => assert.fail("copilotWorktreeVisible must not run"),
    };
    assert.deepEqual(preflight(effects, platform), []);
  }
});

test("a missing fragment fails the dispatch before spawning, naming the fragment", async () => {
  const { root, promptFile } = fixture();
  const rolesDir = join(root, "roles");
  mkdirSync(rolesDir, { recursive: true });
  writeFileSync(join(rolesDir, "coder.md"), "# P\n{{FRAGMENT:no-such-frag}}\n");
  assert.throws(() => buildDispatch("claude", spec(root, promptFile, { rolesDir })), /no-such-frag/);
  let spawned = false;
  const effects = { spawnWithTimeout: async () => ((spawned = true), { code: 0, stdout: "", stderr: "" }) };
  const r = await dispatch(effects, "claude", spec(root, promptFile, { rolesDir }), {});
  assert.equal(spawned, false);
  assert.notEqual(r.code, 0);
  assert.match(r.stderr, /no-such-frag/);
});

test("an argv prompt over 128 KiB fails the dispatch naming the limit, never truncated", async () => {
  const { root } = fixture();
  const big = join(root, "big.md");
  writeFileSync(big, "x".repeat(128 * 1024 + 1));
  for (const platform of ["claude", "copilot"]) {
    assert.throws(() => buildDispatch(platform, spec(root, big)), /128 KiB/);
    let spawned = false;
    const effects = { spawnWithTimeout: async () => ((spawned = true), { code: 0, stdout: "", stderr: "" }) };
    const r = await dispatch(effects, platform, spec(root, big), {});
    assert.equal(spawned, false);
    assert.match(r.stderr, /128 KiB/);
  }
  const effects = new Effects({ scriptsDir: SCRIPTS, mainRoot: root, dryRun: true });
  const r = await dispatchPlain(effects, "claude", { prompt: "y".repeat(128 * 1024 + 1), cwd: root, mainRoot: root, outFile: join(root, "plain.md") });
  assert.match(r.stderr, /128 KiB/);
  assert.equal(effects.recorded.length, 0);
});

test("a prompt over 128 KiB still reaches codex, which reads it on stdin, and pi, whose two argv strings are each under the cap", () => {
  const { root } = fixture();
  const big = join(root, "big.md");
  writeFileSync(big, "x".repeat(100 * 1024));
  const codex = buildDispatch("codex", spec(root, big));
  assert.ok(codex.input.length > 100 * 1024);
  // pi: the ~100 KiB prompt plus the protocol is over the cap in total, but no one string is.
  assert.doesNotThrow(() => buildDispatch("pi", spec(root, big)));
});

test("on Windows the whole command line is capped", async () => {
  const { assertArgvFits } = await import("../../orchestrator/lib/adapters/common.mjs");
  assert.throws(() => assertArgvFits(["x".repeat(40_000)], "copilot", "win32"), /32767-character/);
  assert.doesNotThrow(() => assertArgvFits(["x".repeat(40_000)], "copilot", "linux"));
});

test("claude cost, session id, resume and budget over a recorded stream-json fixture", async () => {
  const { root, promptFile } = fixture();
  const stream = readFileSync("tests/orchestrator/fixtures/claude-stream.jsonl", "utf8");
  let seen;
  const effects = {
    spawnWithTimeout: async (cmd, args, { onLine }) => {
      seen = args;
      onLine(stream);
      return { code: 0, stdout: "", stderr: "", timedOut: false, dryRun: false };
    },
  };
  const r = await dispatch(effects, "claude", spec(root, promptFile, { resumeSessionId: "sess-prev", maxBudgetUsd: 3 }), {});
  assert.equal(r.costUsd, 0.42);
  assert.equal(r.sessionId, "sess-fixture");
  assert.equal(r.numTurns, 3);
  assert.equal(r.text, '{"status":"complete"}');
  assert.equal(seen[seen.indexOf("--resume") + 1], "sess-prev");
  assert.equal(seen[seen.indexOf("--max-budget-usd") + 1], "3");
});

test("copilot's --model is a real flag now, not accepted-and-ignored", () => {
  // On the prose body the model was session-selected and `task` took no model argument, so
  // --model printed a notice and did nothing. A worker is its own process now, so the flag
  // reaches the CLI — and no model still means no --model.
  const { root, promptFile } = fixture();
  assert.doesNotMatch(buildDispatch("copilot", spec(root, promptFile, { model: null })).args.join(" "), /--model/);
  assert.match(
    buildDispatch("copilot", spec(root, promptFile, { model: "claude-sonnet-4.5" })).args.join(" "),
    /--model claude-sonnet-4\.5/,
  );
});

test("copilot's concurrency is a number, not a plan-tier batching paragraph", () => {
  // "Concurrency is capped by the Copilot plan (Free 2 … Enterprise 32)" described the
  // in-session `task` cap. A worker is its own session now, so the default is conservative
  // and `--max-parallel` raises it.
  assert.equal(DEFAULT_PARALLEL.copilot, 2);
});

// ─── dispatchPlain: agent-less dispatch ──────────────────────────────
//
// Every dispatchPlain() call — command discovery's included — gets the same
// read/bash/edit/write toolset an interactive session would. A noTools option once
// stripped it for command discovery, but claude's --tools flag is variadic: with no
// --model between it and the prompt (the default, unless a sprint passes --model),
// `--tools ""` swallowed the prompt itself into its own argument list, so claude saw no
// prompt at all and exited 1 — surfaced as "Command discovery: model dispatch did not
// complete (exit 1)". See dispatch.mjs's dispatchPlain doc comment.

async function recordedDispatch(platform, over = {}) {
  const { root } = fixture();
  const effects = new Effects({ scriptsDir: SCRIPTS, mainRoot: root, dryRun: true });
  await dispatchPlain(effects, platform, { prompt: "the whole prompt", cwd: root, mainRoot: root, outFile: join(root, "plain.md"), ...over });
  return { root, rec: effects.recorded.at(-1) };
}

test("a plain role dispatches through its platform's adapter, with its prompt and no protocol", async () => {
  for (const platform of ["pi", "codex", "claude", "copilot"]) {
    const { root, rec } = await recordedDispatch(platform);
    const promptFile = join(root, "plain.md.prompt.md");
    const built = buildDispatch(platform, { agent: "plain", cwd: root, mainRoot: root, promptFile, outFile: join(root, "plain.md") });
    assert.deepEqual(rec.argv, [built.cmd, ...built.args], platform);
    assert.doesNotMatch(rec.argv.join(" "), /# Coder|# Reviewer|# Triage/, `${platform}: no protocol`);
    if (platform !== "codex") assert.ok(rec.argv.includes("the whole prompt"), platform);
  }
});

test("claude: a plain role's prompt sits right after -p, so no variadic flag swallows it, and gets no --tools", async () => {
  // --add-dir and --tools are variadic: a prompt after them was consumed as their values, and
  // claude exited 1 with "Input must be provided either through stdin or as a prompt argument".
  for (const model of [null, "opus"]) {
    const { rec } = await recordedDispatch("claude", { model });
    assert.equal(rec.argv[rec.argv.indexOf("-p") + 1], "the whole prompt");
    assert.equal(rec.argv.includes("--tools"), false);
  }
});

// A plain role is a one-shot, stateless pass: auto-memory's project dir is shared across every
// worktree, and a parent session's ids attached the child to its hook chain (a global
// UserPromptSubmit hook once rewrote command discovery's prompt).
test("claude: a plain role disables auto-memory and starts its own session; no other runtime gets those vars", async () => {
  const { rec } = await recordedDispatch("claude");
  assert.equal(rec.env.CLAUDE_CODE_DISABLE_AUTO_MEMORY, "1");
  assert.equal(rec.env.CLAUDE_CODE_SESSION_ID, "");
  assert.equal(rec.env.CLAUDE_CODE_CHILD_SESSION, "");
  for (const platform of ["pi", "codex", "copilot"]) {
    assert.equal("CLAUDE_CODE_DISABLE_AUTO_MEMORY" in (await recordedDispatch(platform)).rec.env, false, platform);
  }
});

test("a plain role's model comes through", async () => {
  for (const platform of ["pi", "codex", "claude", "copilot"]) {
    const { rec } = await recordedDispatch(platform, { model: "m-1" });
    assert.equal(rec.argv[rec.argv.indexOf("--model") + 1], "m-1", platform);
  }
});

// ─── json-stream visibility ────────────────────────────────
//
// The "live [TOOL]/[TOOL-ERROR] line while the worker is still running" behaviour lives
// here for every platform, driven by formatJsonTraceLine/extractFinalText and dispatch()'s onLine wiring.

test("formatJsonTraceLine reads claude's tool_use content block", () => {
  const line = JSON.stringify({
    type: "assistant",
    message: { content: [{ type: "tool_use", id: "t1", name: "Bash", input: { command: "echo hi" } }] },
  });
  assert.equal(formatJsonTraceLine("claude", "crew-coder", line), "[TOOL] agent=crew-coder tool=Bash $ echo hi");
});

test("formatJsonTraceLine summarises a read/write/edit call by its path, and falls back to a JSON preview for anything else", () => {
  const readLine = JSON.stringify({
    type: "assistant",
    message: { content: [{ type: "tool_use", name: "Read", input: { file_path: "/a/b.js" } }] },
  });
  assert.equal(formatJsonTraceLine("claude", "crew-coder", readLine), "[TOOL] agent=crew-coder tool=Read /a/b.js");

  const mcpLine = JSON.stringify({
    type: "assistant",
    message: { content: [{ type: "tool_use", name: "mcp__thing", input: { query: "x" } }] },
  });
  assert.equal(
    formatJsonTraceLine("claude", "crew-coder", mcpLine),
    '[TOOL] agent=crew-coder tool=mcp__thing args={"query":"x"}',
  );
});

test("formatJsonTraceLine reads claude's failed tool_result", () => {
  const line = JSON.stringify({
    type: "user",
    message: { content: [{ type: "tool_result", tool_use_id: "t1", is_error: true }] },
  });
  assert.equal(formatJsonTraceLine("claude", "crew-coder", line), "[TOOL-ERROR] agent=crew-coder tool_use_id=t1");
});

// A run that dies on an API error (quota, auth) says so only in an event: without a line
// for it, the trace log and the orca tab both show nothing at all.
test("formatJsonTraceLine names a run-ending error from claude's result and copilot's session.error", () => {
  const claude = JSON.stringify({ type: "result", subtype: "success", is_error: true, result: "API Error: 403 forbidden" });
  assert.equal(formatJsonTraceLine("claude", "crew-coder", claude), '[AGENT-ERROR] agent=crew-coder error="API Error: 403 forbidden"');
  const copilot = JSON.stringify({ type: "session.error", data: { errorType: "quota", message: "You have exceeded your monthly quota" } });
  assert.equal(
    formatJsonTraceLine("copilot", "crew-coder", copilot),
    '[AGENT-ERROR] agent=crew-coder type=quota error="You have exceeded your monthly quota"',
  );
});

test("formatJsonTraceLine ignores claude's non-tool events and unparseable lines", () => {
  assert.equal(formatJsonTraceLine("claude", "crew-coder", JSON.stringify({ type: "result", result: "done" })), null);
  assert.equal(formatJsonTraceLine("claude", "crew-coder", "not json"), null);
});

test("formatJsonTraceLine reads copilot's tool.execution_start/complete (copilot-sdk session-events schema)", () => {
  const start = JSON.stringify({
    type: "tool.execution_start",
    data: { toolName: "bash", arguments: { command: "ls" } },
  });
  assert.equal(formatJsonTraceLine("copilot", "crew-coder", start), "[TOOL] agent=crew-coder tool=bash $ ls");
  const failed = JSON.stringify({
    type: "tool.execution_complete",
    data: { success: false, toolCallId: "c1", error: { message: "nope" } },
  });
  assert.equal(
    formatJsonTraceLine("copilot", "crew-coder", failed),
    '[TOOL-ERROR] agent=crew-coder toolCallId=c1 error="nope"',
  );
  const ok = JSON.stringify({ type: "tool.execution_complete", data: { success: true } });
  assert.equal(formatJsonTraceLine("copilot", "crew-coder", ok), null);
});

test("extractFinalText reads claude's terminal result line, not the last assistant message", () => {
  const lines = [
    JSON.stringify({ type: "assistant", message: { content: [{ type: "text", text: "intermediate" }] } }),
    JSON.stringify({ type: "result", result: "final answer" }),
  ];
  assert.equal(extractFinalText("claude", lines), "final answer");
  assert.equal(extractFinalText("claude", []), "");
});

test("extractFinalText reads copilot's last assistant.message (no terminal result event)", () => {
  const lines = [
    JSON.stringify({ type: "assistant.message", data: { content: "first turn" } }),
    JSON.stringify({ type: "tool.execution_start", data: {} }),
    JSON.stringify({ type: "assistant.message", data: { content: "final turn" } }),
  ];
  assert.equal(extractFinalText("copilot", lines), "final turn");
  assert.equal(extractFinalText("copilot", ["not json"]), "");
});

test("dispatch() writes only the final text to outFile, buffers a JSON line split across chunks, and traces the tool call live", async () => {
  const { root, promptFile } = fixture();
  const outFile = join(root, "dispatch", "alpha.report.md");
  const logFile = join(root, "trace.log");

  const stream =
    JSON.stringify({
      type: "assistant",
      message: { content: [{ type: "tool_use", id: "t1", name: "Bash", input: { command: "echo hi" } }] },
    }) +
    "\n" +
    JSON.stringify({ type: "result", result: "polo" }) +
    "\n";
  // An arbitrary mid-line split — proves the buffering in dispatch(), not just a
  // lucky one-chunk-per-line stream.
  const splitAt = 40;

  const fakeEffects = {
    spawnWithTimeout: async (cmd, args, { onLine }) => {
      onLine(stream.slice(0, splitAt));
      onLine(stream.slice(splitAt));
      return { code: 0, stdout: "", stderr: "", timedOut: false, dryRun: false };
    },
  };

  const result = await dispatch(
    fakeEffects,
    "claude",
    { agent: "crew-coder", cwd: root, promptFile, outFile, model: null, mainRoot: root, logFile, scriptsDir: SCRIPTS },
    {},
  );

  assert.equal(result.text, "polo", "outFile holds only the final assistant text, not the raw stream");
  assert.ok(existsSync(`${outFile}.events.jsonl`), "the raw stream is kept for post-hoc debugging");
  assert.equal(readFileSync(`${outFile}.events.jsonl`, "utf8").trim().split("\n").length, 2);
  const logged = readFileSync(logFile, "utf8");
  assert.match(logged, /\[TOOL\] agent=crew-coder tool=Bash/);
  // Every trace line in the file carries a date and a level, unconditionally.
  assert.match(logged, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z DEBUG \[TOOL\] /m);
});

test("dispatch() reports a claude dispatch killed on timeout as cost-unknown with its tokens", async () => {
  const { root, promptFile } = fixture();
  const outFile = join(root, "dispatch", "alpha.report.md");
  const stream =
    JSON.stringify({ type: "assistant", message: { id: "m1", content: [{ type: "text", text: "partial" }], usage: { input_tokens: 10, output_tokens: 5 } } }) + "\n";
  const fakeEffects = {
    spawnWithTimeout: async (cmd, args, { onLine }) => {
      onLine(stream);
      return { code: null, stdout: "", stderr: "", timedOut: true, dryRun: false };
    },
  };
  const result = await dispatch(
    fakeEffects,
    "claude",
    { agent: "crew-coder", cwd: root, promptFile, outFile, model: null, mainRoot: root, scriptsDir: SCRIPTS },
    {},
  );
  assert.equal(result.timedOut, true);
  assert.equal(result.costUnknown, true);
  assert.equal(result.costUsd, null);
  assert.equal(result.tokens, 15);
  assert.equal(result.numTurns, 1);
});

test("dispatch() tags every file-logged trace line with slug when the caller passes one", async () => {
  const { root, promptFile } = fixture();
  const outFile = join(root, "dispatch", "alpha.report.md");
  const logFile = join(root, "trace.log");
  const stream = JSON.stringify({ type: "result", result: "done" }) + "\n";
  const fakeEffects = {
    spawnWithTimeout: async (cmd, args, { onLine }) => {
      onLine(
        JSON.stringify({
          type: "assistant",
          message: { content: [{ type: "tool_use", name: "Bash", input: { command: "echo hi" } }] },
        }) + "\n",
      );
      onLine(stream);
      return { code: 0, stdout: "", stderr: "", timedOut: false, dryRun: false };
    },
  };
  await dispatch(
    fakeEffects,
    "claude",
    { agent: "crew-coder", cwd: root, promptFile, outFile, model: null, mainRoot: root, logFile, scriptsDir: SCRIPTS, slug: "alpha" },
    {},
  );
  assert.match(readFileSync(logFile, "utf8"), /^\S+Z DEBUG \[TOOL\] slug=alpha agent=crew-coder tool=Bash/m);
});

test("dispatch() throttles claude/copilot trace lines before calling onTrace, but writes every one to logFile", async () => {
  const { root, promptFile } = fixture();
  const outFile = join(root, "dispatch", "alpha.report.md");
  const logFile = join(root, "trace.log");
  const toolUse = (n) =>
    JSON.stringify({
      type: "assistant",
      message: { content: [{ type: "tool_use", name: "Bash", input: { command: `echo ${n}` } }] },
    }) + "\n";
  const fakeEffects = {
    spawnWithTimeout: async (cmd, args, { onLine }) => {
      for (let i = 1; i <= 7; i++) onLine(toolUse(i));
      onLine(JSON.stringify({ type: "result", result: "done" }) + "\n");
      return { code: 0, stdout: "", stderr: "", timedOut: false, dryRun: false };
    },
  };
  const traced = [];
  await dispatch(
    fakeEffects,
    "claude",
    { agent: "crew-coder", cwd: root, promptFile, outFile, model: null, mainRoot: root, logFile, scriptsDir: SCRIPTS },
    { onTrace: (line) => traced.push(line) },
  );
  assert.equal(traced.length, 1, "only the 5th of 7 tool calls should cross the heartbeat throttle");
  assert.match(traced[0], /tool=Bash \$ echo 5/);
  assert.equal(
    readFileSync(logFile, "utf8").trim().split("\n").filter((l) => l.includes("[TOOL]")).length,
    7,
    "the file gets every tool call, unthrottled",
  );
});

// ─── extractResultMeta: claude's cost/error/turn metadata, scoped to claude only ──────
test("extractResultMeta pulls cost/error/turns/session out of claude's terminal result event", () => {
  const lines = [
    JSON.stringify({ type: "assistant", message: { content: [{ type: "text", text: "hi" }] } }),
    JSON.stringify({
      type: "result",
      subtype: "success",
      is_error: false,
      total_cost_usd: 0.08,
      duration_ms: 2500,
      num_turns: 1,
      permission_denials: [],
      session_id: "abc123",
      result: "done",
    }),
  ];
  assert.deepEqual(extractResultMeta("claude", lines), {
    isError: false,
    subtype: "success",
    costUsd: 0.08,
    durationMs: 2500,
    numTurns: 1,
    permissionDenials: [],
    sessionId: "abc123",
    contextTokens: null,
    costUnknown: false,
    tokens: null,
  });
});

test("extractResultMeta's contextTokens is the last assistant turn's prompt size, not the session total", () => {
  const turn = (input, read, created) =>
    JSON.stringify({ type: "assistant", message: { usage: { input_tokens: input, cache_read_input_tokens: read, cache_creation_input_tokens: created, output_tokens: 50 } } });
  const lines = [turn(10, 1000, 200), turn(5, 30_000, 400), JSON.stringify({ type: "result", session_id: "s1", total_cost_usd: 0.5 })];
  assert.equal(extractResultMeta("claude", lines).contextTokens, 30_405);
});

test("extractResultMeta sums turns and agent time over every result event and takes the last cost", () => {
  const result = (cost, ms, turns, extra = {}) =>
    JSON.stringify({ type: "result", subtype: "success", is_error: false, total_cost_usd: cost, duration_ms: ms, num_turns: turns, session_id: "s1", ...extra });
  const meta = extractResultMeta("claude", [result(0.1, 1000, 3), result(0.35, 2500, 7), result(0.4, 500, 2)]);
  assert.equal(meta.numTurns, 12);
  assert.equal(meta.durationMs, 4000);
  assert.equal(meta.costUsd, 0.4);
  assert.equal(meta.costUnknown, false);
  assert.equal(meta.sessionId, "s1");
});

test("extractResultMeta reports a stream with no result event as cost-unknown, with its tokens and assistant turns", () => {
  const turn = (id, input, output) =>
    JSON.stringify({ type: "assistant", message: { id, usage: { input_tokens: input, cache_read_input_tokens: 100, cache_creation_input_tokens: 0, output_tokens: output } } });
  const lines = [turn("m1", 10, 20), turn("m1", 10, 20), turn("m2", 5, 7), JSON.stringify({ type: "user" })];
  const meta = extractResultMeta("claude", lines);
  assert.equal(meta.costUsd, null);
  assert.equal(meta.costUnknown, true);
  assert.equal(meta.tokens, 130 + 112);
  assert.equal(meta.numTurns, 2);
  assert.equal(meta.durationMs, null);
});

test("extractResultMeta returns the empty shape when the stream holds no events at all", () => {
  assert.deepEqual(extractResultMeta("claude", []), {
    isError: null,
    subtype: null,
    costUsd: null,
    durationMs: null,
    numTurns: null,
    permissionDenials: [],
    sessionId: null,
    contextTokens: null,
    costUnknown: false,
    tokens: null,
  });
});

test("extractResultMeta returns the empty shape for non-claude platforms — no confirmed equivalent field", () => {
  const lines = [JSON.stringify({ type: "result", is_error: true, total_cost_usd: 1 })];
  assert.deepEqual(extractResultMeta("copilot", lines), {
    isError: null,
    subtype: null,
    costUsd: null,
    durationMs: null,
    numTurns: null,
    permissionDenials: [],
    sessionId: null,
    contextTokens: null,
    costUnknown: false,
    tokens: null,
  });
});

test("extractResultMeta skips unparseable lines instead of throwing", () => {
  const lines = ["not json", JSON.stringify({ type: "result", is_error: true, permission_denials: [{ tool: "Bash" }] })];
  const meta = extractResultMeta("claude", lines);
  assert.equal(meta.isError, true);
  assert.equal(meta.permissionDenials.length, 1);
});

test("claude continues a session with --resume, and the prompt stays right after -p", () => {
  const { root, promptFile } = fixture();
  const args = buildDispatch("claude", spec(root, promptFile, { resumeSessionId: "sess-1" })).args;
  const i = args.indexOf("--resume");
  assert.notEqual(i, -1);
  assert.equal(args[i + 1], "sess-1");
  assert.equal(args[1], readFileSync(promptFile, "utf8"), "variadic flags cannot swallow a prompt that precedes them");
  assert.doesNotMatch(buildDispatch("claude", spec(root, promptFile)).args.join(" "), /--resume/);
});

test("dispatch() keeps an earlier attempt's event stream instead of overwriting it", async () => {
  const { root, promptFile } = fixture();
  const outFile = join(root, "dispatch", "alpha.report.md");
  const run = (cost) => {
    const stream = JSON.stringify({ type: "result", result: "ok", total_cost_usd: cost }) + "\n";
    const fakeEffects = { spawnWithTimeout: async (cmd, args, { onLine }) => (onLine(stream), { code: 0, stdout: "", stderr: "" }) };
    return dispatch(fakeEffects, "claude", { agent: "crew-coder", cwd: root, promptFile, outFile, mainRoot: root, scriptsDir: SCRIPTS }, {});
  };
  await run(0.1);
  await run(0.2);
  await run(0.3);
  const cost = (f) => JSON.parse(readFileSync(f, "utf8").trim()).total_cost_usd;
  assert.equal(cost(`${outFile}.events.jsonl`), 0.3, "the latest stays at the canonical path");
  assert.equal(cost(join(root, "dispatch", "alpha.report.md.events.1.jsonl")), 0.1);
  assert.equal(cost(join(root, "dispatch", "alpha.report.md.events.2.jsonl")), 0.2);
});

// A normal dispatch that had a tool call denied used to log [DISPATCH-FAIL] with a bare count,
// which read as a failed dispatch and said nothing about what was denied.
async function dispatchLogging(result, { code = 0 } = {}) {
  const { root, promptFile } = fixture();
  const outFile = join(root, "dispatch", "alpha.report.md");
  const logFile = join(root, "trace.log");
  const stream = `${JSON.stringify({ type: "result", ...result })}\n`;
  const fakeEffects = { spawnWithTimeout: async (cmd, args, { onLine }) => (onLine(stream), { code, stdout: "", stderr: "" }) };
  await dispatch(fakeEffects, "claude", { agent: "crew-coder", cwd: root, promptFile, outFile, mainRoot: root, logFile, scriptsDir: SCRIPTS, slug: "alpha" }, {});
  return existsSync(logFile) ? readFileSync(logFile, "utf8") : "";
}

test("dispatch() logs permission denials on a normal dispatch as a warning naming the tools", async () => {
  const denials = [{ tool_name: "Bash", tool_use_id: "t1" }, { tool_name: "WebFetch", tool_use_id: "t2" }, { tool_name: "Bash", tool_use_id: "t3" }];
  const log = await dispatchLogging({ result: "done", is_error: false, permission_denials: denials });
  assert.match(log, /^\S+Z WARN  \[DISPATCH-WARN\] agent=crew-coder slug=alpha code=0 permissionDenials=3 tools=Bash,WebFetch$/m);
  assert.doesNotMatch(log, /DISPATCH-FAIL/);
});

test("dispatch() still logs a real failure as DISPATCH-FAIL, denials included", async () => {
  const log = await dispatchLogging({ result: "", is_error: true, permission_denials: [{ tool_name: "Edit" }] }, { code: 1 });
  assert.match(log, /\[DISPATCH-FAIL\] agent=crew-coder slug=alpha code=1 .*isError=true permissionDenials=1 tools=Edit/);
  assert.doesNotMatch(log, /DISPATCH-WARN/);
});

test("dispatch() logs nothing for a clean dispatch", async () => {
  assert.equal(await dispatchLogging({ result: "done", is_error: false, permission_denials: [] }), "");
});

// afk.limits.<role>.usd. The result shape below is what claude 2.1.283 printed for
// `claude -p --max-budget-usd 0.01 --output-format stream-json`: exit 1, and no result text.
test("claude caps a dispatch with --max-budget-usd only when a cap is set", () => {
  const { root, promptFile } = fixture();
  const capped = buildDispatch("claude", { ...spec(root, promptFile), maxBudgetUsd: 2.5 }).args;
  const i = capped.indexOf("--max-budget-usd");
  assert.notEqual(i, -1);
  assert.equal(capped[i + 1], "2.5");
  assert.doesNotMatch(buildDispatch("claude", spec(root, promptFile)).args.join(" "), /--max-budget-usd/);
});

test("extractResultMeta carries claude's budget-cap subtype", () => {
  const lines = [JSON.stringify({ type: "result", subtype: "error_max_budget_usd", is_error: true, terminal_reason: "budget_exhausted", total_cost_usd: 0.09, result: null, errors: ["Reached maximum budget ($0.01)"] })];
  const meta = extractResultMeta("claude", lines);
  assert.equal(meta.subtype, "error_max_budget_usd");
  assert.equal(meta.isError, true);
});

test("a coder's targeted test run measures from the feature branch it was cut from", () => {
  const { root, promptFile } = fixture();
  for (const platform of ["pi", "codex", "claude", "copilot"]) {
    assert.equal(buildDispatch(platform, spec(root, promptFile, { baseRef: "feature/demo" })).env.CREW_BASE_REF, "feature/demo", platform);
    assert.equal("CREW_BASE_REF" in buildDispatch(platform, spec(root, promptFile, { agent: "crew-reviewer", baseRef: "feature/demo" })).env, false, platform);
  }
});

test("only crew-coder dispatches set CREW_DEFER_FULL_CHECKS, on every runtime", () => {
  const { root, promptFile } = fixture();
  for (const platform of ["claude", "copilot", "pi", "codex"]) {
    assert.equal(buildDispatch(platform, spec(root, promptFile)).env.CREW_DEFER_FULL_CHECKS, "1", platform);
    for (const agent of ["crew-reviewer", "crew-triage"]) {
      assert.equal("CREW_DEFER_FULL_CHECKS" in buildDispatch(platform, spec(root, promptFile, { agent })).env, false, `${platform} ${agent}`);
    }
  }
});

// ─── doctor: --help flag probe ───────────────────────────────────────────────

test("the flag probe reads a help text that folds a flag's variant into brackets", () => {
  // claude 2.1's --help lists the file form only as `--append-system-prompt[-file]`.
  const help = ({ exec: (cmd, args) => (args[0] === "-c" ? { code: 0, stdout: "/bin/x", stderr: "" } : { code: 0, stdout: "  --permission-mode <m>\n  --output-format <f>\n  --add-dir <d>\n  --append-system-prompt <p>\n     … also --append-system-prompt[-file], --add-dir\n", stderr: "" }) });
  assert.deepEqual(preflight(help, "claude", { probeFlags: true }), []);
});

test("preflight with probeFlags reports a PROBLEM when --help omits a flag the adapter needs", async () => {
  const { ADAPTERS } = await import("../../orchestrator/lib/adapters/index.mjs");
  for (const platform of ["pi", "codex", "claude", "copilot"]) {
    const { requiredFlags } = ADAPTERS[platform];
    assert.ok(requiredFlags.length, `${platform} declares requiredFlags`);
    const helpWith = (flags) => ({ exec: (cmd, args) => (args[0] === "-c" ? { code: 0, stdout: "/bin/x", stderr: "" } : { code: 0, stdout: flags.join("\n"), stderr: "" }) });
    assert.deepEqual(preflight(helpWith(requiredFlags), platform, { probeFlags: true }), []);
    const out = preflight(helpWith(requiredFlags.slice(1)), platform, { probeFlags: true });
    assert.equal(out.length, 1);
    assert.match(out[0], new RegExp(requiredFlags[0]));
  }
});

test("the coder's protocol ends with each named skill's installed SKILL.md, per platform and scope", async () => {
  const { renderRolePrompt } = await import("../../orchestrator/lib/adapters/render.mjs");
  const main = mkdtempSync(join(tmpdir(), "skills-main-"));
  const home = mkdtempSync(join(tmpdir(), "skills-home-"));
  mkdirSync(join(main, ".agents/skills/solve-issue"), { recursive: true });
  writeFileSync(join(main, ".agents/skills/solve-issue/SKILL.md"), "x");
  mkdirSync(join(home, ".agents/skills/dep-install"), { recursive: true });
  writeFileSync(join(home, ".agents/skills/dep-install/SKILL.md"), "x");
  const saved = process.env.HOME;
  process.env.HOME = home;
  try {
    const text = renderRolePrompt("coder", "codex", { mainRoot: main });
    assert.match(text, /## Installed skills/);
    assert.ok(text.includes(`\`solve-issue\`: ${join(main, ".agents/skills/solve-issue/SKILL.md")}`), "the project install");
    assert.ok(text.includes(`\`dep-install\`: ${join(home, ".agents/skills/dep-install/SKILL.md")}`), "the user-level install");
    assert.match(text, /`tdd`: not installed/);
    assert.match(text, /BLOCKED: solve-issue skill not installed/);
  } finally {
    process.env.HOME = saved;
  }
});

test("codex: a plain role (command finder, feature planner, PR writer) runs read-only, writing only its result", () => {
  const { root, promptFile } = fixture();
  const b = buildDispatch("codex", { agent: "pr-writer", cwd: root, mainRoot: root, promptFile, outFile: join(root, "dispatch/pr-writer.md") });
  assert.equal(b.args.includes("sandbox_workspace_write.network_access=true"), false);
  assert.equal(b.args.at(b.args.indexOf("--cd") + 1), join(realpathSync(root), "dispatch"));
});
