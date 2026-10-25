import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { closingRefs, createIssue, featureMarker, linkBlockers, listFeatureIssues, listFeatures, parseIssue, retryTransient, selectDispatchable, writeSection } from "../../lib/tracker/github.mjs";
import { fakeGithub, ghFeature, ghIssue } from "../helpers/fake-github.mjs";

// github.mjs's read path: listFeatureIssues/parseIssue/selectDispatchable, all `gh` calls stubbed
// via an injected fake exec — no real network access, no PATH stubbing. A feature is a root issue
// carrying `Feature: <slug>` and the root's sub-issues (tests/helpers/fake-github.mjs models both).
// See tests/tracker/tracker.test.mjs for the equivalent local-backend coverage and
// tests/tracker/body-format.test.mjs for the shared markdown-body helpers this reuses.
//
// The write path — createIssue/writeSection — is covered further down this same file.

function repo() {
  return mkdtempSync(join(tmpdir(), "crew-tracker-github-"));
}

/** The fake GitHub holding `issues` as feature `feat`: the first is its root, the rest sub-issues. */
function fakeExec(issues) {
  const [root, ...subs] = issues;
  return fakeGithub(root ? ghFeature("feat", root, ...subs) : []);
}

function failingExec(stderr, code = 1) {
  const calls = [];
  const exec = (cmd, args) => {
    calls.push([cmd, ...args]);
    return { code, stdout: "", stderr };
  };
  exec.calls = calls;
  return exec;
}

const argv = (exec) => exec.calls.map((c) => c.slice(1).join(" "));
const SCAN_OPEN = "api repos/{owner}/{repo}/issues?state=open&per_page=100 --paginate --slurp";
const SCAN_ALL = "api repos/{owner}/{repo}/issues?state=all&per_page=100 --paginate --slurp";
const subIssues = (n) => `api repos/{owner}/{repo}/issues/${n}/sub_issues?per_page=100 --paginate --slurp`;

test("listFeatureIssues finds the root among open issues, then reads its sub-issues, both paginated", () => {
  const exec = fakeExec([ghIssue(4), ghIssue(5, { state: "CLOSED" })]);
  const issues = listFeatureIssues(repo(), { featureSlug: "feat", exec });
  assert.deepEqual(issues.map((i) => i.number), [4, 5]);
  assert.deepEqual(argv(exec), [SCAN_OPEN, subIssues(4)]);
  for (const call of exec.calls) assert.ok(!call.includes("--repo"), call.join(" "));
});

test("listFeatureIssues returns every one of a feature's 34 sub-issues, past the API's page size", () => {
  const subs = Array.from({ length: 34 }, (_, i) => ghIssue(i + 2, { state: i % 2 ? "CLOSED" : "OPEN" }));
  const exec = fakeExec([ghIssue(1, { title: "PRD: big" }), ...subs]);
  const issues = listFeatureIssues(repo(), { featureSlug: "feat", exec });
  assert.equal(issues.filter((i) => i.number !== 1).length, 34);
});

test("listFeatureIssues finds a root past the first page of open issues, and drops pull requests", () => {
  const others = Array.from({ length: 150 }, (_, i) => ghIssue(i + 10));
  const pr = { ...ghIssue(500, { pr: true }), body: "Feature: feat\n" };
  const exec = fakeGithub([...ghFeature("feat", ghIssue(2), ghIssue(3)), ...others, pr]);
  assert.deepEqual(listFeatureIssues(repo(), { featureSlug: "feat", exec }).map((i) => i.number), [2, 3]);
});

test("listFeatureIssues reads a slug with no root as an empty feature, after scanning open then all issues", () => {
  const exec = fakeGithub([...ghFeature("other", ghIssue(1), ghIssue(2)), ghIssue(3, { body: "  Feature: feat\nFeature: feat-two\n" })]);
  assert.deepEqual(listFeatureIssues(repo(), { featureSlug: "feat", exec }), []);
  // The list lags a create, so the number past its newest (#3) is read too: not taken, so no root.
  assert.deepEqual(argv(exec), [SCAN_OPEN, SCAN_ALL, "api repos/{owner}/{repo}/issues/4"]);
});

test("listFeatureIssues finds a closed root when no open issue carries the marker", () => {
  const exec = fakeGithub(ghFeature("feat", ghIssue(7, { state: "CLOSED" }), ghIssue(8)));
  assert.deepEqual(listFeatureIssues(repo(), { featureSlug: "feat", exec }).map((i) => i.number), [7, 8]);
  assert.deepEqual(argv(exec), [SCAN_OPEN, SCAN_ALL, "api repos/{owner}/{repo}/issues/9", subIssues(7)]);
});

test("listFeatureIssues: one open root wins over closed ones carrying the same marker", () => {
  const exec = fakeGithub([...ghFeature("feat", ghIssue(2, { state: "CLOSED" })), ...ghFeature("feat", ghIssue(9), ghIssue(10))]);
  assert.deepEqual(listFeatureIssues(repo(), { featureSlug: "feat", exec }).map((i) => i.number), [9, 10]);
});

test("listFeatureIssues throws naming both when two open issues carry the same Feature: line", () => {
  const exec = fakeGithub([...ghFeature("feat", ghIssue(3)), ...ghFeature("feat", ghIssue(5))]);
  assert.throws(() => listFeatureIssues(repo(), { featureSlug: "feat", exec }), /#3.*#5|#5.*#3/);
});

test("listFeatureIssues throws naming both when no root is open and two closed ones carry the marker", () => {
  const closed = { state: "CLOSED" };
  const exec = fakeGithub([...ghFeature("feat", ghIssue(3, closed)), ...ghFeature("feat", ghIssue(5, closed))]);
  assert.throws(() => listFeatureIssues(repo(), { featureSlug: "feat", exec }), /#3.*#5|#5.*#3/);
});

test("listFeatureIssues throws on a gh failure with its stderr verbatim", () => {
  const exec = failingExec("gh: authentication required\n");
  assert.throws(() => listFeatureIssues(repo(), { featureSlug: "my-feature", exec }), (e) => e.message.includes("gh: authentication required\n"));
});

test("listFeatureIssues scans once per process: a later read re-reads the root found and scans nothing", () => {
  const exec = fakeExec([ghIssue(4), ghIssue(5)]);
  listFeatureIssues(repo(), { featureSlug: "feat", exec });
  exec.calls.length = 0;
  assert.deepEqual(listFeatureIssues(repo(), { featureSlug: "feat", exec }).map((i) => i.number), [4, 5]);
  assert.deepEqual(argv(exec), ["api repos/{owner}/{repo}/issues/4", subIssues(4)]);
});

test("listFeatureIssues scans again once the root it found loses its Feature: line", () => {
  const exec = fakeExec([ghIssue(4), ghIssue(5)]);
  listFeatureIssues(repo(), { featureSlug: "feat", exec });
  exec.issues.find((i) => i.number === 4).body = "moved\n";
  exec.issues.push({ ...ghIssue(9), body: "Feature: feat\n" });
  assert.deepEqual(listFeatureIssues(repo(), { featureSlug: "feat", exec }).map((i) => i.number), [9]);
});

test("listFeatureIssues rescans when the root it found is gone, and throws gh's stderr on any other failure", () => {
  const gone = fakeExec([ghIssue(4)]);
  listFeatureIssues(repo(), { featureSlug: "feat", exec: gone });
  gone.issues.splice(0);
  assert.deepEqual(listFeatureIssues(repo(), { featureSlug: "feat", exec: gone }), []);

  const failures = {};
  const exec = fakeGithub(ghFeature("feat", ghIssue(4)), { fail: failures });
  listFeatureIssues(repo(), { featureSlug: "feat", exec });
  failures["api repos/{owner}/{repo}/issues/4"] = { stderr: "gh: Bad credentials (HTTP 401)\n" };
  assert.throws(() => listFeatureIssues(repo(), { featureSlug: "feat", exec }), /Bad credentials/);
});

test("listFeatureIssues stops reading past the list's newest issue after a bounded few, even if every number answers", () => {
  const exec = (cmd, args) => {
    const path = args[1];
    if (/issues\?state=/.test(path)) return { code: 0, stdout: "[[]]", stderr: "" };
    return { code: 0, stdout: JSON.stringify({ number: 1, body: "", state: "open" }), stderr: "" };
  };
  assert.deepEqual(listFeatureIssues(repo(), { featureSlug: "feat", exec }), []);
});

test("featureMarker reads a column-0 Feature: line holding one slug, and nothing else", () => {
  assert.equal(featureMarker("Actor: x\nFeature: my-feat\n\n## What\n"), "my-feat");
  assert.equal(featureMarker("  Feature: my-feat\n"), null);
  assert.equal(featureMarker("Feature: login form\n"), null);
  assert.equal(featureMarker(""), null);
});

test("parseIssue is a pure transform producing local.mjs's exact output shape", () => {
  const json = {
    number: 5,
    title: "Fix Flaky Auth Test",
    body: ["## Blocked by", "", "- Issue 3", "", "## Acceptance criteria", "", "- [ ] a", "- [x] b", ""].join("\n"),
    labels: [{ name: "ready-for-agent" }],
    state: "OPEN",
  };
  const i = parseIssue(json);
  assert.deepEqual(Object.keys(i).sort(), [
    "blockedBy",
    "labels",
    "number",
    "ref",
    "slug",
    "status",
    "text",
    "title",
  ].sort());
  assert.equal(i.ref, 5);
  assert.equal(i.number, 5);
  assert.equal(i.title, "Fix Flaky Auth Test");
  assert.equal(i.slug, "fix-flaky-auth-test");
  assert.equal(i.status, "ready-for-agent");
  assert.deepEqual(i.blockedBy, [3]);
  assert.equal(i.text, json.body);
  assert.deepEqual(i.labels, ["ready-for-agent"]);
});

test("selectDispatchable skips a ready issue labelled blocked until the label is removed", () => {
  const root = repo();
  const blocked = { number: 1, title: "Stuck", body: "", labels: [{ name: "ready-for-agent" }, { name: "blocked" }], state: "OPEN" };
  assert.deepEqual(selectDispatchable(root, { featureSlug: "feat", exec: fakeExec([blocked]) }), []);
  const freed = { ...blocked, labels: [{ name: "ready-for-agent" }] };
  assert.deepEqual(selectDispatchable(root, { featureSlug: "feat", exec: fakeExec([freed]) }).map((i) => i.number), [1]);
});

test("selectDispatchable holds back an issue whose blocker carries the blocked label", () => {
  const root = repo();
  const exec = fakeExec([
    { number: 1, title: "Stuck", body: "", labels: [{ name: "ready-for-agent" }, { name: "blocked" }], state: "OPEN" },
    { number: 2, title: "Waits", body: "## Blocked by\n\n- Issue 1\n", labels: [{ name: "ready-for-agent" }], state: "OPEN" },
  ]);
  assert.deepEqual(selectDispatchable(root, { featureSlug: "feat", exec }), []);
});

test("parseIssue maps a closed issue's status to done regardless of any label still attached", () => {
  const i = parseIssue({ number: 9, title: "Old thing", body: "", labels: [{ name: "needs-triage" }], state: "CLOSED" });
  assert.equal(i.status, "done");
});

test("parseIssue maps an open awaiting-merge issue to done, even with ready-for-agent still attached", () => {
  const labels = [{ name: "ready-for-agent" }, { name: "awaiting-merge" }];
  const i = parseIssue({ number: 9, title: "Merged thing", body: "", labels, state: "OPEN" });
  assert.equal(i.status, "done");
});

test("parseIssue derives slug deterministically (kebab-case) from the title, not a filename", () => {
  const i = parseIssue({ number: 1, title: "Add the Widget!", body: "", labels: [], state: "OPEN" });
  assert.equal(i.slug, "add-the-widget");
});

test("selectDispatchable includes a ready issue with no blockers", () => {
  const root = repo();
  const exec = fakeExec([{ number: 1, title: "First", body: "", labels: [{ name: "ready-for-agent" }], state: "OPEN" }]);
  const picked = selectDispatchable(root, { featureSlug: "feat", exec });
  assert.deepEqual(picked.map((i) => i.number), [1]);
});

test("selectDispatchable excludes a ready issue whose blocker is still open", () => {
  const root = repo();
  const exec = fakeExec([
    { number: 1, title: "Blocker", body: "", labels: [{ name: "ready-for-agent" }], state: "OPEN" },
    {
      number: 2,
      title: "Second",
      body: "## Blocked by\n\n- Issue 1\n",
      labels: [{ name: "ready-for-agent" }],
      state: "OPEN",
    },
  ]);
  const picked = selectDispatchable(root, { featureSlug: "feat", exec }).map((i) => i.number);
  assert.deepEqual(picked, [1]);
});

test("selectDispatchable includes a ready issue whose blocker is closed", () => {
  const root = repo();
  const exec = fakeExec([
    { number: 1, title: "Blocker", body: "", labels: [], state: "CLOSED" },
    {
      number: 2,
      title: "Second",
      body: "## Blocked by\n\n- Issue 1\n",
      labels: [{ name: "ready-for-agent" }],
      state: "OPEN",
    },
  ]);
  const picked = selectDispatchable(root, { featureSlug: "feat", exec }).map((i) => i.number);
  assert.deepEqual(picked, [2]);
});

test("selectDispatchable includes a ready issue whose blocker is open but awaiting-merge", () => {
  const root = repo();
  const exec = fakeExec([
    { number: 1, title: "Blocker", body: "", labels: [{ name: "awaiting-merge" }], state: "OPEN" },
    {
      number: 2,
      title: "Second",
      body: "## Blocked by\n\n- Issue 1\n",
      labels: [{ name: "ready-for-agent" }],
      state: "OPEN",
    },
  ]);
  const picked = selectDispatchable(root, { featureSlug: "feat", exec }).map((i) => i.number);
  assert.deepEqual(picked, [2]);
});

test("selectDispatchable makes the same two gh calls regardless of issue or blocker count (the N+1 this avoids)", () => {
  const root = repo();
  const issues = Array.from({ length: 5 }, (_, idx) => ({
    number: idx + 1,
    title: `Issue ${idx + 1}`,
    body: idx === 0 ? "" : `## Blocked by\n\n- Issue ${idx}\n`,
    labels: [{ name: "ready-for-agent" }],
    state: "OPEN",
  }));
  const exec = fakeExec(issues);
  selectDispatchable(root, { featureSlug: "feat", exec });
  assert.equal(exec.calls.length, 2);
});

/** Feature `feat` (root #1) with ready #2 blocked by #40, an issue outside the feature; `outside` is #40's JSON, or absent. */
function outsideBlocker(outside, opts) {
  const two = ghIssue(2, { labels: ["ready-for-agent"], body: "## Blocked by\n\n- #40\n" });
  return fakeGithub([...ghFeature("feat", ghIssue(1), two), ...(outside ? [outside] : [])], opts);
}

test("selectDispatchable includes a ready issue whose only blocker is a closed issue outside the feature", () => {
  const exec = outsideBlocker(ghIssue(40, { state: "CLOSED" }));
  assert.deepEqual(selectDispatchable(repo(), { featureSlug: "feat", exec }).map((i) => i.number), [2]);
  assert.ok(argv(exec).includes("api repos/{owner}/{repo}/issues/40"), argv(exec).join("\n"));
});

test("selectDispatchable includes a ready issue whose blockers were closed as not planned, in the feature or outside it", () => {
  const exec = fakeGithub([
    ...ghFeature(
      "feat",
      ghIssue(1),
      { ...ghIssue(3, { state: "CLOSED" }), state_reason: "not_planned" },
      ghIssue(2, { labels: ["ready-for-agent"], body: "## Blocked by\n\n- Issue 3\n- #40\n" }),
    ),
    { ...ghIssue(40, { state: "CLOSED" }), state_reason: "not_planned" },
  ]);
  assert.deepEqual(selectDispatchable(repo(), { featureSlug: "feat", exec }).map((i) => i.number), [2]);
});

test("selectDispatchable includes a ready issue whose blocker is outside the feature, open and awaiting-merge", () => {
  const exec = outsideBlocker(ghIssue(40, { labels: ["awaiting-merge"] }));
  assert.deepEqual(selectDispatchable(repo(), { featureSlug: "feat", exec }).map((i) => i.number), [2]);
});

test("selectDispatchable excludes a ready issue whose blocker is outside the feature and open", () => {
  const exec = outsideBlocker(ghIssue(40, { labels: ["ready-for-agent"] }));
  assert.deepEqual(selectDispatchable(repo(), { featureSlug: "feat", exec }), []);
});

test("selectDispatchable excludes a ready issue whose out-of-feature blocker answers 404 or 410", () => {
  assert.deepEqual(selectDispatchable(repo(), { featureSlug: "feat", exec: outsideBlocker(null) }), []);
  const gone = outsideBlocker(null, { fail: { "api repos/{owner}/{repo}/issues/40": { stderr: "gh: This issue was deleted (HTTP 410)" } } });
  assert.deepEqual(selectDispatchable(repo(), { featureSlug: "feat", exec: gone }), []);
});

test("listFeatures counts a ready issue whose blocker is a closed issue outside the feature", () => {
  const exec = outsideBlocker(ghIssue(40, { state: "CLOSED" }));
  assert.deepEqual(listFeatures(repo(), { exec, warn: () => {} }), [{ slug: "feat", state: "open", ready: 1 }]);
});

test("selectDispatchable finds nothing for a slug with no root", () => {
  const exec = fakeGithub([ghIssue(1, { labels: ["ready-for-agent"] })]);
  assert.deepEqual(selectDispatchable(repo(), { featureSlug: "feat", exec }), []);
});

test("selectDispatchable skips a non-ready status", () => {
  const root = repo();
  const exec = fakeExec([{ number: 1, title: "Triage me", body: "", labels: [{ name: "needs-triage" }], state: "OPEN" }]);
  assert.deepEqual(selectDispatchable(root, { featureSlug: "feat", exec }), []);
});

// ─────────────────────────────── write path ───────────────────────────────
//
// createIssue/writeSection, all `gh` calls stubbed via an injected fake exec.

const createCall = (exec) => exec.calls.find((c) => c[1] === "issue" && c[2] === "create");
const flagOf = (call, name) => (call.includes(name) ? call[call.indexOf(name) + 1] : undefined);
const noMilestone = (exec) => {
  for (const call of exec.calls) assert.ok(!call.some((a) => /milestone/i.test(a)), call.join(" "));
};

test("createIssue for a slug with no root files the issue as its root: a Feature: line first, no --parent", () => {
  const exec = fakeGithub([ghIssue(1)]);
  const r = createIssue({ title: "New work", body: "## What\n\nx\n", labels: ["ready-for-agent"], featureSlug: "feat" }, { mainRoot: repo(), exec, parent: null });
  assert.equal(r.number, 2);
  assert.equal(exec.issues.find((i) => i.number === 2).body, "Feature: feat\n\n## What\n\nx\n");
  assert.equal(flagOf(createCall(exec), "--parent"), undefined);
  assert.equal(flagOf(createCall(exec), "--label"), "ready-for-agent");
  noMilestone(exec);
});

test("createIssue files the issue under the feature's root with --parent, its body passed through unmodified", () => {
  const exec = fakeGithub(ghFeature("feat", ghIssue(3, { title: "PRD: f" })));
  const body = "## Blocked by\n\n- Issue 3\n\nSource: review\n";
  const r = createIssue({ title: "New work", body, labels: ["ready-for-agent"], featureSlug: "feat" }, { mainRoot: repo(), exec, parent: 3 });
  assert.equal(flagOf(createCall(exec), "--parent"), "3");
  assert.equal(flagOf(createCall(exec), "--title"), "New work");
  const made = exec.issues.find((i) => i.number === r.number);
  assert.equal(made.body, body);
  assert.equal(made.parent, 3);
  noMilestone(exec);
});

test("createIssue never passes --repo: gh targets the git remote", () => {
  const exec = fakeGithub(ghFeature("feat", ghIssue(3), ghIssue(4)));
  createIssue({ title: "New work", body: "## Blocked by\n- Issue #4\n", labels: [], featureSlug: "feat" }, { mainRoot: repo(), exec, parent: 3 });
  for (const call of exec.calls) assert.ok(!call.includes("--repo"), call.join(" "));
  const apiPaths = exec.calls.filter((c) => c[1] === "api").map((c) => c.find((a) => a.startsWith("repos/")));
  assert.ok(apiPaths.length > 0);
  for (const path of apiPaths) assert.ok(path.startsWith("repos/{owner}/{repo}/"), path);
});

test("createIssue surfaces a gh issue create failure rather than swallowing it", () => {
  const exec = fakeGithub([], { fail: { "issue create": { stderr: "gh: something went wrong" } } });
  assert.throws(
    () => createIssue({ title: "New work", body: "b", labels: [], featureSlug: "feat" }, { mainRoot: repo(), exec, parent: null }),
    /gh issue create failed.*something went wrong/,
  );
});

test("writeSection always calls gh issue comment, never gh issue edit", () => {
  const root = repo();
  const exec = fakeGithub([ghIssue(3)]);
  writeSection(root, 3, { heading: "Progress", body: "started work", exec });
  assert.ok(exec.calls.some((c) => c[1] === "issue" && c[2] === "comment"));
  assert.ok(!exec.calls.some((c) => c[1] === "issue" && c[2] === "edit"));
});

test("a `## Blocked` write goes through the same writeSection/comment path, with no `blocked` label", () => {
  const root = repo();
  const exec = fakeGithub([ghIssue(3)]);
  writeSection(root, 3, { heading: "Blocked", body: "waiting on issue 5", exec });
  const commentCall = exec.calls.find((c) => c[1] === "issue" && c[2] === "comment");
  assert.ok(commentCall, "expected a gh issue comment call");
  // The comment body legitimately says "## Blocked" — what must never appear is a
  // `--label` flag: there is no `blocked` *label* anywhere in this module.
  assert.ok(!commentCall.includes("--label"));
});

/** A feature `feat` of open issues: PRD #2 as its root when `withPrd`, else work issue #1. */
const issue = (number, label, title = `Work ${number}`) => ghIssue(number, { title, labels: label ? [label] : [] });
const prd = (number, body = "") => ({ ...ghIssue(number, { title: "PRD: the feature" }), body });
const feature = (...issues) => {
  const root = issues.find((i) => i.title.startsWith("PRD:")) ?? ghIssue(1, { title: "Root", state: "CLOSED" });
  return fakeGithub(ghFeature("feat", root, ...issues.filter((i) => i !== root)));
};

test("closingRefs lists the feature's open awaiting-merge issues as Closes lines, in number order", () => {
  const exec = feature(issue(12, "awaiting-merge"), issue(3, "awaiting-merge"));
  assert.deepEqual(closingRefs(repo(), { featureSlug: "feat", exec }), ["Closes #3", "Closes #12"]);
  noMilestone(exec);
});

test("closingRefs adds the PRD's line when only awaiting-merge work issues are open, sorted by number", () => {
  const exec = feature(issue(12, "awaiting-merge"), prd(2), issue(3, "awaiting-merge"));
  assert.deepEqual(closingRefs(repo(), { featureSlug: "feat", exec }), ["Closes #2", "Closes #3", "Closes #12"]);
});

test("closingRefs omits the PRD's line while any open work issue is not awaiting-merge", () => {
  for (const label of ["ready-for-agent", "blocked", "ready-for-human", "needs-triage", ""]) {
    const exec = feature(prd(2), issue(3, "awaiting-merge"), issue(4, label));
    assert.deepEqual(closingRefs(repo(), { featureSlug: "feat", exec }), ["Closes #3"], `label: ${label || "none"}`);
  }
});

test("closingRefs returns no lines when nothing is awaiting-merge, PRD or not", () => {
  assert.deepEqual(closingRefs(repo(), { featureSlug: "feat", exec: feature(prd(2)) }), []);
  assert.deepEqual(closingRefs(repo(), { featureSlug: "feat", exec: feature(prd(2), issue(4, "ready-for-agent")) }), []);
  assert.deepEqual(closingRefs(repo(), { featureSlug: "feat", exec: fakeGithub([]) }), []);
});

test("closingRefs yields the work issues' lines alone for a feature with no PRD issue", () => {
  const exec = feature(issue(5, "awaiting-merge"), issue(4, "awaiting-merge"));
  assert.deepEqual(closingRefs(repo(), { featureSlug: "feat", exec }), ["Closes #4", "Closes #5"]);
});

test("closingRefs lists a single-slice root awaiting merge, and never a closed issue", () => {
  const exec = fakeGithub(ghFeature("feat", ghIssue(7, { labels: ["awaiting-merge"] }), ghIssue(8, { state: "CLOSED", labels: ["awaiting-merge"] })));
  assert.deepEqual(closingRefs(repo(), { featureSlug: "feat", exec }), ["Closes #7"]);
});

test("closingRefs surfaces a gh failure rather than reporting nothing to close", () => {
  assert.throws(() => closingRefs(repo(), { featureSlug: "feat", exec: failingExec("boom") }), /boom/);
});
// link-blockers: native blocked_by relationships mirrored from the body's `## Blocked by`.
function fakeLink({ failLink = "", noBlocker = false } = {}) {
  const calls = [];
  const exec = (cmd, args) => {
    calls.push([cmd, ...args]);
    if (args[0] === "api" && args.includes("--jq")) {
      if (noBlocker) return { code: 1, stdout: "", stderr: "Not Found" };
      const n = /issues\/(\d+)$/.exec(args[1])[1];
      return { code: 0, stdout: `${n}000\n`, stderr: "" };
    }
    if (args[0] === "api" && args.includes("POST")) {
      return failLink ? { code: 1, stdout: "", stderr: failLink } : { code: 0, stdout: "{}", stderr: "" };
    }
    return { code: 0, stdout: "", stderr: "" };
  };
  exec.calls = calls;
  return exec;
}
const posts = (exec) => exec.calls.filter((c) => c.includes("POST"));

test("linkBlockers posts one blocked_by per ## Blocked by number, using numeric ids", () => {
  const exec = fakeLink();
  assert.equal(linkBlockers(9, { mainRoot: repo(), exec, body: "## Blocked by\n\n- Issue #3\n- Issue #4\n\n## X\n", warn: () => {} }), 2);
  assert.deepEqual(posts(exec).map((c) => [c[4], c[6]]), [
    ["repos/{owner}/{repo}/issues/9/dependencies/blocked_by", "issue_id=3000"],
    ["repos/{owner}/{repo}/issues/9/dependencies/blocked_by", "issue_id=4000"],
  ]);
});

test("linkBlockers makes no dependency calls without ## Blocked by", () => {
  const exec = fakeLink();
  linkBlockers(9, { mainRoot: repo(), exec, body: "## What\nx\n", warn: () => {} });
  assert.equal(exec.calls.filter((c) => c[1] === "api").length, 0);
});

test("linkBlockers warns, never throws, on API error or missing blocker; already-linked is silent", () => {
  const warns = [];
  const warn = (m) => warns.push(m);
  const body = "## Blocked by\n- Issue #3\n";
  linkBlockers(9, { mainRoot: repo(), exec: fakeLink({ failLink: "boom" }), body, warn });
  linkBlockers(9, { mainRoot: repo(), exec: fakeLink({ noBlocker: true }), body, warn });
  assert.equal(warns.length, 2);
  linkBlockers(9, { mainRoot: repo(), exec: fakeLink({ failLink: "Issue has already been taken" }), body, warn });
  assert.equal(warns.length, 2);
});

test("linkBlockers resolves the repo from the git remote", () => {
  const exec = fakeLink();
  linkBlockers(9, { mainRoot: repo(), exec, body: "## Blocked by\n- Issue #3\n", warn: () => {} });
  assert.ok(posts(exec)[0].includes("repos/{owner}/{repo}/issues/9/dependencies/blocked_by"));
});

test("createIssue links blockers for the issue it created, and a link failure does not fail creation", () => {
  const exec = fakeGithub(ghFeature("feat", ghIssue(1)), { fail: { "api repos/{owner}/{repo}/issues/3 ": { stderr: "nope" } } });
  const r = createIssue({ title: "T", body: "## Blocked by\n- Issue #3\n", featureSlug: "feat" }, { mainRoot: repo(), exec, parent: 1 });
  assert.equal(r.number, 2);
});

test("closingRefs adds Origin: issues exactly when the PRD's line is returned", () => {
  const body = "Actor: x\nOrigin: #7, #5\n";
  assert.deepEqual(closingRefs(repo(), { featureSlug: "feat", exec: feature(prd(2, body), issue(3, "awaiting-merge")) }),
    ["Closes #2", "Closes #3", "Closes #5", "Closes #7"]);
  assert.deepEqual(closingRefs(repo(), { featureSlug: "feat", exec: feature(prd(2, body), issue(3, "awaiting-merge"), issue(4, "blocked")) }), ["Closes #3"]);
});

test("parseIssue reads blockedBy after an indented closing code fence", () => {
  const body = "## What to build\n\n1. x:\n   ```sh\n   y\n   ```\n\n## Blocked by\n\n- #12\n";
  const i = parseIssue({ number: 5, title: "t", body, labels: [], state: "OPEN" });
  assert.deepEqual(i.blockedBy, [12]);
});

test("parseIssue does not read a PR / pull request number in ## Blocked by as a blocker", () => {
  const body = "## Blocked by\n\n- Issue #3 (needs the parser from PR #40)\n- #12, after pull request #41 and pull #42\n- Issue #2, #5\n";
  const i = parseIssue({ number: 9, title: "t", body, labels: [], state: "OPEN" });
  assert.deepEqual(i.blockedBy, [3, 12, 2, 5]);
});

// Transient `gh` failures: retried with backoff; anything else surfaces on the first attempt.
const EOF_STDERR = 'Post "https://api.github.com/graphql": EOF\n';

/** A fake `exec` answering each call with the next of `results`; the last one repeats. */
function scriptedExec(results) {
  const calls = [];
  const exec = (cmd, args) => {
    calls.push([cmd, ...args]);
    return results[Math.min(calls.length, results.length) - 1];
  };
  exec.calls = calls;
  return exec;
}

test("listFeatureIssues retries a gh api read that failed with an EOF and returns the issues", () => {
  const dir = repo();
  const count = join(dir, "calls");
  const gh = join(dir, "fake-gh.sh");
  const root = JSON.stringify([[{ number: 1, title: "A", body: "Feature: feat\n", labels: [{ name: "ready-for-agent" }], state: "open" }]]);
  writeFileSync(
    gh,
    `#!/usr/bin/env bash\necho x >> '${count}'\nif [ "$(wc -l < '${count}')" -eq 1 ]; then printf '%s' '${EOF_STDERR.trim()}' >&2; exit 1; fi\n` +
      `case "$2" in *sub_issues*) printf '[[]]' ;; *) printf '%s' '${root}' ;; esac\n`,
    { mode: 0o755 },
  );
  const prev = process.env.CREW_FAKE_GH;
  process.env.CREW_FAKE_GH = gh;
  try {
    const issues = listFeatureIssues(dir, { featureSlug: "feat" });
    assert.deepEqual(issues.map((i) => i.number), [1]);
    assert.equal(readFileSync(count, "utf8").split("\n").filter(Boolean).length, 3);
  } finally {
    if (prev === undefined) delete process.env.CREW_FAKE_GH;
    else process.env.CREW_FAKE_GH = prev;
  }
});

const quiet = { sleep: () => {}, warn: () => {} };

for (const stderr of [
  "gh: To get started with GitHub CLI, please run:  gh auth login\n",
  "GraphQL: Could not resolve to an Issue with the number of 999. (repository.issue)\n",
  "unknown flag: --bogus\n\nUsage:  gh issue list [flags]\n",
]) {
  test(`a non-transient gh failure is thrown on the first attempt with gh's stderr verbatim: ${stderr.split("\n")[0]}`, () => {
    const exec = scriptedExec([{ code: 1, stdout: "", stderr }]);
    assert.throws(
      () => listFeatureIssues(repo(), { featureSlug: "feat", exec: retryTransient(exec, quiet) }),
      (err) => err.message.includes(stderr),
    );
    assert.equal(exec.calls.length, 1);
  });
}

test("a transient gh failure that outlasts the retries throws the last gh error", () => {
  const exec = scriptedExec([
    { code: 1, stdout: "", stderr: EOF_STDERR },
    { code: 1, stdout: "", stderr: "read: connection reset by peer\n" },
    { code: 1, stdout: "", stderr: "HTTP 502: Bad Gateway (https://api.github.com/graphql)\n" },
  ]);
  const slept = [];
  const retrying = retryTransient(exec, { sleep: (ms) => slept.push(ms), warn: () => {} });
  assert.throws(
    () => listFeatureIssues(repo(), { featureSlug: "feat", exec: retrying }),
    (err) => err.message.includes("HTTP 502: Bad Gateway") && !err.message.includes("EOF"),
  );
  assert.equal(exec.calls.length, 4);
  assert.deepEqual(slept, [1000, 2000, 4000]);
});

for (const [what, args] of [
  ["gh issue create", ["issue", "create", "--title", "T", "--body-file", "f"]],
  ["gh issue comment", ["issue", "comment", "7", "--body", "b"]],
  ["gh api -X POST", ["api", "-X", "POST", "repos/{owner}/{repo}/issues/9/dependencies/blocked_by", "-F", "issue_id=1"]],
  ["gh api with a field (an implicit POST)", ["api", "repos/{owner}/{repo}/issues/9/sub_issues", "-F", "sub_issue_id=1"]],
]) {
  test(`${what} is not retried after an ambiguous failure, but is after one before the request was sent`, () => {
    const ambiguous = scriptedExec([{ code: 1, stdout: "", stderr: EOF_STDERR }, { code: 0, stdout: "ok", stderr: "" }]);
    assert.equal(retryTransient(ambiguous, quiet)("gh", args).code, 1);
    assert.equal(ambiguous.calls.length, 1);

    const unsent = scriptedExec([
      { code: 1, stdout: "", stderr: 'Post "https://api.github.com/graphql": dial tcp: lookup api.github.com: no such host\n' },
      { code: 0, stdout: "ok", stderr: "" },
    ]);
    assert.equal(retryTransient(unsent, quiet)("gh", args).code, 0);
    assert.equal(unsent.calls.length, 2);
  });
}

test("an idempotent gh write (issue edit) is retried after an ambiguous failure", () => {
  const exec = scriptedExec([{ code: 1, stdout: "", stderr: EOF_STDERR }, { code: 0, stdout: "", stderr: "" }]);
  assert.equal(retryTransient(exec, quiet)("gh", ["issue", "edit", "7", "--add-label", "x"]).code, 0);
  assert.equal(exec.calls.length, 2);
});
