import { beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { copyFileSync, mkdtempSync, mkdirSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { mainCheckout, readTrackerConfig } from "../../lib/tracker/tracker-config.mjs";
import { run } from "../../lib/tracker/cli.mjs";

const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), "..", "fixtures", "tracker-config");

// Every test gets its own HOME, so a developer's real ~/.coding-crew/config.json never decides an outcome.
beforeEach(() => {
  process.env.HOME = mkdtempSync(join(tmpdir(), "crew-tracker-config-home-"));
});

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
const userConfig = (content) => configJson(process.env.HOME, content);
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

// --- the user-level ~/.coding-crew/config.json -------------------------------------------

test("the user file's tracker applies when the project sets none: cli config prints tracker=github, configured=yes", async () => {
  const root = repo();
  userConfig({ tracker: { kind: "github" } });
  assert.deepEqual(readTrackerConfig(root), { tracker: "github", configured: true });
  assert.deepEqual(await cliConfig(root), { code: 0, stdout: "tracker=github\nconfigured=yes\n", stderr: "" });
  configJson(root, { fixture: "config-afk-only.json" });
  assert.deepEqual(readTrackerConfig(root), { tracker: "github", configured: true });
});

test("a user-level github tracker makes the other ops use the github backend", async () => {
  const root = repo();
  userConfig({ tracker: { kind: "github" } });
  const calls = [];
  const exec = (cmd, args) => {
    calls.push([cmd, ...args].join(" "));
    return { code: 0, stdout: JSON.stringify({ number: 5, title: "T", body: "b", state: "OPEN", labels: [] }), stderr: "" };
  };
  let stdout = "";
  const code = await run(["fetch", "5", "--main-root", root], { exec, out: (s) => (stdout += s), err: () => {} });
  assert.equal(code, 0);
  assert.ok(calls.some((c) => c.startsWith("gh issue view 5")), calls.join("\n"));
});

test("a project tracker section, or a legacy issue-tracker.md, wins over the user file's tracker", () => {
  userConfig({ tracker: { kind: "github" } });
  const withSection = repo();
  configJson(withSection, { tracker: { kind: "local" } });
  assert.deepEqual(readTrackerConfig(withSection), { tracker: "local", configured: true });
  const withLegacy = repo();
  configJson(withLegacy, { fixture: "config-afk-only.json" });
  legacyDoc(withLegacy, { fixture: "issue-tracker-no-front-matter.md" });
  assert.deepEqual(readTrackerConfig(withLegacy), { tracker: "local", configured: true });
});

test("a user file with no tracker section is no error: local, not configured", () => {
  userConfig({ solveFeature: { models: { coder: "sonnet" } } });
  assert.deepEqual(readTrackerConfig(repo()), { tracker: "local", configured: false });
});

for (const [name, content] of [
  ["not valid JSON", "{ tracker: github"],
  ["not a JSON object", "[1]"],
  ["an invalid tracker.kind", { tracker: { kind: "jira" } }],
]) {
  test(`a user file that is ${name} fails config and the other ops with its path, even when the project sets a tracker`, async () => {
    const root = repo();
    configJson(root, { tracker: { kind: "local" } });
    userConfig(content);
    const path = join(process.env.HOME, ".coding-crew/config.json");
    assert.throws(() => readTrackerConfig(root), (e) => e.message.includes(path));
    const r = await cliConfig(root);
    assert.equal(r.code, 1);
    assert.ok(r.stderr.includes(path), r.stderr);
    let stderr = "";
    const code = await run(["features", "--main-root", root], { out: () => {}, err: (s) => (stderr += s) });
    assert.equal(code, 1);
    assert.ok(stderr.includes(path), stderr);
  });
}

test("mainCheckout: a checkout whose git dir is not named .git (git init --separate-git-dir) resolves to its top level from a subdirectory and from a linked worktree", () => {
  const dir = realpathSync(repo()); // macOS: git reports tmpdir()'s /var as /private/var
  const git = (cwd, ...a) => spawnSync("git", a, { cwd, encoding: "utf8" });
  mkdirSync(join(dir, "main/sub"), { recursive: true });
  git(join(dir, "main"), "init", "-q", "-b", "main", "--separate-git-dir", join(dir, "gitdir"));
  git(join(dir, "main"), "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init");
  git(join(dir, "main"), "worktree", "add", "-q", join(dir, "wt"), "-b", "wt");
  mkdirSync(join(dir, "wt/sub"));
  assert.equal(mainCheckout(join(dir, "main/sub")), join(dir, "main"));
  // Git records no path back to the main checkout here, so a linked worktree reads its own checkout's config.
  assert.equal(mainCheckout(join(dir, "wt/sub")), join(dir, "wt"));
});
