/**
 * platforms.test.mjs — the conformance test a new platform must pass.
 *
 * A platform is one `orchestrator/platforms.json` entry (where it keeps skills) plus one adapter
 * in `orchestrator/lib/adapters/` (how to run its CLI). Half of that pair fails here, naming the
 * platform: an entry with no adapter, an adapter with no entry, or an adapter missing a field of
 * the contract. Each adapter's `policyArgs(ROLE_POLICY[role])` is pinned to the flags each role
 * carried before role policy was declared once.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { ADAPTERS, DEFAULT_PARALLEL, PLATFORMS } from "../../orchestrator/lib/adapters/index.mjs";
import { ROLE_AGENTS, ROLE_POLICY, renderRolePrompt } from "../../orchestrator/lib/adapters/render.mjs";

const ROLES_DIR = fileURLToPath(new URL("../../orchestrator/roles", import.meta.url));
const PLATFORMS_JSON = JSON.parse(readFileSync(fileURLToPath(new URL("../../orchestrator/platforms.json", import.meta.url)), "utf8"));

/** The adapter contract's required fields, and the type each must have. */
const REQUIRED = {
  cmd: "string",
  defaultParallel: "number",
  coAuthor: "string",
  requiredFlags: "object",
  build: "function",
  policyArgs: "function",
  finalText: "function",
  normalize: "function",
  interactive: "function",
};

/** Every way `data` (platforms.json) and `adapters` disagree, one message per problem, each naming its platform. */
function conformanceProblems(data, adapters) {
  const problems = [];
  for (const p of Object.keys(data)) if (!adapters[p]) problems.push(`${p}: platforms.json entry has no adapter in orchestrator/lib/adapters/`);
  for (const [p, adapter] of Object.entries(adapters)) {
    if (!Object.hasOwn(data, p)) problems.push(`${p}: adapter has no orchestrator/platforms.json entry`);
    for (const [field, type] of Object.entries(REQUIRED)) {
      if (typeof adapter[field] !== type) problems.push(`${p}: adapter lacks ${field} (${type})`);
    }
    // Declared even when the CLI picks its own model (undefined), so the choice is explicit.
    if (!("defaultModel" in adapter)) problems.push(`${p}: adapter lacks defaultModel`);
  }
  return problems;
}

test("platforms.json and the adapters name the same platforms, each adapter with every contract field", () => {
  assert.deepEqual(conformanceProblems(PLATFORMS_JSON, ADAPTERS), []);
  assert.deepEqual([...PLATFORMS].sort(), Object.keys(PLATFORMS_JSON).sort());
  for (const p of PLATFORMS) assert.equal(DEFAULT_PARALLEL[p], ADAPTERS[p].defaultParallel, p);
});

test("conformance names the platform of an entry with no adapter, an adapter with no entry, and a missing field", () => {
  const { build, ...noBuild } = ADAPTERS.pi;
  const problems = conformanceProblems({ ...PLATFORMS_JSON, cursor: {} }, { ...ADAPTERS, pi: noBuild, gemini: { ...ADAPTERS.claude } });
  assert.ok(problems.includes("cursor: platforms.json entry has no adapter in orchestrator/lib/adapters/"), problems.join("\n"));
  assert.ok(problems.includes("gemini: adapter has no orchestrator/platforms.json entry"), problems.join("\n"));
  assert.ok(problems.includes("pi: adapter lacks build (function)"), problems.join("\n"));
  assert.equal(problems.length, 3, problems.join("\n"));
});

test("conformance reports an adapter that does not declare defaultModel", () => {
  const { defaultModel, ...noDefault } = ADAPTERS.codex;
  assert.deepEqual(conformanceProblems(PLATFORMS_JSON, { ...ADAPTERS, codex: noDefault }), ["codex: adapter lacks defaultModel"]);
});

test("conformance reports an adapter without normalize", () => {
  const { normalize, ...noNormalize } = ADAPTERS.claude;
  const problems = conformanceProblems(PLATFORMS_JSON, { ...ADAPTERS, claude: noNormalize });
  assert.deepEqual(problems, ["claude: adapter lacks normalize (function)"]);
});

test("conformance reports an adapter without interactive", () => {
  const { interactive, ...noInteractive } = ADAPTERS.pi;
  assert.deepEqual(conformanceProblems(PLATFORMS_JSON, { ...ADAPTERS, pi: noInteractive }), ["pi: adapter lacks interactive (function)"]);
});

test("ROLE_POLICY declares a policy for every role with a protocol", () => {
  assert.deepEqual(Object.keys(ROLE_POLICY).sort(), Object.keys(ROLE_AGENTS).sort());
});

// The flags each role carried per platform before ROLE_POLICY (role-args.mjs, deleted).
// Since then: the reviewer and triage may spawn sub-agents, so claude no longer denies them Agent.
// And claude passes the role's effort (`--effort`), which it used to drop.
const CLAUDE_READ_ONLY = ["--effort", "high", "--disallowedTools", "Edit", "Write", "NotebookEdit"];
// The feature agent (followup): it edits, takes no sub-agents, and has no effort (its CLI's default applies).
const EXPECTED_POLICY_ARGS = {
  claude: {
    coder: ["--effort", "high", "--disallowedTools", "Agent"],
    reviewer: CLAUDE_READ_ONLY,
    triage: CLAUDE_READ_ONLY,
    followup: ["--disallowedTools", "Agent"],
  },
  copilot: {
    coder: ["--reasoning-effort", "high"],
    reviewer: ["--reasoning-effort", "high", "--deny-tool", "write"],
    triage: ["--reasoning-effort", "high", "--deny-tool", "write"],
    followup: [],
  },
  pi: {
    coder: ["--thinking", "high", "--tools", "read,bash,edit,write"],
    reviewer: ["--thinking", "high", "--tools", "read,bash"],
    triage: ["--thinking", "high", "--tools", "read,bash"],
    followup: ["--tools", "read,bash,edit,write"],
  },
  codex: {
    coder: ["-c", 'model_reasoning_effort="high"'],
    reviewer: ["-c", 'model_reasoning_effort="high"'],
    triage: ["-c", 'model_reasoning_effort="high"'],
    followup: [],
  },
};

for (const platform of Object.keys(EXPECTED_POLICY_ARGS)) {
  test(`${platform}: policyArgs(ROLE_POLICY[role]) is each role's flags`, () => {
    for (const role of Object.keys(ROLE_POLICY)) {
      assert.deepEqual(ADAPTERS[platform].policyArgs(ROLE_POLICY[role]), EXPECTED_POLICY_ARGS[platform][role], `${platform} × ${role}`);
    }
  });
}

test("every platform's expected policy flags are pinned", () => {
  assert.deepEqual(Object.keys(EXPECTED_POLICY_ARGS).sort(), [...PLATFORMS].sort());
});

test("followup is the feature agent: it may edit, takes no sub-agents or default effort, and renders its protocol on every platform", () => {
  assert.equal(ROLE_AGENTS.followup, "crew-followup");
  assert.deepEqual(ROLE_POLICY.followup, { readOnly: false });
  for (const platform of PLATFORMS) {
    const text = renderRolePrompt("followup", platform);
    assert.match(text, /feature agent/i, platform);
    assert.doesNotMatch(text, /\{\{/, platform);
  }
});

test("the feature agent's brief: checkout unchanged until the end notice, follow-up work in place after it, commit everything, never an issue's Status or criteria", () => {
  for (const platform of PLATFORMS) {
    const text = renderRolePrompt("followup", platform);
    assert.match(text, /Until the end notice[\s\S]*leave the checkout unchanged/, platform);
    assert.match(text, /After the end notice[\s\S]*follow-up work in place/, platform);
    assert.match(text, /Commit everything before you stop/, platform);
    assert.match(text, /Never edit an issue's `Status:` line or tick its criteria boxes/, platform);
    assert.doesNotMatch(text, /crew-afk followup|followup (start|wait|reply)|_followup/, platform);
  }
});

test("there is no watcher role", () => {
  assert.equal(ROLE_AGENTS.watcher, undefined);
  assert.equal(ROLE_POLICY.watcher, undefined);
  assert.equal(existsSync(join(ROLES_DIR, "watcher.md")), false);
});

// interactive({cwd, mainRoot, model, protocol, policy}) → argv, `cmd` first: the CLI's own
// interactive mode with the protocol as its initial prompt, then the policy's flags.
const WATCHER = ROLE_POLICY.followup;
const INTERACTIVE = { cwd: "/main", mainRoot: "/main", protocol: "BRIEF", policy: WATCHER };
const EXPECTED_INTERACTIVE = {
  claude: ["claude", "BRIEF", "--add-dir", "/main", "--model", "sonnet", "--disallowedTools", "Agent"],
  codex: ["codex", "--cd", "/main", "--sandbox", "workspace-write", "--model", "gpt-5", "BRIEF"],
  pi: ["pi", "--model", "m1", "--tools", "read,bash,edit,write", "BRIEF"],
  copilot: ["copilot", "-i", "BRIEF", "--add-dir", "/main", "--model", "m1"],
};
const MODELS = { claude: "sonnet", codex: "gpt-5", pi: "m1", copilot: "m1" };

for (const platform of Object.keys(EXPECTED_INTERACTIVE)) {
  test(`${platform}: interactive() is the CLI's interactive argv with the protocol as the initial prompt and the policy's flags`, () => {
    const argv = ADAPTERS[platform].interactive({ ...INTERACTIVE, model: MODELS[platform] });
    assert.deepEqual(argv, EXPECTED_INTERACTIVE[platform]);
    assert.equal(argv[0], ADAPTERS[platform].cmd);
    assert.ok(!argv.includes("-p") && !argv.includes("exec") && !argv.includes("--mode"), "interactive, not a headless run");
  });

  test(`${platform}: interactive() leaves the model flag out for no model or "inherit", and applies a set effort`, () => {
    for (const model of [undefined, "inherit"]) {
      assert.ok(!ADAPTERS[platform].interactive({ ...INTERACTIVE, model }).includes("--model"), `${platform} model=${model}`);
    }
    const effort = ADAPTERS[platform].interactive({ ...INTERACTIVE, policy: { ...WATCHER, effort: "low" } });
    assert.ok(effort.join(" ").includes("low"), effort.join(" "));
  });
}

test("every platform's interactive argv is pinned", () => {
  assert.deepEqual(Object.keys(EXPECTED_INTERACTIVE).sort(), [...PLATFORMS].sort());
});

// A human is in every interactive pane, so no role's argv may turn off its CLI's permission or
// approval prompts, and the feature agent's argv has its edit tools on.
const NO_PROMPT_FLAGS = ["--permission-mode", "bypassPermissions", "--dangerously-skip-permissions", "--allow-all-tools", "--allow-all", "--yolo", "--ask-for-approval", "never"];

for (const platform of Object.keys(EXPECTED_INTERACTIVE)) {
  test(`${platform}: no role's interactive() argv turns off permission or approval prompts`, () => {
    for (const role of Object.keys(ROLE_POLICY)) {
      assert.equal(ROLE_POLICY[role].unattended, undefined, `${role} has no unattended policy`);
      const argv = ADAPTERS[platform].interactive({ ...INTERACTIVE, model: MODELS[platform], policy: ROLE_POLICY[role] });
      for (const flag of NO_PROMPT_FLAGS) assert.ok(!argv.includes(flag), `${platform} × ${role}: ${flag} in ${argv.join(" ")}`);
      assert.ok(!argv.some((a) => /skipDangerousModePermissionPrompt/.test(a)), `${platform} × ${role}: no settings override of the bypass-mode dialog`);
    }
  });
}
