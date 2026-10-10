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
  ignoredLimitsNotice,
  loadConfig,
  resolveCrew,
  resolvePaneHost,
  resolveSettings,
  resolveWorktreeRoot,
  validateFlags,
} from "../../orchestrator/lib/crew-config.mjs";
import { ROLE_POLICY } from "../../orchestrator/lib/adapters/render.mjs";

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
  const root = tmpRoot({ "afk-models.json": { commandsDiscovery: "" } });
  assert.throws(
    () => loadConfig(root, { write: true, home: EMPTY_HOME }),
    (err) => err instanceof ConfigError && /afk-models\.json: "commandsDiscovery" must be a non-empty string/.test(err.message),
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
  assert.match(r.warnings[0], /still applies to reviewer, triage, commandFinder, prWriter, on claude/);
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

// Every CLI on PATH.
const cliFound = { exec: () => ({ code: 0, stdout: "/usr/bin/x", stderr: "" }) };
const onClaude = (over = {}) => Object.fromEntries(activeRoles().map((r) => [r, { runtime: over[r] ?? "claude", model: null }]));

test("crewPreflight: a pi/codex runtime needs its CLI and nothing else — no dispatcher, no agent file", () => {
  const prev = process.env.CREW_FAKE_DISPATCH;
  delete process.env.CREW_FAKE_DISPATCH;
  try {
    const crew = onClaude({ reviewer: "codex", commandFinder: "pi" });
    assert.deepEqual(crewPreflight(cliFound, EMPTY_HOME, { crew, roles: activeRoles(), launcher: "claude" }), []);
    const noCli = { exec: (cmd, args) => ({ code: /codex/.test(args.join(" ")) ? 1 : 0, stdout: "", stderr: "" }) };
    assert.deepEqual(crewPreflight(noCli, EMPTY_HOME, { crew, roles: activeRoles(), launcher: "claude" }), ["reviewer → codex: codex CLI not found on PATH"]);
  } finally {
    if (prev !== undefined) process.env.CREW_FAKE_DISPATCH = prev;
  }
});

test("activeRoles: the command finder and the PR writer are checked only when the run does them", () => {
  assert.deepEqual(activeRoles(), ["coder", "reviewer", "triage", "commandFinder"]);
  assert.deepEqual(activeRoles({ commands: false, openPr: true }), ["coder", "reviewer", "triage", "prWriter"]);
});

// ─── settings ────────────────────────────────────────────────────────────────

test("loadConfig: every afk setting is validated, all problems at once", () => {
  const root = tmpRoot({
    "config.json": {
      afk: {
        fixFindings: "critical-high",
        maxParallel: 0,
        installDeps: "no",
        squashCommits: 1,
        baselineCheck: "yes",
        integrationCheck: "yes",
        resumeCoderSession: 0,
        timeouts: { coder: -1, worker: 5 },
      },
    },
  });
  assert.throws(
    () => loadConfig(root, { home: EMPTY_HOME }),
    (err) =>
      err instanceof ConfigError &&
      [
        /"afk\.fixFindings" is "critical-high" \(expected actionable, critical, high, medium, none\)/,
        /"afk\.maxParallel" must be a positive integer/,
        /"afk\.installDeps" must be true or false/,
        /"afk\.squashCommits" must be true or false/,
        /"afk\.baselineCheck" must be true or false/,
        /"afk\.integrationCheck" must be true or false/,
        /"afk\.resumeCoderSession" must be true or false/,
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
  assert.equal(defaults.fixFindings, "actionable", "every Actionable finding is fixed unless told otherwise");
  assert.equal("PRDAudit" in defaults, false, "the PRD audit is gone");
  assert.equal(defaults.installDeps, true);
  assert.equal(defaults.squashCommits, false, "squashing rewrites history, so it is opt-in");
  assert.equal(defaults.baselineCheck, true, "the baseline runs unless turned off");
  assert.equal(defaults.integrationCheck, true, "the integration check runs unless turned off");
  assert.equal(defaults.resumeCoderSession, false, "session resume is opt-in until measured");
  assert.equal(defaults.maxParallel, null);
  assert.deepEqual(defaults.timeouts, { coder: 60, reviewer: 20, triage: 20, commandFinder: 5, prWriter: 10, merge: 5 });

  const origin = {};
  const s = resolveSettings({
    afk: { fixFindings: "medium", squashCommits: true, timeouts: { coder: 60, merge: 8 } },
    cli: { fixFindings: "none", timeouts: { merge: 2 } },
    origin,
  });
  assert.equal(s.fixFindings, "none");
  assert.equal(s.squashCommits, true);
  assert.equal(s.timeouts.coder, 60);
  assert.equal(s.timeouts.merge, 2);
  assert.equal(origin.fixFindings, "flag");
  assert.equal(origin["timeouts.merge"], "flag");
  assert.equal(origin.squashCommits, undefined);
});

test("validateFlags: a bad flag names the flag the user typed", () => {
  assert.deepEqual(validateFlags({ fixFindings: "high" }), []);
  assert.deepEqual(validateFlags({ fixFindings: "actionable" }), []);
  assert.match(validateFlags({ fixFindings: "severe" })[0], /^--fix-findings is "severe"/);
  assert.match(validateFlags({ fixFindings: "critical-medium" }, { fixFindings: "--fix-findings" })[0], /^--fix-findings is "critical-medium"/);
  assert.match(validateFlags({ timeouts: { coder: Number.NaN } })[0], /^--coder-timeout must be a positive number/);
  assert.match(validateFlags({ maxParallel: 0 })[0], /^--max-parallel must be a positive integer/);
  // setTimeout fires at once past 2^31-1 ms: a "no limit" timeout would kill every dispatch.
  assert.match(validateFlags({ timeouts: { coder: 40000 } })[0], /^--coder-timeout .* at most 35791/);
  assert.match(validateFlags({ timeouts: { coder: Infinity } })[0], /^--coder-timeout .* at most 35791/);
  assert.deepEqual(validateFlags({ timeouts: { coder: 35791 } }), []);
  // The flag the user typed, once, when more than one sets the same timeout.
  assert.match(validateFlags({ timeouts: { coder: Number.NaN } }, { "timeouts.coder": "--coder-timeout" })[0], /^--coder-timeout /);
  const review = { reviewer: 0, triage: 0, commandFinder: 0, prWriter: 0 };
  const flagOf = Object.fromEntries(Object.keys(review).map((k) => [`timeouts.${k}`, "--reviewer-timeout"]));
  assert.deepEqual(validateFlags({ timeouts: review }, flagOf).length, 1);
  assert.match(validateFlags({ timeouts: review }, flagOf)[0], /^--reviewer-timeout /);
});

test("loadConfig: a legacy afk-models.json's old role names move under the new ones; the PRD audit's is dropped", () => {
  const root = tmpRoot({ "afk-models.json": { commandsDiscovery: "haiku", coverageValidation: "opus" } });
  const { config, notices } = loadConfig(root, { home: EMPTY_HOME });
  assert.deepEqual(config.afk.models.claude, { commandFinder: "haiku" });
  assert.match(notices.join("\n"), /afk-models\.json: unknown key "coverageValidation" is dropped/);
  rmSync(root, { recursive: true, force: true });
});

// ─── the retired PRD audit's settings: accepted, ignored, one notice each ───

test("loadConfig: afk.PRDAudit loads, does nothing, and says so once", () => {
  const root = tmpRoot({ "config.json": { afk: { PRDAudit: "fix", fixFindings: "medium" } } });
  const { config, notices } = loadConfig(root, { home: EMPTY_HOME });
  assert.deepEqual(config.afk, { fixFindings: "medium" });
  assert.equal(notices.length, 1);
  assert.match(notices[0], /`afk\.PRDAudit` no longer does anything: the feature review checks PRD coverage/);
  assert.equal("PRDAudit" in resolveSettings({ afk: config.afk }), false);
  rmSync(root, { recursive: true, force: true });
});

test("loadConfig: the prdAuditor role under models, timeouts or limits loads, with one notice per entry", () => {
  const root = tmpRoot({
    "config.json": {
      afk: {
        models: { claude: { prdAuditor: "opus", coder: "sonnet" } },
        timeouts: { prdAuditor: 30, coder: 60 },
        limits: { prdAuditor: { usd: 1 } },
      },
    },
  });
  const { config, notices } = loadConfig(root, { home: EMPTY_HOME });
  assert.deepEqual(config.afk.models.claude, { coder: "sonnet" });
  assert.deepEqual(config.afk.timeouts, { coder: 60 });
  assert.deepEqual(config.afk.limits ?? {}, {});
  assert.equal(notices.length, 3, notices.join("\n"));
  for (const name of ["afk.models.claude.prdAuditor", "afk.timeouts.prdAuditor", "afk.limits.prdAuditor"]) {
    assert.equal(notices.filter((n) => n.includes(`\`${name}\` no longer does anything`)).length, 1, name);
  }
  rmSync(root, { recursive: true, force: true });
});

test("loadConfig: the user's config may still set the PRD audit, and the notice names that file", () => {
  const root = tmpRoot();
  const home = tmpRoot({ "config.json": { afk: { PRDAudit: "off", runtime: { prdAuditor: "codex" } } } });
  const { notices } = loadConfig(root, { home });
  assert.equal(notices.length, 2);
  assert.ok(notices.every((n) => n.startsWith("~/.coding-crew/config.json: ")), notices.join("\n"));
  rmSync(root, { recursive: true, force: true });
  rmSync(home, { recursive: true, force: true });
});

// ─── tracker: the repo's own, read by tracker-config.mjs ─────────────────────

test("loadConfig: a tracker section is accepted beside afk in the repo's config, rejected in the user's", () => {
  const root = tmpRoot({ "config.json": { afk: { maxParallel: 2 }, tracker: { kind: "github" } } });
  const { config } = loadConfig(root, { home: EMPTY_HOME });
  assert.equal(config.afk.maxParallel, 2);
  const home = tmpRoot({ "config.json": { tracker: { kind: "github" } } });
  assert.throws(
    () => loadConfig(tmpRoot(), { home }),
    (e) => e instanceof ConfigError && /~\/\.coding-crew\/config\.json/.test(e.message) && /"tracker"/.test(e.message),
  );
  for (const d of [root, home]) rmSync(d, { recursive: true, force: true });
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

test("loadConfig: afk.branchPrefix is any string, \"\" included, from either file, the repo's winning", () => {
  const home = tmpRoot({ "config.json": { afk: { branchPrefix: "user/" } } });
  const root = tmpRoot();
  assert.equal(loadConfig(root, { home }).config.afk.branchPrefix, "user/");
  for (const prefix of ["feat/", ""]) {
    const repo = tmpRoot({ "config.json": { afk: { branchPrefix: prefix } } });
    const { config, origin } = loadConfig(repo, { home });
    assert.equal(config.afk.branchPrefix, prefix);
    assert.equal(origin.branchPrefix, "project");
    rmSync(repo, { recursive: true, force: true });
  }
  for (const bad of [3, null, true, ["feat/"]]) {
    const r = tmpRoot({ "config.json": { afk: { branchPrefix: bad } } });
    assert.throws(() => loadConfig(r, { home: EMPTY_HOME }), /"afk\.branchPrefix" must be a string/);
    rmSync(r, { recursive: true, force: true });
  }
  for (const d of [home, root]) rmSync(d, { recursive: true, force: true });
});

test("resolveWorktreeRoot: CREW_WORKTREE_ROOT, then the file, else null (the default)", () => {
  assert.equal(resolveWorktreeRoot({ env: {} }), null);
  assert.equal(resolveWorktreeRoot({ afk: { worktreeRoot: "../wt" }, env: {} }), "../wt");
  const origin = { worktreeRoot: "project" };
  assert.equal(resolveWorktreeRoot({ afk: { worktreeRoot: "../wt" }, env: { CREW_WORKTREE_ROOT: "/wt" }, origin }), "/wt");
  assert.equal(origin.worktreeRoot, "CREW_WORKTREE_ROOT");
});

// ─── afk.limits.<role>.usd ───────────────────────────────────────────────────

test("loadConfig: afk.limits is validated per role, all problems at once", () => {
  const root = tmpRoot({
    "config.json": { afk: { limits: { coder: { usd: 0 }, reviewer: { usd: "5" }, worker: { usd: 1 }, triage: 3, prWriter: { usd: 1, turns: 9 } } } },
  });
  assert.throws(
    () => loadConfig(root, { home: EMPTY_HOME }),
    (err) =>
      err instanceof ConfigError &&
      [
        /"afk\.limits\.coder\.usd" must be a positive number of dollars/,
        /"afk\.limits\.reviewer\.usd" must be a positive number of dollars/,
        /unknown role "afk\.limits\.worker"/,
        /"afk\.limits\.triage" must be an object like \{ "usd": 5 \}/,
        /unknown key "afk\.limits\.prWriter\.turns" \(expected usd\)/,
      ].every((re) => re.test(err.message)),
  );
  rmSync(root, { recursive: true, force: true });
});

test("afk.limits merges one role at a time and is off by default", () => {
  const root = tmpRoot({ "config.json": { afk: { limits: { coder: { usd: 4 } } } } });
  const home = tmpRoot({ "config.json": { afk: { limits: { coder: { usd: 9 }, reviewer: { usd: 1.5 } } } } });
  const { config, origin } = loadConfig(root, { home });
  assert.deepEqual(resolveSettings({ afk: config.afk }).limitsUsd, { coder: 4, reviewer: 1.5 });
  assert.equal(origin["limits.coder.usd"], "project");
  assert.equal(origin["limits.reviewer.usd"], "user");
  assert.deepEqual(resolveSettings({}).limitsUsd, {});
  rmSync(root, { recursive: true, force: true });
  rmSync(home, { recursive: true, force: true });
});

test("ignoredLimitsNotice names each capped role on a runtime with no budget flag, in one line", () => {
  const crew = { coder: { runtime: "claude" }, reviewer: { runtime: "codex" }, triage: { runtime: "pi" } };
  assert.equal(ignoredLimitsNotice({ coder: 5 }, crew), null);
  assert.equal(ignoredLimitsNotice({}, crew), null);
  const notice = ignoredLimitsNotice({ coder: 5, reviewer: 1, triage: 1 }, crew);
  assert.match(notice, /^afk\.limits ignored for reviewer \(codex\), triage \(pi\) — /);
  assert.doesNotMatch(notice, /coder/);
});

test("maxWallMinutes: default 120, flag over config, 0 allowed, non-number rejected", async () => {
  const { resolveSettings, validateFlags, DEFAULT_SETTINGS } = await import("../../orchestrator/lib/crew-config.mjs");
  assert.equal(resolveSettings({}).maxWallMinutes, 120);
  assert.equal(DEFAULT_SETTINGS.maxWallMinutes, 120);
  assert.equal(resolveSettings({ afk: { maxWallMinutes: 30 } }).maxWallMinutes, 30);
  assert.equal(resolveSettings({ afk: { maxWallMinutes: 30 }, cli: { maxWallMinutes: 0 } }).maxWallMinutes, 0);
  assert.deepEqual(validateFlags({ maxWallMinutes: 0 }), []);
  assert.match(validateFlags({ maxWallMinutes: NaN })[0], /--max-wall/);
});

// ─── capabilities: decided by the runtime's adapter, not its name ────────────

// `full` has every optional capability crew-config reads; `bare` has none.
const FAKE_ADAPTERS = {
  full: { defaultModel: "mid", modelTiers: { low: 0, mid: 1, high: 2 }, modelAliasEnv: { mid: "FULL_MID_MODEL" }, budget: (usd) => ["--cap", String(usd)] },
  bare: {},
};

test("resolveCrew takes a runtime's default model and tier order from its adapter", () => {
  const full = resolveCrew({ cliPlatform: "full", afk: { models: { full: { coder: "high", reviewer: "low" } } }, adapters: FAKE_ADAPTERS });
  assert.equal(resolveCrew({ cliPlatform: "full", adapters: FAKE_ADAPTERS }).roles.coder.model, "mid");
  assert.equal(full.roles.reviewer.model, "low");
  assert.equal(full.warnings.length, 1);
  assert.match(full.warnings[0], /reviewer model "low" is a weaker tier than coder model "high"/);
  const bare = resolveCrew({ cliPlatform: "bare", afk: { models: { bare: { coder: "high", reviewer: "low" } } }, adapters: FAKE_ADAPTERS });
  assert.equal(resolveCrew({ cliPlatform: "bare", adapters: FAKE_ADAPTERS }).roles.coder.model, null);
  assert.deepEqual(bare.warnings, [], "no modelTiers, no tier warning");
});

test("describeModel shows an alias mapping only on an adapter with modelAliasEnv", () => {
  const env = { FULL_MID_MODEL: "vendor/mid-7" };
  assert.equal(describeModel("full", "mid", env, FAKE_ADAPTERS), "mid (→ vendor/mid-7, FULL_MID_MODEL)");
  assert.equal(describeModel("bare", "mid", env, FAKE_ADAPTERS), "mid");
});

test("ignoredLimitsNotice: a cap on a runtime whose adapter has no budget is ignored, naming the runtime", () => {
  const crew = { coder: { runtime: "full" }, reviewer: { runtime: "bare" } };
  assert.equal(ignoredLimitsNotice({ coder: 5 }, crew, FAKE_ADAPTERS), null);
  const notice = ignoredLimitsNotice({ coder: 5, reviewer: 1 }, crew, FAKE_ADAPTERS);
  assert.match(notice, /^afk\.limits ignored for reviewer \(bare\) — /);
  assert.match(notice, /not supported by bare/);
  assert.doesNotMatch(notice, /claude/);
});

// ─── afk.effort ──────────────────────────────────────────────────────────────

test("afk.effort: defaults to high, the repo's role wins over the user's, and origin says where each came from", () => {
  assert.deepEqual(resolveSettings({}).effort, { coder: "high", reviewer: "high", triage: "high" });
  const root = tmpRoot({ "config.json": { afk: { effort: { coder: "medium" } } } });
  const home = tmpRoot({ "config.json": { afk: { effort: { coder: "low", reviewer: "max" } } } });
  const loaded = loadConfig(root, { home });
  assert.equal(loaded.origin["effort.coder"], "project");
  assert.equal(loaded.origin["effort.reviewer"], "user");
  const s = resolveSettings({ afk: loaded.config.afk, origin: loaded.origin });
  assert.deepEqual(s.effort, { coder: "medium", reviewer: "max", triage: "high" });
  rmSync(root, { recursive: true, force: true });
  rmSync(home, { recursive: true, force: true });
});

test("afk.effort: the roles it accepts and resolves are ROLE_POLICY's, so a role added there is settable", () => {
  ROLE_POLICY.planner = { readOnly: true, subagents: false, effort: "low" };
  try {
    assert.equal(resolveSettings({}).effort.planner, "low");
    const root = tmpRoot({ "config.json": { afk: { effort: { planner: "medium" } } } });
    const loaded = loadConfig(root, { home: EMPTY_HOME });
    assert.equal(resolveSettings({ afk: loaded.config.afk, origin: loaded.origin }).effort.planner, "medium");
    rmSync(root, { recursive: true, force: true });
  } finally {
    delete ROLE_POLICY.planner;
  }
});

test("afk.effort: a non-object, an unknown role or a non-string value is a config error naming the key", () => {
  for (const [effort, pattern] of [
    ["high", /"afk\.effort" must be an object/],
    [{ commandFinder: "high" }, /unknown role "afk\.effort\.commandFinder"/],
    [{ coder: "" }, /"afk\.effort\.coder" must be a non-empty string/],
    [{ reviewer: 3 }, /"afk\.effort\.reviewer" must be a non-empty string/],
  ]) {
    const root = tmpRoot({ "config.json": { afk: { effort } } });
    assert.throws(() => loadConfig(root, { home: EMPTY_HOME }), pattern);
    rmSync(root, { recursive: true, force: true });
  }
});

test("afk.effort: the feature agent (followup) has no default effort and takes one from afk.effort.followup; watcher is an unknown role", () => {
  assert.equal("followup" in resolveSettings({}).effort, false);
  const root = tmpRoot({ "config.json": { afk: { effort: { followup: "low" } } } });
  const loaded = loadConfig(root, { home: EMPTY_HOME });
  assert.equal(resolveSettings({ afk: loaded.config.afk, origin: loaded.origin }).effort.followup, "low");
  rmSync(root, { recursive: true, force: true });

  const stale = tmpRoot({ "config.json": { afk: { effort: { watcher: "low" } } } });
  assert.throws(() => loadConfig(stale, { home: EMPTY_HOME }), /unknown role "afk\.effort\.watcher"/);
  rmSync(stale, { recursive: true, force: true });
});
