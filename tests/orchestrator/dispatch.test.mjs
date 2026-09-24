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
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// resolveAgentFile()'s home-dir fallback reads os.homedir(), which reads $HOME — so a
// real per-user install (e.g. ~/.claude/agents/crew-coder.md) would otherwise leak into
// the "no definition anywhere" assertions below. Point HOME at an empty directory for
// the whole file, and restore it once these tests are done.
const isolatedHome = mkdtempSync(join(tmpdir(), "crew-dispatch-home-"));
const realHome = process.env.HOME;

// ensurePaneWorkspace/renameTriggeringPaneTab/notifyTriggeringPane all key off
// HERDR_WORKSPACE_ID/HERDR_TAB_ID/HERDR_PANE_ID (herdr) or
// ORCA_WORKTREE_ID/ORCA_TAB_ID/ORCA_TERMINAL_HANDLE (orca) — injected by a real herdr/orca
// session, which this suite may itself be running inside of (e.g. a managed dev sandbox).
// Left ambient, those leak into every "not inside a pane host" / "creates its own
// workspace" assertion below. Cleared for the whole file; the handful of tests that need a
// specific value set and restore it themselves, locally.
const ambientPaneHostEnv = {
  HERDR_WORKSPACE_ID: process.env.HERDR_WORKSPACE_ID,
  HERDR_TAB_ID: process.env.HERDR_TAB_ID,
  HERDR_PANE_ID: process.env.HERDR_PANE_ID,
  ORCA_WORKTREE_ID: process.env.ORCA_WORKTREE_ID,
  ORCA_TAB_ID: process.env.ORCA_TAB_ID,
  ORCA_TERMINAL_HANDLE: process.env.ORCA_TERMINAL_HANDLE,
};
before(() => {
  process.env.HOME = isolatedHome;
  for (const key of Object.keys(ambientPaneHostEnv)) delete process.env[key];
});
after(() => {
  if (realHome === undefined) delete process.env.HOME;
  else process.env.HOME = realHome;
  for (const [key, value] of Object.entries(ambientPaneHostEnv)) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
});

import {
  buildDispatch,
  closePaneLogTab,
  closePaneWorkspace,
  dispatch,
  dispatchPlain,
  ensurePaneWorkspace,
  extractFinalText,
  extractResultMeta,
  formatJsonTraceLine,
  notifyTriggeringPane,
  preflight,
  resolveAgentFile,
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


// ─── pane hosts, herdr (https://herdr.dev) and orca (https://onorca.dev): ambient only,
// nothing load-bearing ──────────────────────────────────────────────────────────────────
//
// Per-worker panes (dispatchViaHerdr) are gone: every coder/reviewer/triage dispatch is
// always headless now. crew-afk's own process is never relaunched into a hosted pane either
// (herdr's `pane run` cannot report a real exit code back, so an earlier design had to fake
// completion-detection with a sentinel-file poll and a blind timeout — removed rather than
// worked around). What's left of either host is: a shared workspace with one tab/terminal
// that just tails the sprint's own trace log (ensurePaneWorkspace/ensurePaneLogTab, closed
// by closePaneWorkspace/closePaneLogTab), and a best-effort, advisory nudge to the
// triggering pane at the end of a run (notifyTriggeringPane). The herdr fixtures below are
// the actual JSON shapes captured from a real herdr workspace/tab-create round-trip; the
// orca ones are from a real live spike against a running orca runtime (`orca terminal
// create`/`rename`/`send`/`close`, each with `--json`).

function fakePaneHostEffects(paneHost, responses, { mainRoot = "/root", dryRun = false } = {}) {
  const calls = [];
  const timeouts = [];
  return {
    paneHost,
    mainRoot,
    dryRun,
    _calls: calls,
    _timeouts: timeouts,
    spawnWithTimeout: async (cmd, args, { timeoutMs } = {}) => {
      calls.push([cmd, ...args]);
      timeouts.push(timeoutMs);
      const next = responses.shift();
      if (!next) throw new Error(`no more canned ${paneHost} responses — call was: ${cmd} ${args.join(" ")}`);
      return next;
    },
    gitRead: () => ({ code: 0, stdout: ".git\n", stderr: "" }),
  };
}
const fakeHerdrEffects = (responses, opts) => fakePaneHostEffects("herdr", responses, opts);
const fakeOrcaEffects = (responses, opts) => fakePaneHostEffects("orca", responses, opts);
const json = (obj) => ({ code: 0, stdout: JSON.stringify(obj), stderr: "" });

// Every canned-response list for ensurePaneWorkspace (herdr) that passes a logFile needs
// these two responses spliced in right after the workspace create/reuse response —
// ensurePaneLogTab always fires immediately after, in both branches.
const herdrLogTabResponses = () => [
  json({ result: { tab: { tab_id: "w1:log" }, root_pane: { pane_id: "w1:plog" } } }), // log tab create
  json({ result: { type: "ok" } }), // pane run tail -f
];

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

function withHerdrPaneId(id, fn) {
  const prior = process.env.HERDR_PANE_ID;
  process.env.HERDR_PANE_ID = id;
  return Promise.resolve()
    .then(fn)
    .finally(() => {
      if (prior === undefined) delete process.env.HERDR_PANE_ID;
      else process.env.HERDR_PANE_ID = prior;
    });
}

function withOrcaWorktreeId(id, fn) {
  const prior = process.env.ORCA_WORKTREE_ID;
  process.env.ORCA_WORKTREE_ID = id;
  return Promise.resolve()
    .then(fn)
    .finally(() => {
      if (prior === undefined) delete process.env.ORCA_WORKTREE_ID;
      else process.env.ORCA_WORKTREE_ID = prior;
    });
}

function withOrcaTerminalHandle(handle, fn) {
  const prior = process.env.ORCA_TERMINAL_HANDLE;
  process.env.ORCA_TERMINAL_HANDLE = handle;
  return Promise.resolve()
    .then(fn)
    .finally(() => {
      if (prior === undefined) delete process.env.ORCA_TERMINAL_HANDLE;
      else process.env.ORCA_TERMINAL_HANDLE = prior;
    });
}

test("ensurePaneWorkspace (herdr) creates a workspace and opens a log tab that tails logFile", async () => {
  const { root } = fixture();
  const logFile = join(root, "trace.log");
  const effects = fakeHerdrEffects(
    [
      json({ result: { workspace: { workspace_id: "w1" } } }), // workspace create
      ...herdrLogTabResponses(),
    ],
    { mainRoot: root },
  );

  const workspaceId = await ensurePaneWorkspace(effects, { featureSlug: "implement-user-auth", logFile });

  assert.equal(workspaceId, "w1");
  const workspaceCreate = effects._calls[0];
  assert.deepEqual(workspaceCreate.slice(0, 3), ["herdr", "workspace", "create"]);
  assert.equal(workspaceCreate[workspaceCreate.indexOf("--label") + 1], "implement-user-auth");

  const tabCreate = effects._calls[1];
  assert.deepEqual(tabCreate.slice(0, 6), ["herdr", "tab", "create", "--workspace", "w1", "--cwd"]);
  assert.equal(tabCreate[tabCreate.indexOf("--label") + 1], "implement-user-auth-log");

  assert.deepEqual(effects._calls.at(-1), ["herdr", "pane", "run", "w1:plog", "tail", "-f", logFile]);
});

test("ensurePaneWorkspace (herdr) never opens a log tab when no logFile is given", async () => {
  const { root } = fixture();
  const effects = fakeHerdrEffects([json({ result: { workspace: { workspace_id: "w1" } } })], { mainRoot: root });

  await ensurePaneWorkspace(effects, { featureSlug: "alpha" });

  assert.deepEqual(effects._calls, [effects._calls[0]], "only the workspace create — no tab was ever requested");
  assert.ok(!effects._calls.some((c) => c[1] === "tab"));
});

test("ensurePaneWorkspace (herdr) swallows a failed log tab create — cosmetic, not a reason to fail the run", async () => {
  const { root } = fixture();
  const logFile = join(root, "trace.log");
  const effects = fakeHerdrEffects(
    [
      json({ result: { workspace: { workspace_id: "w1" } } }),
      { code: 1, stdout: "", stderr: "herdr unreachable" }, // log tab create fails
    ],
    { mainRoot: root },
  );

  const workspaceId = await ensurePaneWorkspace(effects, { featureSlug: "alpha", logFile });

  assert.equal(workspaceId, "w1", "the workspace itself is still returned — only the log tab is best-effort");
  assert.ok(!effects._calls.some((c) => c[1] === "pane" && c[2] === "run"), "never attempted pane run without a pane id");
});

// The reused pane's own tab still shows whatever it was called before crew-afk started
// running in it — herdr also injects that pane's own tab as HERDR_TAB_ID, so this is the
// one chance to relabel it to the sprint's feature slug, the same way a freshly created
// workspace already is. The run's own log tab still opens inside the reused workspace too.
test("ensurePaneWorkspace (herdr) reuses an ambient HERDR_WORKSPACE_ID, renames the triggering tab, and still opens its own log tab", async () => {
  const { root } = fixture();
  const logFile = join(root, "trace.log");
  const effects = fakeHerdrEffects(
    [
      json({ result: { type: "ok" } }), // tab rename
      ...herdrLogTabResponses(),
    ],
    { mainRoot: root },
  );

  const workspaceId = await withHerdrWorkspaceId("w1", () =>
    withHerdrTabId("w1:t1", () => ensurePaneWorkspace(effects, { featureSlug: "implement-user-auth", logFile })),
  );

  assert.equal(workspaceId, "w1", "the ambient workspace is reused, not created");
  assert.ok(!effects._calls.some((c) => c[1] === "workspace" && c[2] === "create"));
  assert.deepEqual(effects._calls[0], ["herdr", "tab", "rename", "w1:t1", "implement-user-auth"]);
  assert.deepEqual(effects._calls.at(-1), ["herdr", "pane", "run", "w1:plog", "tail", "-f", logFile]);
});

test("ensurePaneWorkspace (herdr) never renames the triggering pane's own tab when no feature slug resolved", async () => {
  const { root } = fixture();
  const effects = fakeHerdrEffects([], { mainRoot: root });

  await withHerdrWorkspaceId("w1", () => withHerdrTabId("w1:t1", () => ensurePaneWorkspace(effects, {})));

  assert.deepEqual(effects._calls, [], "no feature slug resolved, so the pane's own tab is left exactly as the human named it");
});

test("closePaneWorkspace (herdr) closes the workspace ensurePaneWorkspace created, and is a no-op when nothing was ever created", async () => {
  const untouched = fakeHerdrEffects([], { mainRoot: "/root" });
  await closePaneWorkspace(untouched);
  assert.deepEqual(untouched._calls, [], "nothing to close — no run ever created a workspace on this effects instance");

  const { root } = fixture();
  const effects = fakeHerdrEffects([json({ result: { workspace: { workspace_id: "w1" } } }), json({ result: { type: "ok" } })], { mainRoot: root });
  await ensurePaneWorkspace(effects, { featureSlug: "alpha" });
  await closePaneWorkspace(effects);
  assert.deepEqual(effects._calls.at(-1), ["herdr", "workspace", "close", "w1"]);
});

test("closePaneWorkspace (herdr) never closes a workspace reused via HERDR_WORKSPACE_ID — that would close the pane crew-afk was launched from", async () => {
  const { root } = fixture();
  const effects = fakeHerdrEffects([], { mainRoot: root });

  await withHerdrWorkspaceId("w1", () => ensurePaneWorkspace(effects, { featureSlug: "alpha" }));
  await closePaneWorkspace(effects);

  assert.ok(
    !effects._calls.some((c) => c[1] === "workspace" && c[2] === "close"),
    "the reused workspace is left open — it belongs to whoever is still using that pane",
  );
});

test("closePaneLogTab (herdr) closes the log tab ensurePaneWorkspace opened, and is a no-op when none was ever created", async () => {
  const untouched = fakeHerdrEffects([], { mainRoot: "/root" });
  await closePaneLogTab(untouched);
  assert.deepEqual(untouched._calls, [], "nothing to close — no run ever created a log tab on this effects instance");

  const { root } = fixture();
  const logFile = join(root, "trace.log");
  const effects = fakeHerdrEffects(
    [json({ result: { workspace: { workspace_id: "w1" } } }), ...herdrLogTabResponses(), json({ result: { type: "ok" } })],
    { mainRoot: root },
  );
  await ensurePaneWorkspace(effects, { featureSlug: "alpha", logFile });
  await closePaneLogTab(effects);
  assert.deepEqual(effects._calls.at(-1), ["herdr", "tab", "close", "w1:log"]);
});

// The case closePaneWorkspace's own reuse test above leaves unclosed: a workspace reused
// via HERDR_WORKSPACE_ID survives (it belongs to whoever's pane triggered the run), but this
// run's own log tab inside it is still this run's to close — otherwise it tails the trace
// log forever after a run launched from inside an existing herdr pane.
test("closePaneLogTab (herdr) closes this run's own log tab even when the workspace it lives in was reused, not created", async () => {
  const { root } = fixture();
  const logFile = join(root, "trace.log");
  const effects = fakeHerdrEffects([...herdrLogTabResponses(), json({ result: { type: "ok" } })], { mainRoot: root });

  await withHerdrWorkspaceId("w1", () => ensurePaneWorkspace(effects, { featureSlug: "alpha", logFile }));
  await closePaneWorkspace(effects);
  await closePaneLogTab(effects);

  assert.ok(!effects._calls.some((c) => c[1] === "workspace" && c[2] === "close"), "the reused workspace itself is still left open");
  assert.deepEqual(effects._calls.at(-1), ["herdr", "tab", "close", "w1:log"], "but this run's own log tab is closed");
});

test("notifyTriggeringPane (herdr) is a no-op when not running inside herdr — no HERDR_PANE_ID", async () => {
  const effects = fakeHerdrEffects([], { mainRoot: "/root" });
  await notifyTriggeringPane(effects, "crew-afk (alpha): sprint finished.");
  assert.deepEqual(effects._calls, [], "nothing to notify — the run wasn't launched inside a herdr pane");
});

test("notifyTriggeringPane (herdr) prompts the triggering pane directly by its injected HERDR_PANE_ID, waiting for herdr to confirm delivery", async () => {
  const effects = fakeHerdrEffects([json({ result: { type: "ok" } })], { mainRoot: "/root" });
  const result = await withHerdrPaneId("w1:p1", () => notifyTriggeringPane(effects, "crew-afk (alpha): sprint finished."));
  assert.deepEqual(effects._calls, [
    ["herdr", "agent", "prompt", "w1:p1", "crew-afk (alpha): sprint finished.", "--wait", "--until", "working", "--timeout-ms", "2000"],
  ]);
  assert.deepEqual(result, { sent: true });
});

test("notifyTriggeringPane (herdr) reports a stalled push as a failure instead of a false success", async () => {
  const effects = fakeHerdrEffects([{ code: 1, stdout: "", stderr: "agent_prompt_stalled" }], { mainRoot: "/root" });
  const result = await withHerdrPaneId("w1:p1", () => notifyTriggeringPane(effects, "crew-afk (alpha): sprint finished."));
  assert.equal(result.sent, false);
  assert.match(result.reason, /agent_prompt_stalled/);
});

test("notifyTriggeringPane (herdr) swallows a failed prompt — the sprint's own outcome is already decided by then", async () => {
  const calls = [];
  const effects = {
    paneHost: "herdr",
    mainRoot: "/root",
    spawnWithTimeout: async (cmd, args) => {
      calls.push([cmd, ...args]);
      throw new Error("herdr unreachable");
    },
  };
  const result = await withHerdrPaneId("w1:p1", () => notifyTriggeringPane(effects, "crew-afk (alpha): sprint finished."));
  assert.equal(calls.length, 1, "still attempted once, just didn't throw");
  assert.equal(result.sent, false);
});

// ─── orca: same contract, no separate workspace object ─────────────────────────────────
//
// Confirmed live against a running orca runtime this session: a git checkout's own root is
// already an Orca-managed worktree with no `repo add`/`worktree create` needed (`orca
// worktree current` resolves it directly from cwd), so `terminal create --worktree
// path:<mainRoot>` is the whole story — there is no herdr-style workspace object to create, reuse, or close.

test("ensurePaneWorkspace (orca) creates a log terminal directly — no separate workspace-create call exists", async () => {
  const { root } = fixture();
  const logFile = join(root, "trace.log");
  const effects = fakeOrcaEffects([json({ result: { terminal: { handle: "term_1" } } })], { mainRoot: root });

  const workspaceId = await ensurePaneWorkspace(effects, { featureSlug: "implement-user-auth", logFile });

  assert.equal(workspaceId, null, "orca has no workspace object to return an id for");
  assert.equal(effects._calls.length, 1, "straight to the log terminal — no separate workspace/tab split exists in orca's model");
  const create = effects._calls[0];
  assert.deepEqual(create.slice(0, 4), ["orca", "terminal", "create", "--worktree"]);
  assert.equal(create[create.indexOf("--title") + 1], "implement-user-auth-log");
  assert.equal(create[create.indexOf("--worktree") + 1], `path:${root}`, "scoped to this checkout, not whatever worktree orca's GUI has active");
  assert.equal(create[create.indexOf("--command") + 1], `tail -f '${logFile}'`);
});

// `--command` is typed into the terminal's shell, not passed as argv — an unquoted path with
// a space or quote in it would tail the wrong file or leave the shell mid-quote.
test("ensurePaneWorkspace (orca) shell-quotes the log path it types into the new terminal", async () => {
  const effects = fakeOrcaEffects([json({ result: { terminal: { handle: "term_1" } } })], { mainRoot: "/root" });

  await ensurePaneWorkspace(effects, { featureSlug: "alpha", logFile: "/my repo/it's.log" });

  const create = effects._calls[0];
  assert.equal(create[create.indexOf("--command") + 1], `tail -f '/my repo/it'\\''s.log'`);
});

test("ensurePaneWorkspace (orca) never creates a terminal when no logFile is given", async () => {
  const { root } = fixture();
  const effects = fakeOrcaEffects([], { mainRoot: root });

  const workspaceId = await ensurePaneWorkspace(effects, { featureSlug: "alpha" });

  assert.equal(workspaceId, null);
  assert.deepEqual(effects._calls, []);
});

// Orca has no workspace create to fail loudly, so without this a failed log terminal (e.g.
// ORCA_ENV=1 in a checkout orca doesn't manage) left no tab and no word of why. Rejecting is
// still not fatal: main.mjs catches it, prints it, and continues without a log tab.
test("ensurePaneWorkspace (orca) rejects with the reason when the log terminal create fails", async () => {
  const { root } = fixture();
  const logFile = join(root, "trace.log");
  const effects = fakeOrcaEffects([{ code: 1, stdout: "", stderr: "orca unreachable" }], { mainRoot: root });

  await assert.rejects(ensurePaneWorkspace(effects, { featureSlug: "alpha", logFile }), /orca terminal create failed: exit=1 orca unreachable/);
  assert.equal(effects._paneLogTabId, undefined, "nothing for closePaneLogTab to close");
});

// Orca is a desktop app that can be quit mid-run: an unbounded create blocks the sprint from
// starting, an unbounded close in main.mjs's `finally` blocks it from exiting.
test("every orca call is bounded by a timeout", async () => {
  const { root } = fixture();
  const logFile = join(root, "trace.log");
  const effects = fakeOrcaEffects(
    [
      json({ result: { rename: { title: "alpha" } } }), // terminal rename
      json({ result: { terminal: { handle: "term_2" } } }), // log terminal create
      json({ result: { closed: true } }), // log terminal close
    ],
    { mainRoot: root },
  );

  await withOrcaTerminalHandle("term_1", () => ensurePaneWorkspace(effects, { featureSlug: "alpha", logFile }));
  await closePaneLogTab(effects);

  assert.equal(effects._calls.length, 3);
  for (const [i, timeoutMs] of effects._timeouts.entries()) {
    assert.ok(timeoutMs > 0, `${effects._calls[i].slice(0, 3).join(" ")} has no timeout`);
  }
});

// The triggering terminal's own tab still shows whatever it was called before crew-afk
// started running in it — orca also injects that terminal's own handle as
// ORCA_TERMINAL_HANDLE, alongside ORCA_WORKTREE_ID for the enclosing worktree — so this is
// the one chance to relabel it, the same way herdr's reuse path does. Unlike herdr, no
// separate "reuse the workspace" call is needed: every terminal create is already scoped by
// --worktree path:<mainRoot>, so the ambient ORCA_WORKTREE_ID is returned for symmetry with herdr's
// return value, not because orca ever needs it again.
test("ensurePaneWorkspace (orca) renames the triggering terminal via ORCA_TERMINAL_HANDLE, and reuses ORCA_WORKTREE_ID implicitly", async () => {
  const { root } = fixture();
  const logFile = join(root, "trace.log");
  const effects = fakeOrcaEffects(
    [
      json({ result: { rename: { title: "implement-user-auth" } } }), // terminal rename
      json({ result: { terminal: { handle: "term_2" } } }), // log terminal create
    ],
    { mainRoot: root },
  );

  const workspaceId = await withOrcaWorktreeId("wt1", () =>
    withOrcaTerminalHandle("term_1", () => ensurePaneWorkspace(effects, { featureSlug: "implement-user-auth", logFile })),
  );

  assert.equal(workspaceId, "wt1");
  assert.deepEqual(effects._calls[0], ["orca", "terminal", "rename", "--terminal", "term_1", "--title", "implement-user-auth", "--json"]);
  assert.equal(effects._calls[1][4], `path:${root}`, "the log terminal is scoped by --worktree path:<mainRoot> — reuse needs nothing explicit");
});

test("ensurePaneWorkspace (orca) never renames the triggering terminal when no feature slug resolved", async () => {
  const { root } = fixture();
  const effects = fakeOrcaEffects([], { mainRoot: root });

  await withOrcaTerminalHandle("term_1", () => ensurePaneWorkspace(effects, {}));

  assert.deepEqual(effects._calls, [], "no feature slug resolved, so the terminal is left exactly as the human named it");
});

test("closePaneWorkspace (orca) is always a no-op — orca has no workspace object to close", async () => {
  const { root } = fixture();
  const logFile = join(root, "trace.log");
  const effects = fakeOrcaEffects([json({ result: { terminal: { handle: "term_1" } } })], { mainRoot: root });

  await ensurePaneWorkspace(effects, { featureSlug: "alpha", logFile });
  await closePaneWorkspace(effects);

  assert.deepEqual(effects._calls, [effects._calls[0]], "only the terminal create — close never called anything");
});

test("closePaneLogTab (orca) closes the log terminal ensurePaneWorkspace opened, and is a no-op when none was ever created", async () => {
  const untouched = fakeOrcaEffects([], { mainRoot: "/root" });
  await closePaneLogTab(untouched);
  assert.deepEqual(untouched._calls, []);

  const { root } = fixture();
  const logFile = join(root, "trace.log");
  const effects = fakeOrcaEffects([json({ result: { terminal: { handle: "term_1" } } })], { mainRoot: root });
  await ensurePaneWorkspace(effects, { featureSlug: "alpha", logFile });
  await closePaneLogTab(effects);
  assert.deepEqual(effects._calls.at(-1), ["orca", "terminal", "close", "--terminal", "term_1", "--json"]);
});

test("notifyTriggeringPane (orca) is a no-op when not running inside orca — no ORCA_TERMINAL_HANDLE", async () => {
  const effects = fakeOrcaEffects([], { mainRoot: "/root" });
  const result = await notifyTriggeringPane(effects, "crew-afk (alpha): sprint finished.");
  assert.deepEqual(effects._calls, [], "nothing to notify — the run wasn't launched inside an orca terminal");
  assert.equal(result.sent, false);
});

// Confirmed live: sending into a plain shell terminal returned `accepted: true` but
// `prompt.observation: "unsupported"` — orca self-reports what it can't confirm rather than
// silently claiming success like herdr's pre-#4537-fix `agent prompt` did, so there is no
// `--wait`-style workaround needed here, just the `accepted` flag.
const orcaAgentShow = () => json({ result: { terminal: { handle: "term_1", agentIdentity: "claude" } } });

test("notifyTriggeringPane (orca) sends into the triggering terminal by its injected ORCA_TERMINAL_HANDLE", async () => {
  const effects = fakeOrcaEffects(
    [orcaAgentShow(), json({ result: { send: { accepted: true, prompt: { observation: "supported" } } } })],
    { mainRoot: "/root" },
  );
  const result = await withOrcaTerminalHandle("term_1", () => notifyTriggeringPane(effects, "crew-afk (alpha): sprint finished."));
  assert.deepEqual(effects._calls, [
    ["orca", "terminal", "show", "--terminal", "term_1", "--json"],
    ["orca", "terminal", "send", "--terminal", "term_1", "--text", "crew-afk (alpha): sprint finished.", "--enter", "--json"],
  ]);
  assert.deepEqual(result, { sent: true });
});

// orca's `terminal send` types into any terminal, agent or not, and reports `accepted: true`
// for a plain shell — where the message plus Enter runs as a shell command. Confirmed live:
// `terminal show` reports agentIdentity for a claude pane, and no such field for a shell.
test("notifyTriggeringPane (orca) never types into a triggering terminal orca doesn't see an agent in", async () => {
  const effects = fakeOrcaEffects([json({ result: { terminal: { handle: "term_1", title: "bash" } } })], { mainRoot: "/root" });
  const result = await withOrcaTerminalHandle("term_1", () => notifyTriggeringPane(effects, "crew-afk (alpha): sprint finished."));
  assert.deepEqual(effects._calls, [["orca", "terminal", "show", "--terminal", "term_1", "--json"]], "a shell, not an agent — no send");
  assert.equal(result.sent, false);
  assert.match(result.reason, /not running an agent/);
});

test("notifyTriggeringPane (orca) never sends when terminal show itself fails", async () => {
  const effects = fakeOrcaEffects([{ code: 1, stdout: "", stderr: "terminal not found" }], { mainRoot: "/root" });
  const result = await withOrcaTerminalHandle("term_1", () => notifyTriggeringPane(effects, "crew-afk (alpha): sprint finished."));
  assert.equal(effects._calls.length, 1, "show only — an unknown pane is never typed into");
  assert.equal(result.sent, false);
});

// Measured live: `terminal send` into an idle claude pane takes ~8s to return (it watches for
// turn start) — a 5s cap killed it at exit 124 after delivery, logging a false NOTIFY-FAIL.
test("notifyTriggeringPane (orca) gives terminal send long enough to return from a live agent pane", async () => {
  let timeoutMs;
  const effects = {
    paneHost: "orca",
    mainRoot: "/root",
    spawnWithTimeout: async (cmd, args, opts) => {
      if (args[1] === "show") return orcaAgentShow();
      timeoutMs = opts.timeoutMs;
      return json({ result: { send: { accepted: true } } });
    },
  };
  await withOrcaTerminalHandle("term_1", () => notifyTriggeringPane(effects, "crew-afk (alpha): sprint finished."));
  assert.ok(timeoutMs >= 20000, `timeout ${timeoutMs}ms is shorter than a live agent pane's ~8s send`);
});

test("notifyTriggeringPane (orca) reports an explicitly-not-accepted send as a failure", async () => {
  const effects = fakeOrcaEffects([orcaAgentShow(), json({ result: { send: { accepted: false } } })], { mainRoot: "/root" });
  const result = await withOrcaTerminalHandle("term_1", () => notifyTriggeringPane(effects, "crew-afk (alpha): sprint finished."));
  assert.equal(result.sent, false);
  assert.match(result.reason, /not accepted/);
});

test("notifyTriggeringPane (orca) swallows a failed send — the sprint's own outcome is already decided by then", async () => {
  const calls = [];
  const effects = {
    paneHost: "orca",
    mainRoot: "/root",
    spawnWithTimeout: async (cmd, args) => {
      calls.push([cmd, ...args]);
      if (args[1] === "show") return orcaAgentShow();
      throw new Error("orca unreachable");
    },
  };
  const result = await withOrcaTerminalHandle("term_1", () => notifyTriggeringPane(effects, "crew-afk (alpha): sprint finished."));
  assert.equal(calls.length, 2, "show, then the send attempted once — it just didn't throw");
  assert.equal(result.sent, false);
});

// ─── extractResultMeta: claude's cost/error/turn metadata, scoped to claude only ──────
test("extractResultMeta pulls cost/error/turns/session out of claude's terminal result event", () => {
  const lines = [
    JSON.stringify({ type: "assistant", message: { content: [{ type: "text", text: "hi" }] } }),
    JSON.stringify({
      type: "result",
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
    costUsd: 0.08,
    durationMs: 2500,
    numTurns: 1,
    permissionDenials: [],
    sessionId: "abc123",
  });
});

test("extractResultMeta returns the all-null/empty shape when no result event is found", () => {
  assert.deepEqual(extractResultMeta("claude", [JSON.stringify({ type: "assistant" })]), {
    isError: null,
    costUsd: null,
    durationMs: null,
    numTurns: null,
    permissionDenials: [],
    sessionId: null,
  });
});

test("extractResultMeta returns the empty shape for non-claude platforms — no confirmed equivalent field", () => {
  const lines = [JSON.stringify({ type: "result", is_error: true, total_cost_usd: 1 })];
  assert.deepEqual(extractResultMeta("copilot", lines), {
    isError: null,
    costUsd: null,
    durationMs: null,
    numTurns: null,
    permissionDenials: [],
    sessionId: null,
  });
});

test("extractResultMeta skips unparseable lines instead of throwing", () => {
  const lines = ["not json", JSON.stringify({ type: "result", is_error: true, permission_denials: [{ tool: "Bash" }] })];
  const meta = extractResultMeta("claude", lines);
  assert.equal(meta.isError, true);
  assert.equal(meta.permissionDenials.length, 1);
});
