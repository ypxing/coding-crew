import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cpSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, renameSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { run } from "../../lib/tracker/cli.mjs";
import { fakeGithub, ghFeature, ghIssue } from "../helpers/fake-github.mjs";

// tracker/cli.mjs — the read ops (`fetch`, `prd`, `known`) on both backends, `gh` stubbed through
// the injected `exec` (as tracker-github.test.mjs does), plus a few real-process runs for the exit
// code and stderr a caller actually sees.

const REPO = join(dirname(fileURLToPath(import.meta.url)), "../..");
const CLI = join(REPO, "lib/tracker/cli.mjs");

function root({ github = false } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "crew-tracker-cli-"));
  mkdirSync(join(dir, ".coding-crew/scratch"), { recursive: true });
  if (github) {
    mkdirSync(join(dir, ".coding-crew/docs"), { recursive: true });
    writeFileSync(join(dir, ".coding-crew/docs/issue-tracker.md"), "---\ntracker: github\n---\n");
  }
  return dir;
}

/** Runs the CLI in-process; `exec` stands in for `gh`. */
async function cli(mainRoot, argv, exec = () => assert.fail("gh must not be called")) {
  let stdout = "";
  let stderr = "";
  const code = await run([...argv, "--main-root", mainRoot], {
    exec,
    cwd: mainRoot,
    out: (s) => (stdout += s),
    err: (s) => (stderr += s),
  });
  return { code, stdout, stderr };
}

/** A fake `gh`: `routes` maps an argv prefix ("issue view") to a result; every call is recorded. */
function fakeGh(routes) {
  const calls = [];
  const exec = (cmd, args) => {
    calls.push([cmd, ...args]);
    const key = Object.keys(routes).find((k) => args.join(" ").startsWith(k));
    if (!key) return { code: 1, stdout: "", stderr: `unexpected gh ${args.join(" ")}` };
    const r = routes[key];
    return { code: r.code ?? 0, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
  };
  exec.calls = calls;
  return exec;
}

function writeIssue(dir, state, name, text) {
  const d = join(dir, ".coding-crew/scratch/feat/issues", state);
  mkdirSync(d, { recursive: true });
  writeFileSync(join(d, name), text);
  return join(d, name);
}

// --- prd ---------------------------------------------------------------------------

test("prd (local) prints .coding-crew/scratch/S/PRD.md", async () => {
  const dir = root();
  mkdirSync(join(dir, ".coding-crew/scratch/feat"), { recursive: true });
  writeFileSync(join(dir, ".coding-crew/scratch/feat/PRD.md"), "# PRD: feat\n\n- **D1** — x\n");
  const r = await cli(dir, ["prd", "--feature-slug", "feat"]);
  assert.equal(r.code, 0);
  assert.equal(r.stdout, "# PRD: feat\n\n- **D1** — x\n");
});

test("prd (local) exits 3 when the feature has no PRD.md", async () => {
  const r = await cli(root(), ["prd", "--feature-slug", "feat"]);
  assert.equal(r.code, 3);
  assert.equal(r.stdout, "");
});

test("prd (github) prints the feature's PRD: issue body, whether it is the root or a sub-issue", async () => {
  const prd = { ...ghIssue(3, { title: "PRD: Feat" }), body: "## Decisions\n\n- **D1** — x\n" };
  for (const issues of [ghFeature("feat", prd, ghIssue(4)), ghFeature("feat", ghIssue(4), prd)]) {
    const exec = fakeGithub(issues);
    const r = await cli(root({ github: true }), ["prd", "--feature-slug", "feat"], exec);
    assert.equal(r.code, 0);
    assert.match(r.stdout, /^<!-- PRD issue #3: PRD: Feat -->\n/);
    assert.match(r.stdout, /## Decisions\n\n- \*\*D1\*\* — x/);
  }
});

test("prd (github) exits 3 when the feature has no PRD: issue, or no root at all", async () => {
  for (const issues of [ghFeature("feat", ghIssue(4, { title: "Work" })), [ghIssue(4, { title: "PRD: Other" })]]) {
    const r = await cli(root({ github: true }), ["prd", "--feature-slug", "feat"], fakeGithub(issues));
    assert.equal(r.code, 3);
  }
});

test("prd and known (github) exit 1 naming both when two open issues carry the slug's Feature: line", async () => {
  const issues = [...ghFeature("feat", ghIssue(3)), ...ghFeature("feat", ghIssue(5))];
  for (const argv of [["prd", "--feature-slug", "feat"], ["known", "--feature-slug", "feat", "--out", "x"]]) {
    const dir = root({ github: true });
    const r = await cli(dir, argv.map((a) => (a === "x" ? join(dir, "known") : a)), fakeGithub(issues));
    assert.equal(r.code, 1, argv.join(" "));
    assert.match(r.stderr, /#3, #5/);
  }
});

test("a feature slug that could leave .coding-crew/scratch/ is a usage error", async () => {
  for (const slug of ["../x", "a/b", ".."]) {
    const r = await cli(root(), ["prd", "--feature-slug", slug]);
    assert.equal(r.code, 2, slug);
  }
});

// --- fetch -------------------------------------------------------------------------

test("fetch (local) prints '# <title>', a blank line, then the body", async () => {
  const dir = root();
  const path = writeIssue(dir, "open", "01-thing.md", "# Do the thing\n\nStatus: ready-for-agent\n\n## What to build\n\nIt.\n");
  const r = await cli(dir, ["fetch", path]);
  assert.equal(r.code, 0);
  assert.equal(r.stdout, "# Do the thing\n\nStatus: ready-for-agent\n\n## What to build\n\nIt.\n");
});

test("fetch (local) resolves a ref relative to the main root, and --comments changes nothing", async () => {
  const dir = root();
  writeIssue(dir, "open", "01-thing.md", "# T\n\nbody\n\n## Progress\n\nnote\n");
  const plain = await cli(dir, ["fetch", ".coding-crew/scratch/feat/issues/open/01-thing.md"]);
  const withComments = await cli(dir, ["fetch", ".coding-crew/scratch/feat/issues/open/01-thing.md", "--comments"]);
  assert.equal(plain.code, 0);
  assert.equal(withComments.stdout, plain.stdout);
  assert.match(plain.stdout, /## Progress\n\nnote/);
});

test("fetch (local) exits 3 for a path under .coding-crew/scratch/ that does not exist", async () => {
  const dir = root();
  const r = await cli(dir, ["fetch", join(dir, ".coding-crew/scratch/feat/issues/open/99-none.md")]);
  assert.equal(r.code, 3);
});

test("fetch (local) exits 2 for a path outside .coding-crew/scratch/, before reading it", async () => {
  const dir = root();
  writeFileSync(join(dir, "secret.md"), "# secret\n");
  for (const ref of [join(dir, "secret.md"), ".coding-crew/scratch/../secret.md", "/etc/passwd", "12"]) {
    const r = await cli(dir, ["fetch", ref]);
    assert.equal(r.code, 2, ref);
    assert.equal(r.stdout, "", ref);
  }
});

test("fetch (local) exits 2 for a symlink under .coding-crew/scratch/ that resolves outside it", async () => {
  const dir = root();
  writeFileSync(join(dir, "secret.md"), "# secret\n");
  mkdirSync(join(dir, ".coding-crew/scratch/feat/issues/open"), { recursive: true });
  symlinkSync(join(dir, "secret.md"), join(dir, ".coding-crew/scratch/feat/issues/open/01-link.md"));
  const r = await cli(dir, ["fetch", ".coding-crew/scratch/feat/issues/open/01-link.md"]);
  assert.equal(r.code, 2);
  assert.equal(r.stdout, "");
});

test("fetch (github) prints '# <title>', a blank line, then the body", async () => {
  const exec = fakeGh({ "issue view 12": { stdout: JSON.stringify({ title: "Fix it", body: "## What to build\n\nIt." }) } });
  const r = await cli(root({ github: true }), ["fetch", "12"], exec);
  assert.equal(r.code, 0);
  assert.equal(r.stdout, "# Fix it\n\n## What to build\n\nIt.\n");
  assert.deepEqual(exec.calls[0], ["gh", "issue", "view", "12", "--json", "title,body"]);
});

test("fetch (github) --comments appends each comment from gh", async () => {
  const exec = fakeGh({
    ...writers("ann", "bob"),
    "issue view 12": {
      stdout: JSON.stringify({
        title: "Fix it",
        body: "body",
        comments: [
          { author: { login: "ann" }, createdAt: "2026-01-01T00:00:00Z", body: "first" },
          { author: { login: "bob" }, createdAt: "2026-01-02T00:00:00Z", body: "second" },
        ],
      }),
    },
  });
  const r = await cli(root({ github: true }), ["fetch", "12", "--comments"], exec);
  assert.equal(r.code, 0);
  assert.equal(exec.calls[0].at(-1), "title,body,comments");
  assert.match(r.stdout, /^# Fix it\n\nbody\n/);
  assert.ok(r.stdout.indexOf("first") < r.stdout.indexOf("second"));
  assert.match(r.stdout, /@ann/);
  assert.match(r.stdout, /@bob/);
});

/** Permission routes giving each login write access. */
function writers(...logins) {
  return Object.fromEntries(logins.map((l) => [`api repos/{owner}/{repo}/collaborators/${l}/permission`, { stdout: "write\nwrite\n" }]));
}

/** An `issue view 12` route whose comments are `[login, body]` pairs. */
const issueWith = (...comments) => ({
  "issue view 12": {
    stdout: JSON.stringify({
      title: "Fix it",
      body: "body",
      comments: comments.map(([login, body], i) => ({ author: { login }, createdAt: `2026-01-0${i + 1}T00:00:00Z`, body })),
    }),
  },
});

const permissionCalls = (exec) => exec.calls.filter((c) => c.join(" ").includes("/permission"));

test("fetch (github) --comments keeps only writers' comments and names the omitted authors once", async () => {
  const exec = fakeGh({
    "api user": { stdout: "me\n" },
    "api repos/{owner}/{repo}/collaborators/wanda/permission": { stdout: "write\nwrite\n" },
    "api repos/{owner}/{repo}/collaborators/rita/permission": { stdout: "read\nread\n" },
    "api repos/{owner}/{repo}/collaborators/ghost/permission": { code: 1, stderr: "gh: Not Found (HTTP 404)\n" },
    ...issueWith(["wanda", "keep me"], ["rita", "drop rita"], ["ghost", "drop ghost"], ["wanda", "keep me too"]),
  });
  const r = await cli(root({ github: true }), ["fetch", "12", "--comments"], exec);
  assert.equal(r.code, 0);
  assert.match(r.stdout, /keep me\n/);
  assert.match(r.stdout, /keep me too/);
  assert.doesNotMatch(r.stdout, /drop rita|drop ghost/);
  assert.ok(r.stdout.endsWith("\n(omitted 2 comment(s) by @rita, @ghost: no write access to this repo)\n"), r.stdout);
  assert.deepEqual(permissionCalls(exec).map((c) => c[2]).sort(), [
    "repos/{owner}/{repo}/collaborators/ghost/permission",
    "repos/{owner}/{repo}/collaborators/rita/permission",
    "repos/{owner}/{repo}/collaborators/wanda/permission",
  ]);
});

test("fetch (github) --comments with every author trusted prints what it did before the filter", async () => {
  const exec = fakeGh({ "api user": { stdout: "me\n" }, ...writers("ann"), ...issueWith(["ann", "first"], ["ann", "second"]) });
  const r = await cli(root({ github: true }), ["fetch", "12", "--comments"], exec);
  assert.equal(
    r.stdout,
    "# Fix it\n\nbody\n\n## Comments\n\n### @ann — 2026-01-01T00:00:00Z\n\nfirst\n\n### @ann — 2026-01-02T00:00:00Z\n\nsecond\n",
  );
  assert.equal(permissionCalls(exec).length, 1);
});

test("fetch (github) without --comments makes no permission or user call", async () => {
  const exec = fakeGh(issueWith(["rita", "x"]));
  const r = await cli(root({ github: true }), ["fetch", "12"], exec);
  assert.equal(r.code, 0);
  assert.equal(exec.calls.length, 1);
});

test("fetch (github) --comments keeps Copilot's and the posting identity's comments with no permission call", async () => {
  const exec = fakeGh({
    "api user": { stdout: "me\n" },
    ...issueWith(["copilot-pull-request-reviewer[bot]", "rest"], ["copilot-pull-request-reviewer", "graphql"], ["me", "mine"]),
  });
  const r = await cli(root({ github: true }), ["fetch", "12", "--comments"], exec);
  assert.match(r.stdout, /rest[\s\S]*graphql[\s\S]*mine/);
  assert.doesNotMatch(r.stdout, /omitted/);
  assert.equal(permissionCalls(exec).length, 0);
});

test("fetch (github) --comments on Actions, where gh api user fails, posts as github-actions[bot]", async () => {
  const saved = process.env.GITHUB_ACTIONS;
  process.env.GITHUB_ACTIONS = "true";
  try {
    const exec = fakeGh({
      "api user": { code: 1, stderr: "gh: Resource not accessible by integration (HTTP 403)\n" },
      ...issueWith(["github-actions[bot]", "from the bot"], ["github-actions", "graphql name"]),
    });
    const r = await cli(root({ github: true }), ["fetch", "12", "--comments"], exec);
    assert.match(r.stdout, /from the bot[\s\S]*graphql name/);
    assert.equal(permissionCalls(exec).length, 0);
  } finally {
    if (saved === undefined) delete process.env.GITHUB_ACTIONS;
    else process.env.GITHUB_ACTIONS = saved;
  }
});

test("fetch (github) --comments with only untrusted comments prints the omitted line after the body", async () => {
  const exec = fakeGh({
    "api user": { stdout: "me\n" },
    "api repos/{owner}/{repo}/collaborators/rita/permission": { stdout: "read\nread\n" },
    ...issueWith(["rita", "a"], ["rita", "b"]),
  });
  const r = await cli(root({ github: true }), ["fetch", "12", "--comments"], exec);
  assert.equal(r.stdout, "# Fix it\n\nbody\n\n(omitted 2 comment(s) by @rita: no write access to this repo)\n");
  assert.equal(permissionCalls(exec).length, 1);
});

const WIZ = "wiz-security-bot-22793c4344";
const PRIVATE_REPO = { stdout: "acme/widgets PRIVATE\n" };

/** Writes the main root's `.coding-crew/config.json` (a string as is). */
function configJson(dir, config) {
  mkdirSync(join(dir, ".coding-crew"), { recursive: true });
  writeFileSync(join(dir, ".coding-crew/config.json"), typeof config === "string" ? config : JSON.stringify(config));
  return dir;
}

test("fetch (github) --comments keeps a github.trustedBots bot's comment with no permission call for it", async () => {
  const dir = configJson(root({ github: true }), { github: { trustedBots: [WIZ] } });
  const exec = fakeGh({
    "repo view": PRIVATE_REPO,
    "api user": { stdout: "me\n" },
    "api repos/{owner}/{repo}/collaborators/dependabot%5Bbot%5D/permission": { stdout: "none\nnone\n" },
    ...issueWith([`${WIZ}[bot]`, "finding"], ["dependabot[bot]", "bump"]),
  });
  const r = await cli(dir, ["fetch", "12", "--comments"], exec);
  assert.equal(r.code, 0, r.stderr);
  assert.match(r.stdout, new RegExp(`### @${WIZ}\\[bot\\] — [^\\n]*\\n\\nfinding\\n`));
  assert.doesNotMatch(r.stdout, /bump/);
  assert.ok(r.stdout.endsWith("(omitted 1 comment(s) by @dependabot[bot]: no write access to this repo)\n"), r.stdout);
  assert.deepEqual(permissionCalls(exec).map((c) => c[2]), ["repos/{owner}/{repo}/collaborators/dependabot%5Bbot%5D/permission"]);
});

test("fetch (github) --comments drops a listed bot's comment on a public repo", async () => {
  const dir = configJson(root({ github: true }), { github: { trustedBots: [WIZ] } });
  const exec = fakeGh({
    "repo view": { stdout: "acme/widgets PUBLIC\n" },
    "api user": { stdout: "me\n" },
    [`api repos/{owner}/{repo}/collaborators/${WIZ}%5Bbot%5D/permission`]: { code: 1, stderr: "gh: Not Found (HTTP 404)\n" },
    ...issueWith([`${WIZ}[bot]`, "finding"]),
  });
  const r = await cli(dir, ["fetch", "12", "--comments"], exec);
  assert.equal(r.code, 0, r.stderr);
  assert.doesNotMatch(r.stdout, /finding/);
  assert.match(r.stdout, new RegExp(`omitted 1 comment\\(s\\) by @${WIZ}\\[bot\\]:`));
});

const MALFORMED_GITHUB = [{ github: [] }, { github: { trustedBots: "x" } }, { github: { trustedBots: [""] } }, { github: { trustedBots: null } }];

test("fetch (github) --comments keeps a listed bot's bare login only while no user or organisation holds it", async () => {
  const dir = configJson(root({ github: true }), { github: { trustedBots: [WIZ] } });
  const issue = issueWith([WIZ, "finding"]);
  // `api users/…` before `api user`: fakeGh routes by prefix, first match.
  const free = fakeGh({ "repo view": PRIVATE_REPO, [`api users/${WIZ}`]: { code: 1, stderr: "gh: Not Found (HTTP 404)\n" }, "api user": { stdout: "me\n" }, ...issue });
  const kept = await cli(dir, ["fetch", "12", "--comments"], free);
  assert.equal(kept.code, 0, kept.stderr);
  assert.match(kept.stdout, /finding/);
  assert.equal(permissionCalls(free).length, 0);

  const squatted = fakeGh({
    "repo view": PRIVATE_REPO,
    [`api users/${WIZ}`]: { stdout: "User\n" },
    "api user": { stdout: "me\n" },
    [`api repos/{owner}/{repo}/collaborators/${WIZ}/permission`]: { code: 1, stderr: "gh: Not Found (HTTP 404)\n" },
    ...issue,
  });
  const dropped = await cli(dir, ["fetch", "12", "--comments"], squatted);
  assert.equal(dropped.code, 0, dropped.stderr);
  assert.doesNotMatch(dropped.stdout, /finding/);
  assert.match(dropped.stdout, new RegExp(`omitted 1 comment\\(s\\) by @${WIZ}:`));
});

test("fetch (github) --comments exits 1 on a malformed github section, naming the file and the expected shape", async () => {
  for (const config of MALFORMED_GITHUB) {
    const dir = configJson(root({ github: true }), config);
    const r = await cli(dir, ["fetch", "12", "--comments"], fakeGh({ "api user": { stdout: "me\n" }, ...issueWith(["ann", "x"]) }));
    assert.equal(r.code, 1, JSON.stringify(config));
    assert.ok(r.stderr.includes(join(dir, ".coding-crew/config.json")), r.stderr);
    assert.match(r.stderr, /"trustedBots" is an array of non-empty bot logins/);
  }
});

test("a malformed github section fails neither config, plain fetch (github), nor fetch --comments (local)", async () => {
  for (const config of MALFORMED_GITHUB) {
    const gh = configJson(root({ github: true }), config);
    assert.equal((await cli(gh, ["config"])).code, 0);
    const exec = fakeGh(issueWith(["ann", "x"]));
    const plain = await cli(gh, ["fetch", "12"], exec);
    assert.equal(plain.code, 0, plain.stderr);
    assert.equal(permissionCalls(exec).length, 0);

    const local = configJson(root(), { ...config, tracker: { kind: "local" } });
    writeIssue(local, "open", "01-thing.md", "# Thing\n");
    const r = await cli(local, ["fetch", ".coding-crew/scratch/feat/issues/open/01-thing.md", "--comments"]);
    assert.equal(r.code, 0, r.stderr);
  }
});

test("fetch (github) exits 3 when the issue does not exist", async () => {
  const exec = fakeGh({
    "issue view": { code: 1, stderr: "GraphQL: Could not resolve to an issue or pull request with the number of 999. (repository.issue)\n" },
  });
  const r = await cli(root({ github: true }), ["fetch", "999"], exec);
  assert.equal(r.code, 3);
});

test("fetch (github) exits 2 for a ref that is not all digits, before any gh call", async () => {
  for (const ref of ["#12", "12a", ".coding-crew/scratch/feat/issues/open/01-x.md", "-1", ""]) {
    const r = await cli(root({ github: true }), ["fetch", ref]);
    assert.equal(r.code, 2, ref);
  }
});

test("fetch (github, from config.json) lets gh infer the repo: no --repo", async () => {
  const dir = root();
  mkdirSync(join(dir, ".coding-crew"), { recursive: true });
  writeFileSync(join(dir, ".coding-crew/config.json"), JSON.stringify({ tracker: { kind: "github" } }));
  const exec = fakeGh({ "issue view 12": { stdout: JSON.stringify({ title: "T", body: "b" }) } });
  await cli(dir, ["fetch", "12"], exec);
  assert.deepEqual(exec.calls[0], ["gh", "issue", "view", "12", "--json", "title,body"]);
});

test("a legacy front matter naming repo: fails every op, exit 1, before any gh call", async () => {
  const dir = root({ github: true });
  writeFileSync(join(dir, ".coding-crew/docs/issue-tracker.md"), "---\ntracker: github\nrepo: o/n\n---\n");
  const r = await cli(dir, ["fetch", "12"]);
  assert.equal(r.code, 1);
  assert.match(r.stderr, /`repo` is no longer supported/);
});

test("a failing gh call exits 1 with gh's stderr verbatim", async () => {
  const stderr = "HTTP 401: Bad credentials (https://api.github.com/graphql)\nTry authenticating with:  gh auth login\n";
  for (const argv of [["fetch", "12"], ["prd", "--feature-slug", "feat"], ["known", "--feature-slug", "feat", "--out", "x"]]) {
    const exec = fakeGh({ issue: { code: 1, stderr }, api: { code: 1, stderr } });
    const dir = root({ github: true });
    const r = await cli(dir, argv.map((a) => (a === "x" ? join(dir, "known") : a)), exec);
    assert.equal(r.code, 1, argv.join(" "));
    assert.ok(r.stderr.includes(stderr), `${argv.join(" ")}: ${r.stderr}`);
  }
});

// --- known -------------------------------------------------------------------------

test("known (local) writes every open and done issue under its own filename", async () => {
  const dir = root();
  writeIssue(dir, "open", "02-open.md", "# Open\n\nStatus: ready-for-agent\n");
  writeIssue(dir, "done", "01-done.md", "# Done\n\nStatus: done\n\n## Implements\n\nD1\n");
  writeIssue(dir, "open", "issues-notes.txt", "not an issue");
  const out = join(dir, "known");
  const r = await cli(dir, ["known", "--feature-slug", "feat", "--out", out]);
  assert.equal(r.code, 0);
  assert.deepEqual(readdirSync(out).sort(), ["01-done.md", "02-open.md"]);
  assert.match(readFileSync(join(out, "01-done.md"), "utf8"), /## Implements\n\nD1/);
});

test("known (local) leaves out an issue whose Status: is wontfix", async () => {
  const dir = root();
  writeIssue(dir, "open", "01-open.md", "# Open\n\nStatus: ready-for-agent\n");
  writeIssue(dir, "open", "02-dropped.md", "# Dropped\n\nStatus: wontfix\n");
  const out = join(dir, "known");
  const r = await cli(dir, ["known", "--feature-slug", "feat", "--out", out]);
  assert.equal(r.code, 0);
  assert.deepEqual(readdirSync(out), ["01-open.md"]);
});

test("known (local) with no issues writes an empty directory", async () => {
  const dir = root();
  const out = join(dir, "known");
  const r = await cli(dir, ["known", "--feature-slug", "feat", "--out", out]);
  assert.equal(r.code, 0);
  assert.deepEqual(readdirSync(out), []);
});

test("known (github) writes <n>-<slug>.md for the root and every sub-issue, open and closed, but not the PRD", async () => {
  const exec = fakeGithub(
    ghFeature(
      "feat",
      { ...ghIssue(3, { title: "PRD: Feat" }), body: "prd" },
      { ...ghIssue(7, { title: "Add the store", labels: ["ready-for-agent"] }), body: "## Implements\n\nD1" },
      { ...ghIssue(5, { title: "Old: thing!", state: "CLOSED" }), body: "done body" },
    ),
  );
  const dir = root({ github: true });
  const out = join(dir, "known");
  const r = await cli(dir, ["known", "--feature-slug", "feat", "--out", out], exec);
  assert.equal(r.code, 0);
  assert.deepEqual(readdirSync(out).sort(), ["5-old-thing.md", "7-add-the-store.md"]);
  assert.equal(readFileSync(join(out, "7-add-the-store.md"), "utf8"), "# Add the store\n\n## Implements\n\nD1\n");
});

test("known (github) leaves out an issue closed as not planned (wontfix)", async () => {
  const exec = fakeGithub(
    ghFeature(
      "feat",
      ghIssue(1, { title: "PRD: Feat" }),
      { ...ghIssue(5, { title: "Shipped", state: "closed" }), state_reason: "completed" },
      { ...ghIssue(6, { title: "Dropped", state: "closed" }), state_reason: "not_planned" },
    ),
  );
  const dir = root({ github: true });
  const out = join(dir, "known");
  const r = await cli(dir, ["known", "--feature-slug", "feat", "--out", out], exec);
  assert.equal(r.code, 0, r.stderr);
  assert.deepEqual(readdirSync(out), ["5-shipped.md"]);
});

test("known (github) writes all 34 sub-issues of a feature whose PRD is its root", async () => {
  const subs = Array.from({ length: 34 }, (_, i) => ghIssue(i + 2, { title: `Slice ${i + 2}`, state: i % 3 ? "OPEN" : "CLOSED" }));
  const exec = fakeGithub(ghFeature("feat", ghIssue(1, { title: "PRD: Big" }), ...subs));
  const dir = root({ github: true });
  const out = join(dir, "known");
  const r = await cli(dir, ["known", "--feature-slug", "feat", "--out", out], exec);
  assert.equal(r.code, 0, r.stderr);
  assert.equal(readdirSync(out).length, 34);
});

test("known (github) writes nothing for a slug with no root", async () => {
  const dir = root({ github: true });
  const out = join(dir, "known");
  const r = await cli(dir, ["known", "--feature-slug", "feat", "--out", out], fakeGithub([ghIssue(1)]));
  assert.equal(r.code, 0);
  assert.deepEqual(readdirSync(out), []);
});

test("known and fetch accept the existing local issue fixtures", async () => {
  const dir = root();
  for (const kind of ["legacy", "promoted", "human"]) {
    cpSync(join(REPO, "tests/tracker/fixtures", kind, "issues"), join(dir, ".coding-crew/scratch/feat/issues/open"), { recursive: true });
  }
  const out = join(dir, "known");
  const r = await cli(dir, ["known", "--feature-slug", "feat", "--out", out]);
  assert.equal(r.code, 0, r.stderr);
  const names = readdirSync(out).sort();
  assert.deepEqual(names, ["01-old.md", "02-older.md", "106-enable-main-ruleset.md", "50-fix-finding.md"]);
  for (const name of names) {
    const f = await cli(dir, ["fetch", join(dir, ".coding-crew/scratch/feat/issues/open", name)]);
    assert.equal(f.code, 0, name);
    assert.match(f.stdout, /^# \S.*\n\n/, name);
  }
  const promoted = await cli(dir, ["fetch", join(dir, ".coding-crew/scratch/feat/issues/open/50-fix-finding.md")]);
  assert.match(promoted.stdout, /^# fix-finding\n\nSource: \S+\/feat\/review\.md/);
  const legacy = await cli(dir, ["fetch", join(dir, ".coding-crew/scratch/feat/issues/open/01-old.md")]);
  assert.match(legacy.stdout, /^# old style\n\nStatus: ready-for-agent\n\n## Part of Flow/);
});

// --- usage -------------------------------------------------------------------------

test("an unknown op or a missing argument exits 2", async () => {
  const dir = root();
  for (const argv of [["nope"], [], ["fetch"], ["prd"], ["known", "--feature-slug", "feat"], ["known", "--out", "x"], ["prd", "--feature-slug"], ["fetch", "1", "--bogus"]]) {
    const r = await cli(dir, argv);
    assert.equal(r.code, 2, JSON.stringify(argv));
    assert.match(r.stderr, /usage|unknown|requires/i, JSON.stringify(argv));
  }
});

// --- the real process ----------------------------------------------------------------

function node(args, { cwd, env = {} }) {
  return spawnSync(process.execPath, [CLI, ...args], { cwd, encoding: "utf8", env: { ...process.env, ...env } });
}

test("the CLI process: exit codes and gh's stderr reach the caller", () => {
  const dir = root({ github: true });
  const gh = join(dir, "fake-gh.sh");
  writeFileSync(gh, '#!/usr/bin/env bash\necho "gh: To get started with GitHub CLI, please run:  gh auth login" >&2\nexit 4\n', { mode: 0o755 });
  const failed = node(["fetch", "12", "--main-root", dir], { cwd: dir, env: { CREW_FAKE_GH: gh } });
  assert.equal(failed.status, 1);
  assert.ok(failed.stderr.includes("gh: To get started with GitHub CLI, please run:  gh auth login\n"), failed.stderr);

  const local = root();
  assert.equal(node(["prd", "--feature-slug", "x", "--main-root", local], { cwd: local }).status, 3);
  assert.equal(node(["nope", "--main-root", local], { cwd: local }).status, 2);
});

test("the CLI refuses a cwd outside any git repo when no --main-root is given", () => {
  const dir = root({ github: true });
  const outside = realpathSync(root()); // macOS: the process sees tmpdir()'s /var as /private/var
  const r = node(["config"], { cwd: outside });
  assert.equal(r.status, 2);
  assert.equal(r.stdout, "");
  assert.ok(r.stderr.includes(`not inside a git repository (${outside})`), r.stderr);
  assert.ok(r.stderr.includes("--main-root"), r.stderr);
  assert.equal(node(["config", "--main-root", dir], { cwd: outside }).stdout, "tracker=github\nconfigured=yes\n");
});

test("the CLI finds the main root from a linked worktree's cwd", () => {
  const dir = root();
  const git = (...a) => spawnSync("git", a, { cwd: dir, encoding: "utf8" });
  git("init", "-q", "-b", "main");
  git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init");
  git("worktree", "add", "-q", join(dir, ".coding-crew/scratch/wt"), "-b", "wt");
  mkdirSync(join(dir, ".coding-crew/scratch/feat"), { recursive: true });
  writeFileSync(join(dir, ".coding-crew/scratch/feat/PRD.md"), "the prd\n");
  const r = node(["prd", "--feature-slug", "feat"], { cwd: join(dir, ".coding-crew/scratch/wt") });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout, "the prd\n");
});

test("create-issue, feature-issues and link-blockers on a github repo are unknown ops, and the op list names no backend op", async () => {
  const dir = root({ github: true });
  for (const op of ["create-issue", "feature-issues", "link-blockers"]) {
    const r = await cli(dir, [op, "--feature-slug", "feat"]);
    assert.equal(r.code, 2, op);
    assert.match(r.stderr, new RegExp(`^unknown op: ${op} — ops: `), op);
    assert.doesNotMatch(r.stderr.replace(`unknown op: ${op}`, ""), /create-issue|feature-issues|link-blockers/, op);
  }
});

// --- closing-refs ------------------------------------------------------------------

test("closing-refs (github) prints closingRefs' Closes lines, one per line, and nothing when nothing ships", async () => {
  const dir = root({ github: true });
  const prd = ghIssue(2, { title: "PRD: Feat" });
  const shipped = fakeGithub(ghFeature("feat", prd, ghIssue(7, { labels: ["awaiting-merge"] }), ghIssue(4, { labels: ["awaiting-merge"] })));
  const r = await cli(dir, ["closing-refs", "--feature-slug", "feat"], shipped);
  assert.equal(r.code, 0, r.stderr);
  assert.equal(r.stdout, "Closes #2\nCloses #4\nCloses #7\n");
  const none = await cli(dir, ["closing-refs", "--feature-slug", "feat"], fakeGithub(ghFeature("feat", prd, ghIssue(4, { labels: ["ready-for-agent"] }))));
  assert.equal(none.code, 0, none.stderr);
  assert.equal(none.stdout, "");
  for (const argv of [[], ["--feature-slug", "../x"], ["--feature-slug", "feat", "--bogus"]]) {
    assert.equal((await cli(dir, ["closing-refs", ...argv])).code, 2, argv.join(" "));
  }
  const failed = await cli(dir, ["closing-refs", "--feature-slug", "feat"], fakeGh({ api: { code: 1, stderr: "boom\n" }, issue: { code: 1, stderr: "boom\n" } }));
  assert.equal(failed.code, 1);
  assert.match(failed.stderr, /boom/);
});

test("closing-refs (local) prints nothing and exits 0; bad arguments exit 2", async () => {
  const dir = root();
  writeIssue(dir, "open", "01-a.md", "# A\n\nStatus: ready-for-agent\n");
  const r = await cli(dir, ["closing-refs", "--feature-slug", "feat"]);
  assert.equal(r.code, 0, r.stderr);
  assert.equal(r.stdout, "");
  for (const argv of [[], ["--feature-slug", "../x"], ["--feature-slug", "feat", "--bogus"]]) {
    assert.equal((await cli(dir, ["closing-refs", ...argv])).code, 2, argv.join(" "));
  }
});

// --- next ------------------------------------------------------------------------------

/** A `gh` argv that reads: `issue list`, `issue view`, or a `gh api` GET (no method or field flag). */
const isRead = (call) => /^(issue list|issue view|api)/.test(call.slice(1, 3).join(" ")) && !call.some((a) => /^(-X|--method|-f|-F|--input)$/.test(a));

const blockedBy = (...ns) => `## Blocked by\n\n${ns.map((n) => `- #${n}`).join("\n")}\n`;

test("next (github) prints the lowest ready, unblocked issue: not labelled blocked, every blocker closed or awaiting-merge", async () => {
  const dir = root({ github: true });
  const ready = ["ready-for-agent"];
  const feature = (two = {}) =>
    fakeGithub([
      ...ghFeature(
        "feat",
        ghIssue(1),
        ghIssue(2, { labels: ready, ...two }),
        ghIssue(3, { labels: ready, body: blockedBy(2) }),
        ghIssue(4, { labels: [...ready, "blocked"] }),
        ghIssue(5, { labels: ready, body: blockedBy(9) }),
        ghIssue(6, { labels: ready, body: blockedBy(30) }),
        ghIssue(9, { labels: ["awaiting-merge"] }),
      ),
      ghIssue(30, { labels: ready }),
    ]);
  const first = feature();
  const r = await cli(dir, ["next", "--feature-slug", "feat"], first);
  assert.equal(r.code, 0, r.stderr);
  assert.equal(r.stdout, "2\n");
  for (const call of first.calls) assert.ok(isRead(call), call.join(" "));
  const then = await cli(dir, ["next", "--feature-slug", "feat"], feature({ state: "CLOSED" }));
  assert.equal(then.code, 0, then.stderr);
  assert.equal(then.stdout, "3\n");
});

test("next (github) exits 1 with gh's stderr when reading an out-of-feature blocker fails other than 404/410", async () => {
  const dir = root({ github: true });
  const exec = fakeGithub([...ghFeature("feat", ghIssue(1), ghIssue(2, { labels: ["ready-for-agent"], body: blockedBy(40) })), ghIssue(40, { state: "CLOSED" })], {
    fail: { "api repos/{owner}/{repo}/issues/40": { stderr: "gh: Resource not accessible by integration (HTTP 403)\n" } },
  });
  const r = await cli(dir, ["next", "--feature-slug", "feat"], exec);
  assert.equal(r.code, 1);
  assert.equal(r.stdout, "");
  assert.ok(r.stderr.includes("gh: Resource not accessible by integration (HTTP 403)"), r.stderr);
});

test("next (local) prints the first ready file whose blockers are all in done/, as a path fetch accepts; issues-deps.json wins over prose", async () => {
  const dir = root();
  const write = (state, name, status, blockedBy = "None") =>
    writeIssue(dir, state, name, `# ${name}\n\nStatus: ${status}\n\n## Acceptance criteria\n\n- [ ] x\n\n## Blocked by\n\n${blockedBy}\n`);
  write("open", "01-a.md", "ready-for-agent");
  write("open", "02-b.md", "ready-for-agent", "- 01-a.md");
  write("open", "03-c.md", "ready-for-human");
  write("open", "04-d.md", "ready-for-agent", "- 00-done.md");
  write("done", "00-done.md", "done");
  const snapshot = () => readdirSync(join(dir, ".coding-crew/scratch/feat/issues"), { recursive: true }).sort();
  const before = snapshot();
  const r = await cli(dir, ["next", "--feature-slug", "feat"]);
  assert.equal(r.code, 0, r.stderr);
  // Absolute: the ref names the main checkout's file from any cwd, a worktree without .coding-crew/scratch/ too.
  assert.equal(r.stdout, `${join(dir, ".coding-crew/scratch/feat/issues/open/01-a.md")}\n`);
  assert.deepEqual(snapshot(), before);
  const fetched = await cli(dir, ["fetch", r.stdout.trim()]);
  assert.equal(fetched.code, 0, fetched.stderr);
  assert.match(fetched.stdout, /^# 01-a\.md\n/);

  renameSync(join(dir, ".coding-crew/scratch/feat/issues/open/01-a.md"), join(dir, ".coding-crew/scratch/feat/issues/done/01-a.md"));
  assert.equal((await cli(dir, ["next", "--feature-slug", "feat"])).stdout, `${join(dir, ".coding-crew/scratch/feat/issues/open/02-b.md")}\n`);

  writeFileSync(join(dir, ".coding-crew/scratch/feat/issues/issues-deps.json"), JSON.stringify({ "02-b.md": ["03-c.md"], "04-d.md": [] }));
  assert.equal((await cli(dir, ["next", "--feature-slug", "feat"])).stdout, `${join(dir, ".coding-crew/scratch/feat/issues/open/04-d.md")}\n`);
});

test("next (github) prints a one-slice feature's ready root; exits 3 with empty stdout when nothing is dispatchable or no root exists", async () => {
  const dir = root({ github: true });
  const ready = ["ready-for-agent"];
  const solo = await cli(dir, ["next", "--feature-slug", "feat"], fakeGithub(ghFeature("feat", ghIssue(7, { labels: ready }))));
  assert.equal(solo.code, 0, solo.stderr);
  assert.equal(solo.stdout, "7\n");
  const waiting = fakeGithub(ghFeature("feat", ghIssue(1), ghIssue(2, { labels: ready, body: blockedBy(3) }), ghIssue(3, { labels: ["in-progress"] })));
  assert.deepEqual(await cli(dir, ["next", "--feature-slug", "feat"], waiting), { code: 3, stdout: "", stderr: "" });
  assert.deepEqual(await cli(dir, ["next", "--feature-slug", "feat"], fakeGithub([ghIssue(1)])), { code: 3, stdout: "", stderr: "" });
});

test("next (local) exits 3 with empty stdout when every ready issue is blocked or the feature has no issues", async () => {
  const dir = root();
  writeIssue(dir, "open", "01-a.md", "# a\n\nStatus: ready-for-agent\n\n## Blocked by\n\n- 02-b.md\n");
  writeIssue(dir, "open", "02-b.md", "# b\n\nStatus: ready-for-human\n");
  writeFileSync(join(dir, ".coding-crew/scratch/feat/issues/issues-deps.json"), JSON.stringify({ "01-a.md": ["02-b.md"], "02-b.md": [] }));
  assert.deepEqual(await cli(dir, ["next", "--feature-slug", "feat"]), { code: 3, stdout: "", stderr: "" });
  assert.deepEqual(await cli(dir, ["next", "--feature-slug", "nope"]), { code: 3, stdout: "", stderr: "" });
});

test("next (local) reads blockers from issues-deps.json only: a [] entry dispatches an issue whose Blocked by names an open one", async () => {
  const dir = root();
  writeIssue(dir, "open", "01-a.md", "# a\n\nStatus: ready-for-agent\n\n## Blocked by\n\n- 02-b.md\n");
  writeIssue(dir, "open", "02-b.md", "# b\n\nStatus: ready-for-human\n");
  writeFileSync(join(dir, ".coding-crew/scratch/feat/issues/issues-deps.json"), JSON.stringify({ "01-a.md": [], "02-b.md": [] }));
  const r = await cli(dir, ["next", "--feature-slug", "feat"]);
  assert.equal(r.code, 0, r.stderr);
  assert.match(r.stdout, /01-a\.md\n$/);
});

test("next exits 2 without --feature-slug, on an invalid slug or an unknown flag; 1 naming both roots when github has two", async () => {
  for (const dir of [root(), root({ github: true })]) {
    for (const argv of [[], ["--feature-slug", "../x"], ["--feature-slug", "feat", "--bogus"]]) {
      const r = await cli(dir, ["next", ...argv]);
      assert.equal(r.code, 2, argv.join(" "));
      assert.equal(r.stdout, "");
    }
  }
  const dup = await cli(root({ github: true }), ["next", "--feature-slug", "feat"], fakeGithub([...ghFeature("feat", ghIssue(3)), ...ghFeature("feat", ghIssue(5))]));
  assert.equal(dup.code, 1);
  assert.equal(dup.stdout, "");
  assert.match(dup.stderr, /#3, #5/);
});

test("cli.mjs with no op lists next among the ops", async () => {
  const r = await cli(root(), []);
  assert.equal(r.code, 2);
  assert.ok(r.stderr.replace(/^.*ops: /s, "").split(/,\s*/).map((s) => s.trim()).includes("next"), r.stderr);
});

// --- features ----------------------------------------------------------------------

function writeFeatureIssue(dir, slug, state, name, status) {
  const d = join(dir, ".coding-crew/scratch", slug, "issues", state);
  mkdirSync(d, { recursive: true });
  writeFileSync(join(d, name), `# ${name}\n\nStatus: ${status}\n\n## Acceptance criteria\n\n- [ ] x\n`);
}

test("features (local) lists each .coding-crew/scratch/<slug>/ with issues/, sorted, open|closed and its ready count", async () => {
  const dir = root();
  writeFeatureIssue(dir, "zeta", "open", "01-a.md", "ready-for-agent");
  writeFeatureIssue(dir, "zeta", "open", "02-b.md", "ready-for-agent");
  writeFeatureIssue(dir, "zeta", "open", "03-c.md", "ready-for-human");
  writeFeatureIssue(dir, "alpha", "done", "01-a.md", "done");
  writeFeatureIssue(dir, "mid", "open", "01-a.md", "needs-triage");
  mkdirSync(join(dir, ".coding-crew/scratch/no-issues"), { recursive: true });
  writeFileSync(join(dir, ".coding-crew/scratch/stray-file"), "x");
  const r = await cli(dir, ["features"]);
  assert.equal(r.code, 0);
  assert.equal(r.stdout, "alpha\tclosed\t0\nmid\topen\t0\nzeta\topen\t2\n");
});

test("features (local) counts only the ready issues whose every blocker, from issues-deps.json, is in the feature's done/", async () => {
  const dir = root();
  const write = (slug, state, name, status, blockedBy = "None") => {
    const d = join(dir, ".coding-crew/scratch", slug, "issues", state);
    mkdirSync(d, { recursive: true });
    writeFileSync(join(d, name), `# ${name}\n\nStatus: ${status}\n\n## Blocked by\n\n${blockedBy}\n`);
  };
  write("prose", "open", "01-a.md", "ready-for-agent");
  write("prose", "open", "02-b.md", "ready-for-agent", "- 01-a.md");
  write("prose", "open", "03-c.md", "ready-for-agent", "- 00-done.md");
  write("prose", "done", "00-done.md", "done");
  write("waiting", "open", "01-a.md", "ready-for-human");
  write("waiting", "open", "02-b.md", "ready-for-agent", "- 01-a.md");
  write("deps", "open", "01-a.md", "ready-for-agent");
  write("deps", "open", "02-b.md", "ready-for-agent");
  writeFileSync(join(dir, ".coding-crew/scratch/deps/issues/issues-deps.json"), JSON.stringify({ "01-a.md": [], "02-b.md": ["01-a.md"] }));
  writeFileSync(join(dir, ".coding-crew/scratch/prose/issues/issues-deps.json"), JSON.stringify({ "01-a.md": [], "02-b.md": ["01-a.md"], "03-c.md": ["00-done.md"] }));
  writeFileSync(join(dir, ".coding-crew/scratch/waiting/issues/issues-deps.json"), JSON.stringify({ "02-b.md": ["01-a.md"] }));
  const r = await cli(dir, ["features"]);
  assert.equal(r.code, 0, r.stderr);
  assert.equal(r.stdout, "deps\topen\t1\nprose\topen\t2\nwaiting\topen\t0\n");
});

test("features (local) with no .coding-crew/scratch/ exits 0 and prints nothing", async () => {
  const dir = mkdtempSync(join(tmpdir(), "crew-tracker-cli-"));
  const r = await cli(dir, ["features"]);
  assert.deepEqual(r, { code: 0, stdout: "", stderr: "" });
});

test("features (github) lists one line per marked root: slug, open|closed, and the dispatchable count among root and sub-issues", async () => {
  const dir = root({ github: true });
  writeFileSync(join(dir, ".coding-crew/config.json"), JSON.stringify({ tracker: { kind: "github" } }));
  const ready = ["ready-for-agent"];
  const exec = fakeGithub([
    ...ghFeature("zeta", ghIssue(2, { labels: ready }), ghIssue(5, { labels: ready }), ghIssue(6, { labels: ready, state: "CLOSED" })),
    ...ghFeature("alpha", ghIssue(1, { state: "CLOSED" }), ghIssue(7, { state: "CLOSED" })),
    ...ghFeature("reopened", ghIssue(3, { state: "CLOSED" }), ghIssue(8, { labels: ready })),
    ghIssue(9, { labels: ready }),
  ]);
  const r = await cli(dir, ["features"], exec);
  assert.equal(r.code, 0, r.stderr);
  assert.equal(r.stdout, "alpha\tclosed\t0\nreopened\topen\t1\nzeta\topen\t2\n");
  for (const call of exec.calls) assert.ok(!call.some((a) => /milestone/i.test(a)), call.join(" "));
});

test("features (github) counts only the ready issues dispatch would start: no `blocked` label, every blocker done, in the feature or not", async () => {
  const dir = root({ github: true });
  writeFileSync(join(dir, ".coding-crew/config.json"), JSON.stringify({ tracker: { kind: "github" } }));
  const ready = ["ready-for-agent"];
  const after = (...ns) => `## Blocked by\n\n${ns.map((n) => `- #${n}`).join("\n")}\n`;
  const exec = fakeGithub([
    ...ghFeature(
      "mixed",
      ghIssue(1),
      ghIssue(2, { labels: ready }),
      ghIssue(3, { labels: ready, body: after(2) }),
      ghIssue(4, { labels: [...ready, "blocked"] }),
      ghIssue(5, { labels: ready, body: after(30) }),
      ghIssue(6, { labels: ready, body: after(7) }),
      ghIssue(7, { state: "CLOSED" }),
      ghIssue(8, { labels: ready, body: after(9) }),
      ghIssue(9, { labels: ["awaiting-merge"] }),
      ghIssue(13, { labels: ready, body: after(31) }),
    ),
    ...ghFeature("waiting", ghIssue(10), ghIssue(11, { labels: ready, body: after(10) }), ghIssue(12, { labels: [...ready, "blocked"] })),
    ghIssue(30, { state: "CLOSED" }),
    ghIssue(31, { labels: ready }),
  ]);
  const r = await cli(dir, ["features"], exec);
  assert.equal(r.code, 0, r.stderr);
  assert.equal(r.stdout, "mixed\topen\t4\nwaiting\topen\t0\n");
  const reads = exec.calls.filter((c) => !/issues\?state=all/.test(c.join(" ")));
  assert.deepEqual(reads.map((c) => /issues\/(\d+)(\/sub_issues)?\b/.exec(c.join(" "))?.slice(1, 3).join("")), ["1/sub_issues", "30", "31", "10/sub_issues"]);
});

test("features (github) reads no sub-issues of a closed root whose sub-issues have all closed", async () => {
  const dir = root({ github: true });
  writeFileSync(join(dir, ".coding-crew/config.json"), JSON.stringify({ tracker: { kind: "github" } }));
  const exec = fakeGithub([
    ...ghFeature("done", ghIssue(1, { state: "CLOSED" }), ghIssue(2, { state: "CLOSED" })),
    ...ghFeature("live", ghIssue(3, { state: "CLOSED" }), ghIssue(4, { labels: ["ready-for-agent"] })),
  ]);
  const r = await cli(dir, ["features"], exec);
  assert.equal(r.code, 0, r.stderr);
  assert.equal(r.stdout, "done\tclosed\t0\nlive\topen\t1\n");
  const reads = exec.calls.filter((c) => /\/sub_issues/.test(c.join(" ")));
  assert.deepEqual(reads.map((c) => /issues\/(\d+)\/sub_issues/.exec(c.join(" "))[1]), ["3"]);
});

test("features (github) lists a slug on two open roots once, with a warning, and every other slug as usual", async () => {
  const dir = root({ github: true });
  writeFileSync(join(dir, ".coding-crew/config.json"), JSON.stringify({ tracker: { kind: "github" } }));
  const exec = fakeGithub([...ghFeature("dup", ghIssue(3)), ...ghFeature("dup", ghIssue(5)), ...ghFeature("solo", ghIssue(6))]);
  const r = await cli(dir, ["features"], exec);
  assert.equal(r.code, 0, r.stderr);
  assert.equal(r.stdout, "dup\topen\t0\nsolo\topen\t0\n");
  assert.match(r.stderr, /WARNING: .*dup.*#3, #5/);
});

test("features (github) exits 1 with gh's stderr verbatim when gh fails", async () => {
  const dir = root({ github: true });
  writeFileSync(join(dir, ".coding-crew/config.json"), JSON.stringify({ tracker: { kind: "github" } }));
  const r = await cli(dir, ["features"], fakeGh({ "api ": { code: 4, stderr: "gh: To use GitHub CLI, run: gh auth login\n" } }));
  assert.equal(r.code, 1);
  assert.equal(r.stdout, "");
  assert.ok(r.stderr.includes("gh: To use GitHub CLI, run: gh auth login\n"), r.stderr);
});

test("features exits 2 on an extra argument, on both trackers", async () => {
  const local = await cli(root(), ["features", "extra"]);
  assert.equal(local.code, 2);
  const dir = root({ github: true });
  writeFileSync(join(dir, ".coding-crew/config.json"), JSON.stringify({ tracker: { kind: "github" } }));
  const gh = await cli(dir, ["features", "extra"]);
  assert.equal(gh.code, 2);
});
