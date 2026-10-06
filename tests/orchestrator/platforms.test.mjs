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
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { ADAPTERS, DEFAULT_PARALLEL, PLATFORMS } from "../../orchestrator/lib/adapters/index.mjs";
import { ROLE_AGENTS, ROLE_POLICY } from "../../orchestrator/lib/adapters/render.mjs";

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

test("conformance reports an adapter without normalize", () => {
  const { normalize, ...noNormalize } = ADAPTERS.claude;
  const problems = conformanceProblems(PLATFORMS_JSON, { ...ADAPTERS, claude: noNormalize });
  assert.deepEqual(problems, ["claude: adapter lacks normalize (function)"]);
});

test("ROLE_POLICY declares a policy for every role with a protocol", () => {
  assert.deepEqual(Object.keys(ROLE_POLICY).sort(), Object.keys(ROLE_AGENTS).sort());
});

// The flags each role carried per platform before ROLE_POLICY (role-args.mjs, deleted).
const CLAUDE_READ_ONLY = ["--disallowedTools", "Edit", "Write", "NotebookEdit", "Agent"];
const EXPECTED_POLICY_ARGS = {
  claude: { coder: ["--disallowedTools", "Agent"], reviewer: CLAUDE_READ_ONLY, triage: CLAUDE_READ_ONLY },
  copilot: { coder: [], reviewer: ["--deny-tool", "write"], triage: ["--deny-tool", "write"] },
  pi: { coder: ["--tools", "read,bash,edit,write"], reviewer: ["--tools", "read,bash"], triage: ["--tools", "read,bash"] },
  codex: {
    coder: ["-c", 'model_reasoning_effort="medium"'],
    reviewer: ["-c", 'model_reasoning_effort="high"'],
    triage: ["-c", 'model_reasoning_effort="high"'],
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
