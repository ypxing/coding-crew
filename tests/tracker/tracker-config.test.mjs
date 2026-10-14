import { test } from "node:test";
import assert from "node:assert/strict";
import { copyFileSync, mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { readTrackerConfig } from "../../tracker/tracker-config.mjs";
import { run } from "../../tracker/cli.mjs";

const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), "..", "fixtures", "tracker-config");

function repo() {
  return mkdtempSync(join(tmpdir(), "crew-tracker-config-"));
}

/** Write `.coding-crew/<rel>`: a fixture file's copy (`{fixture}`) or the given text. */
function put(root, rel, content) {
  const path = join(root, ".coding-crew", rel);
  mkdirSync(dirname(path), { recursive: true });
  if (content.fixture) copyFileSync(join(FIXTURES, content.fixture), path);
  else writeFileSync(path, content);
}
const legacyDoc = (root, content) => put(root, "docs/issue-tracker.md", content);
const configJson = (root, content) => put(root, "config.json", typeof content === "string" ? content : JSON.stringify(content));

async function cliConfig(root) {
  let stdout = "";
  let stderr = "";
  const code = await run(["config", "--main-root", root], { out: (s) => (stdout += s), err: (s) => (stderr += s) });
  return { code, stdout, stderr };
}

test("config.json's tracker section, with no issue-tracker.md, resolves github and configured", () => {
  const root = repo();
  configJson(root, { tracker: { kind: "github" } });
  assert.deepEqual(readTrackerConfig(root), { tracker: "github", configured: true });
});

test("config.json's tracker section wins over the legacy front matter", () => {
  const root = repo();
  configJson(root, { tracker: { kind: "local" } });
  legacyDoc(root, { fixture: "issue-tracker-github.md" });
  assert.deepEqual(readTrackerConfig(root), { tracker: "local", configured: true });
});

test("a legacy issue-tracker.md with front matter tracker: github resolves github, configured", () => {
  const root = repo();
  configJson(root, { fixture: "config-afk-only.json" });
  legacyDoc(root, { fixture: "issue-tracker-github.md" });
  assert.deepEqual(readTrackerConfig(root), { tracker: "github", configured: true });
});

test("a legacy issue-tracker.md with no front matter resolves local, configured", () => {
  const root = repo();
  configJson(root, { fixture: "config-afk-only.json" });
  legacyDoc(root, { fixture: "issue-tracker-no-front-matter.md" });
  assert.deepEqual(readTrackerConfig(root), { tracker: "local", configured: true });
});

test("neither config.json's tracker section nor issue-tracker.md: local, not configured", () => {
  const root = repo();
  assert.deepEqual(readTrackerConfig(root), { tracker: "local", configured: false });
  configJson(root, { fixture: "config-afk-only.json" });
  assert.deepEqual(readTrackerConfig(root), { tracker: "local", configured: false });
});

for (const [name, content] of [
  ["config.json that is not valid JSON", "{ tracker: github"],
  ["an unknown tracker.kind", { tracker: { kind: "jira" } }],
  ["a tracker section with no kind", { tracker: {} }],
  ["a tracker section that is not an object", { tracker: "github" }],
]) {
  test(`${name} throws naming .coding-crew/config.json, and cli config exits 1`, async () => {
    const root = repo();
    configJson(root, content);
    assert.throws(() => readTrackerConfig(root), /\.coding-crew\/config\.json/);
    const r = await cliConfig(root);
    assert.equal(r.code, 1);
    assert.equal(r.stdout, "");
    assert.match(r.stderr, /\.coding-crew\/config\.json/);
  });
}

test("a legacy front matter naming repo: throws `repo` is no longer supported with the path; cli config exits 1", async () => {
  const root = repo();
  legacyDoc(root, "---\ntracker: github\nrepo: owner/name\n---\n\n# Issue tracker\n");
  const path = join(root, ".coding-crew/docs/issue-tracker.md");
  assert.throws(() => readTrackerConfig(root), (e) => e.message.includes("`repo` is no longer supported") && e.message.includes(path));
  const r = await cliConfig(root);
  assert.equal(r.code, 1);
  assert.ok(r.stderr.includes("`repo` is no longer supported"), r.stderr);
  assert.ok(r.stderr.includes(path), r.stderr);
});

test("cli config prints exactly tracker=<kind> and configured=yes|no, exit 0", async () => {
  const root = repo();
  assert.deepEqual(await cliConfig(root), { code: 0, stdout: "tracker=local\nconfigured=no\n", stderr: "" });
  configJson(root, { tracker: { kind: "github" } });
  assert.deepEqual(await cliConfig(root), { code: 0, stdout: "tracker=github\nconfigured=yes\n", stderr: "" });
});
