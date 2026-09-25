import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { ConfigError, activeRoles, crewPreflight, describeModel, loadConfig, resolveCrew } from "../../orchestrator/lib/crew-config.mjs";

function tmpRoot(files = {}) {
  const root = mkdtempSync(join(tmpdir(), "crew-config-"));
  mkdirSync(join(root, ".coding-crew"));
  for (const [name, value] of Object.entries(files)) {
    writeFileSync(join(root, ".coding-crew", name), typeof value === "string" ? value : JSON.stringify(value));
  }
  return root;
}
const EMPTY_HOME = mkdtempSync(join(tmpdir(), "crew-config-home-"));
const read = (root, name) => JSON.parse(readFileSync(join(root, ".coding-crew", name), "utf8"));
const models = (r) => Object.fromEntries(Object.entries(r.roles).map(([k, v]) => [k, v.model]));
const runtimes = (r) => Object.fromEntries(Object.entries(r.roles).map(([k, v]) => [k, v.runtime]));

// ─── loadConfig ──────────────────────────────────────────────────────────────

test("loadConfig: no files is an empty config", () => {
  const root = tmpRoot();
  assert.deepEqual(loadConfig(root, { home: EMPTY_HOME }), { config: {}, origin: {}, notices: [] });
  rmSync(root, { recursive: true, force: true });
});

test("loadConfig: malformed JSON is a ConfigError, not silently ignored", () => {
  const root = tmpRoot({ "config.json": "{ not json" });
  assert.throws(() => loadConfig(root, { home: EMPTY_HOME }), ConfigError);
  rmSync(root, { recursive: true, force: true });
});

test("loadConfig: a legacy afk-models.json moves into afk.models.claude of an existing config.json, and is deleted", () => {
  const root = tmpRoot({ "afk-models.json": { coder: "sonnet", reviewer: "opus", triage: null } });
  writeFileSync(join(root, ".coding-crew/config.json"), JSON.stringify({}));
  const { config, notices } = loadConfig(root, { write: true, home: EMPTY_HOME });
  const want = { afk: { models: { claude: { coder: "sonnet", reviewer: "opus" } } } };
  assert.deepEqual(config, want, "null (the old 'inherit') is dropped, since absent means that now");
  assert.deepEqual(read(root, "config.json"), want);
  assert.equal(existsSync(join(root, ".coding-crew/afk-models.json")), false);
  assert.match(notices[0], /moved .*afk-models\.json into .*config\.json \(afk\.models\.claude\) — commit it/);
  rmSync(root, { recursive: true, force: true });
});

test("loadConfig: without write, the move happens in memory only", () => {
  const root = tmpRoot({ "afk-models.json": { coder: "opus" } });
  const { config, notices } = loadConfig(root, { home: EMPTY_HOME });
  assert.deepEqual(config, { afk: { models: { claude: { coder: "opus" } } } });
  assert.equal(existsSync(join(root, ".coding-crew/config.json")), false);
  assert.equal(existsSync(join(root, ".coding-crew/afk-models.json")), true);
  assert.match(notices[0], /will be moved/);
  rmSync(root, { recursive: true, force: true });
});

test("loadConfig: both files present — config.json wins, the legacy file is left alone and named", () => {
  const root = tmpRoot({
    "afk-models.json": { coder: "haiku" },
    "config.json": { afk: { models: { claude: { coder: "opus" } } } },
  });
  const { config, notices } = loadConfig(root, { write: true, home: EMPTY_HOME });
  assert.equal(config.afk.models.claude.coder, "opus");
  assert.equal(existsSync(join(root, ".coding-crew/afk-models.json")), true);
  assert.match(notices[0], /afk-models\.json is ignored/);
  rmSync(root, { recursive: true, force: true });
});

test("loadConfig: a legacy file with an unknown role fails validation instead of being moved", () => {
  const root = tmpRoot({ "afk-models.json": { reviwer: "opus" } });
  // Named in the legacy file's own terms: that's the file and key the user has to fix.
  assert.throws(
    () => loadConfig(root, { write: true, home: EMPTY_HOME }),
    (err) => err instanceof ConfigError && /^\.coding-crew\/afk-models\.json: unknown role "reviwer"/.test(err.message),
  );
  assert.equal(existsSync(join(root, ".coding-crew/afk-models.json")), true);
  rmSync(root, { recursive: true, force: true });
});

test("loadConfig: every validation problem is reported at once", () => {
  const root = tmpRoot({
    "config.json": {
      trackr: {},
      afk: { runtimes: {}, runtime: { coder: "cursor" }, models: { gemini: {}, claude: { coder: 3 } } },
    },
  });
  let message = "";
  try {
    loadConfig(root, { home: EMPTY_HOME });
  } catch (err) {
    assert.ok(err instanceof ConfigError);
    message = err.message;
  }
  for (const want of [
    /unknown section "trackr"/,
    /unknown key "afk\.runtimes"/,
    /"afk\.runtime\.coder" is "cursor"/,
    /unknown runtime "afk\.models\.gemini"/,
    /"afk\.models\.claude\.coder" must be a non-empty string/,
  ]) {
    assert.match(message, want);
  }
  rmSync(root, { recursive: true, force: true });
});

// ─── user level (~/.coding-crew/config.json) under the repo's ─────────────────

test("loadConfig: the user's config applies where the repo's says nothing, per setting", () => {
  const home = tmpRoot({
    "config.json": { afk: { runtime: { reviewer: "codex" }, models: { claude: { coder: "opus", triage: "haiku" } } } },
  });
  const root = tmpRoot({ "config.json": { afk: { models: { claude: { coder: "sonnet" } } } } });
  const { config, origin } = loadConfig(root, { home });
  assert.deepEqual(config.afk, { runtime: { reviewer: "codex" }, models: { claude: { coder: "sonnet", triage: "haiku" } } });
  assert.deepEqual(origin, { "runtime.reviewer": "user", "models.claude.coder": "project", "models.claude.triage": "user" });
  rmSync(home, { recursive: true, force: true });
  rmSync(root, { recursive: true, force: true });
});

test("loadConfig: only a user config — it is the whole config", () => {
  const home = tmpRoot({ "config.json": { afk: { runtime: { triage: "pi" } } } });
  const root = tmpRoot();
  assert.deepEqual(loadConfig(root, { home }).config, { afk: { runtime: { triage: "pi" } } });
  rmSync(home, { recursive: true, force: true });
  rmSync(root, { recursive: true, force: true });
});

test("loadConfig: an invalid user config is an error naming the user file", () => {
  const home = tmpRoot({ "config.json": { afk: { runtime: { coder: "cursor" } } } });
  const root = tmpRoot();
  assert.throws(() => loadConfig(root, { home }), /~\/\.coding-crew\/config\.json: "afk\.runtime\.coder" is "cursor"/);
  rmSync(home, { recursive: true, force: true });
  rmSync(root, { recursive: true, force: true });
});

test("loadConfig: a repo at $HOME is one file, read once, as the repo's", () => {
  const root = tmpRoot({ "config.json": { afk: { runtime: { reviewer: "codex" } } } });
  const { origin } = loadConfig(root, { home: root });
  assert.deepEqual(origin, { "runtime.reviewer": "project" });
  rmSync(root, { recursive: true, force: true });
});

test("loadConfig: the legacy move writes only the repo's config, never the user's", () => {
  const home = tmpRoot({ "config.json": { afk: { runtime: { reviewer: "codex" } } } });
  const root = tmpRoot({ "afk-models.json": { coder: "opus" } });
  const { config } = loadConfig(root, { write: true, home });
  assert.deepEqual(read(root, "config.json"), { afk: { models: { claude: { coder: "opus" } } } });
  assert.deepEqual(read(home, "config.json"), { afk: { runtime: { reviewer: "codex" } } });
  assert.deepEqual(config.afk, { runtime: { reviewer: "codex" }, models: { claude: { coder: "opus" } } });
  rmSync(home, { recursive: true, force: true });
  rmSync(root, { recursive: true, force: true });
});

// ─── resolveCrew: one runtime (the common case, and every sprint before config.json) ──

test("resolveCrew: nothing configured, claude — every role on claude, on the coder's default", () => {
  const r = resolveCrew({ cliPlatform: "claude" });
  assert.deepEqual(new Set(Object.values(runtimes(r))), new Set(["claude"]));
  assert.deepEqual(new Set(Object.values(models(r))), new Set(["sonnet"]));
  assert.deepEqual(r.warnings, []);
});

test("resolveCrew: nothing configured, non-claude — no known default, so no --model for anyone", () => {
  const r = resolveCrew({ cliPlatform: "codex" });
  assert.deepEqual(new Set(Object.values(models(r))), new Set([null]));
});

test("resolveCrew: --model sets every role on the launcher's runtime", () => {
  const r = resolveCrew({ cliPlatform: "codex", cliModel: "gpt-5.1-codex" });
  assert.deepEqual(new Set(Object.values(models(r))), new Set(["gpt-5.1-codex"]));
});

test("resolveCrew: an omitted role inherits the coder's model; a named one keeps its own", () => {
  const r = resolveCrew({ cliPlatform: "claude", afk: { models: { claude: { coder: "opus", commandsDiscovery: "haiku" } } } });
  assert.equal(r.roles.reviewer.model, "opus");
  assert.equal(r.roles.commandsDiscovery.model, "haiku");
});

test("resolveCrew: --model overrides the file's coder; the file's explicit reviewer is kept", () => {
  const r = resolveCrew({ cliPlatform: "claude", cliModel: "haiku", afk: { models: { claude: { coder: "opus", reviewer: "opus" } } } });
  assert.equal(r.roles.coder.model, "haiku");
  assert.equal(r.roles.reviewer.model, "opus");
  assert.equal(r.roles.triage.model, "haiku");
});

test("resolveCrew: an explicit weaker claude role warns, but is honoured", () => {
  const r = resolveCrew({ cliPlatform: "claude", afk: { models: { claude: { coder: "opus", reviewer: "haiku" } } } });
  assert.equal(r.roles.reviewer.model, "haiku");
  assert.equal(r.warnings.length, 1);
  assert.match(r.warnings[0], /reviewer model "haiku" is a weaker tier than coder model "opus"/);
});

test("resolveCrew: claude models are not honoured when the sprint runs on another runtime", () => {
  const r = resolveCrew({ cliPlatform: "pi", afk: { models: { claude: { coder: "opus" } } } });
  assert.equal(r.roles.coder.model, null);
});

// ─── resolveCrew: mixed runtimes ─────────────────────────────────────────────

test("resolveCrew: a role moved to another runtime does not inherit the coder's model", () => {
  const r = resolveCrew({ cliPlatform: "claude", afk: { runtime: { reviewer: "codex" } } });
  assert.deepEqual(r.roles.coder, { runtime: "claude", model: "sonnet" });
  assert.deepEqual(r.roles.reviewer, { runtime: "codex", model: null });
  assert.deepEqual(r.roles.triage, { runtime: "claude", model: "sonnet" });
});

test("resolveCrew: a moved role takes the model named under its own runtime", () => {
  const r = resolveCrew({
    cliPlatform: "claude",
    afk: { runtime: { reviewer: "codex" }, models: { codex: { reviewer: "gpt-5.1-codex" } } },
  });
  assert.equal(r.roles.reviewer.model, "gpt-5.1-codex");
});

test("resolveCrew: a role moved onto claude gets claude's default, not the codex coder's model", () => {
  const r = resolveCrew({ cliPlatform: "codex", cliModel: "gpt-5.1-codex", afk: { runtime: { triage: "claude" } } });
  assert.equal(r.roles.coder.model, "gpt-5.1-codex");
  assert.deepEqual(r.roles.triage, { runtime: "claude", model: "sonnet" });
});

test("resolveCrew: a coder moved off the launcher's runtime ignores --model, and says so", () => {
  const r = resolveCrew({ cliPlatform: "claude", cliModel: "opus", afk: { runtime: { coder: "codex" } } });
  assert.deepEqual(r.roles.coder, { runtime: "codex", model: null });
  assert.equal(r.roles.reviewer.model, "opus", "--model still reaches the roles left on the launcher's runtime");
  assert.match(r.warnings[0], /--model opus is ignored for the coder: it runs on codex/);
});

test("resolveCrew: no tier warning across runtimes, where there is nothing to compare", () => {
  const r = resolveCrew({
    cliPlatform: "claude",
    afk: { runtime: { reviewer: "codex" }, models: { claude: { coder: "opus" }, codex: { reviewer: "haiku" } } },
  });
  assert.deepEqual(r.warnings, []);
});

// ─── describeModel ───────────────────────────────────────────────────────────

test("describeModel shows a visible ANTHROPIC_DEFAULT_*_MODEL mapping for a claude alias", () => {
  const env = { ANTHROPIC_DEFAULT_SONNET_MODEL: "au.anthropic.claude-sonnet-5" };
  assert.equal(describeModel("claude", "sonnet", env), "sonnet (→ au.anthropic.claude-sonnet-5, ANTHROPIC_DEFAULT_SONNET_MODEL)");
  assert.equal(describeModel("claude", "opus", env), "opus");
  assert.equal(describeModel("codex", "sonnet", env), "sonnet", "the Anthropic env vars mean nothing to codex");
  assert.equal(describeModel("codex", null, env), "runtime default");
});

// ─── crewPreflight ───────────────────────────────────────────────────────────

// Every CLI on PATH, no agent definition anywhere: only dispatcher and agent problems remain.
const cliFound = { exec: () => ({ code: 0, stdout: "/usr/bin/x", stderr: "" }) };
const onClaude = (over = {}) => Object.fromEntries(activeRoles({ coverage: true }).map((r) => [r, { runtime: over[r] ?? "claude", model: null }]));

test("crewPreflight: a runtime only a plain dispatch uses needs its CLI, not its dispatcher", () => {
  const prev = process.env.CREW_FAKE_DISPATCH;
  delete process.env.CREW_FAKE_DISPATCH;
  try {
    const crew = onClaude({ commandsDiscovery: "codex", coverageValidation: "pi" });
    const problems = crewPreflight(cliFound, EMPTY_HOME, {
      crew, roles: activeRoles({ coverage: true }), launcher: "claude", dispatcherDirs: { codex: null, pi: null },
    });
    assert.deepEqual(problems.filter((p) => /→ (codex|pi)/.test(p)), [], problems.join("\n"));
  } finally {
    if (prev !== undefined) process.env.CREW_FAKE_DISPATCH = prev;
  }
});

test("crewPreflight: an agent on a pi/codex runtime still needs that runtime's dispatcher", () => {
  const prev = process.env.CREW_FAKE_DISPATCH;
  delete process.env.CREW_FAKE_DISPATCH;
  try {
    const problems = crewPreflight(cliFound, EMPTY_HOME, {
      crew: onClaude({ reviewer: "codex" }), roles: activeRoles(), launcher: "claude", dispatcherDirs: { codex: null },
    });
    assert.ok(problems.includes("reviewer → codex: dispatch-codex-agent.sh not found for codex — run: ./install.sh codex --skill crew-afk"), problems.join("\n"));
  } finally {
    if (prev !== undefined) process.env.CREW_FAKE_DISPATCH = prev;
  }
});

test("activeRoles: command discovery and coverage validation are checked only when the run does them", () => {
  assert.deepEqual(activeRoles(), ["coder", "reviewer", "triage", "commandsDiscovery"]);
  assert.deepEqual(activeRoles({ commands: false }), ["coder", "reviewer", "triage"]);
  assert.deepEqual(activeRoles({ coverage: true }), ["coder", "reviewer", "triage", "commandsDiscovery", "coverageValidation"]);
});
