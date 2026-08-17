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
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { buildDispatch, dispatchPlain, preflight, resolveAgentFile, splitFrontmatter, DEFAULT_PARALLEL } from "../../orchestrator/lib/dispatch.mjs";
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
  assert.match(argv, /--silent/);
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
