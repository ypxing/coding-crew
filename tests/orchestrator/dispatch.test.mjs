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

import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  buildDispatch,
  buildHerdrInvocation,
  closeHerdrPane,
  closeHerdrWorkspace,
  dispatch,
  dispatchPlain,
  dispatchViaHerdr,
  extractFinalText,
  extractHerdrReply,
  herdrAgentName,
  herdrDispatchName,
  formatJsonTraceLine,
  preflight,
  resolveAgentFile,
  splitFrontmatter,
  DEFAULT_PARALLEL,
} from "../../orchestrator/lib/dispatch.mjs";
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

test("codex dispatches through its own script, pinned to the issue's worktree", () => {
  const { root, promptFile } = fixture();
  const b = buildDispatch("codex", spec(root, promptFile));
  assert.equal(b.cmd, "bash");
  assert.equal(b.args[0], join(SCRIPTS, "dispatch-codex-agent.sh"));
  assert.equal(b.capture, "file");
  const argv = b.args.join(" ");
  assert.match(argv, /--agent crew-coder/);
  assert.match(argv, new RegExp(`--dir ${join(root, "worktree")}`));
  assert.match(argv, /--out .*alpha\.report\.md/);
  // The worker's log goes to the sprint trace; the dispatcher writes its own DISPATCH line.
  assert.match(argv, /--log .*trace\.log/);
  // The script cds into --dir itself, so it runs from the main checkout.
  assert.equal(b.cwd, root);
  assert.equal(b.env.CREW_ORCHESTRATED, "1");
  assert.equal(b.env.MAIN_ROOT, root);
});

test("codex is not handed pi's dispatcher, and pi is not handed codex's", () => {
  const { root, promptFile } = fixture();
  assert.match(buildDispatch("codex", spec(root, promptFile)).args[0], /dispatch-codex-agent\.sh$/);
  assert.match(buildDispatch("pi", spec(root, promptFile)).args[0], /dispatch-agent\.sh$/);
});

test("no model resolves to no --model flag (what `--model inherit` means)", () => {
  const { root, promptFile } = fixture();
  for (const platform of ["codex", "pi"]) {
    const argv = buildDispatch(platform, spec(root, promptFile, { model: null })).args.join(" ");
    assert.doesNotMatch(argv, /--model/, `${platform} invented a model`);
  }
  const withModel = buildDispatch("codex", spec(root, promptFile, { model: "gpt-5" })).args.join(" ");
  assert.match(withModel, /--model gpt-5/);
});

test("the reviewer runs from the main checkout, on the same model as the coder", () => {
  const { root, promptFile } = fixture();
  const b = buildDispatch(
    "codex",
    spec(root, promptFile, {
      agent: "crew-code-reviewer",
      cwd: root,
      outFile: join(root, "dispatch/alpha.review.md"),
      model: "gpt-5",
    }),
  );
  const argv = b.args.join(" ");
  assert.match(argv, /--agent crew-code-reviewer/);
  assert.match(argv, new RegExp(`--dir ${root}`));
  assert.match(argv, /--model gpt-5/);
});

test("codex resolves its agent definition from the project, then the home, TOML", () => {
  const { root } = fixture();
  assert.equal(resolveAgentFile("codex", root, "crew-coder"), null);
  mkdirSync(join(root, ".codex/agents"), { recursive: true });
  const file = join(root, ".codex/agents/crew-coder.toml");
  writeFileSync(file, 'name = "crew-coder"\n');
  assert.equal(resolveAgentFile("codex", root, "crew-coder"), file);
});

test("a missing codex agent definition is a preflight failure naming the fix", () => {
  const { root } = fixture();
  const effects = { exec: () => ({ code: 0, stdout: "/usr/bin/codex", stderr: "" }) };
  const problems = preflight(effects, "codex", root, ["crew-coder", "crew-code-reviewer"]);
  assert.equal(problems.length, 2);
  assert.match(problems[0], /crew-coder agent definition not installed for codex/);
  assert.match(problems[0], /\.\/install\.sh codex --skill crew-afk/);
});

test("a missing CLI is a preflight failure, not a first-dispatch failure", () => {
  const { root } = fixture();
  mkdirSync(join(root, ".codex/agents"), { recursive: true });
  writeFileSync(join(root, ".codex/agents/crew-coder.toml"), 'name = "crew-coder"\n');
  const effects = { exec: () => ({ code: 1, stdout: "", stderr: "" }) };
  const problems = preflight(effects, "codex", root, ["crew-coder"]);
  assert.deepEqual(problems, ["codex CLI not found on PATH"]);
});

test("splitFrontmatter keeps the agent body and drops the YAML head", () => {
  const { frontmatter, body } = splitFrontmatter("---\nname: crew-coder\ntools: bash\n---\nDo the work.\n");
  assert.equal(frontmatter.name, "crew-coder");
  assert.equal(body, "Do the work.\n");
});

// ─── claude ──────────────────────────────────────────────────────────────────
//
// The claude cutover deleted the prose body that used to carry these: "dispatch in
// batches of 3", "call the Agent tool with isolation: worktree", and the permission
// paragraph. They are adapter facts now, so they are asserted on the adapter.

test("a claude worker is its own process, in its own worktree, under bypassPermissions", () => {
  const { root, promptFile } = fixture();
  const b = buildDispatch("claude", spec(root, promptFile));
  assert.equal(b.cmd, "claude");
  assert.equal(b.capture, "stdout");
  // The worktree is the cwd, so isolation does not depend on Claude's runtime managing it
  // (`isolation: worktree`) nor on the worker obeying a directory line in its prompt.
  assert.equal(b.cwd, join(root, "worktree"));
  const argv = b.args.join(" ");
  assert.match(argv, /^-p /);
  assert.match(argv, /--agent crew-coder/);
  assert.match(argv, /--permission-mode bypassPermissions/);
  assert.match(argv, new RegExp(`--add-dir ${root}`), "the main checkout holds .scratch/ and the issue files");
  // --output-format stream-json --verbose replaces plain text output: JSONL tool-call
  // events for live tracing (see dispatch()/formatJsonTraceLine), with the terminal
  // `result` line's `.result` as the report (see extractFinalText).
  assert.match(argv, /--output-format stream-json/);
  assert.match(argv, /--verbose/);
  assert.equal(b.jsonEvents, "claude");
  assert.equal(b.args.at(-1), "prompt body", "the prompt is the positional argument");
  assert.equal(b.env.CREW_ORCHESTRATED, "1");
});

test("claude is handed the agent name only — the definition is never re-sent", () => {
  // Verified against Claude Code 2.1.221: `--agent <name>` loads the project-level
  // definition, enforces its `tools:` list, and exits 1 when the name is unknown. An
  // appended body would duplicate what is already loaded and override it on conflict.
  const { root, promptFile } = fixture();
  mkdirSync(join(root, ".claude/agents"), { recursive: true });
  writeFileSync(join(root, ".claude/agents/crew-coder.md"), "---\nname: crew-coder\n---\nBody.\n");
  const argv = buildDispatch("claude", spec(root, promptFile)).args.join(" ");
  assert.doesNotMatch(argv, /--append-system-prompt/);
  assert.doesNotMatch(argv, /Body\./);
});

test("claude resolves its agent definition from the project, then the home dir", () => {
  const { root } = fixture();
  assert.equal(resolveAgentFile("claude", root, "crew-coder"), null);
  mkdirSync(join(root, ".claude/agents"), { recursive: true });
  const file = join(root, ".claude/agents/crew-coder.md");
  writeFileSync(file, "---\nname: crew-coder\n---\n");
  assert.equal(resolveAgentFile("claude", root, "crew-coder"), file);
});

test("a missing claude agent definition is a preflight failure naming the fix", () => {
  const { root } = fixture();
  const effects = { exec: () => ({ code: 0, stdout: "/usr/bin/claude", stderr: "" }) };
  const problems = preflight(effects, "claude", root, ["crew-coder"]);
  assert.equal(problems.length, 1);
  assert.match(problems[0], /crew-coder agent definition not installed for claude/);
  assert.match(problems[0], /\.\/install\.sh claude --skill crew-afk/);
});

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

test("a copilot worker is its own process, in its own worktree, with the main root added", () => {
  const { root, promptFile } = fixture();
  const b = buildDispatch("copilot", spec(root, promptFile));
  assert.equal(b.cmd, "copilot");
  assert.equal(b.capture, "stdout");
  // Isolation is the cwd now, not a "Working directory:" line a subagent had to obey while
  // sharing this session's working root.
  assert.equal(b.cwd, join(root, "worktree"));
  const argv = b.args.join(" ");
  assert.match(argv, /^-p /);
  assert.match(argv, /--agent crew-coder/);
  assert.match(argv, new RegExp(`-C ${join(root, "worktree")}`));
  // The worker reads the issue file and writes <slug>.report.json under the main root.
  assert.match(argv, new RegExp(`--add-dir ${root}`));
  assert.match(argv, /--allow-all-tools/, "an unattended sprint cannot answer a permission prompt");
  // --output-format json replaces --silent: JSONL tool-call events for live tracing
  // (see dispatch()/formatJsonTraceLine), with the final assistant.message as the report.
  assert.match(argv, /--output-format json/);
  assert.doesNotMatch(argv, /--silent/);
  assert.equal(b.jsonEvents, "copilot");
  assert.equal(b.env.CREW_ORCHESTRATED, "1");
  assert.equal(b.env.MAIN_ROOT, root);
});

test("copilot is handed the agent name only — the definition is never prepended", () => {
  // The body prepend duplicated a definition the CLI loads itself, and could not have
  // rescued an unresolvable name: copilot exits before it reads the prompt.
  const { root, promptFile } = fixture();
  mkdirSync(join(root, ".github/agents"), { recursive: true });
  writeFileSync(join(root, ".github/agents/crew-coder.agent.md"), "---\nname: crew-coder\n---\nBody.\n");
  const b = buildDispatch("copilot", spec(root, promptFile));
  assert.equal(b.args[1], "prompt body", "the prompt is passed as-is");
  assert.doesNotMatch(b.args.join(" "), /Body\./);
});

test("copilot resolves its agent definition from .github/agents, then ~/.copilot/agents", () => {
  const { root } = fixture();
  assert.equal(resolveAgentFile("copilot", root, "crew-coder"), null);
  mkdirSync(join(root, ".github/agents"), { recursive: true });
  const file = join(root, ".github/agents/crew-coder.agent.md");
  writeFileSync(file, "---\nname: crew-coder\n---\n");
  assert.equal(resolveAgentFile("copilot", root, "crew-coder"), file);
});

test("a copilot definition invisible from a worktree is a preflight failure naming both fixes", () => {
  // Copilot resolves --agent from the worker's cwd, so an *untracked* definition in the main
  // root is installed and unreachable: without this check every worker dies on `No such
  // agent` after the sprint has already started, and a dead dispatch used to be the moment
  // the orchestrator started implementing issues itself.
  const { root } = fixture();
  mkdirSync(join(root, ".github/agents"), { recursive: true });
  writeFileSync(join(root, ".github/agents/crew-coder.agent.md"), "---\nname: crew-coder\n---\n");
  const effects = {
    exec: () => ({ code: 0, stdout: "/usr/bin/copilot", stderr: "" }),
    gitRead: () => ({ code: 1, stdout: "", stderr: "" }), // not in HEAD
  };
  const problems = preflight(effects, "copilot", root, ["crew-coder"]);
  assert.equal(problems.length, 1);
  assert.match(problems[0], /not visible from a worktree/);
  assert.match(problems[0], /Commit \.github\/agents\/crew-coder\.agent\.md/);
  assert.match(problems[0], /TARGET_REPO=\$HOME \.\/install\.sh copilot --skill crew-afk/);
});

test("a copilot definition tracked in HEAD passes preflight", () => {
  const { root } = fixture();
  mkdirSync(join(root, ".github/agents"), { recursive: true });
  writeFileSync(join(root, ".github/agents/crew-coder.agent.md"), "---\nname: crew-coder\n---\n");
  const asked = [];
  const effects = {
    exec: () => ({ code: 0, stdout: "/usr/bin/copilot", stderr: "" }),
    gitRead: (args) => {
      asked.push(args.join(" "));
      return { code: 0, stdout: "", stderr: "" };
    },
  };
  assert.deepEqual(preflight(effects, "copilot", root, ["crew-coder"]), []);
  assert.ok(
    asked.some((a) => a.includes("HEAD:.github/agents/crew-coder.agent.md")),
    "the check is against HEAD, which is what a worktree checks out",
  );
});

test("a missing copilot agent definition is still the ordinary preflight failure", () => {
  const { root } = fixture();
  const effects = {
    exec: () => ({ code: 0, stdout: "/usr/bin/copilot", stderr: "" }),
    gitRead: () => ({ code: 1, stdout: "", stderr: "" }),
  };
  const problems = preflight(effects, "copilot", root, ["crew-coder"]);
  assert.equal(problems.length, 1);
  assert.match(problems[0], /crew-coder agent definition not installed for copilot/);
  assert.match(problems[0], /\.\/install\.sh copilot --skill crew-afk/);
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

test("the copilot reviewer runs from the main checkout, read-only by its definition", () => {
  const { root, promptFile } = fixture();
  const b = buildDispatch(
    "copilot",
    spec(root, promptFile, {
      agent: "crew-code-reviewer",
      cwd: root,
      outFile: join(root, "dispatch/alpha.review.md"),
    }),
  );
  const argv = b.args.join(" ");
  assert.match(argv, /--agent crew-code-reviewer/);
  assert.match(argv, new RegExp(`-C ${root}`));
  // --allow-all-tools removes the confirmation prompt, not the definition's tools: list —
  // probed: an agent declaring `tools: ["view"]` has no shell under it.
  assert.match(argv, /--allow-all-tools/);
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

async function recordedArgv(platform, over = {}) {
  const effects = new Effects({ scriptsDir: SCRIPTS, mainRoot: "/tmp/does-not-run", dryRun: true });
  await dispatchPlain(effects, platform, {
    prompt: "the whole prompt",
    cwd: "/tmp/does-not-run",
    mainRoot: "/tmp/does-not-run",
    outFile: null,
    ...over,
  });
  return effects.recorded.at(-1).argv;
}

test("pi dispatchPlain never gets a --no-tools/--no-context-files flag", async () => {
  const argv = await recordedArgv("pi", {});
  assert.deepEqual(argv, ["pi", "-p", "the whole prompt"]);
});

test("claude dispatchPlain never gets a --tools flag", async () => {
  const argv = await recordedArgv("claude", { mainRoot: "/tmp/does-not-run" });
  assert.equal(argv.includes("--tools"), false);
});

test("claude dispatchPlain with a model still gets the prompt as its own argument, not swallowed by --model", async () => {
  const argv = await recordedArgv("claude", { mainRoot: "/tmp/does-not-run", model: "opus" });
  assert.equal(argv.includes("the whole prompt"), true);
  assert.deepEqual(argv.slice(-2), ["--model", "opus"]);
});

test("claude dispatchPlain with no model still gets the prompt as its own argument, not swallowed by --add-dir", async () => {
  // Regression: --add-dir is variadic (`<directories...>`). With no --model in between
  // (the default), a prompt placed after --add-dir's value used to be consumed as a
  // second directory instead of claude's -p positional argument, so claude saw no
  // prompt at all and exited 1 with "Input must be provided either through stdin or as
  // a prompt argument" — surfaced as "Command discovery: model dispatch did not complete
  // (exit 1)". The prompt must sit right after -p, before --add-dir, so no flag's arity
  // can ever swallow it.
  const argv = await recordedArgv("claude", { mainRoot: "/tmp/does-not-run", model: null });
  assert.deepEqual(argv, [
    "claude",
    "-p",
    "the whole prompt",
    "--permission-mode",
    "bypassPermissions",
    "--add-dir",
    "/tmp/does-not-run",
  ]);
});

test("model still comes through, in the same order as before", async () => {
  const argv = await recordedArgv("pi", { model: "gemini-flash" });
  assert.deepEqual(argv, ["pi", "-p", "--model", "gemini-flash", "the whole prompt"]);
});

// dispatchPlain is always a one-shot, stateless reasoning pass — command discovery
// re-derives its answer from a source hash every run, coverage validation from the current
// diff — so nothing here benefits from persisting across runs, and auto-memory's project
// directory is shared across every worktree, while this dispatch gets full write-tool
// access before any worktree exists.
test("claude dispatchPlain disables auto-memory", async () => {
  const effects = new Effects({ scriptsDir: SCRIPTS, mainRoot: "/tmp/does-not-run", dryRun: true });
  await dispatchPlain(effects, "claude", {
    prompt: "the whole prompt",
    cwd: "/tmp/does-not-run",
    mainRoot: "/tmp/does-not-run",
    outFile: null,
  });
  assert.equal(effects.recorded.at(-1).env.CLAUDE_CODE_DISABLE_AUTO_MEMORY, "1");
});

// Command discovery's own probe hit this for real: dispatched from inside a Claude Code
// session, the child inherited the parent's CLAUDE_CODE_SESSION_ID/CLAUDE_CODE_CHILD_SESSION,
// attached to its hook chain, and a global UserPromptSubmit hook rewrote the prompt into
// something claude answered with its default "your message came through empty" greeting
// instead of the discovery question — no cache, no error, just a silent fallback.
test("claude dispatchPlain clears the parent session's id so the child starts its own", async () => {
  const effects = new Effects({ scriptsDir: SCRIPTS, mainRoot: "/tmp/does-not-run", dryRun: true });
  await dispatchPlain(effects, "claude", {
    prompt: "the whole prompt",
    cwd: "/tmp/does-not-run",
    mainRoot: "/tmp/does-not-run",
    outFile: null,
  });
  assert.equal(effects.recorded.at(-1).env.CLAUDE_CODE_SESSION_ID, "");
  assert.equal(effects.recorded.at(-1).env.CLAUDE_CODE_CHILD_SESSION, "");
});

test("pi and codex dispatchPlain get no auto-memory env var — the flag is claude-specific", async () => {
  for (const platform of ["pi", "codex", "copilot"]) {
    const effects = new Effects({ scriptsDir: SCRIPTS, mainRoot: "/tmp/does-not-run", dryRun: true });
    await dispatchPlain(effects, platform, {
      prompt: "the whole prompt",
      cwd: "/tmp/does-not-run",
      mainRoot: "/tmp/does-not-run",
      outFile: null,
    });
    assert.equal("CLAUDE_CODE_DISABLE_AUTO_MEMORY" in effects.recorded.at(-1).env, false);
  }
});

// ─── json-stream visibility (claude, copilot) ────────────────────────────────
//
// pi and codex keep their own bash-side trace_event (dispatch-agent.sh,
// dispatch-codex-agent.sh); claude and copilot have no bash dispatcher, so the same
// "live [TOOL]/[TOOL-ERROR] line while the worker is still running" behaviour lives
// here, driven by formatJsonTraceLine/extractFinalText and dispatch()'s onLine wiring.

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
  // PR 3: every trace line in the file carries a timestamp, unconditionally.
  assert.match(logged, /^\[\d{2}:\d{2}:\d{2}Z\] /m);
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
  assert.match(readFileSync(logFile, "utf8"), /^\[\d{2}:\d{2}:\d{2}Z\] slug=alpha \[TOOL\] agent=crew-coder tool=Bash/m);
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

test("dispatch() wires onLine for pi/codex too, but only forwards their own already-throttled [TOOL] line to onTrace — not the raw event stream", async () => {
  const { root, promptFile } = fixture();
  const outFile = join(root, "dispatch", "alpha.report.md");
  let sawOnLine;
  const fakeEffects = {
    spawnWithTimeout: async (cmd, args, opts) => {
      sawOnLine = opts.onLine;
      opts.onLine('{"type":"tool_execution_start","toolName":"bash"}\n');
      opts.onLine("[TOOL] agent=crew-coder tool=bash $ ls\n");
      return { code: 0, stdout: "", stderr: "", timedOut: false, dryRun: false };
    },
  };
  const traced = [];
  await dispatch(
    fakeEffects,
    "pi",
    { agent: "crew-coder", cwd: root, promptFile, outFile, model: null, mainRoot: root, logFile: join(root, "trace.log"), scriptsDir: SCRIPTS },
    { onTrace: (line) => traced.push(line) },
  );
  assert.equal(typeof sawOnLine, "function", "onLine is wired unconditionally now, not just for claude/copilot");
  assert.equal(existsSync(`${outFile}.events.jsonl`), false, "pi/codex still write their own report file, not dispatch.mjs");
  assert.deepEqual(traced, ["[TOOL] agent=crew-coder tool=bash $ ls\n".trimEnd()]);
});

// ─── herdr (https://herdr.dev), verified live against 0.8.2 ─────────────────
//
// herdr drives an interactive REPL agent (idle/working/blocked/done), not a `-p` batch run,
// so dispatchViaHerdr is a second path, not a buildDispatch branch — see its doc comment.
// These fixtures are the actual JSON shapes/transcript text captured from a real
// workspace-create → tab-create → agent-start → agent-prompt → agent-read round-trip.

// herdrExec now runs through spawnWithTimeout (async spawn), not exec (blocking spawnSync)
// — see herdrExec's doc comment in dispatch.mjs for why a blocking call silently serialised
// every herdr-enabled sprint regardless of --max-parallel.
function fakeHerdrEffects(responses, { mainRoot = "/root", dryRun = false } = {}) {
  const calls = [];
  return {
    mainRoot,
    dryRun,
    _calls: calls,
    spawnWithTimeout: async (cmd, args) => {
      calls.push([cmd, ...args]);
      const next = responses.shift();
      if (!next) throw new Error(`no more canned herdr responses — call was: ${cmd} ${args.join(" ")}`);
      return next;
    },
    // buildHerdrInvocation's codex branch reads this for the writable-roots sandbox fix
    // (see dispatch-codex-agent.sh's identical one) — a plain relative ".git" is enough for
    // these fixtures, which never actually run git.
    gitRead: () => ({ code: 0, stdout: ".git\n", stderr: "" }),
  };
}
const json = (obj) => ({ code: 0, stdout: JSON.stringify(obj), stderr: "" });
// herdr's own contract (`herdr --skill`): "CLI server errors are JSON on stderr with exit
// status 1" — confirmed against a real server, where agent_not_ready landed on stderr.
const err = (code, message, errCode) => ({ code, stdout: "", stderr: JSON.stringify({ error: { code: errCode, message } }) });

// ensureHerdrWorkspace opens a log tab right after creating the shared workspace, whenever
// spec.logFile is set (it is, by spec()'s default) — every canned-response list below that
// starts with a workspace-create response needs these two responses spliced in right after
// it, since that's the only call site that ever triggers the log tab (see its own tests
// further down).
const herdrLogTabResponses = () => [
  json({ result: { tab: { tab_id: "w1:log" }, root_pane: { pane_id: "w1:plog" } } }), // log tab create
  json({ result: { type: "ok" } }), // pane run tail -f
];

const RENDERED_REPLY = [
  " ▐▛███▛█   Claude Code v2.1.263",
  "",
  "❯ Reply with exactly: herdr spike ok",
  "",
  "● herdr spike ok",
  "",
  "✻ Worked for 2s · done 7:57 AM",
  "",
].join("\n");

const COPILOT_RENDERED_REPLY = [
  " ● Selected custom agent: crew-coder",
  "",
  " ❯ Reply with exactly: herdr spike ok                                                08:54",
  "",
  " herdr spike ok",
  "",
  " ~/repo [master]                                                        Session: 0 AIC used",
  "─────────────────────────────",
  " ❯",
].join("\n");

test("herdrAgentName sanitises issue slugs into herdr's ^[a-z][a-z0-9_-]{0,31}$ contract", () => {
  assert.equal(herdrAgentName("Implement-User-Auth"), "implement-user-auth");
  assert.equal(herdrAgentName("123-numeric-lead").length <= 32, true);
  assert.match(herdrAgentName("123-numeric-lead"), /^[a-z][a-z0-9_-]{0,31}$/);
  assert.match(
    herdrAgentName("implement-a-very-long-descriptive-issue-slug-that-exceeds-the-limit"),
    /^[a-z][a-z0-9_-]{0,31}$/,
  );
  assert.match(herdrAgentName(""), /^[a-z][a-z0-9_-]{0,31}$/);
});

test("herdrDispatchName gives coder/review/triage distinct, human-readable pane names for the same issue slug — no worker reuses another's pane", () => {
  const coder = herdrDispatchName("implement-user-auth", "crew-coder");
  const review = herdrDispatchName("implement-user-auth", "crew-code-reviewer");
  const triage = herdrDispatchName("implement-user-auth", "crew-triage");
  assert.equal(coder, "implement-user-auth-coder");
  assert.equal(review, "implement-user-auth-review");
  assert.equal(triage, "implement-user-auth-triage");
  assert.equal(new Set([coder, review, triage]).size, 3, "each role gets its own pane name");
  for (const name of [coder, review, triage]) assert.match(name, /^[a-z][a-z0-9_-]{0,31}$/);
});

test("herdrDispatchName is deterministic and stable across repeated calls for the same (label, agent)", () => {
  assert.equal(herdrDispatchName("implement-user-auth", "crew-coder"), herdrDispatchName("implement-user-auth", "crew-coder"));
});

test("herdrDispatchName prefixes the issue number, leading with a letter since herdr forbids a leading digit", () => {
  const coder = herdrDispatchName("implement-user-auth", "crew-coder", "42");
  const review = herdrDispatchName("implement-user-auth", "crew-code-reviewer", "42");
  assert.equal(coder, "i42-implement-user-auth-coder");
  assert.equal(review, "i42-implement-user-auth-review");
  assert.match(coder, /^[a-z][a-z0-9_-]{0,31}$/);
});

test("herdrDispatchName omits the issue-number prefix when none is given, unchanged from before issue numbers existed", () => {
  assert.equal(herdrDispatchName("implement-user-auth", "crew-coder", null), "implement-user-auth-coder");
  assert.equal(herdrDispatchName("implement-user-auth", "crew-coder", undefined), "implement-user-auth-coder");
});

test("herdrDispatchName still fits herdr's 32-char cap with an issue number and a long slug, falling back to the hash", () => {
  const label = "implement-a-very-long-descriptive-issue-slug-that-exceeds-the-limit";
  const name = herdrDispatchName(label, "crew-coder", "7");
  assert.match(name, /^[a-z][a-z0-9_-]{0,31}$/);
  assert.match(name, /^i7-.*-coder-[0-9a-f]{6}$/);
});

test("herdrDispatchName keeps the role tag and hash intact even when the label alone would fill herdr's 32-char limit", () => {
  const label = "implement-a-very-long-descriptive-issue-slug-that-exceeds-the-limit";
  const coder = herdrDispatchName(label, "crew-coder");
  const review = herdrDispatchName(label, "crew-code-reviewer");
  assert.match(coder, /^[a-z][a-z0-9_-]{0,31}$/);
  assert.match(review, /^[a-z][a-z0-9_-]{0,31}$/);
  assert.match(coder, /-coder-[0-9a-f]{6}$/);
  assert.match(review, /-review-[0-9a-f]{6}$/);
  assert.notEqual(coder, review, "truncation must never make two roles collide");
});

test("herdrDispatchName never collides across two different issue slugs, even when both truncate to the same 32-char prefix", () => {
  const longPrefix = "a".repeat(40);
  const slugA = `${longPrefix}-issue-one`;
  const slugB = `${longPrefix}-issue-two`;
  // Both slugs share the same first 32+ characters, so herdrAgentName's own truncation alone
  // would collapse them onto the identical base — the hash suffix is what tells them apart.
  assert.equal(herdrAgentName(slugA), herdrAgentName(slugB));
  const nameA = herdrDispatchName(slugA, "crew-coder");
  const nameB = herdrDispatchName(slugB, "crew-coder");
  assert.notEqual(nameA, nameB, "two different issues must never share a coder's pane, even under truncation");
  assert.match(nameA, /^[a-z][a-z0-9_-]{0,31}$/);
  assert.match(nameB, /^[a-z][a-z0-9_-]{0,31}$/);
});

test("extractHerdrReply pulls the reply from between the echoed prompt and the trailing status line", () => {
  assert.equal(extractHerdrReply(RENDERED_REPLY, "Reply with exactly: herdr spike ok"), "herdr spike ok");
});

test("extractHerdrReply returns empty when the prompt was never echoed back (a truncated or unrelated read)", () => {
  assert.equal(extractHerdrReply("some unrelated pane text", "Reply with exactly: herdr spike ok"), "");
});

test("preflightHerdr (via preflight's herdr option) fails when the herdr CLI is missing", () => {
  const { root } = fixture();
  const effects = {
    exec: (cmd, args) => {
      if (cmd === "sh" && args[1]?.includes("herdr")) return { code: 1, stdout: "", stderr: "" };
      return { code: 0, stdout: "/usr/bin/claude", stderr: "" };
    },
  };
  const problems = preflight(effects, "claude", root, [], { herdr: true });
  assert.deepEqual(problems, ["HERDR_ENV=1 but the herdr CLI was not found on PATH"]);
});

test("preflightHerdr fails when herdr's server is not running", () => {
  const { root } = fixture();
  const effects = {
    exec: (cmd, args) => {
      if (cmd === "sh") return { code: 0, stdout: "/usr/local/bin/herdr", stderr: "" };
      if (args[0] === "status") return { code: 0, stdout: "server:\n  status: not running\n", stderr: "" };
      return { code: 0, stdout: "", stderr: "" };
    },
  };
  const problems = preflight(effects, "claude", root, [], { herdr: true });
  assert.deepEqual(problems, ["HERDR_ENV=1 but the herdr server is not running — start it with: herdr server"]);
});

test("preflightHerdr passes when herdr is on PATH and its server is running", () => {
  const { root } = fixture();
  const effects = {
    exec: (cmd, args) => {
      if (cmd === "sh") return { code: 0, stdout: "/usr/local/bin/herdr", stderr: "" };
      if (args[0] === "status") return { code: 0, stdout: "server:\n  status: running\n", stderr: "" };
      return { code: 0, stdout: "", stderr: "" };
    },
  };
  assert.deepEqual(preflight(effects, "claude", root, [], { herdr: true }), []);
});

test("dispatchViaHerdr under --dry-run runs nothing and reports dryRun: true", async () => {
  const { root, promptFile } = fixture();
  const effects = fakeHerdrEffects([], { mainRoot: root, dryRun: true });
  const result = await dispatchViaHerdr(effects, "claude", spec(root, promptFile));
  assert.deepEqual(result, { code: 0, timedOut: false, dryRun: true, stderr: "", text: "" });
  assert.deepEqual(effects._calls, []);
});

// A human running several crew-afk sprints at once tells them apart in herdr's UI by this
// label — see ensureHerdrWorkspace's own doc comment for why it used to be the same
// hardcoded "crew-afk" for every run.
test("dispatchViaHerdr labels the shared workspace with the sprint's feature slug, not a hardcoded 'crew-afk'", async () => {
  const { root, promptFile } = fixture();
  writeFileSync(promptFile, "Reply with exactly: herdr spike ok");
  const outFile = join(root, "dispatch", "alpha.report.md");
  const effects = fakeHerdrEffects(
    [
      json({ result: { workspace: { workspace_id: "w1" } } }), // workspace create
      ...herdrLogTabResponses(),
      json({ result: { tab: { tab_id: "w1:t1" }, root_pane: { pane_id: "w1:p1" } } }), // tab create
      json({ result: { agent: { interactive_ready: true } } }), // agent start
      json({ result: { agent: { agent_status: "idle" } } }), // agent prompt --wait
      { code: 0, stdout: RENDERED_REPLY, stderr: "" }, // agent read
      json({ result: { type: "ok" } }), // tab close
    ],
    { mainRoot: root },
  );

  await dispatchViaHerdr(effects, "claude", spec(root, promptFile, { outFile, slug: "alpha", featureSlug: "implement-user-auth" }), {
    timeoutMs: 60_000,
  });

  const workspaceCreate = effects._calls[0];
  const labelIndex = workspaceCreate.indexOf("--label");
  assert.equal(workspaceCreate[labelIndex + 1], "implement-user-auth");
});

test("dispatchViaHerdr falls back to 'crew-afk' as the workspace label when no feature slug is given", async () => {
  const { root, promptFile } = fixture();
  writeFileSync(promptFile, "Reply with exactly: herdr spike ok");
  const outFile = join(root, "dispatch", "alpha.report.md");
  const effects = fakeHerdrEffects(
    [
      json({ result: { workspace: { workspace_id: "w1" } } }),
      ...herdrLogTabResponses(),
      json({ result: { tab: { tab_id: "w1:t1" }, root_pane: { pane_id: "w1:p1" } } }),
      json({ result: { agent: { interactive_ready: true } } }),
      json({ result: { agent: { agent_status: "idle" } } }),
      { code: 0, stdout: RENDERED_REPLY, stderr: "" },
      json({ result: { type: "ok" } }),
    ],
    { mainRoot: root },
  );

  await dispatchViaHerdr(effects, "claude", spec(root, promptFile, { outFile, slug: "alpha" }), { timeoutMs: 60_000 });

  const workspaceCreate = effects._calls[0];
  const labelIndex = workspaceCreate.indexOf("--label");
  assert.equal(workspaceCreate[labelIndex + 1], "crew-afk");
});

// The second, standing tab a human watching herdr uses to see the sprint's own
// round-by-round narration (the trace log every [DISPATCH-FAIL] line already lands in),
// not just whatever one worker's pane happens to be doing.
test("dispatchViaHerdr opens a log tab that tails the sprint's trace log, once per run, labeled by its purpose", async () => {
  const { root, promptFile } = fixture();
  writeFileSync(promptFile, "Reply with exactly: herdr spike ok");
  const logFile = join(root, "trace.log");
  const effects = fakeHerdrEffects(
    [
      json({ result: { workspace: { workspace_id: "w1" } } }), // workspace create
      json({ result: { tab: { tab_id: "w1:log" }, root_pane: { pane_id: "w1:plog" } } }), // log tab create
      json({ result: { type: "ok" } }), // pane run tail -f
      json({ result: { tab: { tab_id: "w1:t1" }, root_pane: { pane_id: "w1:p1" } } }), // dispatch tab create
      json({ result: { agent: { interactive_ready: true } } }),
      json({ result: { agent: { agent_status: "idle" } } }),
      { code: 0, stdout: RENDERED_REPLY, stderr: "" },
      json({ result: { type: "ok" } }), // dispatch tab close
    ],
    { mainRoot: root },
  );

  await dispatchViaHerdr(
    effects,
    "claude",
    spec(root, promptFile, { outFile: join(root, "a.md"), slug: "alpha", featureSlug: "implement-user-auth", logFile }),
    { timeoutMs: 60_000 },
  );

  assert.deepEqual(effects._calls[1], [
    "herdr",
    "tab",
    "create",
    "--workspace",
    "w1",
    "--cwd",
    root,
    "--label",
    "implement-user-auth-log",
    "--no-focus",
  ]);
  assert.deepEqual(effects._calls[2], ["herdr", "pane", "run", "w1:plog", "tail", "-f", logFile]);
  // The dispatch's own tab is created against the worktree, after the log tab — the log
  // tab is workspace-scoped setup, not part of any one dispatch's own sequence.
  assert.ok(effects._calls[3].includes(spec(root, promptFile).cwd));
});

test("dispatchViaHerdr opens no log tab when the dispatch has no trace log to tail", async () => {
  const { root, promptFile } = fixture();
  writeFileSync(promptFile, "Reply with exactly: herdr spike ok");
  const outFile = join(root, "dispatch", "alpha.report.md");
  const effects = fakeHerdrEffects(
    [
      json({ result: { workspace: { workspace_id: "w1" } } }), // workspace create
      json({ result: { tab: { tab_id: "w1:t1" }, root_pane: { pane_id: "w1:p1" } } }), // dispatch tab create — no log tab in between
      json({ result: { agent: { interactive_ready: true } } }),
      json({ result: { agent: { agent_status: "idle" } } }),
      { code: 0, stdout: RENDERED_REPLY, stderr: "" },
      json({ result: { type: "ok" } }),
    ],
    { mainRoot: root },
  );

  await dispatchViaHerdr(effects, "claude", spec(root, promptFile, { outFile, slug: "alpha", logFile: null }), { timeoutMs: 60_000 });

  assert.equal(
    effects._calls.filter((c) => c[1] === "pane" && c[2] === "run").length,
    0,
    "no logFile means nothing to tail",
  );
});

// A broken tail tab is cosmetic — a human's convenience feature, not part of the sprint's
// own contract — so it must never take down the dispatch that happened to create the shared
// workspace.
test("dispatchViaHerdr still dispatches normally even when the log tab itself fails to create", async () => {
  const { root, promptFile } = fixture();
  writeFileSync(promptFile, "Reply with exactly: herdr spike ok");
  const outFile = join(root, "dispatch", "alpha.report.md");
  const logFile = join(root, "trace.log");
  const effects = fakeHerdrEffects(
    [
      json({ result: { workspace: { workspace_id: "w1" } } }), // workspace create
      { code: 1, stdout: "", stderr: "boom" }, // log tab create fails
      json({ result: { tab: { tab_id: "w1:t1" }, root_pane: { pane_id: "w1:p1" } } }), // dispatch tab create still happens
      json({ result: { agent: { interactive_ready: true } } }),
      json({ result: { agent: { agent_status: "idle" } } }),
      { code: 0, stdout: RENDERED_REPLY, stderr: "" },
      json({ result: { type: "ok" } }),
    ],
    { mainRoot: root },
  );

  const result = await dispatchViaHerdr(effects, "claude", spec(root, promptFile, { outFile, slug: "alpha", logFile }), { timeoutMs: 60_000 });

  assert.equal(result.code, 0);
  assert.equal(result.text, "herdr spike ok");
});

test("dispatchViaHerdr: workspace create, tab create, start, prompt, read, tab close — the happy path", async () => {
  const { root, promptFile } = fixture();
  writeFileSync(promptFile, "Reply with exactly: herdr spike ok");
  const outFile = join(root, "dispatch", "alpha.report.md");
  const effects = fakeHerdrEffects(
    [
      json({ result: { workspace: { workspace_id: "w1" } } }), // workspace create (once per run)
      ...herdrLogTabResponses(),
      json({ result: { tab: { tab_id: "w1:t1" }, root_pane: { pane_id: "w1:p1" } } }), // tab create (once per dispatch)
      json({ result: { agent: { interactive_ready: true } } }), // agent start
      json({ result: { agent: { agent_status: "idle" } } }), // agent prompt --wait
      { code: 0, stdout: RENDERED_REPLY, stderr: "" }, // agent read (raw text, not JSON)
      json({ result: { type: "ok" } }), // tab close
    ],
    { mainRoot: root },
  );

  const result = await dispatchViaHerdr(effects, "claude", spec(root, promptFile, { outFile, slug: "alpha" }), { timeoutMs: 60_000 });

  assert.equal(result.code, 0);
  assert.equal(result.text, "herdr spike ok");
  assert.equal(readFileSync(outFile, "utf8"), "herdr spike ok");
  assert.deepEqual(effects._calls[0].slice(0, 3), ["herdr", "workspace", "create"]);
  assert.ok(effects._calls[0].includes(root), "the shared workspace is anchored at mainRoot, not any one dispatch's worktree");
  assert.deepEqual(effects._calls[3].slice(0, 3), ["herdr", "tab", "create"]);
  assert.ok(effects._calls[3].includes(spec(root, promptFile).cwd), "the dispatch's own worktree, not mainRoot");
  const paneName = effects._calls[4][3];
  assert.equal(paneName, "alpha-coder");
  assert.deepEqual(effects._calls[4], [
    "herdr",
    "agent",
    "start",
    paneName,
    "--kind",
    "claude",
    "--pane",
    "w1:p1",
    "--",
    "--permission-mode",
    "bypassPermissions",
    "--add-dir",
    root,
    "--agent",
    "crew-coder",
  ]);
  assert.deepEqual(effects._calls.at(-1), ["herdr", "tab", "close", "w1:t1"], "the dispatch's own tab is closed, not the shared workspace");
  const promptCall = effects._calls.find((c) => c[1] === "agent" && c[2] === "prompt");
  assert.ok(
    promptCall.includes("--until") &&
      promptCall.filter((a) => a === "--until").length === 2 &&
      promptCall[promptCall.indexOf("--until") + 1] === "idle" &&
      promptCall[promptCall.lastIndexOf("--until") + 1] === "done",
    "waits only for idle or done, not the default idle/done/blocked/unknown — a pane stuck on an unhandled dialog must time out, not read back as a mundane empty reply",
  );
});

test("dispatchViaHerdr retries the pane read when herdr's own idle/done signal says success but an earlier read caught nothing", async () => {
  const { root, promptFile } = fixture();
  writeFileSync(promptFile, "Reply with exactly: herdr spike ok");
  const outFile = join(root, "dispatch", "alpha.report.md");
  const effects = fakeHerdrEffects(
    [
      json({ result: { workspace: { workspace_id: "w1" } } }), // workspace create
      ...herdrLogTabResponses(),
      json({ result: { tab: { tab_id: "w1:t1" }, root_pane: { pane_id: "w1:p1" } } }), // tab create
      json({ result: { agent: { interactive_ready: true } } }), // agent start
      json({ result: { agent: { agent_status: "idle" } } }), // agent prompt --wait
      { code: 0, stdout: "some unrelated pane text, rendering hadn't caught up yet", stderr: "" }, // agent read (stale/empty)
      { code: 0, stdout: "", stderr: "" }, // pane wait-output (finds the anchor)
      { code: 0, stdout: RENDERED_REPLY, stderr: "" }, // agent read (after wait-output — now settled)
      json({ result: { type: "ok" } }), // tab close
    ],
    { mainRoot: root },
  );

  const result = await dispatchViaHerdr(effects, "claude", spec(root, promptFile, { outFile, slug: "alpha" }), { timeoutMs: 60_000 });

  assert.equal(result.code, 0, "herdr's own success signal is trusted once a retry recovers real text");
  assert.equal(result.text, "herdr spike ok");
  assert.equal(readFileSync(outFile, "utf8"), "herdr spike ok");
  const readCalls = effects._calls.filter((c) => c[1] === "agent" && c[2] === "read" && c[3] === "alpha-coder");
  assert.equal(readCalls.length, 2, "stop retrying as soon as a read recovers text, instead of always spending all attempts");
  const waitOutputCall = effects._calls.find((c) => c[1] === "pane" && c[2] === "wait-output");
  assert.ok(waitOutputCall, "waits for this dispatch's own echo+marker before blindly re-reading");
  assert.equal(waitOutputCall[3], "w1:p1", "targets the dispatch's own pane, not the agent name");
  const regexArg = waitOutputCall[waitOutputCall.indexOf("--regex") + 1];
  assert.ok(regexArg.includes("herdr spike ok"), "the regex anchors on this dispatch's own echoed prompt");
});

// herdr's own doc for `agent prompt --wait`: "It does not track turns: if the agent is
// already working, that active turn's completion may match." A pane still finishing an
// earlier turn can make --wait settle before this dispatch's own reply exists — the
// following `agent read --source recent-unwrapped` then rejects with agent_not_idle (that
// source needs the pane idle to scroll its alt-screen buffer), putting a JSON error on
// stdout instead of rendered text. Without recognising that error code, this reads back
// exactly like a genuinely blank pane.
test("dispatchViaHerdr waits out a live agent_not_idle instead of treating it as an empty reply", async () => {
  const { root, promptFile } = fixture();
  writeFileSync(promptFile, "Reply with exactly: herdr spike ok");
  const outFile = join(root, "dispatch", "alpha.report.md");
  const effects = fakeHerdrEffects(
    [
      json({ result: { workspace: { workspace_id: "w1" } } }), // workspace create
      ...herdrLogTabResponses(),
      json({ result: { tab: { tab_id: "w1:t1" }, root_pane: { pane_id: "w1:p1" } } }), // tab create
      json({ result: { agent: { interactive_ready: true } } }), // agent start
      json({ result: { agent: { agent_status: "idle" } } }), // agent prompt --wait — matched a stale idle blip
      { code: 1, stdout: JSON.stringify({ error: { code: "agent_not_idle", message: "alpha-coder is working" } }), stderr: "" }, // agent read — pane still mid-turn
      json({ result: { agent: { agent_status: "idle" } } }), // agent get — settled by the time we poll
      { code: 0, stdout: RENDERED_REPLY, stderr: "" }, // agent read — now readable
      json({ result: { type: "ok" } }), // tab close
    ],
    { mainRoot: root },
  );

  const result = await dispatchViaHerdr(effects, "claude", spec(root, promptFile, { outFile, slug: "alpha" }), { timeoutMs: 60_000 });

  assert.equal(result.code, 0);
  assert.equal(result.text, "herdr spike ok", "recovers the real reply instead of reporting an empty one");
  assert.equal(readFileSync(outFile, "utf8"), "herdr spike ok");
  const getCall = effects._calls.find((c) => c[1] === "agent" && c[2] === "get" && c[3] === "alpha-coder");
  assert.ok(getCall, "polls agent_status directly instead of guessing with the flush-lag backoff");
  const readCalls = effects._calls.filter((c) => c[1] === "agent" && c[2] === "read" && c[3] === "alpha-coder");
  assert.equal(readCalls.length, 2, "one read that hits agent_not_idle, one after the pane actually settles");
});

test("dispatchViaHerdr logs outEmpty=true on a herdr DISPATCH-FAIL only after all retries stay empty", async () => {
  const { root, promptFile } = fixture();
  writeFileSync(promptFile, "Reply with exactly: herdr spike ok");
  const outFile = join(root, "dispatch", "alpha.report.md");
  const logFile = join(root, "trace.log");
  const effects = fakeHerdrEffects(
    [
      json({ result: { workspace: { workspace_id: "w1" } } }), // workspace create
      ...herdrLogTabResponses(),
      json({ result: { tab: { tab_id: "w1:t1" }, root_pane: { pane_id: "w1:p1" } } }), // tab create
      json({ result: { agent: { interactive_ready: true } } }), // agent start
      json({ result: { agent: { agent_status: "idle" } } }), // agent prompt --wait
      { code: 0, stdout: "still unrelated pane text 1", stderr: "" }, // agent read (empty extraction)
      { code: 1, stdout: "", stderr: "" }, // pane wait-output (times out — anchor never appears)
      { code: 0, stdout: "still unrelated pane text 2", stderr: "" }, // agent read (after wait-output — still empty)
      { code: 0, stdout: "still unrelated pane text 3", stderr: "" }, // agent read (retry — still empty)
      { code: 0, stdout: "still unrelated pane text 4", stderr: "" }, // agent read (retry — still empty)
      { code: 0, stdout: "still unrelated pane text 5", stderr: "" }, // agent read (retry — still empty, last attempt)
      json({ result: { type: "ok" } }), // tab close
    ],
    { mainRoot: root },
  );

  const result = await dispatchViaHerdr(effects, "claude", spec(root, promptFile, { outFile, logFile, slug: "alpha" }), { timeoutMs: 60_000 });

  assert.equal(result.code, 0, "herdr's own exit code is untouched by an empty reply — the caller must read outEmpty to tell why it failed");
  assert.equal(result.text, "");
  const readCalls = effects._calls.filter((c) => c[1] === "agent" && c[2] === "read" && c[3] === "alpha-coder");
  assert.equal(readCalls.length, 5, "gives up only after HERDR_READ_MAX_ATTEMPTS reads, not just one retry");
  assert.match(
    readFileSync(logFile, "utf8"),
    /\[DISPATCH-FAIL\] agent=crew-coder herdr=1 code=0 timedOut=false outEmpty=true/,
  );
  assert.match(
    readFileSync(logFile, "utf8"),
    /still unrelated pane text 5/,
    "the last read's pane content lands in the log — an empty reply that never says why is unactionable",
  );
});

test("dispatchViaHerdr sanitises an issue slug for herdr's agent name but keeps it readable as the tab label", async () => {
  const { root, promptFile } = fixture();
  writeFileSync(promptFile, "Reply with exactly: herdr spike ok");
  const outFile = join(root, "dispatch", "alpha.report.md");
  const effects = fakeHerdrEffects(
    [
      json({ result: { workspace: { workspace_id: "w1" } } }), // workspace create
      ...herdrLogTabResponses(),
      json({ result: { tab: { tab_id: "w1:t1" }, root_pane: { pane_id: "w1:p1" } } }), // tab create
      json({ result: { agent: { interactive_ready: true } } }), // agent start
      json({ result: { agent: { agent_status: "idle" } } }), // agent prompt --wait
      { code: 0, stdout: RENDERED_REPLY, stderr: "" }, // agent read (raw text, not JSON)
      json({ result: { type: "ok" } }), // tab close
    ],
    { mainRoot: root },
  );

  await dispatchViaHerdr(effects, "claude", spec(root, promptFile, { outFile, slug: "Implement-User-Auth" }), { timeoutMs: 60_000 });

  const labelIndex = effects._calls[3].indexOf("--label");
  assert.equal(effects._calls[3][labelIndex + 1], "Implement-User-Auth", "label stays human-readable");
  const paneName = effects._calls[4][3];
  assert.equal(paneName, "implement-user-auth-coder");
  assert.deepEqual(effects._calls[4], [
    "herdr",
    "agent",
    "start",
    paneName,
    "--kind",
    "claude",
    "--pane",
    "w1:p1",
    "--",
    "--permission-mode",
    "bypassPermissions",
    "--add-dir",
    root,
    "--agent",
    "crew-coder",
  ]);
});

// Claude's workspace-trust dialog is keyed off the repository, not the literal cwd
// (confirmed live), so it fires at most once per repo, on whichever dispatch happens to hit
// an untrusted one first — there is no separate priming step.
test("dispatchViaHerdr answers the one-time workspace-trust dialog, but only when the blocked text actually matches it", async () => {
  const { root, promptFile } = fixture();
  writeFileSync(promptFile, "Reply with exactly: herdr spike ok");
  const outFile = join(root, "dispatch", "alpha.report.md");
  const effects = fakeHerdrEffects(
    [
      json({ result: { workspace: { workspace_id: "w1" } } }), // workspace create
      ...herdrLogTabResponses(),
      json({ result: { tab: { tab_id: "w1:t1" }, root_pane: { pane_id: "w1:p1" } } }), // tab create
      err(1, "agent alpha is blocked during startup and is not ready for prompts", "agent_not_ready"), // agent start
      { code: 0, stdout: "Is this a project you created or one you trust? (Like your own code...)", stderr: "" }, // agent read (blocked check)
      json({ result: { type: "ok" } }), // agent send-keys down enter
      json({ result: { agent: { interactive_ready: true } } }), // agent get (poll)
      json({ result: { agent: { agent_status: "idle" } } }), // agent prompt --wait
      { code: 0, stdout: RENDERED_REPLY, stderr: "" }, // agent read (final)
      json({ result: { type: "ok" } }), // tab close
    ],
    { mainRoot: root },
  );

  const result = await dispatchViaHerdr(effects, "claude", spec(root, promptFile, { outFile, slug: "alpha" }), { timeoutMs: 60_000 });

  assert.equal(result.code, 0);
  assert.equal(result.text, "herdr spike ok");
  const paneName = effects._calls[6][3];
  assert.equal(paneName, "alpha-coder");
  assert.deepEqual(effects._calls[6], ["herdr", "agent", "send-keys", paneName, "down", "enter"]);
});

test("dispatchViaHerdr fails (does not blindly send keys) on a blocked state it doesn't recognise", async () => {
  const { root, promptFile } = fixture();
  const outFile = join(root, "dispatch", "alpha.report.md");
  const logFile = join(root, "trace.log");
  const effects = fakeHerdrEffects(
    [
      json({ result: { workspace: { workspace_id: "w1" } } }),
      ...herdrLogTabResponses(),
      json({ result: { tab: { tab_id: "w1:t1" }, root_pane: { pane_id: "w1:p1" } } }),
      err(1, "agent alpha is blocked during startup and is not ready for prompts", "agent_not_ready"),
      { code: 0, stdout: "Allow this MCP server to run? [y/n]", stderr: "" }, // an unrelated approval dialog
      json({ result: { type: "ok" } }), // tab close
    ],
    { mainRoot: root },
  );

  const result = await dispatchViaHerdr(effects, "claude", spec(root, promptFile, { outFile, logFile, slug: "alpha" }), { timeoutMs: 60_000 });

  assert.equal(result.code, 1);
  assert.match(result.stderr, /unrecognised dialog/);
  assert.match(readFileSync(logFile, "utf8"), /\[DISPATCH-FAIL\] agent=crew-coder herdr=1/);
  assert.doesNotMatch(effects._calls.map((c) => c.join(" ")).join("\n"), /send-keys/, "never answers a dialog it can't identify");
});

test("dispatchViaHerdr surfaces the rendered pane when the agent is already blocked, instead of a mysterious empty success", async () => {
  const { root, promptFile } = fixture();
  writeFileSync(promptFile, "Reply with exactly: herdr spike ok");
  const outFile = join(root, "dispatch", "alpha.report.md");
  const logFile = join(root, "trace.log");
  const effects = fakeHerdrEffects(
    [
      json({ result: { workspace: { workspace_id: "w1" } } }), // workspace create
      ...herdrLogTabResponses(),
      json({ result: { tab: { tab_id: "w1:t1" }, root_pane: { pane_id: "w1:p1" } } }), // tab create
      json({ result: { agent: { interactive_ready: true } } }), // agent start
      err(1, "agent alpha is blocked and rejected the prompt", "agent_blocked"), // agent prompt --wait
      { code: 0, stdout: "Allow this MCP server to run? [y/n]", stderr: "" }, // agent read (final)
      json({ result: { type: "ok" } }), // tab close
    ],
    { mainRoot: root },
  );

  const result = await dispatchViaHerdr(effects, "claude", spec(root, promptFile, { outFile, logFile, slug: "alpha" }), { timeoutMs: 60_000 });

  assert.equal(result.code, 1);
  assert.match(result.stderr, /already blocked/);
  assert.match(result.stderr, /Allow this MCP server to run/, "the actual blocked screen, not just the CLI's own error JSON");
  assert.match(readFileSync(logFile, "utf8"), /\[DISPATCH-FAIL\] agent=crew-coder herdr=1/);
});

test("dispatchViaHerdr treats a herdr `timeout` error the same as `agent_prompt_stalled` — both mean the worker never settled", async () => {
  const { root, promptFile } = fixture();
  writeFileSync(promptFile, "Reply with exactly: herdr spike ok");
  const outFile = join(root, "dispatch", "alpha.report.md");
  const effects = fakeHerdrEffects(
    [
      json({ result: { workspace: { workspace_id: "w1" } } }), // workspace create
      ...herdrLogTabResponses(),
      json({ result: { tab: { tab_id: "w1:t1" }, root_pane: { pane_id: "w1:p1" } } }), // tab create
      json({ result: { agent: { interactive_ready: true } } }), // agent start
      err(1, "timed out waiting for idle or done", "timeout"), // agent prompt --wait
      { code: 0, stdout: "some unrelated pane text", stderr: "" }, // agent read (final)
      json({ result: { type: "ok" } }), // tab close
    ],
    { mainRoot: root },
  );

  const result = await dispatchViaHerdr(effects, "claude", spec(root, promptFile, { outFile, slug: "alpha" }), { timeoutMs: 60_000 });

  assert.equal(result.code, 1);
  assert.equal(result.timedOut, true);
});

test("dispatch() routes to dispatchViaHerdr for every platform once spec.herdr is set", () => {
  const { root, promptFile } = fixture();
  const outFile = join(root, "dispatch", "alpha.report.md");
  const effects = fakeHerdrEffects(
    [
      json({ result: { workspace: { workspace_id: "w1" } } }),
      ...herdrLogTabResponses(),
      json({ result: { tab: { tab_id: "w1:t1" }, root_pane: { pane_id: "w1:p1" } } }),
      json({ result: { agent: { interactive_ready: true } } }),
      json({ result: { agent: { agent_status: "idle" } } }),
      { code: 0, stdout: RENDERED_REPLY, stderr: "" },
      json({ result: { type: "ok" } }),
    ],
    { mainRoot: root },
  );
  writeFileSync(promptFile, "Reply with exactly: herdr spike ok");

  return dispatch(effects, "claude", spec(root, promptFile, { outFile, slug: "alpha", herdr: true })).then((result) => {
    assert.equal(result.text, "herdr spike ok");
    assert.ok(effects._calls[0][1] === "workspace", "went through the herdr path, not buildDispatch/spawnWithTimeout");
  });
});

test("dispatch() routes to dispatchViaHerdr for copilot too — the platform gate is gone, not just widened to claude", () => {
  const { root, promptFile } = fixture();
  const outFile = join(root, "dispatch", "alpha.report.md");
  const effects = fakeHerdrEffects(
    [
      json({ result: { workspace: { workspace_id: "w1" } } }),
      ...herdrLogTabResponses(),
      json({ result: { tab: { tab_id: "w1:t1" }, root_pane: { pane_id: "w1:p1" } } }),
      json({ result: { agent: { interactive_ready: true } } }),
      json({ result: { agent: { agent_status: "idle" } } }),
      { code: 0, stdout: COPILOT_RENDERED_REPLY, stderr: "" },
      json({ result: { type: "ok" } }),
    ],
    { mainRoot: root },
  );
  writeFileSync(promptFile, "Reply with exactly: herdr spike ok");

  return dispatch(effects, "copilot", spec(root, promptFile, { outFile, slug: "alpha", herdr: true })).then((result) => {
    assert.equal(result.text, "herdr spike ok");
    assert.ok(effects._calls[0][1] === "workspace", "went through the herdr path, not buildDispatch/spawnWithTimeout");
  });
});

test("dispatch() never routes to dispatchViaHerdr under CREW_FAKE_DISPATCH, even with spec.herdr set", async () => {
  const { root, promptFile } = fixture();
  const outFile = join(root, "dispatch", "alpha.report.md");
  const effects = fakeHerdrEffects(
    [{ code: 0, stdout: "", stderr: "" }], // the one CREW_FAKE_DISPATCH spawnWithTimeout call
    { mainRoot: root },
  );
  const prior = process.env.CREW_FAKE_DISPATCH;
  process.env.CREW_FAKE_DISPATCH = "fake-dispatch.sh";
  try {
    await dispatch(effects, "claude", spec(root, promptFile, { outFile, slug: "alpha", herdr: true }));
  } finally {
    if (prior === undefined) delete process.env.CREW_FAKE_DISPATCH;
    else process.env.CREW_FAKE_DISPATCH = prior;
  }
  assert.equal(effects._calls.length, 1, "the test seam bypasses herdr entirely — exactly the one CREW_FAKE_DISPATCH call, no herdr call");
  assert.notEqual(effects._calls[0][0], "herdr");
});

test("dispatchViaHerdr shares one herdr workspace across every dispatch in a run, closing only its own tab each time", async () => {
  const { root, promptFile } = fixture();
  writeFileSync(promptFile, "Reply with exactly: herdr spike ok");
  const effects = fakeHerdrEffects(
    [
      json({ result: { workspace: { workspace_id: "w1" } } }), // workspace create — first dispatch only
      ...herdrLogTabResponses(),
      json({ result: { tab: { tab_id: "w1:t1" }, root_pane: { pane_id: "w1:p1" } } }), // tab create (alpha)
      json({ result: { agent: { interactive_ready: true } } }),
      json({ result: { agent: { agent_status: "idle" } } }),
      { code: 0, stdout: RENDERED_REPLY, stderr: "" },
      json({ result: { type: "ok" } }), // tab close (alpha)
      json({ result: { tab: { tab_id: "w1:t2" }, root_pane: { pane_id: "w1:p2" } } }), // tab create (beta) — no workspace create here
      json({ result: { agent: { interactive_ready: true } } }),
      json({ result: { agent: { agent_status: "idle" } } }),
      { code: 0, stdout: RENDERED_REPLY, stderr: "" },
      json({ result: { type: "ok" } }), // tab close (beta)
    ],
    { mainRoot: root },
  );

  await dispatchViaHerdr(effects, "claude", spec(root, promptFile, { outFile: join(root, "a.md"), slug: "alpha" }), { timeoutMs: 60_000 });
  const callsAfterFirst = effects._calls.length;
  await dispatchViaHerdr(effects, "claude", spec(root, promptFile, { outFile: join(root, "b.md"), slug: "beta" }), { timeoutMs: 60_000 });

  assert.equal(effects._calls.length - callsAfterFirst, 5, "tab create, agent start, agent prompt, agent read, tab close — no second workspace create");
  const workspaceCreateCalls = effects._calls.filter((c) => c[1] === "workspace" && c[2] === "create");
  assert.equal(workspaceCreateCalls.length, 1, "the workspace is created once for the whole run, not once per dispatch");
  // Excludes the one log tab (its --cwd is mainRoot, not a worktree) — each dispatch's own
  // tab is what "one tab per dispatch" is actually asserting here.
  const tabCreateCalls = effects._calls.filter((c) => c[1] === "tab" && c[2] === "create" && c.includes(spec(root, promptFile).cwd));
  assert.equal(tabCreateCalls.length, 2, "each dispatch still gets its own tab");
  for (const c of tabCreateCalls) assert.ok(c.includes("w1"), "every dispatch's tab belongs to the one shared workspace");
  const workspaceCloseCalls = effects._calls.filter((c) => c[1] === "workspace" && c[2] === "close");
  assert.equal(workspaceCloseCalls.length, 0, "dispatchViaHerdr never closes the shared workspace itself — only closeHerdrWorkspace does");
  assert.deepEqual(
    effects._calls.filter((c) => c[1] === "tab" && c[2] === "close"),
    [
      ["herdr", "tab", "close", "w1:t1"],
      ["herdr", "tab", "close", "w1:t2"],
    ],
    "each dispatch closes only its own tab",
  );
});

test("closeHerdrWorkspace closes the workspace a herdr dispatch created, and is a no-op when no herdr dispatch ever ran", async () => {
  const untouched = fakeHerdrEffects([], { mainRoot: "/root" });
  await closeHerdrWorkspace(untouched);
  assert.deepEqual(untouched._calls, [], "nothing to close — no herdr dispatch ever created a workspace on this effects instance");

  const { root, promptFile } = fixture();
  writeFileSync(promptFile, "Reply with exactly: herdr spike ok");
  const effects = fakeHerdrEffects(
    [
      json({ result: { workspace: { workspace_id: "w1" } } }),
      ...herdrLogTabResponses(),
      json({ result: { tab: { tab_id: "w1:t1" }, root_pane: { pane_id: "w1:p1" } } }),
      json({ result: { agent: { interactive_ready: true } } }),
      json({ result: { agent: { agent_status: "idle" } } }),
      { code: 0, stdout: RENDERED_REPLY, stderr: "" },
      json({ result: { type: "ok" } }), // tab close
      json({ result: { type: "ok" } }), // workspace close, from closeHerdrWorkspace
    ],
    { mainRoot: root },
  );
  await dispatchViaHerdr(effects, "claude", spec(root, promptFile, { outFile: join(root, "a.md"), slug: "alpha" }), { timeoutMs: 60_000 });
  await closeHerdrWorkspace(effects);
  assert.deepEqual(effects._calls.at(-1), ["herdr", "workspace", "close", "w1"]);
});

function withHerdrWorkspaceId(id, fn) {
  const prior = process.env.HERDR_WORKSPACE_ID;
  process.env.HERDR_WORKSPACE_ID = id;
  return Promise.resolve()
    .then(fn)
    .finally(() => {
      if (prior === undefined) delete process.env.HERDR_WORKSPACE_ID;
      else process.env.HERDR_WORKSPACE_ID = prior;
    });
}

test("dispatchViaHerdr reuses the triggering pane's own workspace via HERDR_WORKSPACE_ID, never calling workspace create", async () => {
  const { root, promptFile } = fixture();
  writeFileSync(promptFile, "Reply with exactly: herdr spike ok");
  const outFile = join(root, "dispatch", "alpha.report.md");
  const effects = fakeHerdrEffects(
    [
      ...herdrLogTabResponses(),
      json({ result: { tab: { tab_id: "w1:t1" }, root_pane: { pane_id: "w1:p1" } } }),
      json({ result: { agent: { interactive_ready: true } } }),
      json({ result: { agent: { agent_status: "idle" } } }),
      { code: 0, stdout: RENDERED_REPLY, stderr: "" },
      json({ result: { type: "ok" } }), // tab close
    ],
    { mainRoot: root },
  );

  const result = await withHerdrWorkspaceId("w1", () =>
    dispatchViaHerdr(effects, "claude", spec(root, promptFile, { outFile, slug: "alpha" }), { timeoutMs: 60_000 }),
  );

  assert.equal(result.code, 0);
  assert.equal(result.text, "herdr spike ok");
  assert.ok(
    !effects._calls.some((c) => c[1] === "workspace" && c[2] === "create"),
    "no new workspace — the triggering pane's own is reused instead",
  );
  assert.deepEqual(effects._calls[0], ["herdr", "tab", "create", "--workspace", "w1", "--cwd", root, "--label", "crew-afk-log", "--no-focus"]);
});

function withHerdrTabId(id, fn) {
  const prior = process.env.HERDR_TAB_ID;
  process.env.HERDR_TAB_ID = id;
  return Promise.resolve()
    .then(fn)
    .finally(() => {
      if (prior === undefined) delete process.env.HERDR_TAB_ID;
      else process.env.HERDR_TAB_ID = prior;
    });
}

// The reused pane's own tab still shows whatever it was called before crew-afk started running
// in it — herdr also injects that pane's own tab as HERDR_TAB_ID, so this is the one chance to
// relabel it to the sprint's feature slug, the same way a freshly created workspace already is.
test("dispatchViaHerdr renames the triggering pane's own tab to the feature slug when reusing HERDR_WORKSPACE_ID", async () => {
  const { root, promptFile } = fixture();
  writeFileSync(promptFile, "Reply with exactly: herdr spike ok");
  const outFile = join(root, "dispatch", "alpha.report.md");
  const effects = fakeHerdrEffects(
    [
      json({ result: { type: "ok" } }), // tab rename
      ...herdrLogTabResponses(),
      json({ result: { tab: { tab_id: "w1:t1" }, root_pane: { pane_id: "w1:p1" } } }),
      json({ result: { agent: { interactive_ready: true } } }),
      json({ result: { agent: { agent_status: "idle" } } }),
      { code: 0, stdout: RENDERED_REPLY, stderr: "" },
      json({ result: { type: "ok" } }), // dispatch tab close
    ],
    { mainRoot: root },
  );

  await withHerdrWorkspaceId("w1", () =>
    withHerdrTabId("w1:t1", () =>
      dispatchViaHerdr(effects, "claude", spec(root, promptFile, { outFile, slug: "alpha", featureSlug: "implement-user-auth" }), {
        timeoutMs: 60_000,
      }),
    ),
  );

  assert.deepEqual(effects._calls[0], ["herdr", "tab", "rename", "w1:t1", "implement-user-auth"]);
});

test("dispatchViaHerdr never renames the triggering pane's own tab when no feature slug resolved — nothing meaningful to relabel it to", async () => {
  const { root, promptFile } = fixture();
  writeFileSync(promptFile, "Reply with exactly: herdr spike ok");
  const outFile = join(root, "dispatch", "alpha.report.md");
  const effects = fakeHerdrEffects(
    [
      ...herdrLogTabResponses(),
      json({ result: { tab: { tab_id: "w1:t1" }, root_pane: { pane_id: "w1:p1" } } }),
      json({ result: { agent: { interactive_ready: true } } }),
      json({ result: { agent: { agent_status: "idle" } } }),
      { code: 0, stdout: RENDERED_REPLY, stderr: "" },
      json({ result: { type: "ok" } }),
    ],
    { mainRoot: root },
  );

  await withHerdrWorkspaceId("w1", () =>
    withHerdrTabId("w1:t1", () => dispatchViaHerdr(effects, "claude", spec(root, promptFile, { outFile, slug: "alpha" }), { timeoutMs: 60_000 })),
  );

  assert.ok(
    !effects._calls.some((c) => c[1] === "tab" && c[2] === "rename"),
    "no feature slug resolved, so the pane's own tab is left exactly as the human named it",
  );
});

test("closeHerdrWorkspace never closes a workspace reused via HERDR_WORKSPACE_ID — that would close the pane crew-afk was launched from", async () => {
  const { root, promptFile } = fixture();
  writeFileSync(promptFile, "Reply with exactly: herdr spike ok");
  const outFile = join(root, "dispatch", "alpha.report.md");
  const effects = fakeHerdrEffects(
    [
      ...herdrLogTabResponses(),
      json({ result: { tab: { tab_id: "w1:t1" }, root_pane: { pane_id: "w1:p1" } } }),
      json({ result: { agent: { interactive_ready: true } } }),
      json({ result: { agent: { agent_status: "idle" } } }),
      { code: 0, stdout: RENDERED_REPLY, stderr: "" },
      json({ result: { type: "ok" } }), // tab close
    ],
    { mainRoot: root },
  );

  await withHerdrWorkspaceId("w1", () => dispatchViaHerdr(effects, "claude", spec(root, promptFile, { outFile, slug: "alpha" }), { timeoutMs: 60_000 }));
  await closeHerdrWorkspace(effects);

  assert.ok(
    !effects._calls.some((c) => c[1] === "workspace" && c[2] === "close"),
    "the reused workspace is left open — it belongs to whoever is still using that pane",
  );
});

test("dispatchViaHerdr never reuses one worker's pane for another role on the same issue", async () => {
  const { root, promptFile } = fixture();
  writeFileSync(promptFile, "Reply with exactly: herdr spike ok");
  const effects = fakeHerdrEffects(
    [
      json({ result: { workspace: { workspace_id: "w1" } } }),
      ...herdrLogTabResponses(),
      json({ result: { tab: { tab_id: "w1:t1" }, root_pane: { pane_id: "w1:p1" } } }),
      json({ result: { agent: { interactive_ready: true } } }),
      json({ result: { agent: { agent_status: "idle" } } }),
      { code: 0, stdout: RENDERED_REPLY, stderr: "" },
      json({ result: { type: "ok" } }),
      json({ result: { tab: { tab_id: "w1:t2" }, root_pane: { pane_id: "w1:p2" } } }),
      json({ result: { agent: { interactive_ready: true } } }),
      json({ result: { agent: { agent_status: "idle" } } }),
      { code: 0, stdout: RENDERED_REPLY, stderr: "" },
      json({ result: { type: "ok" } }),
    ],
    { mainRoot: root },
  );

  // The coder's dispatch for this issue.
  await dispatchViaHerdr(effects, "claude", spec(root, promptFile, { outFile: join(root, "coder.md"), slug: "alpha" }), {
    timeoutMs: 60_000,
  });
  // The reviewer's dispatch for the same issue, same slug, once the coder's own tab is closed.
  await dispatchViaHerdr(
    effects,
    "claude",
    spec(root, promptFile, { outFile: join(root, "review.md"), slug: "alpha", agent: "crew-code-reviewer" }),
    { timeoutMs: 60_000 },
  );

  const startCalls = effects._calls.filter((c) => c[1] === "agent" && c[2] === "start");
  assert.equal(startCalls.length, 2);
  assert.equal(startCalls[0][3], "alpha-coder");
  assert.equal(startCalls[1][3], "alpha-review");
  assert.notEqual(startCalls[0][3], startCalls[1][3], "coder and reviewer must never start on the same pane name");
  assert.equal(
    effects._calls.filter((c) => c[1] === "workspace" && c[2] === "create").length,
    1,
    "coder and reviewer share the same herdr workspace",
  );
});

test("dispatchViaHerdr never reuses one coder's pane for another coder — two different issues, same role", async () => {
  const { root, promptFile } = fixture();
  writeFileSync(promptFile, "Reply with exactly: herdr spike ok");
  const effects = fakeHerdrEffects(
    [
      json({ result: { workspace: { workspace_id: "w1" } } }),
      ...herdrLogTabResponses(),
      json({ result: { tab: { tab_id: "w1:t1" }, root_pane: { pane_id: "w1:p1" } } }),
      json({ result: { agent: { interactive_ready: true } } }),
      json({ result: { agent: { agent_status: "idle" } } }),
      { code: 0, stdout: RENDERED_REPLY, stderr: "" },
      json({ result: { type: "ok" } }),
      json({ result: { tab: { tab_id: "w1:t2" }, root_pane: { pane_id: "w1:p2" } } }),
      json({ result: { agent: { interactive_ready: true } } }),
      json({ result: { agent: { agent_status: "idle" } } }),
      { code: 0, stdout: RENDERED_REPLY, stderr: "" },
      json({ result: { type: "ok" } }),
    ],
    { mainRoot: root },
  );

  // Two different issues' coders — as mapPool dispatches them concurrently within a round.
  await dispatchViaHerdr(effects, "claude", spec(root, promptFile, { outFile: join(root, "a.md"), slug: "alpha" }), {
    timeoutMs: 60_000,
  });
  await dispatchViaHerdr(effects, "claude", spec(root, promptFile, { outFile: join(root, "b.md"), slug: "beta" }), {
    timeoutMs: 60_000,
  });

  const startCalls = effects._calls.filter((c) => c[1] === "agent" && c[2] === "start");
  assert.equal(startCalls.length, 2);
  assert.equal(startCalls[0][3], "alpha-coder");
  assert.equal(startCalls[1][3], "beta-coder");
  assert.notEqual(startCalls[0][3], startCalls[1][3], "two different issues' coders must never share a pane");
  assert.equal(
    effects._calls.filter((c) => c[1] === "workspace" && c[2] === "create").length,
    1,
    "two different issues' coders still share the same herdr workspace",
  );
});

// ─── herdr pane persistence + reuse (one retry, see pipeline.mjs's herdr-reuse) ────────

test("dispatchViaHerdr leaves a successful dispatch's tab open when spec.herdrPersistPane is set, returning its ids instead of closing it", async () => {
  const { root, promptFile } = fixture();
  writeFileSync(promptFile, "Reply with exactly: herdr spike ok");
  const effects = fakeHerdrEffects(
    [
      json({ result: { workspace: { workspace_id: "w1" } } }),
      ...herdrLogTabResponses(),
      json({ result: { tab: { tab_id: "w1:t1" }, root_pane: { pane_id: "w1:p1" } } }),
      json({ result: { agent: { interactive_ready: true } } }),
      json({ result: { agent: { agent_status: "idle" } } }),
      { code: 0, stdout: RENDERED_REPLY, stderr: "" },
      // No "tab close" response: persistPane must skip it entirely on success.
    ],
    { mainRoot: root },
  );

  const result = await dispatchViaHerdr(
    effects,
    "claude",
    spec(root, promptFile, { slug: "alpha", herdrPersistPane: true }),
    { timeoutMs: 60_000 },
  );

  assert.equal(result.code, 0);
  assert.equal(result.herdrTabId, "w1:t1");
  assert.equal(result.herdrPaneId, "w1:p1");
  assert.ok(
    !effects._calls.some((c) => c[1] === "tab" && c[2] === "close"),
    "a persisted pane's tab is never closed by the dispatch that produced it",
  );
});

test("dispatchViaHerdr still closes the tab despite spec.herdrPersistPane when the dispatch itself failed", async () => {
  const { root, promptFile } = fixture();
  writeFileSync(promptFile, "Reply with exactly: herdr spike ok");
  const effects = fakeHerdrEffects(
    [
      json({ result: { workspace: { workspace_id: "w1" } } }),
      ...herdrLogTabResponses(),
      json({ result: { tab: { tab_id: "w1:t1" }, root_pane: { pane_id: "w1:p1" } } }),
      json({ result: { agent: { interactive_ready: true } } }),
      err(1, "boom", "agent_prompt_stalled"),
      { code: 0, stdout: "", stderr: "" }, // agent read after the failed prompt
      json({ result: { type: "ok" } }), // tab close — persistPane only defers closing on success
    ],
    { mainRoot: root },
  );

  const result = await dispatchViaHerdr(
    effects,
    "claude",
    spec(root, promptFile, { slug: "alpha", herdrPersistPane: true }),
    { timeoutMs: 60_000 },
  );

  assert.equal(result.code, 1);
  assert.equal(result.herdrTabId, null, "a failed dispatch never hands back ids to keep open");
  assert.deepEqual(effects._calls.at(-1), ["herdr", "tab", "close", "w1:t1"]);
});

test("closeHerdrPane closes the given tab, and is a no-op when tabId is falsy", async () => {
  const effects = fakeHerdrEffects([json({ result: { type: "ok" } })], { mainRoot: "/root" });
  await closeHerdrPane(effects, null);
  assert.equal(effects._calls.length, 0, "no herdr call at all when there is nothing to close");
  await closeHerdrPane(effects, "w1:t1");
  assert.deepEqual(effects._calls[0], ["herdr", "tab", "close", "w1:t1"]);
});

test("dispatchViaHerdr reuses an existing pane via spec.herdrReuse — skips workspace/tab create and agent start, goes straight to agent prompt", async () => {
  const { root, promptFile } = fixture();
  writeFileSync(promptFile, "Reply with exactly: herdr spike ok");
  const effects = fakeHerdrEffects(
    [
      json({ result: { agent: { agent_status: "idle" } } }), // agent prompt --wait
      { code: 0, stdout: RENDERED_REPLY, stderr: "" }, // agent read
      json({ result: { type: "ok" } }), // tab close, using the reused (carried-forward) tabId
    ],
    { mainRoot: root },
  );

  const result = await dispatchViaHerdr(
    effects,
    "claude",
    spec(root, promptFile, { slug: "alpha", herdrReuse: { tabId: "w1:t1", paneId: "w1:p1" } }),
    { timeoutMs: 60_000 },
  );

  assert.equal(result.code, 0);
  assert.equal(result.text, "herdr spike ok");
  assert.ok(
    !effects._calls.some((c) => c[1] === "workspace" && c[2] === "create"),
    "a reuse never needs its own workspace — the one from the prior dispatch is already there",
  );
  assert.ok(!effects._calls.some((c) => c[1] === "tab" && c[2] === "create"), "a reuse skips tab create entirely");
  assert.ok(!effects._calls.some((c) => c[1] === "agent" && c[2] === "start"), "a reuse skips agent start — the agent is already running");
  assert.deepEqual(effects._calls[0], ["herdr", "agent", "prompt", "alpha-coder", "Reply with exactly: herdr spike ok", "--wait", "--until", "idle", "--until", "done", "--timeout", "60000"]);
  assert.deepEqual(effects._calls.at(-1), ["herdr", "tab", "close", "w1:t1"], "closes using the reused tab id, not a freshly created one");
});

test("dispatchViaHerdr skips the pane wait-output pre-check on a reused pane, even on an empty first read", async () => {
  const { root, promptFile } = fixture();
  writeFileSync(promptFile, "Reply with exactly: herdr spike ok");
  const effects = fakeHerdrEffects(
    [
      json({ result: { agent: { agent_status: "idle" } } }), // agent prompt --wait
      { code: 0, stdout: "leftover text from a prior turn in this same pane", stderr: "" }, // agent read (empty extraction)
      { code: 0, stdout: RENDERED_REPLY, stderr: "" }, // agent read (fixed-delay retry — now settled)
      json({ result: { type: "ok" } }), // tab close, using the reused (carried-forward) tabId
    ],
    { mainRoot: root },
  );

  const result = await dispatchViaHerdr(
    effects,
    "claude",
    spec(root, promptFile, { slug: "alpha", herdrReuse: { tabId: "w1:t1", paneId: "w1:p1" } }),
    { timeoutMs: 60_000 },
  );

  assert.equal(result.code, 0);
  assert.equal(result.text, "herdr spike ok");
  assert.ok(
    !effects._calls.some((c) => c[1] === "pane" && c[2] === "wait-output"),
    "a reused pane's buffer already carries a prior turn's echo+marker — wait-output's leftmost regex match could lock onto that stale pair instead of this turn's, so it's skipped in favour of the fixed-delay backoff",
  );
});

test("dispatchViaHerdr falls back to a fresh dispatch when the reused pane's agent is gone", async () => {
  const { root, promptFile } = fixture();
  writeFileSync(promptFile, "Reply with exactly: herdr spike ok");
  const effects = fakeHerdrEffects(
    [
      err(1, "no such agent", "agent_not_found"), // agent prompt --wait, against the stale reuse target
      // Falls through to a normal fresh dispatch:
      json({ result: { workspace: { workspace_id: "w1" } } }),
      ...herdrLogTabResponses(),
      json({ result: { tab: { tab_id: "w1:t2" }, root_pane: { pane_id: "w1:p2" } } }),
      json({ result: { agent: { interactive_ready: true } } }),
      json({ result: { agent: { agent_status: "idle" } } }),
      { code: 0, stdout: RENDERED_REPLY, stderr: "" },
      json({ result: { type: "ok" } }),
    ],
    { mainRoot: root },
  );

  const result = await dispatchViaHerdr(
    effects,
    "claude",
    spec(root, promptFile, { slug: "alpha", herdrReuse: { tabId: "w1:t1", paneId: "w1:p1" } }),
    { timeoutMs: 60_000 },
  );

  assert.equal(result.code, 0);
  assert.equal(result.text, "herdr spike ok");
  assert.ok(
    effects._calls.some((c) => c[1] === "tab" && c[2] === "create"),
    "the stale reuse target falls back to creating a brand-new tab",
  );
  assert.deepEqual(effects._calls.at(-1), ["herdr", "tab", "close", "w1:t2"], "closes the freshly created tab, not the stale one");
});

// ─── herdr, per platform ─────────────────────────────────────────────────────
//
// The claude-only gate is gone (see dispatch()'s own doc comment): herdr's own --kind
// already lists pi/claude/codex/copilot as supported kinds, so buildHerdrInvocation builds
// each platform's interactive argv the same way buildDispatch builds its headless one, minus
// -p/prompt/output-format — the prompt is submitted after the pane is ready, not at launch.
// pi and copilot were verified live against herdr 0.8.2 with real transcripts; codex could
// not be (no credentials in the environment this was built in), so its argv comes from
// documented flags only and its reply-extraction falls back to pi's glyph-less shape.

test("buildHerdrInvocation resolves pi's agent file into --tools/--model/--append-system-prompt, always trusting the run with --approve", () => {
  const { root, promptFile } = fixture();
  mkdirSync(join(root, ".pi/agents"), { recursive: true });
  writeFileSync(join(root, ".pi/agents/crew-coder.md"), "---\ntools: read, bash, edit\nmodel: some-default\n---\nDo the work.\n");
  const { args, prompt } = buildHerdrInvocation({}, "pi", spec(root, promptFile, { model: "gpt-5" }));
  assert.deepEqual(args, ["--approve", "--model", "gpt-5", "--tools", "read,bash,edit", "--append-system-prompt", "Do the work.\n"]);
  assert.equal(prompt, readFileSync(promptFile, "utf8"));
});

test("buildHerdrInvocation falls back to pi's agent file's own model when spec.model is empty, but an explicit override wins", () => {
  const { root, promptFile } = fixture();
  mkdirSync(join(root, ".pi/agents"), { recursive: true });
  writeFileSync(join(root, ".pi/agents/crew-coder.md"), "---\nmodel: agent-default\n---\nDo the work.\n");
  const withDefault = buildHerdrInvocation({}, "pi", spec(root, promptFile, { model: null }));
  assert.deepEqual(withDefault.args.slice(0, 3), ["--approve", "--model", "agent-default"]);
  const withOverride = buildHerdrInvocation({}, "pi", spec(root, promptFile, { model: "gpt-5" }));
  assert.deepEqual(withOverride.args.slice(0, 3), ["--approve", "--model", "gpt-5"]);
});

test("buildHerdrInvocation throws when the pi agent definition is missing, so dispatchViaHerdr fails before ever touching herdr", () => {
  const { root, promptFile } = fixture();
  assert.throws(() => buildHerdrInvocation({}, "pi", spec(root, promptFile)), /pi agent definition not found/);
});

test("buildHerdrInvocation prepends codex's developer_instructions to the task and submits both as one prompt", () => {
  const { root, promptFile } = fixture();
  writeFileSync(promptFile, "Fix the bug.");
  mkdirSync(join(root, ".codex/agents"), { recursive: true });
  writeFileSync(join(root, ".codex/agents/crew-coder.toml"), "model = \"gpt-5-codex\"\ndeveloper_instructions = '''\nYou are the coder.\n'''\n");
  const effects = { gitRead: () => ({ code: 0, stdout: ".git\n", stderr: "" }) };
  const { args, prompt } = buildHerdrInvocation(effects, "codex", spec(root, promptFile));
  assert.equal(prompt, "You are the coder.\n\n---\n\n# Task\n\nFix the bug.");
  assert.match(args.join(" "), /-C .*worktree -a never -s workspace-write/);
  assert.match(args.join(" "), /--model gpt-5-codex/);
});

test("buildHerdrInvocation adds codex's git-common-dir as a writable root under workspace-write, the same fix dispatch-codex-agent.sh carries", () => {
  const { root, promptFile } = fixture();
  mkdirSync(join(root, ".codex/agents"), { recursive: true });
  writeFileSync(join(root, ".codex/agents/crew-coder.toml"), "developer_instructions = '''\nInstructions.\n'''\n");
  const effects = { gitRead: (args, opts) => ({ code: 0, stdout: "../.git/worktrees/alpha\n", stderr: "" }) };
  const { args } = buildHerdrInvocation(effects, "codex", spec(root, promptFile));
  assert.match(args.join(" "), /sandbox_workspace_write\.writable_roots=\["[^"]*\.git\/worktrees\/alpha"]/);
});

test("buildHerdrInvocation throws when the codex agent definition is missing", () => {
  const { root, promptFile } = fixture();
  assert.throws(() => buildHerdrInvocation({}, "codex", spec(root, promptFile)), /codex agent definition not found/);
});

test("buildHerdrInvocation throws when the codex agent definition has empty developer_instructions", () => {
  const { root, promptFile } = fixture();
  mkdirSync(join(root, ".codex/agents"), { recursive: true });
  writeFileSync(join(root, ".codex/agents/crew-coder.toml"), 'model = "gpt-5-codex"\n');
  assert.throws(() => buildHerdrInvocation({}, "codex", spec(root, promptFile)), /empty developer_instructions/);
});

test("buildHerdrInvocation builds copilot's interactive argv the same as buildDispatch's headless one, minus -p/prompt/output-format", () => {
  const { root, promptFile } = fixture();
  const { args, prompt } = buildHerdrInvocation({}, "copilot", spec(root, promptFile, { model: "gpt-5.4" }));
  assert.deepEqual(args, [
    "--agent",
    "crew-coder",
    "-C",
    join(root, "worktree"),
    "--add-dir",
    root,
    "--allow-all-tools",
    "--no-color",
    "--model",
    "gpt-5.4",
  ]);
  assert.equal(prompt, readFileSync(promptFile, "utf8"));
});

test("extractHerdrReply reads pi's glyph-less echo, ending at its rule pair", () => {
  const rendered = [
    " pi v0.85.1",
    "",
    " What is 2+2? Answer in one short sentence.",
    "",
    " 2+2 equals 4.",
    "",
    "─────────────────────────────",
    "─────────────────────────────",
    "~/repo (master)",
  ].join("\n");
  assert.equal(extractHerdrReply(rendered, "What is 2+2? Answer in one short sentence.", "pi"), "2+2 equals 4.");
});

test("extractHerdrReply reads copilot's echo despite its trailing right-aligned timestamp, ending at the AIC-used status bar", () => {
  const rendered = [
    " ● Selected custom agent: test-agent",
    "",
    " ❯ What is 2+2? Answer in one short sentence.                                          08:54",
    "",
    " 2+2 equals 4.",
    "",
    " ~/repo [master]                                                            Session: 0 AIC used",
    "─────────────────────────────",
    " ❯",
  ].join("\n");
  assert.equal(extractHerdrReply(rendered, "What is 2+2? Answer in one short sentence.", "copilot"), "2+2 equals 4.");
});

test("extractHerdrReply falls back to pi's glyph-less shape for codex, unverified against a live transcript", () => {
  const rendered = [" Welcome to Codex", "", " Fix the bug.", "", " Done.", "", "─────────────────────────────"].join("\n");
  assert.equal(extractHerdrReply(rendered, "Fix the bug.", "codex"), "Done.");
});

test("dispatchViaHerdr answers copilot's own trust dialog with a plain enter, not claude's down+enter", async () => {
  const { root, promptFile } = fixture();
  writeFileSync(promptFile, "Reply with exactly: herdr spike ok");
  const outFile = join(root, "dispatch", "alpha.report.md");
  const effects = fakeHerdrEffects(
    [
      json({ result: { workspace: { workspace_id: "w1" } } }),
      ...herdrLogTabResponses(),
      json({ result: { tab: { tab_id: "w1:t1" }, root_pane: { pane_id: "w1:p1" } } }),
      err(1, "agent alpha is blocked during startup", "agent_not_ready"),
      { code: 0, stdout: "Do you trust the files in this folder?\n❯ 1. Yes", stderr: "" },
      json({ result: { type: "ok" } }), // agent send-keys enter
      json({ result: { agent: { interactive_ready: true } } }), // agent get (poll)
      json({ result: { agent: { agent_status: "idle" } } }), // agent prompt --wait
      { code: 0, stdout: COPILOT_RENDERED_REPLY, stderr: "" },
      json({ result: { type: "ok" } }), // tab close
    ],
    { mainRoot: root },
  );

  const result = await dispatchViaHerdr(effects, "copilot", spec(root, promptFile, { outFile, slug: "alpha" }), { timeoutMs: 60_000 });

  assert.equal(result.code, 0);
  assert.equal(result.text, "herdr spike ok");
  const paneName = effects._calls[6][3];
  assert.deepEqual(effects._calls[6], ["herdr", "agent", "send-keys", paneName, "enter"]);
});

test("dispatchViaHerdr fails loud on codex's sign-in screen instead of guessing a keystroke — codex has no HERDR_DIALOGS entry", async () => {
  const { root, promptFile } = fixture();
  mkdirSync(join(root, ".codex/agents"), { recursive: true });
  writeFileSync(join(root, ".codex/agents/crew-coder.toml"), "developer_instructions = '''\nInstructions.\n'''\n");
  const outFile = join(root, "dispatch", "alpha.report.md");
  const logFile = join(root, "trace.log");
  const effects = fakeHerdrEffects(
    [
      json({ result: { workspace: { workspace_id: "w1" } } }),
      ...herdrLogTabResponses(),
      json({ result: { tab: { tab_id: "w1:t1" }, root_pane: { pane_id: "w1:p1" } } }),
      err(1, "agent alpha is blocked during startup", "agent_not_ready"),
      { code: 0, stdout: "Sign in with ChatGPT to use Codex\n1. Sign in with ChatGPT", stderr: "" },
      json({ result: { type: "ok" } }), // tab close
    ],
    { mainRoot: root },
  );

  const result = await dispatchViaHerdr(effects, "codex", spec(root, promptFile, { outFile, logFile, slug: "alpha" }), { timeoutMs: 60_000 });

  assert.equal(result.code, 1);
  assert.match(result.stderr, /unrecognised dialog/);
  assert.doesNotMatch(effects._calls.map((c) => c.join(" ")).join("\n"), /send-keys/, "no HERDR_DIALOGS entry for codex — never a blind keypress");
});
