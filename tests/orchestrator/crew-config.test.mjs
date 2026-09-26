import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  ConfigError,
  activeRoles,
  crewPreflight,
  describeModel,
  loadConfig,
  resolveCrew,
  resolvePaneHost,
  resolveSettings,
  resolveWorktreeRoot,
  validateFlags,
} from "../../orchestrator/lib/crew-config.mjs";

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
  assert.deepEqual(loadConfig(root, { home: EMPTY_HOME }), { config: {}, origin: {}, notices: [], legacyMove: null });
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
  const { config, notices, legacyMove } = loadConfig(root, { home: EMPTY_HOME });
  assert.deepEqual(config, { afk: { models: { claude: { coder: "opus" } } } });
  assert.equal(existsSync(join(root, ".coding-crew/config.json")), false);
  assert.equal(existsSync(join(root, ".coding-crew/afk-models.json")), true);
  assert.deepEqual(notices, []);
  assert.match(legacyMove.pending, /will be moved/);
  assert.match(legacyMove.apply(), /moved .*afk-models\.json into/);
  assert.deepEqual(JSON.parse(readFileSync(join(root, ".coding-crew/config.json"), "utf8")), config);
  assert.equal(existsSync(join(root, ".coding-crew/afk-models.json")), false);
  rmSync(root, { recursive: true, force: true });
});

test("loadConfig: a non-object config.json is an error, not overwritten by the legacy move", () => {
  const root = tmpRoot({ "afk-models.json": { coder: "opus" } });
  writeFileSync(join(root, ".coding-crew/config.json"), "[1]");
  assert.throws(
    () => loadConfig(root, { write: true, home: EMPTY_HOME }),
    (err) => err instanceof ConfigError && /config\.json must be a JSON object/.test(err.message),
  );
  assert.equal(readFileSync(join(root, ".coding-crew/config.json"), "utf8"), "[1]");
  assert.equal(existsSync(join(root, ".coding-crew/afk-models.json")), true);
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

test("loadConfig: a legacy file's unknown key is dropped with a notice, as the old loader ignored it", () => {
  const root = tmpRoot({ "afk-models.json": { coder: "opus", _comment: "tiers" } });
  const { config, notices } = loadConfig(root, { write: true, home: EMPTY_HOME });
  assert.deepEqual(config.afk.models.claude, { coder: "opus" });
  assert.deepEqual(read(root, "config.json"), { afk: { models: { claude: { coder: "opus" } } } });
  assert.match(notices.join("\n"), /afk-models\.json: unknown key "_comment" is dropped/);
  assert.match(notices.join("\n"), /moved .*afk-models\.json into/);
  rmSync(root, { recursive: true, force: true });
});

test("loadConfig: a bad legacy value names the key the user wrote, not its new name", () => {
  const root = tmpRoot({ "afk-models.json": { coverageValidation: "" } });
  assert.throws(
    () => loadConfig(root, { write: true, home: EMPTY_HOME }),
    (err) => err instanceof ConfigError && /afk-models\.json: "coverageValidation" must be a non-empty string/.test(err.message),
  );
  assert.equal(existsSync(join(root, ".coding-crew/afk-models.json")), true);
  rmSync(root, { recursive: true, force: true });
});

test("loadConfig: an invalid user config fails before the legacy move writes anything", () => {
  const home = tmpRoot({ "config.json": { afk: { runtime: { reviewer: "nope" } } } });
  const root = tmpRoot({ "afk-models.json": { coder: "opus" } });
  assert.throws(() => loadConfig(root, { write: true, home }), ConfigError);
  assert.equal(existsSync(join(root, ".coding-crew/afk-models.json")), true, "the legacy file was moved anyway");
  assert.equal(existsSync(join(root, ".coding-crew/config.json")), false);
  rmSync(home, { recursive: true, force: true });
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
  const r = resolveCrew({ cliPlatform: "claude", afk: { models: { claude: { coder: "opus", commandFinder: "haiku" } } } });
  assert.equal(r.roles.reviewer.model, "opus");
  assert.equal(r.roles.commandFinder.model, "haiku");
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
  assert.match(r.warnings[0], /still applies to reviewer, triage, commandFinder, prdAuditor, on claude/);
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
const onClaude = (over = {}) => Object.fromEntries(activeRoles().map((r) => [r, { runtime: over[r] ?? "claude", model: null }]));

test("crewPreflight: a runtime only a plain dispatch uses needs its CLI, not its dispatcher", () => {
  const prev = process.env.CREW_FAKE_DISPATCH;
  delete process.env.CREW_FAKE_DISPATCH;
  try {
    const crew = onClaude({ commandFinder: "codex", prdAuditor: "pi" });
    const problems = crewPreflight(cliFound, EMPTY_HOME, {
      crew, roles: activeRoles(), launcher: "claude", dispatcherDirs: { codex: null, pi: null },
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

test("activeRoles: the command finder and the PRD audit are checked only when the run does them", () => {
  assert.deepEqual(activeRoles(), ["coder", "reviewer", "triage", "commandFinder", "prdAuditor"]);
  assert.deepEqual(activeRoles({ commands: false, PRDAudit: "report" }), ["coder", "reviewer", "triage", "prdAuditor"]);
  assert.deepEqual(activeRoles({ PRDAudit: "off" }), ["coder", "reviewer", "triage", "commandFinder"]);
});

// ─── settings ────────────────────────────────────────────────────────────────

test("loadConfig: every afk setting is validated, all problems at once", () => {
  const root = tmpRoot({
    "config.json": {
      afk: {
        fixFindings: "critical-high",
        PRDAudit: true,
        maxParallel: 0,
        installDeps: "no",
        squashCommits: 1,
        timeouts: { coder: -1, worker: 5 },
      },
    },
  });
  assert.throws(
    () => loadConfig(root, { home: EMPTY_HOME }),
    (err) =>
      err instanceof ConfigError &&
      [
        /"afk\.fixFindings" is "critical-high" \(expected critical, high, medium, none\)/,
        /"afk\.PRDAudit" is true \(expected off, report, fix\)/,
        /"afk\.maxParallel" must be a positive integer/,
        /"afk\.installDeps" must be true or false/,
        /"afk\.squashCommits" must be true or false/,
        /"afk\.timeouts\.coder" must be a positive number of minutes/,
        /unknown key "afk\.timeouts\.worker"/,
      ].every((re) => re.test(err.message)),
  );
  rmSync(root, { recursive: true, force: true });
});

test("loadConfig: an Object.prototype name is still an unknown timeouts key", () => {
  const root = tmpRoot({ "config.json": { afk: { timeouts: { toString: 3, constructor: 3 } } } });
  assert.throws(
    () => loadConfig(root, { home: EMPTY_HOME }),
    (err) =>
      err instanceof ConfigError &&
      /unknown key "afk\.timeouts\.toString"/.test(err.message) &&
      /unknown key "afk\.timeouts\.constructor"/.test(err.message),
  );
  rmSync(root, { recursive: true, force: true });
});

test("loadConfig: settings merge per key, the repo's over the user's, timeouts one role at a time", () => {
  const root = tmpRoot({ "config.json": { afk: { fixFindings: "medium", timeouts: { coder: 60 } } } });
  const home = tmpRoot({ "config.json": { afk: { fixFindings: "critical", maxParallel: 5, timeouts: { merge: 8 } } } });
  const { config, origin } = loadConfig(root, { home });
  assert.equal(config.afk.fixFindings, "medium");
  assert.equal(config.afk.maxParallel, 5);
  assert.deepEqual(config.afk.timeouts, { merge: 8, coder: 60 });
  assert.equal(origin.fixFindings, "project");
  assert.equal(origin.maxParallel, "user");
  assert.equal(origin["timeouts.merge"], "user");
  rmSync(root, { recursive: true, force: true });
  rmSync(home, { recursive: true, force: true });
});

test("resolveSettings: defaults, then config.json, then flags — and a flag is credited", () => {
  const defaults = resolveSettings({});
  assert.equal(defaults.fixFindings, "high");
  assert.equal(defaults.PRDAudit, "fix");
  assert.equal(defaults.installDeps, true);
  assert.equal(defaults.squashCommits, true);
  assert.equal(defaults.maxParallel, null);
  assert.deepEqual(defaults.timeouts, { coder: 45, reviewer: 20, triage: 20, commandFinder: 5, prdAuditor: 20, merge: 5 });

  const origin = {};
  const s = resolveSettings({
    afk: { fixFindings: "medium", squashCommits: false, timeouts: { coder: 60, merge: 8 } },
    cli: { fixFindings: "none", timeouts: { merge: 2 } },
    origin,
  });
  assert.equal(s.fixFindings, "none");
  assert.equal(s.squashCommits, false);
  assert.equal(s.timeouts.coder, 60);
  assert.equal(s.timeouts.merge, 2);
  assert.equal(origin.fixFindings, "flag");
  assert.equal(origin["timeouts.merge"], "flag");
  assert.equal(origin.squashCommits, undefined);
});

test("validateFlags: a bad flag names the flag the user typed", () => {
  assert.deepEqual(validateFlags({ fixFindings: "high" }), []);
  assert.match(validateFlags({ fixFindings: "severe" })[0], /^--fix-findings is "severe"/);
  assert.match(validateFlags({ fixFindings: "critical-medium" }, { fixFindings: "--promote" })[0], /^--promote is "critical-medium"/);
  assert.match(validateFlags({ timeouts: { coder: Number.NaN } })[0], /^--coder-timeout must be a positive number/);
  assert.match(validateFlags({ maxParallel: 0 })[0], /^--max-parallel must be a positive integer/);
  // setTimeout fires at once past 2^31-1 ms: a "no limit" timeout would kill every dispatch.
  assert.match(validateFlags({ timeouts: { coder: 40000 } })[0], /^--coder-timeout .* at most 35791/);
  assert.match(validateFlags({ timeouts: { coder: Infinity } })[0], /^--coder-timeout .* at most 35791/);
  assert.deepEqual(validateFlags({ timeouts: { coder: 35791 } }), []);
  // The flag the user typed, once, when more than one sets the same timeout.
  assert.match(validateFlags({ timeouts: { coder: Number.NaN } }, { "timeouts.coder": "--worker-timeout" })[0], /^--worker-timeout /);
  const review = { reviewer: 0, triage: 0, commandFinder: 0, prdAuditor: 0 };
  const flagOf = Object.fromEntries(Object.keys(review).map((k) => [`timeouts.${k}`, "--review-timeout"]));
  assert.deepEqual(validateFlags({ timeouts: review }, flagOf).length, 1);
  assert.match(validateFlags({ timeouts: review }, flagOf)[0], /^--review-timeout /);
});

test("loadConfig: a legacy afk-models.json's old role names move under the new ones", () => {
  const root = tmpRoot({ "afk-models.json": { commandsDiscovery: "haiku", coverageValidation: "opus" } });
  const { config } = loadConfig(root, { home: EMPTY_HOME });
  assert.deepEqual(config.afk.models.claude, { commandFinder: "haiku", prdAuditor: "opus" });
  rmSync(root, { recursive: true, force: true });
});

// ─── paneHost: per-machine, with an env layer ────────────────────────────────

test("loadConfig: afk.paneHost is accepted from the user's config only", () => {
  const home = tmpRoot({ "config.json": { afk: { paneHost: "orca" } } });
  const root = tmpRoot();
  const { config, origin } = loadConfig(root, { home });
  assert.equal(config.afk.paneHost, "orca");
  assert.equal(origin.paneHost, "user");
  const repo = tmpRoot({ "config.json": { afk: { paneHost: "orca" } } });
  assert.throws(() => loadConfig(repo, { home: EMPTY_HOME }), /"afk\.paneHost" is per-machine — set it in ~\/\.coding-crew\/config\.json/);
  // A repo at $HOME: its one file is also the user's.
  assert.equal(loadConfig(home, { home }).config.afk.paneHost, "orca");
  assert.throws(() => loadConfig(root, { home: tmpRoot({ "config.json": { afk: { paneHost: "tmux" } } }) }), /"afk\.paneHost" is "tmux"/);
  for (const d of [home, root, repo]) rmSync(d, { recursive: true, force: true });
});

test("resolvePaneHost: flag, then CREW_PANE_HOST, then ORCA_ENV/HERDR_ENV, then the file, else none", () => {
  const host = (args) => resolvePaneHost({ env: {}, ...args }).paneHost;
  assert.equal(host({}), null);
  assert.equal(host({ afk: { paneHost: "herdr" } }), "herdr");
  assert.equal(host({ afk: { paneHost: "herdr" }, env: { HERDR_ENV: "1" } }), "herdr");
  assert.equal(host({ afk: { paneHost: "herdr" }, env: { ORCA_ENV: "1" } }), "orca");
  assert.equal(host({ env: { ORCA_ENV: "1", CREW_PANE_HOST: "none" } }), null);
  assert.equal(host({ env: { CREW_PANE_HOST: "orca" }, cli: { paneHost: "herdr" } }), "herdr");
  const origin = {};
  resolvePaneHost({ env: { CREW_PANE_HOST: "orca" }, origin });
  assert.equal(origin.paneHost, "CREW_PANE_HOST");
});

test("resolvePaneHost: both legacy vars set is orca with a notice, not an error", () => {
  const r = resolvePaneHost({ env: { ORCA_ENV: "1", HERDR_ENV: "1" } });
  assert.equal(r.paneHost, "orca");
  assert.match(r.notices[0], /both set — using orca/);
});

test("resolvePaneHost: auto picks the host whose terminal id is ambient, orca first", () => {
  const auto = (env) => resolvePaneHost({ afk: { paneHost: "auto" }, env }).paneHost;
  assert.equal(auto({}), null);
  assert.equal(auto({ HERDR_PANE_ID: "p1" }), "herdr");
  assert.equal(auto({ ORCA_TERMINAL_HANDLE: "t1", HERDR_PANE_ID: "p1" }), "orca");
});

test("validateFlags: a bad --pane-host or CREW_PANE_HOST is named", () => {
  assert.match(validateFlags({ paneHost: "tmux" }, {}, {})[0], /^--pane-host is "tmux"/);
  assert.match(validateFlags({}, {}, { CREW_PANE_HOST: "tmux" })[0], /^CREW_PANE_HOST is "tmux"/);
  assert.deepEqual(validateFlags({ paneHost: "auto" }, {}, { CREW_PANE_HOST: "none" }), []);
});

test("loadConfig: afk.worktreeRoot is accepted from either file, the repo's winning", () => {
  const home = tmpRoot({ "config.json": { afk: { worktreeRoot: "/mnt/fast/wt" } } });
  const root = tmpRoot();
  assert.equal(loadConfig(root, { home }).config.afk.worktreeRoot, "/mnt/fast/wt");
  const repo = tmpRoot({ "config.json": { afk: { worktreeRoot: "../wt" } } });
  const { config, origin } = loadConfig(repo, { home });
  assert.equal(config.afk.worktreeRoot, "../wt");
  assert.equal(origin.worktreeRoot, "project");
  for (const bad of ["", "  ", 3]) {
    const r = tmpRoot({ "config.json": { afk: { worktreeRoot: bad } } });
    assert.throws(() => loadConfig(r, { home: EMPTY_HOME }), /"afk\.worktreeRoot" must be a non-empty path/);
    rmSync(r, { recursive: true, force: true });
  }
  for (const d of [home, root, repo]) rmSync(d, { recursive: true, force: true });
});

test("resolveWorktreeRoot: CREW_WORKTREE_ROOT, then the file, else null (the default)", () => {
  assert.equal(resolveWorktreeRoot({ env: {} }), null);
  assert.equal(resolveWorktreeRoot({ afk: { worktreeRoot: "../wt" }, env: {} }), "../wt");
  const origin = { worktreeRoot: "project" };
  assert.equal(resolveWorktreeRoot({ afk: { worktreeRoot: "../wt" }, env: { CREW_WORKTREE_ROOT: "/wt" }, origin }), "/wt");
  assert.equal(origin.worktreeRoot, "CREW_WORKTREE_ROOT");
});
