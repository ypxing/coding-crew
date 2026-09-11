import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { loadModelConfig, resolveModelTiers } from "../../orchestrator/lib/model-config.mjs";

function tmpRoot() {
  return mkdtempSync(join(tmpdir(), "model-config-"));
}

test("loadModelConfig returns {} when .coding-crew/afk-models.json is absent", () => {
  const root = tmpRoot();
  assert.deepEqual(loadModelConfig(root), {});
  rmSync(root, { recursive: true, force: true });
});

test("loadModelConfig returns {} and warns, rather than throwing, on malformed JSON", () => {
  const root = tmpRoot();
  mkdirSync(join(root, ".coding-crew"));
  writeFileSync(join(root, ".coding-crew/afk-models.json"), "{ not json");
  assert.deepEqual(loadModelConfig(root), {});
  rmSync(root, { recursive: true, force: true });
});

test("loadModelConfig parses a well-formed file", () => {
  const root = tmpRoot();
  mkdirSync(join(root, ".coding-crew"));
  writeFileSync(join(root, ".coding-crew/afk-models.json"), JSON.stringify({ coder: "opus" }));
  assert.deepEqual(loadModelConfig(root), { coder: "opus" });
  rmSync(root, { recursive: true, force: true });
});

test("resolveModelTiers: no file, no --model, claude platform — coder defaults to sonnet, every role matches it", () => {
  const r = resolveModelTiers({ fileConfig: {}, cliModel: null, platform: "claude" });
  assert.deepEqual(r, {
    coder: "sonnet",
    reviewer: "sonnet",
    triage: "sonnet",
    commandsDiscovery: "sonnet",
    coverageValidation: "sonnet",
    warnings: [],
  });
});

test("resolveModelTiers: no file, no --model, non-claude platform — every role is null (no known default)", () => {
  const r = resolveModelTiers({ fileConfig: {}, cliModel: null, platform: "codex" });
  assert.deepEqual(r, {
    coder: null,
    reviewer: null,
    triage: null,
    commandsDiscovery: null,
    coverageValidation: null,
    warnings: [],
  });
});

test("resolveModelTiers: no file, --model given — all roles match it, unchanged", () => {
  const r = resolveModelTiers({ fileConfig: {}, cliModel: "opus", platform: "claude" });
  assert.deepEqual(r, {
    coder: "opus",
    reviewer: "opus",
    triage: "opus",
    commandsDiscovery: "opus",
    coverageValidation: "opus",
    warnings: [],
  });
});

test("resolveModelTiers: file sets only coder — reviewer/triage/commandsDiscovery/coverageValidation default to it by omission", () => {
  const r = resolveModelTiers({ fileConfig: { coder: "opus" }, cliModel: null, platform: "claude" });
  assert.deepEqual(r, {
    coder: "opus",
    reviewer: "opus",
    triage: "opus",
    commandsDiscovery: "opus",
    coverageValidation: "opus",
    warnings: [],
  });
});

test("resolveModelTiers: file explicitly diverges reviewer — that value is kept, no warning if stronger", () => {
  const r = resolveModelTiers({
    fileConfig: { coder: "sonnet", reviewer: "opus" },
    cliModel: null,
    platform: "claude",
  });
  assert.deepEqual(r, {
    coder: "sonnet",
    reviewer: "opus",
    triage: "sonnet",
    commandsDiscovery: "sonnet",
    coverageValidation: "sonnet",
    warnings: [],
  });
});

test("resolveModelTiers: file explicitly diverges commandsDiscovery — that value is kept", () => {
  const r = resolveModelTiers({
    fileConfig: { coder: "sonnet", commandsDiscovery: "haiku" },
    cliModel: null,
    platform: "claude",
  });
  assert.equal(r.commandsDiscovery, "haiku");
  assert.equal(r.coder, "sonnet");
});

test("resolveModelTiers: file explicitly diverges coverageValidation — that value is kept, warns if weaker", () => {
  const r = resolveModelTiers({
    fileConfig: { coder: "opus", coverageValidation: "haiku" },
    cliModel: null,
    platform: "claude",
  });
  assert.equal(r.coverageValidation, "haiku");
  assert.equal(r.warnings.length, 1);
  assert.match(r.warnings[0], /coverageValidation model "haiku" is a weaker tier than coder model "opus"/);
});

test("resolveModelTiers: --model overrides the file's coder; the file's explicit reviewer is kept", () => {
  const r = resolveModelTiers({
    fileConfig: { coder: "opus", reviewer: "opus" },
    cliModel: "haiku",
    platform: "claude",
  });
  assert.equal(r.coder, "haiku");
  assert.equal(r.reviewer, "opus");
  assert.equal(r.triage, "haiku");
});

test("resolveModelTiers: an explicit weaker reviewer on the claude platform warns, but is not blocked", () => {
  const r = resolveModelTiers({
    fileConfig: { coder: "opus", reviewer: "haiku" },
    cliModel: null,
    platform: "claude",
  });
  assert.equal(r.reviewer, "haiku", "advisory only — the value is honored, not overridden");
  assert.equal(r.warnings.length, 1);
  assert.match(r.warnings[0], /reviewer model "haiku" is a weaker tier than coder model "opus"/);
});

test("resolveModelTiers: a non-empty file on a non-claude platform is ignored, with a warning", () => {
  const r = resolveModelTiers({
    fileConfig: { coder: "opus", triage: "haiku" },
    cliModel: null,
    platform: "codex",
  });
  assert.equal(r.triage, null, "the file's values are not honored outside the claude platform");
  assert.equal(r.coder, null);
  assert.equal(r.warnings.length, 1);
  assert.match(r.warnings[0], /afk-models\.json is ignored on the codex platform/);
});

test("resolveModelTiers: a --model override still applies on a non-claude platform even though the file is ignored", () => {
  const r = resolveModelTiers({
    fileConfig: { coder: "opus", triage: "haiku" },
    cliModel: "some-codex-model",
    platform: "codex",
  });
  assert.equal(r.coder, "some-codex-model");
  assert.equal(r.triage, "some-codex-model");
  assert.equal(r.warnings.length, 1, "the file is still ignored (and still warned about) even when --model wins");
});

test("resolveModelTiers: an explicit null coder (file's 'inherit') still resolves to the claude default, so a weaker reviewer now warns", () => {
  // Previously coder stayed unresolved (null) here, which hid this exact divergence from
  // the warning check — the blind spot CLAUDE_DEFAULT_CODER_MODEL exists to close: a
  // default living only in claude.agent.md's frontmatter was invisible to this comparison.
  const r = resolveModelTiers({
    fileConfig: { coder: null, reviewer: "haiku" },
    cliModel: null,
    platform: "claude",
  });
  assert.equal(r.coder, "sonnet");
  assert.equal(r.warnings.length, 1);
  assert.match(r.warnings[0], /reviewer model "haiku" is a weaker tier than coder model "sonnet"/);
});

test("resolveModelTiers: an explicit null coder on a non-claude platform stays unresolved (file ignored anyway)", () => {
  const r = resolveModelTiers({
    fileConfig: { coder: null, reviewer: "haiku" },
    cliModel: null,
    platform: "codex",
  });
  assert.equal(r.coder, null);
  assert.equal(r.reviewer, null);
  assert.equal(r.warnings.length, 1);
});
