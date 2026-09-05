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

test("resolveModelTiers: no file, no --model — every role is null (today's behavior)", () => {
  const r = resolveModelTiers({ fileConfig: {}, cliModel: null, platform: "claude" });
  assert.deepEqual(r, { coder: null, reviewer: null, triage: null, warnings: [] });
});

test("resolveModelTiers: no file, --model given — all three roles match it, unchanged", () => {
  const r = resolveModelTiers({ fileConfig: {}, cliModel: "opus", platform: "claude" });
  assert.deepEqual(r, { coder: "opus", reviewer: "opus", triage: "opus", warnings: [] });
});

test("resolveModelTiers: file sets only coder — reviewer/triage default to it by omission", () => {
  const r = resolveModelTiers({ fileConfig: { coder: "opus" }, cliModel: null, platform: "claude" });
  assert.deepEqual(r, { coder: "opus", reviewer: "opus", triage: "opus", warnings: [] });
});

test("resolveModelTiers: file explicitly diverges reviewer — that value is kept, no warning if stronger", () => {
  const r = resolveModelTiers({
    fileConfig: { coder: "sonnet", reviewer: "opus" },
    cliModel: null,
    platform: "claude",
  });
  assert.deepEqual(r, { coder: "sonnet", reviewer: "opus", triage: "sonnet", warnings: [] });
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

test("resolveModelTiers: the same weaker-tier divergence on a non-claude platform is silently unranked", () => {
  const r = resolveModelTiers({
    fileConfig: { coder: "opus", triage: "haiku" },
    cliModel: null,
    platform: "codex",
  });
  assert.equal(r.triage, "haiku");
  assert.deepEqual(r.warnings, [], "codex/pi/copilot model strings are opaque — no ranking is known");
});

test("resolveModelTiers: 'inherit' (mapped to null upstream) is unranked, never warns", () => {
  const r = resolveModelTiers({
    fileConfig: { coder: null, reviewer: "haiku" },
    cliModel: null,
    platform: "claude",
  });
  assert.deepEqual(r.warnings, []);
});
