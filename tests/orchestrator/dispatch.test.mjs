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

import { buildDispatch, preflight, resolveAgentFile, splitFrontmatter, DEFAULT_PARALLEL } from "../../orchestrator/lib/dispatch.mjs";

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
