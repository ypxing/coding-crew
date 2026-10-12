import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { run } from "../../tracker/cli.mjs";
import { fakeGithub, ghFeature, ghIssue } from "../helpers/fake-github.mjs";

// tracker/cli.mjs — the read ops (`fetch`, `prd`, `known`) on both backends, `gh` stubbed through
// the injected `exec` (as tracker-github.test.mjs does), plus a few real-process runs for the exit
// code and stderr a caller actually sees.

const REPO = join(dirname(fileURLToPath(import.meta.url)), "../..");
const CLI = join(REPO, "tracker/cli.mjs");
const LINT = join(REPO, "skills/to-issues/scripts/lint-issues.sh");

function root({ github = false } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "crew-tracker-cli-"));
  mkdirSync(join(dir, ".scratch"), { recursive: true });
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
  const d = join(dir, ".scratch/feat/issues", state);
  mkdirSync(d, { recursive: true });
  writeFileSync(join(d, name), text);
  return join(d, name);
}

// --- prd ---------------------------------------------------------------------------

test("prd (local) prints .scratch/S/PRD.md", async () => {
  const dir = root();
  mkdirSync(join(dir, ".scratch/feat"), { recursive: true });
  writeFileSync(join(dir, ".scratch/feat/PRD.md"), "# PRD: feat\n\n- **D1** — x\n");
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

test("a feature slug that could leave .scratch/ is a usage error", async () => {
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
  const plain = await cli(dir, ["fetch", ".scratch/feat/issues/open/01-thing.md"]);
  const withComments = await cli(dir, ["fetch", ".scratch/feat/issues/open/01-thing.md", "--comments"]);
  assert.equal(plain.code, 0);
  assert.equal(withComments.stdout, plain.stdout);
  assert.match(plain.stdout, /## Progress\n\nnote/);
});

test("fetch (local) exits 3 for a path under .scratch/ that does not exist", async () => {
  const dir = root();
  const r = await cli(dir, ["fetch", join(dir, ".scratch/feat/issues/open/99-none.md")]);
  assert.equal(r.code, 3);
});

test("fetch (local) exits 2 for a path outside .scratch/, before reading it", async () => {
  const dir = root();
  writeFileSync(join(dir, "secret.md"), "# secret\n");
  for (const ref of [join(dir, "secret.md"), ".scratch/../secret.md", "/etc/passwd", "12"]) {
    const r = await cli(dir, ["fetch", ref]);
    assert.equal(r.code, 2, ref);
    assert.equal(r.stdout, "", ref);
  }
});

test("fetch (local) exits 2 for a symlink under .scratch/ that resolves outside it", async () => {
  const dir = root();
  writeFileSync(join(dir, "secret.md"), "# secret\n");
  mkdirSync(join(dir, ".scratch/feat/issues/open"), { recursive: true });
  symlinkSync(join(dir, "secret.md"), join(dir, ".scratch/feat/issues/open/01-link.md"));
  const r = await cli(dir, ["fetch", ".scratch/feat/issues/open/01-link.md"]);
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

test("fetch (github) exits 3 when the issue does not exist", async () => {
  const exec = fakeGh({
    "issue view": { code: 1, stderr: "GraphQL: Could not resolve to an issue or pull request with the number of 999. (repository.issue)\n" },
  });
  const r = await cli(root({ github: true }), ["fetch", "999"], exec);
  assert.equal(r.code, 3);
});

test("fetch (github) exits 2 for a ref that is not all digits, before any gh call", async () => {
  for (const ref of ["#12", "12a", ".scratch/feat/issues/open/01-x.md", "-1", ""]) {
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

test("lint-issues.sh --known resolves Blocked by refs to the files known wrote", async () => {
  const exec = fakeGithub(ghFeature("feat", ghIssue(7, { title: "Add the store", state: "CLOSED" })));
  const dir = root({ github: true });
  const out = join(dir, "known");
  await cli(dir, ["known", "--feature-slug", "feat", "--out", out], exec);
  const local = root();
  writeIssue(local, "done", "03-old.md", "# Old\n");
  const localOut = join(local, "known");
  await cli(local, ["known", "--feature-slug", "feat", "--out", localOut]);

  const draft = join(dir, "01-new.md");
  writeFileSync(
    draft,
    "# New\n\nStatus: ready-for-agent\n\n## What to build\n\nx\n\n## Implements\n\nD1\n\n## Acceptance criteria\n\n- [ ] y\n\n## Blocked by\n\n- Issue #7\n- 03-old.md\n",
  );
  const known = [...readdirSync(out).map((f) => join(out, f)), ...readdirSync(localOut).map((f) => join(localOut, f))];
  const lint = spawnSync("bash", [LINT, "--issue", draft, ...known.flatMap((k) => ["--known", k])], { encoding: "utf8" });
  assert.doesNotMatch(lint.stdout, /ERROR/, lint.stdout);
  assert.equal(lint.status, 0, lint.stdout + lint.stderr);
});

test("known and fetch accept the existing local issue fixtures", async () => {
  const dir = root();
  for (const kind of ["legacy", "promoted", "human"]) {
    cpSync(join(REPO, "tests/fixtures/lint-issues", kind, "issues"), join(dir, ".scratch/feat/issues/open"), { recursive: true });
  }
  const out = join(dir, "known");
  const r = await cli(dir, ["known", "--feature-slug", "feat", "--out", out]);
  assert.equal(r.code, 0, r.stderr);
  const names = readdirSync(out).sort();
  assert.deepEqual(names, ["01-old.md", "02-older.md", "106-enable-main-ruleset.md", "50-fix-finding.md"]);
  for (const name of names) {
    const f = await cli(dir, ["fetch", join(dir, ".scratch/feat/issues/open", name)]);
    assert.equal(f.code, 0, name);
    assert.match(f.stdout, /^# \S.*\n\n/, name);
  }
  const promoted = await cli(dir, ["fetch", join(dir, ".scratch/feat/issues/open/50-fix-finding.md")]);
  assert.match(promoted.stdout, /^# fix-finding\n\nSource: \.scratch\/feat\/review\.md/);
  const legacy = await cli(dir, ["fetch", join(dir, ".scratch/feat/issues/open/01-old.md")]);
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
  assert.equal(node(["prd", "--feature-slug", "x"], { cwd: local }).status, 3);
  assert.equal(node(["nope"], { cwd: local }).status, 2);
});

test("the CLI finds the main root from a linked worktree's cwd", () => {
  const dir = root();
  const git = (...a) => spawnSync("git", a, { cwd: dir, encoding: "utf8" });
  git("init", "-q", "-b", "main");
  git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init");
  git("worktree", "add", "-q", join(dir, ".scratch/wt"), "-b", "wt");
  mkdirSync(join(dir, ".scratch/feat"), { recursive: true });
  writeFileSync(join(dir, ".scratch/feat/PRD.md"), "the prd\n");
  const r = node(["prd", "--feature-slug", "feat"], { cwd: join(dir, ".scratch/wt") });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout, "the prd\n");
});

test("github.mjs's create-issue and link-blockers stay reachable through the CLI; create-issue files under the root", async () => {
  const dir = root({ github: true });
  writeFileSync(join(dir, "body.md"), "body\n");
  const exec = fakeGithub(ghFeature("feat", ghIssue(8)));
  const r = await cli(dir, ["create-issue", "--title", "T", "--body-file", join(dir, "body.md"), "--feature-slug", "feat", "--label", "ready-for-agent"], exec);
  assert.equal(r.code, 0, r.stderr);
  assert.equal(r.stdout, "https://github.com/o/r/issues/9\n");
  const create = exec.calls.find((c) => c[2] === "create");
  assert.equal(create[create.indexOf("--parent") + 1], "8");
  assert.equal(exec.issues.find((i) => i.number === 9).body, "body\n");

  const links = await cli(dir, ["link-blockers", "--issue", "9"], fakeGh({ "issue view 9": { stdout: "no blockers" } }));
  assert.equal(links.code, 0);
  assert.equal(existsSync(join(dir, "known")), false);
});

// --- feature-issues ----------------------------------------------------------------

test("feature-issues (github) prints the root and its sub-issues as JSON, open ones only with --state open", async () => {
  const dir = root({ github: true });
  const exec = fakeGithub(
    ghFeature("feat", ghIssue(3, { title: "PRD: Feat" }), ghIssue(4, { labels: ["awaiting-merge"] }), ghIssue(5, { state: "CLOSED", labels: ["in-progress"] })),
  );
  const all = await cli(dir, ["feature-issues", "--feature-slug", "feat"], exec);
  assert.equal(all.code, 0, all.stderr);
  assert.deepEqual(JSON.parse(all.stdout), [
    { number: 3, title: "PRD: Feat", state: "OPEN", labels: [] },
    { number: 4, title: "Issue 4", state: "OPEN", labels: [{ name: "awaiting-merge" }] },
    { number: 5, title: "Issue 5", state: "CLOSED", labels: [{ name: "in-progress" }] },
  ]);
  const open = await cli(dir, ["feature-issues", "--feature-slug", "feat", "--state", "open"], exec);
  assert.deepEqual(JSON.parse(open.stdout).map((i) => i.number), [3, 4]);
  for (const call of exec.calls) assert.ok(!call.some((a) => /milestone/i.test(a)), call.join(" "));
});

test("feature-issues (github) prints [] for a slug with no root, exits 1 naming duplicate roots, 2 on bad arguments", async () => {
  const dir = root({ github: true });
  const none = await cli(dir, ["feature-issues", "--feature-slug", "feat"], fakeGithub([ghIssue(1)]));
  assert.equal(none.code, 0, none.stderr);
  assert.equal(none.stdout, "[]\n");
  const dup = await cli(dir, ["feature-issues", "--feature-slug", "feat"], fakeGithub([...ghFeature("feat", ghIssue(3)), ...ghFeature("feat", ghIssue(5))]));
  assert.equal(dup.code, 1);
  assert.match(dup.stderr, /#3, #5/);
  for (const argv of [[], ["--feature-slug", "../x"], ["--feature-slug", "feat", "--state", "closed"], ["--feature-slug", "feat", "--bogus"]]) {
    assert.equal((await cli(dir, ["feature-issues", ...argv])).code, 2, argv.join(" "));
  }
});

// --- features ----------------------------------------------------------------------

function writeFeatureIssue(dir, slug, state, name, status) {
  const d = join(dir, ".scratch", slug, "issues", state);
  mkdirSync(d, { recursive: true });
  writeFileSync(join(d, name), `# ${name}\n\nStatus: ${status}\n\n## Acceptance criteria\n\n- [ ] x\n`);
}

test("features (local) lists each .scratch/<slug>/ with issues/, sorted, open|closed and its ready count", async () => {
  const dir = root();
  writeFeatureIssue(dir, "zeta", "open", "01-a.md", "ready-for-agent");
  writeFeatureIssue(dir, "zeta", "open", "02-b.md", "ready-for-agent");
  writeFeatureIssue(dir, "zeta", "open", "03-c.md", "ready-for-human");
  writeFeatureIssue(dir, "alpha", "done", "01-a.md", "done");
  writeFeatureIssue(dir, "mid", "open", "01-a.md", "needs-triage");
  mkdirSync(join(dir, ".scratch/no-issues"), { recursive: true });
  writeFileSync(join(dir, ".scratch/stray-file"), "x");
  const r = await cli(dir, ["features"]);
  assert.equal(r.code, 0);
  assert.equal(r.stdout, "alpha\tclosed\t0\nmid\topen\t0\nzeta\topen\t2\n");
});

test("features (local) with no .scratch/ exits 0 and prints nothing", async () => {
  const dir = mkdtempSync(join(tmpdir(), "crew-tracker-cli-"));
  const r = await cli(dir, ["features"]);
  assert.deepEqual(r, { code: 0, stdout: "", stderr: "" });
});

test("features (github) lists one line per marked root: slug, open|closed, and the open ready-for-agent count among root and sub-issues", async () => {
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
