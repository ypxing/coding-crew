import { test } from "node:test";
import assert from "node:assert/strict";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { run } from "../../lib/tracker/cli.mjs";
import { featureMarker } from "../../lib/tracker/github.mjs";
import { fakeGithub, ghFeature, ghIssue } from "../helpers/fake-github.mjs";

// tracker/cli.mjs — the write ops (`publish-issues`, `publish-prd`, `rewrite`, `mark-done`) on
// both backends, `gh` stubbed through the injected `exec`, as tracker-cli.test.mjs does for the
// read ops. mark-done's backend-agnostic guards (no criteria section, unchecked criteria)
// live here only; tracker-mark-done-github.bats keeps what is GitHub's own (the label edits).

const REPO = join(dirname(fileURLToPath(import.meta.url)), "../..");

function root({ github = false } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "crew-tracker-cli-write-"));
  mkdirSync(join(dir, ".coding-crew/scratch"), { recursive: true });
  if (github) {
    mkdirSync(join(dir, ".coding-crew/docs"), { recursive: true });
    writeFileSync(join(dir, ".coding-crew/docs/issue-tracker.md"), "---\ntracker: github\n---\n");
  }
  return dir;
}

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
  const d = join(dir, ".coding-crew/scratch/feat/.drafts");
  mkdirSync(d, { recursive: true });
  for (const [name, text] of Object.entries(files)) writeFileSync(join(d, name), text);
  if (deps !== null) writeFileSync(join(d, "deps.json"), JSON.stringify(deps));
  return d;
}

// --- publish-issues (github) --------------------------------------------------------

const flag = (call, name) => (call.includes(name) ? call[call.indexOf(name) + 1] : undefined);
const ghCreates = (exec) => exec.calls.filter((c) => c[1] === "issue" && c[2] === "create");
const issueOf = (exec, n) => exec.issues.find((i) => i.number === n);
const noMilestone = (exec) => {
  for (const call of exec.calls) assert.ok(!call.some((a) => /milestone/i.test(a)), call.join(" "));
};

test("publish-issues (github) with no root makes the first issue the root and files every later one under it", async () => {
  const dir = root({ github: true });
  const d = drafts(dir);
  const exec = fakeGithub(ghFeature("other", ghIssue(10)));
  const r = await cli(dir, ["publish-issues", "--feature-slug", "feat", "--drafts", d], exec);
  assert.equal(r.code, 0, r.stderr);
  assert.equal(r.stdout, "01-a.md 11\n02-b.md 12\n");

  const [a, b] = ghCreates(exec);
  assert.equal(flag(a, "--title"), "Add a");
  assert.equal(flag(a, "--label"), "ready-for-agent");
  assert.equal(flag(a, "--parent"), undefined);
  assert.equal(flag(b, "--title"), "Add b");
  assert.equal(flag(b, "--label"), "ready-for-human");
  assert.equal(flag(b, "--parent"), "11");
  assert.match(issueOf(exec, 11).body, /^Feature: feat\n\n## What to build/);
  assert.doesNotMatch(issueOf(exec, 11).body, /^# Add a|^Status:/m);
  assert.doesNotMatch(issueOf(exec, 12).body, /^# Add b|^Status:|^Feature:/m);
  assert.match(issueOf(exec, 12).body, /## Blocked by\n\n- Issue #11\n/);
  assert.doesNotMatch(issueOf(exec, 12).body, /01-a\.md/);
  // 02-b's blocker is linked natively once it exists.
  assert.equal(exec.calls.filter((c) => c.join(" ").includes("-X POST repos/{owner}/{repo}/issues/12/dependencies/blocked_by")).length, 1);
  noMilestone(exec);
});

test("publish-issues (github) files every issue under an existing root", async () => {
  const dir = root({ github: true });
  const d = drafts(dir);
  const exec = fakeGithub(ghFeature("feat", ghIssue(4, { title: "PRD: Feat" })));
  const r = await cli(dir, ["publish-issues", "--feature-slug", "feat", "--drafts", d], exec);
  assert.equal(r.code, 0, r.stderr);
  assert.deepEqual(ghCreates(exec).map((c) => flag(c, "--parent")), ["4", "4"]);
  assert.doesNotMatch(issueOf(exec, 5).body, /^Feature:/m);
});

test("publish-issues (github) exits 1 naming both when two open issues carry the slug's Feature: line, creating nothing", async () => {
  const dir = root({ github: true });
  const d = drafts(dir);
  const exec = fakeGithub([...ghFeature("feat", ghIssue(3)), ...ghFeature("feat", ghIssue(5))]);
  const r = await cli(dir, ["publish-issues", "--feature-slug", "feat", "--drafts", d], exec);
  assert.equal(r.code, 1);
  assert.match(r.stderr, /#3, #5/);
  assert.equal(ghCreates(exec).length, 0);
});

test("publish-issues (github) rewrites a Blocked by entry naming a known file <n>-<slug>.md to Issue #<n> and links it", async () => {
  const dir = root({ github: true });
  const blocked = "# Add c\n\nStatus: ready-for-agent\n\n## Acceptance criteria\n\n- [ ] c works\n\n## Blocked by\n\n- 7-existing-thing.md\n";
  const d = drafts(dir, { deps: {}, files: { "01-c.md": blocked } });
  const exec = fakeGithub(ghFeature("feat", ghIssue(7, { title: "Existing thing" })));
  const r = await cli(dir, ["publish-issues", "--feature-slug", "feat", "--drafts", d], exec);
  assert.equal(r.code, 0, r.stderr);
  const body = issueOf(exec, 8).body;
  assert.match(body, /## Blocked by\n\n- Issue #7\n/);
  assert.doesNotMatch(body, /7-existing-thing\.md/);
  const { parseIssue } = await import("../../lib/tracker/github.mjs");
  assert.deepEqual(parseIssue({ number: 8, title: "Add c", body, state: "OPEN", labels: [] }).blockedBy, [7]);
  const link = exec.calls.filter((c) => c.join(" ").includes("-X POST repos/{owner}/{repo}/issues/8/dependencies/blocked_by"));
  assert.equal(link.length, 1);
  assert.ok(link[0].includes("issue_id=7000"));
});

test("publish-issues exits 1 and creates nothing when a Blocked by entry names neither a draft nor an issue of the feature", async () => {
  const blocked = "# Add c\n\nStatus: ready-for-agent\n\n## Blocked by\n\n- 03-typo.md\n";
  for (const github of [false, true]) {
    const dir = root({ github });
    const d = drafts(dir, { deps: {}, files: { "01-c.md": blocked } });
    const exec = github ? fakeGithub(ghFeature("feat", ghIssue(7, { title: "Existing thing" }))) : undefined;
    const r = await cli(dir, ["publish-issues", "--feature-slug", "feat", "--drafts", d], exec);
    assert.equal(r.code, 1, `github=${github}: ${r.stderr}`);
    assert.match(r.stderr, /03-typo\.md/);
    if (github) assert.equal(ghCreates(exec).length, 0);
    assert.equal(existsSync(join(dir, ".coding-crew/scratch/feat/issues/open")), false);
    assert.deepEqual(readdirSync(d).sort(), ["01-c.md", "deps.json"]);
  }
});

test("publish-issues (local) --replace exits 1 and writes nothing when a draft is blocked by an open issue it would delete", async () => {
  const dir = root();
  const issues = join(dir, ".coding-crew/scratch/feat/issues");
  mkdirSync(join(issues, "open"), { recursive: true });
  writeFileSync(join(issues, "open/01-old.md"), "# Old\n\nStatus: ready-for-agent\n");
  const blocked = "# Add c\n\nStatus: ready-for-agent\n\n## Blocked by\n\n- 01-old.md\n";
  const d = drafts(dir, { deps: {}, files: { "01-c.md": blocked } });
  const before = tree(dir);
  const r = await cli(dir, ["publish-issues", "--feature-slug", "feat", "--drafts", d, "--replace"]);
  assert.equal(r.code, 1, r.stderr);
  assert.match(r.stderr, /01-old\.md/);
  assert.match(r.stderr, /--replace/);
  assert.deepEqual(tree(dir), before);
});

test("publish-issues (github) deletes the drafts directory after a full publish", async () => {
  const dir = root({ github: true });
  const d = drafts(dir);
  const r = await cli(dir, ["publish-issues", "--feature-slug", "feat", "--drafts", d], fakeGithub());
  assert.equal(r.code, 0, r.stderr);
  assert.equal(existsSync(d), false);
});

test("publish-issues (github) never refuses a re-run: a feature's issues only accumulate", async () => {
  const dir = root({ github: true });
  mkdirSync(join(dir, ".coding-crew/scratch/feat/issues/done"), { recursive: true });
  writeFileSync(join(dir, ".coding-crew/scratch/feat/issues/done/01-old.md"), "# Old\n");
  mkdirSync(join(dir, ".coding-crew/scratch/feat/issues/open"), { recursive: true });
  writeFileSync(join(dir, ".coding-crew/scratch/feat/issues/open/02-old.md"), "# Old\n");
  const d = drafts(dir);
  const r = await cli(dir, ["publish-issues", "--feature-slug", "feat", "--drafts", d], fakeGithub(ghFeature("feat", ghIssue(3))));
  assert.equal(r.code, 0, r.stderr);
});

test("publish-issues (github) stops at a failed create: prints what it made, exits 1, keeps the drafts", async () => {
  const dir = root({ github: true });
  const d = drafts(dir);
  const exec = fakeGithub([], { fail: { "issue create --title Add b": { stderr: "HTTP 502: Bad Gateway\n" } } });
  const r = await cli(dir, ["publish-issues", "--feature-slug", "feat", "--drafts", d], exec);
  assert.equal(r.code, 1);
  assert.equal(r.stdout, "01-a.md 1\n");
  assert.match(r.stderr, /HTTP 502: Bad Gateway/);
  assert.match(r.stderr, /01-a\.md 1/);
  assert.deepEqual(readdirSync(d).sort(), ["01-a.md", "02-b.md", "deps.json"]);
});

// --- publish-issues (local) ---------------------------------------------------------

test("publish-issues (local) writes open/NN-<slug>.md and issues-deps.json with the final filenames", async () => {
  const dir = root();
  const d = drafts(dir);
  const r = await cli(dir, ["publish-issues", "--feature-slug", "feat", "--drafts", d]);
  assert.equal(r.code, 0, r.stderr);
  const open = join(dir, ".coding-crew/scratch/feat/issues/open");
  assert.deepEqual(readdirSync(open).sort(), ["01-a.md", "02-b.md"]);
  assert.equal(readFileSync(join(open, "01-a.md"), "utf8"), DRAFT_A);
  assert.equal(readFileSync(join(open, "02-b.md"), "utf8"), DRAFT_B);
  assert.deepEqual(JSON.parse(readFileSync(join(dir, ".coding-crew/scratch/feat/issues/issues-deps.json"), "utf8")), { "01-a.md": [], "02-b.md": ["01-a.md"] });
  assert.equal(r.stdout, `01-a.md ${join(open, "01-a.md")}\n02-b.md ${join(open, "02-b.md")}\n`);
  assert.equal(existsSync(d), false);
});

test("publish-issues (local) numbers the drafts after any existing issue and rewrites Blocked by to match", async () => {
  const dir = root();
  const issues = join(dir, ".coding-crew/scratch/feat/issues");
  mkdirSync(join(issues, "open"), { recursive: true });
  writeFileSync(join(issues, "open/03-old.md"), "# Old\n\nStatus: ready-for-agent\n");
  const d = drafts(dir);
  const r = await cli(dir, ["publish-issues", "--feature-slug", "feat", "--drafts", d, "--replace"]);
  assert.equal(r.code, 0, r.stderr);
  assert.deepEqual(readdirSync(join(issues, "open")).sort(), ["04-a.md", "05-b.md"]);
  assert.match(readFileSync(join(issues, "open/05-b.md"), "utf8"), /## Blocked by\n\n- 04-a\.md\n/);
  assert.deepEqual(JSON.parse(readFileSync(join(issues, "issues-deps.json"), "utf8")), { "04-a.md": [], "05-b.md": ["04-a.md"] });
});

test("publish-issues (local) writes every draft into issues-deps.json, [] for an unblocked one", async () => {
  const dir = root();
  const d = drafts(dir, { files: { "01-a.md": DRAFT_A, "02-b.md": DRAFT_B, "03-c.md": DRAFT_A.replace("Add a", "Add c") } });
  const r = await cli(dir, ["publish-issues", "--feature-slug", "feat", "--drafts", d]);
  assert.equal(r.code, 0, r.stderr);
  assert.deepEqual(JSON.parse(readFileSync(join(dir, ".coding-crew/scratch/feat/issues/issues-deps.json"), "utf8")), {
    "01-a.md": [],
    "02-b.md": ["01-a.md"],
    "03-c.md": [],
  });
});

test("publish-issues exits 1 and creates nothing when a draft's Blocked by and deps.json differ, naming the draft and both lists", async () => {
  for (const github of [false, true]) {
    const dir = root({ github });
    const d = drafts(dir, { deps: { "02-b.md": [] } });
    const exec = github ? fakeGithub(ghFeature("feat", ghIssue(7, { title: "Existing thing" }))) : undefined;
    const r = await cli(dir, ["publish-issues", "--feature-slug", "feat", "--drafts", d], exec);
    assert.equal(r.code, 1, `github=${github}: ${r.stderr}`);
    assert.match(r.stderr, /02-b\.md/);
    assert.match(r.stderr, /deps\.json: \[\]/);
    assert.match(r.stderr, /## Blocked by: \[01-a\.md\]/);
    assert.match(r.stderr, /names a draft by its filename/);
    if (github) assert.equal(ghCreates(exec).length, 0);
    assert.equal(existsSync(join(dir, ".coding-crew/scratch/feat/issues")), false);
    assert.deepEqual(readdirSync(d).sort(), ["01-a.md", "02-b.md", "deps.json"]);
  }
});

test("publish-issues (local) refuses a draft whose Blocked by names a draft only as Issue #<n>: a draft is named by its filename", async () => {
  const dir = root();
  const d = join(dir, ".coding-crew/scratch/feat/.drafts");
  cpSync(join(REPO, "tests/tracker/fixtures/publish-clean"), d, { recursive: true });
  const docs = join(d, "03-docs.md");
  writeFileSync(docs, readFileSync(docs, "utf8").replace("- 02-cli.md", "- Issue #2"));
  const r = await cli(dir, ["publish-issues", "--feature-slug", "feat", "--drafts", d]);
  assert.equal(r.code, 1, r.stderr);
  assert.match(r.stderr, /03-docs\.md: deps\.json: \[02-cli\.md\] differs from ## Blocked by: \[\]/);
  assert.equal(existsSync(join(dir, ".coding-crew/scratch/feat/issues")), false);
});

test("publish-issues (local) publishes the clean drafts, whose Blocked by names each draft blocker by its filename", async () => {
  const dir = root();
  const d = join(dir, ".coding-crew/scratch/feat/.drafts");
  cpSync(join(REPO, "tests/tracker/fixtures/publish-clean"), d, { recursive: true });
  const r = await cli(dir, ["publish-issues", "--feature-slug", "feat", "--drafts", d]);
  assert.equal(r.code, 0, r.stderr);
  assert.deepEqual(JSON.parse(readFileSync(join(dir, ".coding-crew/scratch/feat/issues/issues-deps.json"), "utf8")), {
    "01-store.md": [],
    "02-cli.md": ["01-store.md"],
    "03-docs.md": ["02-cli.md"],
  });
});

test("publish-issues (local) publishes the smoke demo's issues with its deps", async () => {
  const dir = root();
  const demo = join(REPO, "scripts/smoke-crew-afk/demo/feature/issues");
  const d = join(dir, ".coding-crew/scratch/feat/.drafts");
  cpSync(join(demo, "open"), d, { recursive: true });
  const present = new Set(readdirSync(d));
  const all = JSON.parse(readFileSync(join(demo, "issues-deps.json"), "utf8"));
  writeFileSync(join(d, "deps.json"), JSON.stringify(Object.fromEntries(Object.entries(all).filter(([f]) => present.has(f)))));
  const r = await cli(dir, ["publish-issues", "--feature-slug", "feat", "--drafts", d]);
  assert.equal(r.code, 0, r.stderr);
});

/** Every file under `dir`, relative, sorted — to prove a refused op wrote nothing. */
function tree(dir) {
  return readdirSync(dir, { recursive: true }).map(String).sort();
}

test("publish-issues (local) exits 4 and writes nothing when the feature has done issues, --replace or not", async () => {
  for (const extra of [[], ["--replace"]]) {
    const dir = root();
    mkdirSync(join(dir, ".coding-crew/scratch/feat/issues/done"), { recursive: true });
    writeFileSync(join(dir, ".coding-crew/scratch/feat/issues/done/01-old.md"), "# Old\n");
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
  mkdirSync(join(dir, ".coding-crew/scratch/feat/issues/open"), { recursive: true });
  writeFileSync(join(dir, ".coding-crew/scratch/feat/issues/open/01-old.md"), "# Old\n");
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
      assert.equal(existsSync(join(dir, ".coding-crew/scratch/feat/issues")), false);
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
  assert.equal(existsSync(join(dir, ".coding-crew/scratch/feat/issues")), false);
});

test("publish-issues exits 1 for a draft without its title or Status: line", async () => {
  const dir = root();
  const d = drafts(dir, { deps: {}, files: { "01-a.md": "## What to build\n\nno title\n" } });
  const r = await cli(dir, ["publish-issues", "--feature-slug", "feat", "--drafts", d]);
  assert.equal(r.code, 1);
  assert.match(r.stderr, /01-a\.md/);
});

// --- publish-prd ---------------------------------------------------------------------

test("publish-prd (local) writes .coding-crew/scratch/S/PRD.md and prints its path", async () => {
  const dir = root();
  writeFileSync(join(dir, "prd.md"), "# PRD: Feat\n\n## Decisions\n");
  const r = await cli(dir, ["publish-prd", "--feature-slug", "feat", "--title", "Feat", "--body-file", join(dir, "prd.md")]);
  assert.equal(r.code, 0, r.stderr);
  assert.equal(readFileSync(join(dir, ".coding-crew/scratch/feat/PRD.md"), "utf8"), "# PRD: Feat\n\n## Decisions\n");
  assert.equal(r.stdout, `${join(dir, ".coding-crew/scratch/feat/PRD.md")}\n`);
});

test("publish-prd (github) creates 'PRD: <title>' as the feature's root, marker added, when the slug has none; no pin", async () => {
  const dir = root({ github: true });
  writeFileSync(join(dir, "prd.md"), "## Decisions\n");
  const exec = fakeGithub([ghIssue(4, { title: "Work" })]);
  const r = await cli(dir, ["publish-prd", "--feature-slug", "feat", "--title", "Feat", "--body-file", join(dir, "prd.md")], exec);
  assert.equal(r.code, 0, r.stderr);
  assert.equal(r.stdout, "5\n");
  const [create] = ghCreates(exec);
  assert.equal(flag(create, "--title"), "PRD: Feat");
  assert.equal(flag(create, "--parent"), undefined);
  assert.equal(issueOf(exec, 5).body, "Feature: feat\n\n## Decisions\n");
  assert.ok(!exec.calls.some((c) => c[2] === "pin"), "the PRD was pinned");
  noMilestone(exec);
});

test("publish-prd (github) creates the PRD under a work-issue root with --parent", async () => {
  const dir = root({ github: true });
  writeFileSync(join(dir, "prd.md"), "## Decisions\n");
  const exec = fakeGithub(ghFeature("feat", ghIssue(4, { title: "Work", labels: ["awaiting-merge"] })));
  const r = await cli(dir, ["publish-prd", "--feature-slug", "feat", "--title", "Feat", "--body-file", join(dir, "prd.md")], exec);
  assert.equal(r.code, 0, r.stderr);
  assert.equal(r.stdout, "5\n");
  assert.equal(flag(ghCreates(exec)[0], "--parent"), "4");
  assert.equal(issueOf(exec, 5).body, "## Decisions\n");
  assert.equal(issueOf(exec, 4).state, "OPEN");
});

test("publish-issues (github) right after publish-prd files under the PRD it created, though the issue list has not caught up", async () => {
  const dir = root({ github: true });
  writeFileSync(join(dir, "prd.md"), "## Decisions\n");
  const exec = fakeGithub([ghIssue(1, { title: "Unrelated" }), ghIssue(2, { title: "A PR", pr: true })], { lagCreates: true });
  const prd = await cli(dir, ["publish-prd", "--feature-slug", "feat", "--title", "Feat", "--body-file", join(dir, "prd.md")], exec);
  assert.equal(prd.stdout, "3\n", prd.stderr);
  const r = await cli(dir, ["publish-issues", "--feature-slug", "feat", "--drafts", drafts(dir)], exec);
  assert.equal(r.code, 0, r.stderr);
  assert.equal(issueOf(exec, 4).parent, 3);
  assert.equal(issueOf(exec, 5).parent, 3);
  assert.equal(featureMarker(issueOf(exec, 4).body), null);
});

test("publish-prd (github) under an existing root drops a Feature: line from the body, so it is no second root", async () => {
  const dir = root({ github: true });
  writeFileSync(join(dir, "prd.md"), "Feature: feat\n## Decisions\n");
  const exec = fakeGithub(ghFeature("feat", ghIssue(4, { title: "Work" })));
  const r = await cli(dir, ["publish-prd", "--feature-slug", "feat", "--title", "Feat", "--body-file", join(dir, "prd.md")], exec);
  assert.equal(r.code, 0, r.stderr);
  assert.equal(issueOf(exec, 5).body, "## Decisions\n");
  const again = await cli(dir, ["prd", "--feature-slug", "feat"], exec);
  assert.equal(again.code, 0, again.stderr);
});

test("publish-prd (github) re-publishing edits the existing PRD and keeps its marker", async () => {
  const dir = root({ github: true });
  writeFileSync(join(dir, "prd.md"), "## Decisions v2\n");
  const exec = fakeGithub(ghFeature("feat", { ...ghIssue(3, { title: "PRD: Feat" }), body: "old" }, ghIssue(4)));
  const r = await cli(dir, ["publish-prd", "--feature-slug", "feat", "--title", "Feat", "--body-file", join(dir, "prd.md")], exec);
  assert.equal(r.code, 0, r.stderr);
  assert.equal(r.stdout, "3\n");
  assert.equal(ghCreates(exec).length, 0);
  assert.equal(issueOf(exec, 3).body, "Feature: feat\n\n## Decisions v2\n");
  assert.ok(!exec.calls.some((c) => c[2] === "pin"));
});

test("publish-prd (github) re-publishing a PRD filed under a work-issue root edits it without adding a marker", async () => {
  const dir = root({ github: true });
  writeFileSync(join(dir, "prd.md"), "## Decisions v2\n");
  const exec = fakeGithub(ghFeature("feat", ghIssue(4), { ...ghIssue(6, { title: "PRD: Feat" }), body: "old" }));
  const r = await cli(dir, ["publish-prd", "--feature-slug", "feat", "--title", "Feat", "--body-file", join(dir, "prd.md")], exec);
  assert.equal(r.code, 0, r.stderr);
  assert.equal(r.stdout, "6\n");
  assert.equal(issueOf(exec, 6).body, "## Decisions v2\n");
});

// --- rewrite -------------------------------------------------------------------------

const PROMOTED_BODY = "Source: review (crew/feat/01-thing)\n\n## What to build\n\nFix it.\n\n## Acceptance criteria\n\n- [ ] fixed\n";

const rewriteArgs = (dir, ref = "12", status = "ready-for-agent") =>
  ["rewrite", ref, "--body-file", join(dir, "body.md"), "--status", status, "--feature-slug", "feat"];
const triage = (n, extra = {}) => ghIssue(n, { title: "Fix", labels: ["needs-triage", "bug"], ...extra });

test("rewrite (github) replaces the body, swaps needs-triage for the status, and files the issue under the feature's root", async () => {
  const dir = root({ github: true });
  writeFileSync(join(dir, "body.md"), PROMOTED_BODY);
  const exec = fakeGithub([...ghFeature("feat", ghIssue(5, { state: "CLOSED" })), triage(12)]);
  const r = await cli(dir, rewriteArgs(dir), exec);
  assert.equal(r.code, 0, r.stderr);
  const edit = exec.calls.find((c) => c[2] === "edit");
  assert.deepEqual(edit.slice(edit.indexOf("--remove-label")), [
    "--remove-label", "needs-triage", "--add-label", "ready-for-agent", "--parent", "5",
  ]);
  assert.equal(issueOf(exec, 12).body, PROMOTED_BODY);
  assert.equal(issueOf(exec, 12).parent, 5);
  assert.equal(issueOf(exec, 5).state, "CLOSED", "a closed root is never reopened");
  noMilestone(exec);
});

test("rewrite (github) makes the issue the root, marker added, when the slug has none", async () => {
  const dir = root({ github: true });
  writeFileSync(join(dir, "body.md"), PROMOTED_BODY);
  const exec = fakeGithub([triage(12)]);
  const r = await cli(dir, rewriteArgs(dir), exec);
  assert.equal(r.code, 0, r.stderr);
  assert.ok(!exec.calls.find((c) => c[2] === "edit").includes("--parent"));
  assert.equal(issueOf(exec, 12).body, `Feature: feat\n\n${PROMOTED_BODY}`);
});

test("rewrite (github) keeps the marker when the issue is the root", async () => {
  const dir = root({ github: true });
  writeFileSync(join(dir, "body.md"), PROMOTED_BODY);
  const exec = fakeGithub(ghFeature("feat", triage(12), ghIssue(13)));
  const r = await cli(dir, rewriteArgs(dir), exec);
  assert.equal(r.code, 0, r.stderr);
  assert.ok(!exec.calls.find((c) => c[2] === "edit").includes("--parent"));
  assert.equal(issueOf(exec, 12).body, `Feature: feat\n\n${PROMOTED_BODY}`);
});

test("rewrite (github) leaves --parent off an issue already under the root", async () => {
  const dir = root({ github: true });
  writeFileSync(join(dir, "body.md"), PROMOTED_BODY);
  const exec = fakeGithub(ghFeature("feat", ghIssue(5), triage(12)));
  const r = await cli(dir, rewriteArgs(dir), exec);
  assert.equal(r.code, 0, r.stderr);
  assert.ok(!exec.calls.find((c) => c[2] === "edit").includes("--parent"));
  assert.equal(issueOf(exec, 12).body, PROMOTED_BODY);
});

test("rewrite (github) exits 1 naming the conflict for an issue of another feature, and edits nothing", async () => {
  const dir = root({ github: true });
  writeFileSync(join(dir, "body.md"), PROMOTED_BODY);
  const underOther = fakeGithub([...ghFeature("other", ghIssue(2), triage(12)), ...ghFeature("feat", ghIssue(5))]);
  let r = await cli(dir, rewriteArgs(dir), underOther);
  assert.equal(r.code, 1);
  assert.match(r.stderr, /#12.*#2/);
  assert.ok(!underOther.calls.some((c) => c[2] === "edit"));

  const otherRoot = fakeGithub(ghFeature("other", triage(12)));
  r = await cli(dir, rewriteArgs(dir), otherRoot);
  assert.equal(r.code, 1);
  assert.match(r.stderr, /Feature: other/);
  assert.ok(!otherRoot.calls.some((c) => c[2] === "edit"));

  const rootlessUnderOther = fakeGithub(ghFeature("other", ghIssue(2), triage(12)));
  r = await cli(dir, rewriteArgs(dir), rootlessUnderOther);
  assert.equal(r.code, 1);
  assert.match(r.stderr, /#12.*#2/);
  assert.ok(!rootlessUnderOther.calls.some((c) => c[2] === "edit"));
});

test("rewrite (github) makes a sub-issue of an issue with no Feature: line the root, its parent left as it is", async () => {
  const dir = root({ github: true });
  writeFileSync(join(dir, "body.md"), PROMOTED_BODY);
  const exec = fakeGithub([ghIssue(100, { title: "Epic", body: "A human's epic" }), triage(12, { parent: 100 })]);
  const r = await cli(dir, rewriteArgs(dir), exec);
  assert.equal(r.code, 0, r.stderr);
  assert.ok(!exec.calls.find((c) => c[2] === "edit").includes("--parent"));
  assert.equal(issueOf(exec, 12).body, `Feature: feat\n\n${PROMOTED_BODY}`);
  assert.equal(issueOf(exec, 12).parent, 100);
});

test("rewrite (github) given a draft takes its title and Status: lines off the body, Source: kept", async () => {
  const dir = root({ github: true });
  writeFileSync(join(dir, "body.md"), `# Fix the thing\n\nStatus: ready-for-agent\n\n${PROMOTED_BODY}`);
  const exec = fakeGithub([...ghFeature("feat", ghIssue(5)), triage(12)]);
  const r = await cli(dir, rewriteArgs(dir), exec);
  assert.equal(r.code, 0, r.stderr);
  assert.equal(issueOf(exec, 12).body, PROMOTED_BODY);
});

test("rewrite (github) rewrites a Blocked by entry naming a known file <n>-<slug>.md to Issue #<n>", async () => {
  const dir = root({ github: true });
  writeFileSync(join(dir, "body.md"), `${PROMOTED_BODY}\n## Blocked by\n\n- 7-existing-thing.md\n`);
  const exec = fakeGithub([...ghFeature("feat", ghIssue(5)), triage(12)]);
  const r = await cli(dir, rewriteArgs(dir), exec);
  assert.equal(r.code, 0, r.stderr);
  const body = issueOf(exec, 12).body;
  assert.match(body, /## Blocked by\n\n- Issue #7\n/);
  assert.doesNotMatch(body, /7-existing-thing\.md/);
  const { parseIssue } = await import("../../lib/tracker/github.mjs");
  assert.deepEqual(parseIssue({ number: 12, title: "Fix", body, state: "OPEN", labels: [] }).blockedBy, [7]);
});

test("rewrite (local) leaves a Blocked by entry naming a known issue file as that filename", async () => {
  const dir = root();
  const open = join(dir, ".coding-crew/scratch/feat/issues/open");
  mkdirSync(open, { recursive: true });
  const path = join(open, "02-x.md");
  writeFileSync(path, "# X\n\nStatus: needs-triage\n\nold\n");
  const body = "# X\n\nStatus: needs-triage\n\nnew\n\n## Blocked by\n\n- 01-old.md\n";
  writeFileSync(join(dir, "body.md"), body);
  const r = await cli(dir, ["rewrite", path, "--body-file", join(dir, "body.md"), "--status", "ready-for-agent", "--feature-slug", "feat"]);
  assert.equal(r.code, 0, r.stderr);
  assert.equal(readFileSync(path, "utf8"), body.replace("needs-triage", "ready-for-agent"));
});

test("rewrite (local) records the rewritten Blocked by in issues-deps.json, so dispatch waits on it", async () => {
  const dir = root();
  const unblocked = DRAFT_A.replace("Add a", "Add b").replace("ready-for-agent", "ready-for-human");
  const d = drafts(dir, { deps: {}, files: { "01-a.md": DRAFT_A.replace("ready-for-agent", "ready-for-human"), "02-b.md": unblocked } });
  assert.equal((await cli(dir, ["publish-issues", "--feature-slug", "feat", "--drafts", d])).code, 0);
  const issues = join(dir, ".coding-crew/scratch/feat/issues");
  const path = join(issues, "open/02-b.md");
  writeFileSync(join(dir, "body.md"), `${unblocked}\n## Blocked by\n\n- 01-a.md\n`);
  const r = await cli(dir, ["rewrite", path, "--body-file", join(dir, "body.md"), "--status", "ready-for-agent", "--feature-slug", "feat"]);
  assert.equal(r.code, 0, r.stderr);
  assert.deepEqual(JSON.parse(readFileSync(join(issues, "issues-deps.json"), "utf8")), { "01-a.md": [], "02-b.md": ["01-a.md"] });
  assert.equal((await cli(dir, ["next", "--feature-slug", "feat"])).code, 3);

  writeFileSync(join(dir, "body.md"), unblocked);
  assert.equal((await cli(dir, ["rewrite", path, "--body-file", join(dir, "body.md"), "--status", "ready-for-agent", "--feature-slug", "feat"])).code, 0);
  assert.deepEqual(JSON.parse(readFileSync(join(issues, "issues-deps.json"), "utf8")), { "01-a.md": [], "02-b.md": [] });
});

test("rewrite (github) exits 3 for an issue that does not exist, 2 for a non-numeric ref", async () => {
  const dir = root({ github: true });
  writeFileSync(join(dir, "body.md"), "b\n");
  const exec = fakeGithub(ghFeature("feat", ghIssue(1)));
  assert.equal((await cli(dir, rewriteArgs(dir, "999"), exec)).code, 3);
  assert.equal((await cli(dir, rewriteArgs(dir, "#12"))).code, 2);
});

test("rewrite (local) overwrites the issue at its path with the new body and Status: ST, Source: kept", async () => {
  const dir = root();
  const open = join(dir, ".coding-crew/scratch/feat/issues/open");
  cpSync(join(REPO, "tests/tracker/fixtures/promoted/issues"), open, { recursive: true });
  const path = join(open, "50-fix-finding.md");
  const fixture = readFileSync(path, "utf8");
  const body = fixture.replace("A reviewer found", "The reviewer found");
  writeFileSync(join(dir, "body.md"), body);
  const r = await cli(dir, ["rewrite", path, "--body-file", join(dir, "body.md"), "--status", "ready-for-agent", "--feature-slug", "feat"]);
  assert.equal(r.code, 0, r.stderr);
  const text = readFileSync(path, "utf8");
  assert.match(text, /^Status: ready-for-agent$/m);
  assert.match(text, /^Source: \S+\/feat\/review\.md \(crew\/feat\/01-thing\)$/m);
  assert.match(text, /The reviewer found/);
  assert.equal(text.replace(/^Status: ready-for-agent\n\n/m, ""), body);
});

test("rewrite (local) replaces an existing Status: line rather than adding a second", async () => {
  const dir = root();
  const open = join(dir, ".coding-crew/scratch/feat/issues/open");
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
  const r = await cli(dir, ["rewrite", join(dir, ".coding-crew/scratch/feat/issues/open/09-x.md"), "--body-file", join(dir, "body.md"), "--status", "ready-for-agent", "--feature-slug", "feat"]);
  assert.equal(r.code, 3);
});

// --- mark-done -----------------------------------------------------------------------

const MET = "# T\n\nStatus: ready-for-agent\n\n## Acceptance criteria\n\n- [x] one\n";
const UNMET = `${MET}\n## Cross-cutting Requirements\n\n- [ ] docs\n`;

function localIssue(dir, text = MET) {
  const open = join(dir, ".coding-crew/scratch/feat/issues/open");
  mkdirSync(open, { recursive: true });
  writeFileSync(join(open, "01-t.md"), text);
  return join(open, "01-t.md");
}

test("mark-done (local) sets Status: done and moves the file to done/", async () => {
  const dir = root();
  const path = localIssue(dir);
  const r = await cli(dir, ["mark-done", path]);
  assert.equal(r.code, 0, r.stderr);
  const done = join(dir, ".coding-crew/scratch/feat/issues/done/01-t.md");
  assert.equal(existsSync(path), false);
  assert.match(readFileSync(done, "utf8"), /^Status: done$/m);
});

test("mark-done (local) exits 0 for an issue already in done/, by either path", async () => {
  const dir = root();
  const path = localIssue(dir);
  await cli(dir, ["mark-done", path]);
  const again = await cli(dir, ["mark-done", path]);
  assert.equal(again.code, 0);
  assert.match(again.stdout + again.stderr, /already closed/);
  assert.equal((await cli(dir, ["mark-done", join(dir, ".coding-crew/scratch/feat/issues/done/01-t.md")])).code, 0);
});

test("mark-done with no issue ref is a usage error", async () => {
  const r = await cli(root(), ["mark-done"]);
  assert.equal(r.code, 2);
  assert.match(r.stderr, /usage:/);
});

test("mark-done exits 4 while a criterion is unchecked in a fresh read, on both backends", async () => {
  const dir = root();
  const path = localIssue(dir, UNMET);
  const local = await cli(dir, ["mark-done", path]);
  assert.equal(local.code, 4);
  assert.match(local.stderr, /unchecked criteria/);
  assert.match(local.stderr, /- \[ \] docs/);
  // --force closes an unmet issue, so the refusal never offers it as the next step to take.
  assert.doesNotMatch(local.stderr, /re-run with --force/);
  assert.match(local.stderr, /--force is only for a descope a person approved/);
  assert.equal(existsSync(path), true);

  const acRoot = root();
  const ac = await cli(acRoot, ["mark-done", localIssue(acRoot, `${MET}- [ ] three\n`)]);
  assert.equal(ac.code, 4, "an unchecked acceptance criterion");
  assert.match(ac.stderr, /three/);

  // Fetched live on each call: the same ref refuses on the unmet body, then succeeds once it is met.
  let body = UNMET;
  const exec = fakeGh({ "issue view 12 --json labels": { stdout: '{"labels":[{"name":"ready-for-agent"}]}' }, "issue view 12": () => ({ stdout: body }), "label create": {}, "issue edit 12": {} });
  const ghRoot = root({ github: true });
  const gh = await cli(ghRoot, ["mark-done", "12"], exec);
  assert.equal(gh.code, 4);
  assert.deepEqual(exec.calls[0], ["gh", "issue", "view", "12", "--json", "body", "--jq", ".body"]);
  assert.equal(exec.find("issue edit").length, 0);
  body = MET;
  assert.equal((await cli(ghRoot, ["mark-done", "12"], exec)).code, 0);
  assert.equal(exec.find("issue edit 12").length, 1);
});

// --- reopen ----------------------------------------------------------------------------

test("reopen (local) moves a done issue back to open/ as ready-for-agent, by either path; exits 3 when neither exists", async () => {
  const dir = root();
  const path = localIssue(dir);
  await cli(dir, ["mark-done", path]);
  const r = await cli(dir, ["reopen", path]);
  assert.equal(r.code, 0, r.stderr);
  assert.match(r.stdout, /^REOPENED: 01-t\.md → /);
  assert.equal(existsSync(join(dir, ".coding-crew/scratch/feat/issues/done/01-t.md")), false);
  assert.match(readFileSync(path, "utf8"), /^Status: ready-for-agent$/m);
  assert.match(readFileSync(path, "utf8"), /- \[x\] one/);

  await cli(dir, ["mark-done", path]);
  assert.equal((await cli(dir, ["reopen", join(dir, ".coding-crew/scratch/feat/issues/done/01-t.md")])).code, 0);
  assert.equal(existsSync(path), true);
  assert.equal((await cli(dir, ["reopen", path])).code, 0, "an issue already open is made ready in place");
  assert.equal((await cli(dir, ["reopen", join(dir, ".coding-crew/scratch/feat/issues/open/nope.md")])).code, 3);
  assert.equal((await cli(dir, ["reopen"])).code, 2);
});

test("reopen (github) swaps awaiting-merge for ready-for-agent, reopening a closed issue first; exits 3 for none", async () => {
  const dir = root({ github: true });
  const open = fakeGh({ "issue view 12 --json labels": { stdout: '{"labels":[{"name":"ready-for-agent"}]}' }, "issue view 12": { stdout: '{"state":"OPEN","labels":[{"name":"awaiting-merge"}]}' }, "label create": {}, "issue edit 12": {} });
  const r = await cli(dir, ["reopen", "12"], open);
  assert.equal(r.code, 0, r.stderr);
  assert.equal(r.stdout, "REOPENED: issue #12 labelled ready-for-agent\n");
  assert.deepEqual(open.find("issue edit")[0][0], ["gh", "issue", "edit", "12", "--add-label", "ready-for-agent", "--remove-label", "awaiting-merge"]);
  assert.equal(open.find("issue reopen").length, 0);

  const closed = fakeGh({ "issue view 12 --json labels": { stdout: '{"labels":[{"name":"ready-for-agent"}]}' }, "issue view 12": { stdout: '{"state":"CLOSED","labels":[]}' }, "issue reopen 12": {}, "label create": {}, "issue edit 12": {} });
  assert.equal((await cli(dir, ["reopen", "12"], closed)).code, 0);
  assert.deepEqual(closed.calls.filter((c) => c[1] === "issue").map((c) => c[2]), ["view", "reopen", "edit"]);
  assert.deepEqual(closed.find("issue edit")[0][0], ["gh", "issue", "edit", "12", "--add-label", "ready-for-agent"]);

  const gone = fakeGh({ "issue view 99": { code: 1, stderr: "could not resolve to an Issue" } });
  assert.equal((await cli(dir, ["reopen", "99"], gone)).code, 3);
});

const NO_SECTION = "# T\n\nStatus: ready-for-agent\n\n## What to build\n\nA.\n";

// --- tick / write-section ----------------------------------------------------------------

const TWO_UNMET = "# T\n\nStatus: ready-for-agent\n\n## What to build\n\n- [ ] not a criterion\n\n## Acceptance criteria\n\n- [ ] one\n- [x] two\n\n## Cross-cutting Requirements\n\n- [ ] docs\n";
const TWO_TICKED = TWO_UNMET.replace("- [ ] one", "- [x] one").replace("- [ ] docs", "- [x] docs");

test("tick (local) checks every criterion off under both headings and nothing else, then mark-done closes", async () => {
  const dir = root();
  const path = localIssue(dir, TWO_UNMET);
  const r = await cli(dir, ["tick", path]);
  assert.equal(r.code, 0, r.stderr);
  assert.match(r.stdout, /^TICKED: 01-t\.md — 2 criteria$/m);
  assert.equal(readFileSync(path, "utf8"), TWO_TICKED);
  assert.equal((await cli(dir, ["tick", path])).stdout, "TICKED: 01-t.md — 0 criteria\n");
  assert.equal((await cli(dir, ["mark-done", path])).code, 0);
});

test("tick (local) leaves a body with no criteria section alone, so mark-done still refuses it", async () => {
  const dir = root();
  const path = localIssue(dir, NO_SECTION);
  assert.equal((await cli(dir, ["tick", path])).code, 0);
  assert.equal(readFileSync(path, "utf8"), NO_SECTION);
  assert.equal((await cli(dir, ["mark-done", path])).code, 4);
});

test("tick exits 3 for a missing issue and 2 for a ref outside .coding-crew/scratch/ or no ref", async () => {
  const dir = root();
  assert.equal((await cli(dir, ["tick", join(dir, ".coding-crew/scratch/feat/issues/open/nope.md")])).code, 3);
  assert.equal((await cli(dir, ["tick", join(dir, "elsewhere.md")])).code, 2);
  assert.equal((await cli(dir, ["tick"])).code, 2);
});

test("tick (github) fetches the body live, edits it back ticked, and skips the edit when nothing is unchecked", async () => {
  const exec = fakeGh({ "issue view 12 --json labels": { stdout: '{"labels":[{"name":"ready-for-agent"}]}' }, "issue view 12": { stdout: TWO_UNMET }, "issue edit 12": {} });
  const dir = root({ github: true });
  const r = await cli(dir, ["tick", "12"], exec);
  assert.equal(r.code, 0, r.stderr);
  assert.equal(r.stdout, "TICKED: issue #12 — 2 criteria\n");
  assert.deepEqual(exec.calls[0], ["gh", "issue", "view", "12", "--json", "body", "--jq", ".body"]);
  const [[edit, i]] = exec.find("issue edit 12");
  assert.deepEqual(edit.slice(0, 4), ["gh", "issue", "edit", "12"]);
  assert.equal(exec.bodies[i], TWO_TICKED);

  const met = fakeGh({ "issue view 12 --json labels": { stdout: '{"labels":[{"name":"ready-for-agent"}]}' }, "issue view 12": { stdout: TWO_TICKED } });
  assert.equal((await cli(dir, ["tick", "12"], met)).stdout, "TICKED: issue #12 — 0 criteria\n");
  assert.equal(met.find("issue edit").length, 0);

  const gone = fakeGh({ "issue view 99": { code: 1, stderr: "could not resolve to an Issue" } });
  assert.equal((await cli(dir, ["tick", "99"], gone)).code, 3);
});

test("write-section (local) replaces or appends the section in the file; (github) posts it as a comment", async () => {
  const dir = root();
  const path = localIssue(dir, TWO_UNMET);
  const note = join(dir, "note.md");
  writeFileSync(note, "- one: blocked on the API\n");
  const r = await cli(dir, ["write-section", path, "--heading", "Unmet criteria", "--body-file", note]);
  assert.equal(r.code, 0, r.stderr);
  // validateRef resolves symlinks (macOS's /var → /private/var on the temp dir), so compare realpaths.
  assert.equal(r.stdout, `${realpathSync(path)}\n`);
  assert.match(readFileSync(path, "utf8"), /\n## Unmet criteria\n\n- one: blocked on the API\n$/);
  writeFileSync(note, "- one: descoped\n");
  await cli(dir, ["write-section", path, "--heading", "Unmet criteria", "--body-file", note]);
  const text = readFileSync(path, "utf8");
  assert.equal(text.match(/^## Unmet criteria$/gm).length, 1);
  assert.match(text, /- one: descoped/);
  assert.doesNotMatch(text, /blocked on the API/);
  assert.equal((await cli(dir, ["write-section", path, "--heading", "", "--body-file", note])).code, 2);
  assert.equal((await cli(dir, ["write-section", path, "--body-file", note])).code, 2);

  const exec = fakeGh({ "issue comment 12": {} });
  const gh = await cli(root({ github: true }), ["write-section", "12", "--heading", "Unmet criteria", "--body-file", note], exec);
  assert.equal(gh.code, 0, gh.stderr);
  assert.deepEqual(exec.calls[0], ["gh", "issue", "comment", "12", "--body", "## Unmet criteria\n\n- one: descoped\n"]);
  assert.equal(exec.find("issue edit").length, 0);
});

test("mark-done (local) on an issue already in done/ makes its Status: done in place", async () => {
  const dir = root();
  const done = join(dir, ".coding-crew/scratch/feat/issues/done");
  mkdirSync(done, { recursive: true });
  writeFileSync(join(done, "01-t.md"), "# T\n\nStatus: complete\n");
  const r = await cli(dir, ["mark-done", join(dir, ".coding-crew/scratch/feat/issues/open/01-t.md")]);
  assert.equal(r.code, 0, r.stderr);
  assert.match(readFileSync(join(done, "01-t.md"), "utf8"), /^Status: done$/m);
});

test("mark-done exits 4 for a body with no acceptance-criteria section, on both backends", async () => {
  const dir = root();
  const path = localIssue(dir, NO_SECTION);
  const local = await cli(dir, ["mark-done", path]);
  assert.equal(local.code, 4);
  assert.match(local.stderr, /^REFUSED: .*no '## Acceptance criteria' section/);
  assert.doesNotMatch(local.stderr, /re-run with --force/);
  assert.match(local.stderr, /--force is only for a descope a person approved/);
  assert.equal(existsSync(path), true);

  const exec = fakeGh({ "issue view 12 --json labels": { stdout: '{"labels":[{"name":"ready-for-agent"}]}' }, "issue view 12": { stdout: NO_SECTION }, "label create": {}, "issue edit 12": {} });
  const gh = await cli(root({ github: true }), ["mark-done", "12"], exec);
  assert.equal(gh.code, 4);
  assert.match(gh.stderr, /^REFUSED: .*no '## Acceptance criteria' section/);
  assert.equal(exec.find("issue edit").length, 0);
});

test("mark-done counts neither a fenced heading nor Cross-cutting Requirements as the criteria section", async () => {
  for (const fence of ["```", "~~~"]) {
    const dir = root();
    const body = `${NO_SECTION}\n${fence}md\n## Acceptance criteria\n\n- [x] quoted\n${fence}\n`;
    const r = await cli(dir, ["mark-done", localIssue(dir, body)]);
    assert.equal(r.code, 4, fence);
    assert.match(r.stderr, /no '## Acceptance criteria' section/);
  }
  const dir = root();
  const r = await cli(dir, ["mark-done", localIssue(dir, `${NO_SECTION}\n## Cross-cutting Requirements\n\n- [x] docs\n`)]);
  assert.equal(r.code, 4);
  assert.match(r.stderr, /no '## Acceptance criteria' section/);
});

test("mark-done accepts the published, drafted and promoted fixtures as having the section", async () => {
  for (const body of [MET, DRAFT_A.replace("- [ ]", "- [x]"), PROMOTED_BODY.replace("- [ ]", "- [x]")]) {
    const dir = root();
    const r = await cli(dir, ["mark-done", localIssue(dir, body)]);
    assert.equal(r.code, 0, `${r.stderr}\n${body}`);
  }
});

test("mark-done --force closes a body with no acceptance-criteria section, on both backends", async () => {
  const dir = root();
  const path = localIssue(dir, NO_SECTION);
  const local = await cli(dir, ["mark-done", path, "--force"]);
  assert.equal(local.code, 0, local.stderr);
  assert.equal(existsSync(join(dir, ".coding-crew/scratch/feat/issues/done/01-t.md")), true);

  const exec = fakeGh({ "issue view 12 --json labels": { stdout: '{"labels":[{"name":"ready-for-agent"}]}' }, "issue view 12": { stdout: NO_SECTION }, "label create": {}, "issue edit 12": {} });
  const gh = await cli(root({ github: true }), ["mark-done", "12", "--force"], exec);
  assert.equal(gh.code, 0, gh.stderr);
  assert.equal(exec.find("issue edit 12").length, 1);
});

test("mark-done ignores unchecked boxes outside the criteria sections", async () => {
  const dir = root();
  const r = await cli(dir, ["mark-done", localIssue(dir, `${MET}\n## Notes\n\n- [ ] someone else's todo\n`)]);
  assert.equal(r.code, 0, r.stderr);
});

test("mark-done --force skips the criteria guards", async () => {
  const dir = root();
  const path = localIssue(dir, UNMET);
  const r = await cli(dir, ["mark-done", path, "--force"]);
  assert.equal(r.code, 0, r.stderr);
  assert.equal(existsSync(join(dir, ".coding-crew/scratch/feat/issues/done/01-t.md")), true);

  const exec = fakeGh({ "issue view 12 --json labels": { stdout: '{"labels":[{"name":"ready-for-agent"}]}' }, "issue view 12": { stdout: UNMET }, "label create": {}, "issue edit 12": {} });
  const gh = await cli(root({ github: true }), ["mark-done", "12", "--force"], exec);
  assert.equal(gh.code, 0, gh.stderr);
  assert.equal(exec.find("issue edit 12").length, 1);
});

test("mark-done (github) adds awaiting-merge, removes the ready labels it carries, and leaves the issue open", async () => {
  const labels = '{"labels":[{"name":"ready-for-agent"},{"name":"ready-for-human"},{"name":"bug"}]}';
  const exec = fakeGh({ "issue view 12 --json labels": { stdout: labels }, "issue view 12": { stdout: MET }, "label create": {}, "issue edit 12": {} });
  const r = await cli(root({ github: true }), ["mark-done", "12"], exec);
  assert.equal(r.code, 0, r.stderr);
  const [[edit]] = exec.find("issue edit 12");
  assert.deepEqual(edit.slice(1), [
    "issue", "edit", "12", "--add-label", "awaiting-merge",
    "--remove-label", "ready-for-agent", "--remove-label", "ready-for-human",
  ]);
  assert.equal(exec.find("issue close").length, 0);
  assert.match(r.stdout, /Closes #12/);
});

test("mark-done (local) exits 1 for an issue that exists nowhere", async () => {
  const dir = root();
  const r = await cli(dir, ["mark-done", join(dir, ".coding-crew/scratch/feat/issues/open/09-none.md")]);
  assert.equal(r.code, 1);
  assert.match(r.stderr, /not found/);
});

// --- status labels: the github backend creates them -------------------------------------

const STATUS_LABELS = ["needs-triage", "needs-info", "ready-for-agent", "ready-for-human", "awaiting-merge", "blocked"];

/** The ops that apply a label, each against a fake repo with no labels at all. */
const LABELLING_OPS = {
  "publish-issues": (dir) => [["publish-issues", "--feature-slug", "feat", "--drafts", drafts(dir)], fakeGithub(ghFeature("feat", ghIssue(4)), { labels: [] })],
  "rewrite --status": (dir) => {
    writeFileSync(join(dir, "body.md"), PROMOTED_BODY);
    return [rewriteArgs(dir), fakeGithub([...ghFeature("feat", ghIssue(5)), triage(12)], { labels: [] })];
  },
  "mark-done": () => [["mark-done", "12"], fakeGithub([ghIssue(12, { body: MET, labels: [] })], { labels: [] })],
  reopen: () => [["reopen", "12"], fakeGithub([ghIssue(12, { state: "CLOSED" })], { labels: [] })],
};

for (const [name, setup] of Object.entries(LABELLING_OPS)) {
  test(`${name} (github) in a repo with no status labels creates all six with a fixed colour, once, before the first label is applied`, async () => {
    const dir = root({ github: true });
    const [argv, exec] = setup(dir);
    const r = await cli(dir, argv, exec);
    assert.equal(r.code, 0, r.stderr);
    const lines = exec.calls.map((c) => c.slice(1).join(" "));
    const creates = lines.filter((l) => l.startsWith("label create"));
    assert.deepEqual(creates.map((l) => l.split(" ")[2]).sort(), [...STATUS_LABELS].sort());
    // No --force: a re-run must not recolour a label a team edited; a fixed --color stops gh picking a random one.
    for (const l of creates) assert.ok(!l.includes("--force") && /--color [0-9a-f]{6}\b/.test(l), l);
    const firstLabel = lines.findIndex((l) => / --(add-)?label /.test(`${l} `));
    const lastCreate = lines.findLastIndex((l) => l.startsWith("label create"));
    assert.ok(lastCreate < firstLabel, lines.join("\n"));
  });
}

test("a gh label create that fails because the label already exists counts as created", async () => {
  const dir = root({ github: true });
  const exec = fakeGithub([ghIssue(12, { body: MET })], { fail: { "label create": { stderr: 'label with name "ready-for-agent" already exists; use `--force` to update its color and description' } } });
  const r = await cli(dir, ["mark-done", "12"], exec);
  assert.equal(r.code, 0, r.stderr);
  assert.ok(exec.calls.some((c) => c[1] === "issue" && c[2] === "edit"));
});

test("a failing gh label create exits 1 with gh's error and the label's name", async () => {
  const dir = root({ github: true });
  const exec = fakeGithub([ghIssue(12, { body: MET })], { fail: { "label create ready-for-agent": { stderr: "HTTP 403: Must have admin rights" } } });
  const r = await cli(dir, ["mark-done", "12"], exec);
  assert.equal(r.code, 1);
  assert.match(r.stderr, /ready-for-agent/);
  assert.match(r.stderr, /Must have admin rights/);
  assert.equal(exec.calls.filter((c) => c[2] === "edit").length, 0);
});
