import { test } from "node:test";
import assert from "node:assert/strict";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { run } from "../../tracker/cli.mjs";
import { fakeGithub, ghFeature, ghIssue } from "../helpers/fake-github.mjs";

// tracker/cli.mjs — the write ops (`publish-issues`, `publish-prd`, `rewrite`, `mark-done`) on
// both backends, `gh` stubbed through the injected `exec`, as tracker-cli.test.mjs does for the
// read ops. mark-done's backend-agnostic guards (sprint marker, CREW_ORCHESTRATED, unchecked criteria)
// live here only; tracker-mark-done-github.bats keeps what is GitHub's own (the label edits).

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
  const { parseIssue } = await import("../../tracker/github.mjs");
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
    assert.equal(existsSync(join(dir, ".scratch/feat/issues/open")), false);
    assert.deepEqual(readdirSync(d).sort(), ["01-c.md", "deps.json"]);
  }
});

test("publish-issues (local) --replace exits 1 and writes nothing when a draft is blocked by an open issue it would delete", async () => {
  const dir = root();
  const issues = join(dir, ".scratch/feat/issues");
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
  mkdirSync(join(dir, ".scratch/feat/issues/done"), { recursive: true });
  writeFileSync(join(dir, ".scratch/feat/issues/done/01-old.md"), "# Old\n");
  mkdirSync(join(dir, ".scratch/feat/issues/open"), { recursive: true });
  writeFileSync(join(dir, ".scratch/feat/issues/open/02-old.md"), "# Old\n");
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
  const { parseIssue } = await import("../../tracker/github.mjs");
  assert.deepEqual(parseIssue({ number: 12, title: "Fix", body, state: "OPEN", labels: [] }).blockedBy, [7]);
});

test("rewrite (local) leaves a Blocked by entry naming a known issue file as that filename", async () => {
  const dir = root();
  const open = join(dir, ".scratch/feat/issues/open");
  mkdirSync(open, { recursive: true });
  const path = join(open, "02-x.md");
  writeFileSync(path, "# X\n\nStatus: needs-triage\n\nold\n");
  const body = "# X\n\nStatus: needs-triage\n\nnew\n\n## Blocked by\n\n- 01-old.md\n";
  writeFileSync(join(dir, "body.md"), body);
  const r = await cli(dir, ["rewrite", path, "--body-file", join(dir, "body.md"), "--status", "ready-for-agent", "--feature-slug", "feat"]);
  assert.equal(r.code, 0, r.stderr);
  assert.equal(readFileSync(path, "utf8"), body.replace("needs-triage", "ready-for-agent"));
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
  const again = await cli(dir, ["mark-done", path]);
  assert.equal(again.code, 0);
  assert.match(again.stdout + again.stderr, /already closed/);
  assert.equal((await cli(dir, ["mark-done", join(dir, ".scratch/feat/issues/done/01-t.md")])).code, 0);
});

test("mark-done with no issue ref is a usage error", async () => {
  const r = await cli(root(), ["mark-done"]);
  assert.equal(r.code, 2);
  assert.match(r.stderr, /usage:/);
});

test("mark-done exits 3 when an orchestrator owns the close — env or marker — on both backends", async () => {
  for (const github of [false, true]) {
    const marker = root({ github });
    mkdirSync(join(marker, ".scratch/feat"), { recursive: true });
    writeFileSync(join(marker, ".scratch/feat/.orchestrated"), "");
    const ref = github ? "12" : localIssue(marker);
    const env = github ? { FEATURE_SLUG: "feat" } : {};
    // The issue is pre-ticked (MET): exit 3 fires before the criteria guard, so a worker's own ticks buy nothing.
    const viaMarker = await cli(marker, ["mark-done", ref], undefined, env);
    assert.equal(viaMarker.code, 3, `marker github=${github}`);
    assert.match(viaMarker.stderr, /REFUSED.*orchestrat/);
    if (!github) assert.match(readFileSync(ref, "utf8"), /^Status: ready-for-agent$/m);

    if (github) {
      // A github ref names no feature dir, so the marker is found through SPRINT_DIR too.
      const viaSprintDir = root({ github });
      mkdirSync(join(viaSprintDir, ".scratch/alpha"), { recursive: true });
      writeFileSync(join(viaSprintDir, ".scratch/alpha/.orchestrated"), "");
      const sprintDirEnv = { SPRINT_DIR: join(viaSprintDir, ".scratch/alpha") };
      assert.equal((await cli(viaSprintDir, ["mark-done", "12"], undefined, sprintDirEnv)).code, 3, "SPRINT_DIR");
    }

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
  assert.match(local.stderr, /unchecked criteria/);
  assert.match(local.stderr, /- \[ \] docs/);
  assert.equal(existsSync(path), true);

  const acRoot = root();
  const ac = await cli(acRoot, ["mark-done", localIssue(acRoot, `${MET}- [ ] three\n`)]);
  assert.equal(ac.code, 4, "an unchecked acceptance criterion");
  assert.match(ac.stderr, /three/);

  // Fetched live on each call: the same ref refuses on the unmet body, then succeeds once it is met.
  let body = UNMET;
  const exec = fakeGh({ "issue view 12": () => ({ stdout: body }), "label create": {}, "issue edit 12": {} });
  const ghRoot = root({ github: true });
  const gh = await cli(ghRoot, ["mark-done", "12"], exec);
  assert.equal(gh.code, 4);
  assert.deepEqual(exec.calls[0], ["gh", "issue", "view", "12", "--json", "body", "--jq", ".body"]);
  assert.equal(exec.find("issue edit").length, 0);
  body = MET;
  assert.equal((await cli(ghRoot, ["mark-done", "12"], exec)).code, 0);
  assert.equal(exec.find("issue edit 12").length, 1);
});

test("mark-done ignores unchecked boxes outside the criteria sections", async () => {
  const dir = root();
  const r = await cli(dir, ["mark-done", localIssue(dir, `${MET}\n## Notes\n\n- [ ] someone else's todo\n`)]);
  assert.equal(r.code, 0, r.stderr);
});

test("mark-done --force skips both guards", async () => {
  const dir = root();
  mkdirSync(join(dir, ".scratch/feat"), { recursive: true });
  writeFileSync(join(dir, ".scratch/feat/.orchestrated"), "");
  const path = localIssue(dir, UNMET);
  const r = await cli(dir, ["mark-done", path, "--force"], undefined, { CREW_ORCHESTRATED: "1" });
  assert.equal(r.code, 0, r.stderr);
  assert.equal(existsSync(join(dir, ".scratch/feat/issues/done/01-t.md")), true);

  const exec = fakeGh({ "issue view 12": { stdout: UNMET }, "label create": {}, "issue edit 12": {} });
  const gh = await cli(root({ github: true }), ["mark-done", "12", "--force"], exec, { CREW_ORCHESTRATED: "1" });
  assert.equal(gh.code, 0, gh.stderr);
  assert.equal(exec.find("issue edit 12").length, 1);
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
