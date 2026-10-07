import { test } from "node:test";
import assert from "node:assert/strict";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { run } from "../../tracker/cli.mjs";

// tracker/cli.mjs — the write ops (`publish-issues`, `publish-prd`, `rewrite`, `mark-done`) on
// both backends, `gh` stubbed through the injected `exec`, as tracker-cli.test.mjs does for the
// read ops. mark-issue-done.sh's own contract is pinned by the bats suites.

const REPO = join(dirname(fileURLToPath(import.meta.url)), "../..");

function root({ github = false } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "crew-tracker-cli-write-"));
  mkdirSync(join(dir, ".scratch"), { recursive: true });
  if (github) {
    mkdirSync(join(dir, ".coding-crew/docs"), { recursive: true });
    writeFileSync(join(dir, ".coding-crew/docs/issue-tracker.md"), "---\ntracker: github\n---\n");
  }
  return dir;
}

async function cli(mainRoot, argv, exec = () => assert.fail("gh must not be called"), env = {}) {
  let stdout = "";
  let stderr = "";
  const code = await run([...argv, "--main-root", mainRoot], {
    exec,
    cwd: mainRoot,
    env,
    out: (s) => (stdout += s),
    err: (s) => (stderr += s),
  });
  return { code, stdout, stderr };
}

/**
 * A fake `gh`: `routes` maps an argv prefix to a result, or to a function of the argv returning
 * one; every call is recorded, with a `--body-file`'s content captured as it was at call time.
 */
function fakeGh(routes) {
  const calls = [];
  const bodies = [];
  const exec = (cmd, args) => {
    calls.push([cmd, ...args]);
    const bf = args.indexOf("--body-file");
    bodies.push(bf === -1 ? null : readFileSync(args[bf + 1], "utf8"));
    const key = Object.keys(routes).find((k) => args.join(" ").startsWith(k));
    if (!key) return { code: 1, stdout: "", stderr: `unexpected gh ${args.join(" ")}` };
    const r = typeof routes[key] === "function" ? routes[key](args) : routes[key];
    return { code: r.code ?? 0, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
  };
  exec.calls = calls;
  exec.bodies = bodies;
  exec.find = (prefix) => calls.map((c, i) => [c, i]).filter(([c]) => c.slice(1).join(" ").startsWith(prefix));
  return exec;
}

/** `gh issue create` numbering issues from `first` up, in call order. */
function creates(first) {
  let n = first;
  return () => ({ stdout: `https://github.com/o/n/issues/${n++}\n` });
}

const DRAFT_A = "# Add a\n\nStatus: ready-for-agent\n\n## What to build\n\nA.\n\n## Acceptance criteria\n\n- [ ] a works\n";
const DRAFT_B =
  "# Add b\n\nStatus: ready-for-human\n\n## What to build\n\nB.\n\n## Acceptance criteria\n\n- [ ] b works\n\n## Blocked by\n\n- 01-a.md\n";

function drafts(dir, { deps = { "02-b.md": ["01-a.md"] }, files = { "01-a.md": DRAFT_A, "02-b.md": DRAFT_B } } = {}) {
  const d = join(dir, ".scratch/feat/.drafts");
  mkdirSync(d, { recursive: true });
  for (const [name, text] of Object.entries(files)) writeFileSync(join(d, name), text);
  if (deps !== null) writeFileSync(join(d, "deps.json"), JSON.stringify(deps));
  return d;
}

// --- publish-issues (github) --------------------------------------------------------

test("publish-issues (github) creates blockers first and rewrites the dependent's Blocked by to the real number", async () => {
  const dir = root({ github: true });
  const d = drafts(dir);
  const exec = fakeGh({
    "api repos/{owner}/{repo}/milestones?state=all": { stdout: "1\topen\tfeat\n" },
    "issue create": creates(11),
    "api repos/{owner}/{repo}/issues/11": { stdout: "9011\n" },
    "api -X POST": {},
  });
  const r = await cli(dir, ["publish-issues", "--feature-slug", "feat", "--drafts", d], exec);
  assert.equal(r.code, 0, r.stderr);
  assert.equal(r.stdout, "01-a.md 11\n02-b.md 12\n");

  const made = exec.find("issue create");
  assert.equal(made.length, 2);
  const [[a, ai], [b, bi]] = made;
  const flag = (call, name) => call[call.indexOf(name) + 1];
  assert.equal(flag(a, "--title"), "Add a");
  assert.equal(flag(a, "--label"), "ready-for-agent");
  assert.equal(flag(a, "--milestone"), "feat");
  assert.equal(flag(b, "--title"), "Add b");
  assert.equal(flag(b, "--label"), "ready-for-human");
  assert.equal(flag(b, "--milestone"), "feat");
  assert.doesNotMatch(exec.bodies[ai], /^# Add a|^Status:/m);
  assert.match(exec.bodies[ai], /^## What to build/);
  assert.doesNotMatch(exec.bodies[bi], /^# Add b|^Status:/m);
  assert.match(exec.bodies[bi], /## Blocked by\n\n- Issue #11\n/);
  assert.doesNotMatch(exec.bodies[bi], /01-a\.md/);
  // 02-b's blocker is linked natively once it exists.
  assert.equal(exec.find("api -X POST repos/{owner}/{repo}/issues/12/dependencies/blocked_by").length, 1);
});

test("publish-issues (github) deletes the drafts directory after a full publish", async () => {
  const dir = root({ github: true });
  const d = drafts(dir);
  const exec = fakeGh({ "api repos": { stdout: "1\topen\tfeat\n9011\n" }, "issue create": creates(11), "api -X POST": {} });
  const r = await cli(dir, ["publish-issues", "--feature-slug", "feat", "--drafts", d], exec);
  assert.equal(r.code, 0, r.stderr);
  assert.equal(existsSync(d), false);
});

test("publish-issues (github) never refuses a re-run: a milestone only accumulates", async () => {
  const dir = root({ github: true });
  mkdirSync(join(dir, ".scratch/feat/issues/done"), { recursive: true });
  writeFileSync(join(dir, ".scratch/feat/issues/done/01-old.md"), "# Old\n");
  mkdirSync(join(dir, ".scratch/feat/issues/open"), { recursive: true });
  writeFileSync(join(dir, ".scratch/feat/issues/open/02-old.md"), "# Old\n");
  const d = drafts(dir);
  const exec = fakeGh({ "api repos": { stdout: "1\topen\tfeat\n9011\n" }, "issue create": creates(11), "api -X POST": {} });
  const r = await cli(dir, ["publish-issues", "--feature-slug", "feat", "--drafts", d], exec);
  assert.equal(r.code, 0, r.stderr);
});

test("publish-issues (github) stops at a failed create: prints what it made, exits 1, keeps the drafts", async () => {
  const dir = root({ github: true });
  const d = drafts(dir);
  let n = 0;
  const exec = fakeGh({
    "api repos": { stdout: "1\topen\tfeat\n" },
    "issue create": () => (n++ === 0 ? { stdout: "https://github.com/o/n/issues/11\n" } : { code: 1, stderr: "HTTP 502: Bad Gateway\n" }),
  });
  const r = await cli(dir, ["publish-issues", "--feature-slug", "feat", "--drafts", d], exec);
  assert.equal(r.code, 1);
  assert.equal(r.stdout, "01-a.md 11\n");
  assert.match(r.stderr, /HTTP 502: Bad Gateway/);
  assert.match(r.stderr, /01-a\.md 11/);
  assert.deepEqual(readdirSync(d).sort(), ["01-a.md", "02-b.md", "deps.json"]);
});

// --- publish-issues (local) ---------------------------------------------------------

test("publish-issues (local) writes open/NN-<slug>.md and issues-deps.json with the final filenames", async () => {
  const dir = root();
  const d = drafts(dir);
  const r = await cli(dir, ["publish-issues", "--feature-slug", "feat", "--drafts", d]);
  assert.equal(r.code, 0, r.stderr);
  const open = join(dir, ".scratch/feat/issues/open");
  assert.deepEqual(readdirSync(open).sort(), ["01-a.md", "02-b.md"]);
  assert.equal(readFileSync(join(open, "01-a.md"), "utf8"), DRAFT_A);
  assert.equal(readFileSync(join(open, "02-b.md"), "utf8"), DRAFT_B);
  assert.deepEqual(JSON.parse(readFileSync(join(dir, ".scratch/feat/issues/issues-deps.json"), "utf8")), { "02-b.md": ["01-a.md"] });
  assert.equal(r.stdout, `01-a.md ${join(open, "01-a.md")}\n02-b.md ${join(open, "02-b.md")}\n`);
  assert.equal(existsSync(d), false);
});

test("publish-issues (local) numbers the drafts after any existing issue and rewrites Blocked by to match", async () => {
  const dir = root();
  const issues = join(dir, ".scratch/feat/issues");
  mkdirSync(join(issues, "open"), { recursive: true });
  writeFileSync(join(issues, "open/03-old.md"), "# Old\n\nStatus: ready-for-agent\n");
  const d = drafts(dir);
  const r = await cli(dir, ["publish-issues", "--feature-slug", "feat", "--drafts", d, "--replace"]);
  assert.equal(r.code, 0, r.stderr);
  assert.deepEqual(readdirSync(join(issues, "open")).sort(), ["04-a.md", "05-b.md"]);
  assert.match(readFileSync(join(issues, "open/05-b.md"), "utf8"), /## Blocked by\n\n- 04-a\.md\n/);
  assert.deepEqual(JSON.parse(readFileSync(join(issues, "issues-deps.json"), "utf8")), { "05-b.md": ["04-a.md"] });
});

/** Every file under `dir`, relative, sorted — to prove a refused op wrote nothing. */
function tree(dir) {
  return readdirSync(dir, { recursive: true }).map(String).sort();
}

test("publish-issues (local) exits 4 and writes nothing when the feature has done issues, --replace or not", async () => {
  for (const extra of [[], ["--replace"]]) {
    const dir = root();
    mkdirSync(join(dir, ".scratch/feat/issues/done"), { recursive: true });
    writeFileSync(join(dir, ".scratch/feat/issues/done/01-old.md"), "# Old\n");
    const d = drafts(dir);
    const before = tree(dir);
    const r = await cli(dir, ["publish-issues", "--feature-slug", "feat", "--drafts", d, ...extra]);
    assert.equal(r.code, 4, extra.join(" "));
    assert.match(r.stderr, /already completed/);
    assert.deepEqual(tree(dir), before);
  }
});

test("publish-issues (local) exits 5 and writes nothing when open issues exist and --replace is absent", async () => {
  const dir = root();
  mkdirSync(join(dir, ".scratch/feat/issues/open"), { recursive: true });
  writeFileSync(join(dir, ".scratch/feat/issues/open/01-old.md"), "# Old\n");
  const d = drafts(dir);
  const before = tree(dir);
  const r = await cli(dir, ["publish-issues", "--feature-slug", "feat", "--drafts", d]);
  assert.equal(r.code, 5);
  assert.match(r.stderr, /01-old\.md/);
  assert.match(r.stderr, /--replace/);
  assert.deepEqual(tree(dir), before);
});

test("publish-issues exits 1 before creating anything on a deps.json cycle or an edge to a missing draft", async () => {
  const cases = [
    { "01-a.md": ["02-b.md"], "02-b.md": ["01-a.md"] },
    { "02-b.md": ["03-gone.md"] },
    { "09-gone.md": ["01-a.md"] },
  ];
  for (const github of [false, true]) {
    for (const deps of cases) {
      const dir = root({ github });
      const d = drafts(dir, { deps });
      const r = await cli(dir, ["publish-issues", "--feature-slug", "feat", "--drafts", d]);
      assert.equal(r.code, 1, JSON.stringify(deps));
      assert.match(r.stderr, /cycle|not a draft/, JSON.stringify(deps));
      assert.equal(existsSync(join(dir, ".scratch/feat/issues")), false);
      assert.deepEqual(readdirSync(d).sort(), ["01-a.md", "02-b.md", "deps.json"]);
    }
  }
});

test("publish-issues exits 2 for a missing drafts directory or deps.json", async () => {
  const dir = root();
  const missingDir = await cli(dir, ["publish-issues", "--feature-slug", "feat", "--drafts", join(dir, "nope")]);
  assert.equal(missingDir.code, 2);
  const d = drafts(dir, { deps: null });
  const missingDeps = await cli(dir, ["publish-issues", "--feature-slug", "feat", "--drafts", d]);
  assert.equal(missingDeps.code, 2);
  assert.match(missingDeps.stderr, /deps\.json/);
  assert.equal(existsSync(join(dir, ".scratch/feat/issues")), false);
});

test("publish-issues exits 1 for a draft without its title or Status: line", async () => {
  const dir = root();
  const d = drafts(dir, { deps: {}, files: { "01-a.md": "## What to build\n\nno title\n" } });
  const r = await cli(dir, ["publish-issues", "--feature-slug", "feat", "--drafts", d]);
  assert.equal(r.code, 1);
  assert.match(r.stderr, /01-a\.md/);
});

// --- publish-prd ---------------------------------------------------------------------

test("publish-prd (local) writes .scratch/S/PRD.md and prints its path", async () => {
  const dir = root();
  writeFileSync(join(dir, "prd.md"), "# PRD: Feat\n\n## Decisions\n");
  const r = await cli(dir, ["publish-prd", "--feature-slug", "feat", "--title", "Feat", "--body-file", join(dir, "prd.md")]);
  assert.equal(r.code, 0, r.stderr);
  assert.equal(readFileSync(join(dir, ".scratch/feat/PRD.md"), "utf8"), "# PRD: Feat\n\n## Decisions\n");
  assert.equal(r.stdout, `${join(dir, ".scratch/feat/PRD.md")}\n`);
});

test("publish-prd (github) creates 'PRD: <title>' in the milestone when it has none, and pins it", async () => {
  const dir = root({ github: true });
  writeFileSync(join(dir, "prd.md"), "## Decisions\n");
  const exec = fakeGh({
    "issue list": { stdout: JSON.stringify([{ number: 4, title: "Work", body: "", labels: [], state: "OPEN" }]) },
    "api repos/{owner}/{repo}/milestones?state=all": { stdout: "1\topen\tfeat\n" },
    "issue create": creates(20),
    "issue pin 20": {},
  });
  const r = await cli(dir, ["publish-prd", "--feature-slug", "feat", "--title", "Feat", "--body-file", join(dir, "prd.md")], exec);
  assert.equal(r.code, 0, r.stderr);
  assert.equal(r.stdout, "20\n");
  const [[create, i]] = exec.find("issue create");
  assert.equal(create[create.indexOf("--title") + 1], "PRD: Feat");
  assert.equal(create[create.indexOf("--milestone") + 1], "feat");
  assert.equal(exec.bodies[i], "## Decisions\n");
  assert.equal(exec.find("issue pin 20").length, 1);
});

test("publish-prd (github) edits the milestone's existing PRD: issue; a failed pin only warns", async () => {
  const dir = root({ github: true });
  writeFileSync(join(dir, "prd.md"), "## Decisions v2\n");
  const exec = fakeGh({
    "issue list": { stdout: JSON.stringify([{ number: 3, title: "PRD: Feat", body: "old", labels: [], state: "OPEN" }]) },
    "issue edit 3": {},
    "issue pin": { code: 1, stderr: "GraphQL: Maximum of 3 pinned issues\n" },
  });
  const r = await cli(dir, ["publish-prd", "--feature-slug", "feat", "--title", "Feat", "--body-file", join(dir, "prd.md")], exec);
  assert.equal(r.code, 0, r.stderr);
  assert.equal(r.stdout, "3\n");
  assert.equal(exec.find("issue create").length, 0);
  const [[, i]] = exec.find("issue edit 3");
  assert.equal(exec.bodies[i], "## Decisions v2\n");
  assert.match(r.stderr, /Maximum of 3 pinned issues/);
});

// --- rewrite -------------------------------------------------------------------------

const PROMOTED_BODY = "Source: review (crew/feat/01-thing)\n\n## What to build\n\nFix it.\n\n## Acceptance criteria\n\n- [ ] fixed\n";

test("rewrite (github) replaces the body as written, swaps needs-triage for the status, and reopens the milestone", async () => {
  const dir = root({ github: true });
  writeFileSync(join(dir, "body.md"), PROMOTED_BODY);
  const exec = fakeGh({
    "api repos/{owner}/{repo}/milestones?state=all": { stdout: "5\tclosed\tfeat\n" },
    "api -X PATCH repos/{owner}/{repo}/milestones/5": {},
    "issue edit 12": {},
  });
  const r = await cli(dir, ["rewrite", "12", "--body-file", join(dir, "body.md"), "--status", "ready-for-agent", "--feature-slug", "feat"], exec);
  assert.equal(r.code, 0, r.stderr);
  const reopen = exec.find("api -X PATCH");
  const [[edit, i]] = exec.find("issue edit 12");
  assert.equal(reopen.length, 1);
  assert.ok(reopen[0][1] < i, "the milestone is open before the issue moves into it");
  assert.deepEqual(edit.slice(edit.indexOf("--remove-label")), [
    "--remove-label", "needs-triage", "--add-label", "ready-for-agent", "--milestone", "feat",
  ]);
  assert.equal(exec.bodies[i], PROMOTED_BODY);
});

test("rewrite (github) given a draft takes its title and Status: lines off the body, Source: kept", async () => {
  const dir = root({ github: true });
  writeFileSync(join(dir, "body.md"), `# Fix the thing\n\nStatus: ready-for-agent\n\n${PROMOTED_BODY}`);
  const exec = fakeGh({ "api repos/{owner}/{repo}/milestones?state=all": { stdout: "5\topen\tfeat\n" }, "issue edit 12": {} });
  const r = await cli(dir, ["rewrite", "12", "--body-file", join(dir, "body.md"), "--status", "ready-for-agent", "--feature-slug", "feat"], exec);
  assert.equal(r.code, 0, r.stderr);
  const [[, i]] = exec.find("issue edit 12");
  assert.equal(exec.bodies[i], PROMOTED_BODY);
});

test("rewrite (github) creates the milestone when it is missing", async () => {
  const dir = root({ github: true });
  writeFileSync(join(dir, "body.md"), "b\n");
  const exec = fakeGh({ "api repos/{owner}/{repo}/milestones?state=all": { stdout: "" }, "api repos/{owner}/{repo}/milestones": {}, "issue edit": {} });
  const r = await cli(dir, ["rewrite", "12", "--body-file", join(dir, "body.md"), "--status", "ready-for-human", "--feature-slug", "feat"], exec);
  assert.equal(r.code, 0, r.stderr);
  assert.ok(exec.calls.some((c) => c.includes("title=feat")));
});

test("rewrite (github) exits 3 for an issue that does not exist, 2 for a non-numeric ref", async () => {
  const dir = root({ github: true });
  writeFileSync(join(dir, "body.md"), "b\n");
  const exec = fakeGh({
    "api repos": { stdout: "1\topen\tfeat\n" },
    "issue edit": { code: 1, stderr: "GraphQL: Could not resolve to an issue or pull request with the number of 999.\n" },
  });
  const argv = ["--body-file", join(dir, "body.md"), "--status", "ready-for-agent", "--feature-slug", "feat"];
  assert.equal((await cli(dir, ["rewrite", "999", ...argv], exec)).code, 3);
  assert.equal((await cli(dir, ["rewrite", "#12", ...argv])).code, 2);
});

test("rewrite (local) overwrites the issue at its path with the new body and Status: ST, Source: kept", async () => {
  const dir = root();
  const open = join(dir, ".scratch/feat/issues/open");
  cpSync(join(REPO, "tests/fixtures/lint-issues/promoted/issues"), open, { recursive: true });
  const path = join(open, "50-fix-finding.md");
  const fixture = readFileSync(path, "utf8");
  const body = fixture.replace("A reviewer found", "The reviewer found");
  writeFileSync(join(dir, "body.md"), body);
  const r = await cli(dir, ["rewrite", path, "--body-file", join(dir, "body.md"), "--status", "ready-for-agent", "--feature-slug", "feat"]);
  assert.equal(r.code, 0, r.stderr);
  const text = readFileSync(path, "utf8");
  assert.match(text, /^Status: ready-for-agent$/m);
  assert.match(text, /^Source: \.scratch\/feat\/review\.md \(crew\/feat\/01-thing\)$/m);
  assert.match(text, /The reviewer found/);
  assert.equal(text.replace(/^Status: ready-for-agent\n\n/m, ""), body);
});

test("rewrite (local) replaces an existing Status: line rather than adding a second", async () => {
  const dir = root();
  const open = join(dir, ".scratch/feat/issues/open");
  mkdirSync(open, { recursive: true });
  const path = join(open, "01-x.md");
  writeFileSync(path, "# X\n\nStatus: needs-triage\n\nold\n");
  writeFileSync(join(dir, "body.md"), "# X\n\nStatus: needs-triage\n\nSource: review (crew/feat/01-x)\n\nnew\n");
  const r = await cli(dir, ["rewrite", path, "--body-file", join(dir, "body.md"), "--status", "ready-for-human", "--feature-slug", "feat"]);
  assert.equal(r.code, 0, r.stderr);
  assert.equal(readFileSync(path, "utf8"), "# X\n\nStatus: ready-for-human\n\nSource: review (crew/feat/01-x)\n\nnew\n");
});

test("rewrite (local) exits 3 for a missing issue file", async () => {
  const dir = root();
  writeFileSync(join(dir, "body.md"), "b\n");
  const r = await cli(dir, ["rewrite", join(dir, ".scratch/feat/issues/open/09-x.md"), "--body-file", join(dir, "body.md"), "--status", "ready-for-agent", "--feature-slug", "feat"]);
  assert.equal(r.code, 3);
});

// --- mark-done -----------------------------------------------------------------------

const MET = "# T\n\nStatus: ready-for-agent\n\n## Acceptance criteria\n\n- [x] one\n";
const UNMET = `${MET}\n## Cross-cutting Requirements\n\n- [ ] docs\n`;

function localIssue(dir, text = MET) {
  const open = join(dir, ".scratch/feat/issues/open");
  mkdirSync(open, { recursive: true });
  writeFileSync(join(open, "01-t.md"), text);
  return join(open, "01-t.md");
}

test("mark-done (local) sets Status: done and moves the file to done/", async () => {
  const dir = root();
  const path = localIssue(dir);
  const r = await cli(dir, ["mark-done", path]);
  assert.equal(r.code, 0, r.stderr);
  const done = join(dir, ".scratch/feat/issues/done/01-t.md");
  assert.equal(existsSync(path), false);
  assert.match(readFileSync(done, "utf8"), /^Status: done$/m);
});

test("mark-done (local) exits 0 for an issue already in done/, by either path", async () => {
  const dir = root();
  const path = localIssue(dir);
  await cli(dir, ["mark-done", path]);
  assert.equal((await cli(dir, ["mark-done", path])).code, 0);
  assert.equal((await cli(dir, ["mark-done", join(dir, ".scratch/feat/issues/done/01-t.md")])).code, 0);
});

test("mark-done exits 3 when an orchestrator owns the close — env or marker — on both backends", async () => {
  for (const github of [false, true]) {
    const marker = root({ github });
    mkdirSync(join(marker, ".scratch/feat"), { recursive: true });
    writeFileSync(join(marker, ".scratch/feat/.orchestrated"), "");
    const ref = github ? "12" : localIssue(marker);
    const env = github ? { FEATURE_SLUG: "feat" } : {};
    const viaMarker = await cli(marker, ["mark-done", ref], undefined, env);
    assert.equal(viaMarker.code, 3, `marker github=${github}`);
    assert.match(viaMarker.stderr, /REFUSED.*orchestrat/);

    const plain = root({ github });
    const ref2 = github ? "12" : localIssue(plain);
    const viaEnv = await cli(plain, ["mark-done", ref2], undefined, { CREW_ORCHESTRATED: "1" });
    assert.equal(viaEnv.code, 3, `env github=${github}`);
    if (!github) assert.equal(existsSync(ref2), true);
  }
});

test("mark-done exits 4 while a criterion is unchecked in a fresh read, on both backends", async () => {
  const dir = root();
  const path = localIssue(dir, UNMET);
  const local = await cli(dir, ["mark-done", path]);
  assert.equal(local.code, 4);
  assert.match(local.stderr, /- \[ \] docs/);
  assert.equal(existsSync(path), true);

  const exec = fakeGh({ "issue view 12": { stdout: UNMET } });
  const gh = await cli(root({ github: true }), ["mark-done", "12"], exec);
  assert.equal(gh.code, 4);
  assert.deepEqual(exec.calls[0], ["gh", "issue", "view", "12", "--json", "body", "--jq", ".body"]);
  assert.equal(exec.find("issue edit").length, 0);
});

test("mark-done --force skips both guards", async () => {
  const dir = root();
  mkdirSync(join(dir, ".scratch/feat"), { recursive: true });
  writeFileSync(join(dir, ".scratch/feat/.orchestrated"), "");
  const path = localIssue(dir, UNMET);
  const r = await cli(dir, ["mark-done", path, "--force"], undefined, { CREW_ORCHESTRATED: "1" });
  assert.equal(r.code, 0, r.stderr);
  assert.equal(existsSync(join(dir, ".scratch/feat/issues/done/01-t.md")), true);
});

test("mark-done (github) adds awaiting-merge, removes in-progress, and leaves the issue open", async () => {
  const exec = fakeGh({ "issue view 12": { stdout: MET }, "label create": {}, "issue edit 12": {} });
  const r = await cli(root({ github: true }), ["mark-done", "12"], exec);
  assert.equal(r.code, 0, r.stderr);
  const [[edit]] = exec.find("issue edit 12");
  assert.deepEqual(edit.slice(1), [
    "issue", "edit", "12", "--add-label", "awaiting-merge",
    "--remove-label", "ready-for-agent", "--remove-label", "ready-for-human", "--remove-label", "in-progress",
  ]);
  assert.equal(exec.find("issue close").length, 0);
  assert.match(r.stdout, /Closes #12/);
});

test("mark-done (local) exits 1 for an issue that exists nowhere", async () => {
  const dir = root();
  const r = await cli(dir, ["mark-done", join(dir, ".scratch/feat/issues/open/09-none.md")]);
  assert.equal(r.code, 1);
  assert.match(r.stderr, /not found/);
});
