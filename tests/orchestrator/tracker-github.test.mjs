import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { closingRefs, createIssue, linkBlockers, listFeatureIssues, parseIssue, selectDispatchable, writeProgress } from "../../orchestrator/lib/trackers/github.mjs";

// github.mjs's read path (issue 04): listFeatureIssues/parseIssue/selectDispatchable, all `gh`
// calls stubbed via an injected fake exec — no real network access, no PATH stubbing.
// See tests/orchestrator/tracker.test.mjs for the equivalent local-backend coverage and
// tests/orchestrator/body-format.test.mjs for the shared markdown-body helpers this reuses.
//
// The write path (issue 05) — createIssue/writeProgress — is covered further
// down this same file, same stubbing approach.

function repo() {
  return mkdtempSync(join(tmpdir(), "crew-tracker-github-"));
}

function writeTrackerConfig(root, contents) {
  const dir = join(root, ".coding-crew", "docs");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "issue-tracker.md"), contents);
}

/** A fake `exec` that records every call and returns one JSON payload for `gh issue list`. */
function fakeExec(issues) {
  const calls = [];
  const exec = (cmd, args) => {
    calls.push([cmd, ...args]);
    return { code: 0, stdout: JSON.stringify(issues), stderr: "" };
  };
  exec.calls = calls;
  return exec;
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

test("listFeatureIssues issues exactly one gh issue list call, scoped to the milestone, all states", () => {
  const root = repo();
  const exec = fakeExec([]);
  listFeatureIssues(root, { featureSlug: "my-feature", exec });
  assert.equal(exec.calls.length, 1);
  const argv = exec.calls[0].join(" ");
  assert.equal(exec.calls[0][0], "gh");
  assert.match(argv, /issue list/);
  assert.match(argv, /--milestone my-feature/);
  assert.match(argv, /--state all/);
  assert.match(argv, /--json number,title,body,labels,state/);
  assert.doesNotMatch(argv, /--repo/);
});

test("listFeatureIssues includes --repo only when readTrackerConfig names one", () => {
  const root = repo();
  writeTrackerConfig(root, "---\ntracker: github\nrepo: owner/name\n---\n");
  const exec = fakeExec([]);
  listFeatureIssues(root, { featureSlug: "my-feature", exec });
  assert.match(exec.calls[0].join(" "), /--repo owner\/name/);
});

test("listFeatureIssues returns an empty list for a milestone that does not exist yet, not an error", () => {
  const root = repo();
  const exec = failingExec("gh: could not resolve to a Milestone with the name 'my-feature'.");
  assert.deepEqual(listFeatureIssues(root, { featureSlug: "my-feature", exec }), []);
});

test("listFeatureIssues returns an empty list when gh succeeds with an empty milestone", () => {
  const root = repo();
  const exec = fakeExec([]);
  assert.deepEqual(listFeatureIssues(root, { featureSlug: "my-feature", exec }), []);
});

test("listFeatureIssues throws on a real gh failure unrelated to the milestone", () => {
  const root = repo();
  const exec = failingExec("gh: authentication required");
  assert.throws(() => listFeatureIssues(root, { featureSlug: "my-feature", exec }), /gh issue list failed/);
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
    "criteria",
    "hasBlocked",
    "hasProgress",
    "labels",
    "number",
    "ref",
    "sourceGuarded",
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
  assert.match(i.criteria, /- \[ \] a/);
  assert.equal(i.sourceGuarded, false);
  assert.equal(i.hasProgress, false);
  assert.equal(i.hasBlocked, false);
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

test("selectDispatchable calls gh exactly once regardless of issue or blocker count (the N+1 this avoids)", () => {
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
  assert.equal(exec.calls.length, 1);
});

test("selectDispatchable skips a non-ready status", () => {
  const root = repo();
  const exec = fakeExec([{ number: 1, title: "Triage me", body: "", labels: [{ name: "needs-triage" }], state: "OPEN" }]);
  assert.deepEqual(selectDispatchable(root, { featureSlug: "feat", exec }), []);
});

// ─────────────────────────────── write path (issue 05) ───────────────────────────────
//
// createIssue/writeProgress, all `gh` calls stubbed via an injected fake exec.

/**
 * A stateful fake `exec` that models just enough of `gh api .../milestones` and
 * `gh issue create/view/close/comment` to exercise the write path without a real
 * network call: a "list" milestones call (no `-f`) reflects whichever milestone
 * titles have been "created" so far (an actual create call carries `-f`), and
 * `gh issue view --json body` returns whatever `body` was last set (defaults to
 * `initialViewBody`), independent of whatever the caller's own cached `issue.text` says.
 */
function fakeGhWrite({ milestoneTitles = [], closedMilestoneTitles = [], viewBody = "" } = {}) {
  const calls = [];
  const milestones = [
    ...milestoneTitles.map((title) => ({ title, state: "open" })),
    ...closedMilestoneTitles.map((title) => ({ title, state: "closed" })),
  ].map((m, i) => ({ ...m, number: i + 1 }));
  const exec = (cmd, args) => {
    calls.push([cmd, ...args]);
    if (args[0] === "api") {
      const patch = args.indexOf("PATCH");
      if (patch !== -1) {
        const number = Number(args[patch + 1].split("/").pop());
        milestones.find((m) => m.number === number).state = "open";
        return { code: 0, stdout: "", stderr: "" };
      }
      const createMatch = args.indexOf("-f");
      if (createMatch !== -1) {
        const title = args[createMatch + 1].replace(/^title=/, "");
        milestones.push({ title, state: "open", number: milestones.length + 1 });
        return { code: 0, stdout: "", stderr: "" };
      }
      // Like the real API: open milestones only unless `?state=all`, one page of 30 unless
      // the call paginates, and `--jq` prints the tab-separated number/state/title lines.
      const all = args[1].includes("state=all");
      const visible = milestones.filter((m) => all || m.state === "open");
      const listed = args.includes("--paginate") ? visible : visible.slice(0, 30);
      const stdout = args.includes("--jq")
        ? listed.map((m) => `${m.number}\t${m.state}\t${m.title}\n`).join("")
        : JSON.stringify(listed);
      return { code: 0, stdout, stderr: "" };
    }
    if (args[0] === "issue" && args[1] === "create") {
      return { code: 0, stdout: "https://github.com/owner/name/issues/42\n", stderr: "" };
    }
    if (args[0] === "issue" && args[1] === "view") {
      return { code: 0, stdout: `${viewBody}\n`, stderr: "" };
    }
    if ((args[0] === "issue" && ["close", "comment", "edit"].includes(args[1])) || (args[0] === "label" && args[1] === "create")) {
      return { code: 0, stdout: "", stderr: "" };
    }
    return { code: 0, stdout: "", stderr: "" };
  };
  exec.calls = calls;
  return exec;
}

function apiCreateCalls(exec) {
  return exec.calls.filter((c) => c[1] === "api" && c.includes("-f"));
}

test("createIssue's milestone bootstrap is idempotent: a second call for the same featureSlug makes no create request", () => {
  const root = repo();
  const exec = fakeGhWrite();
  createIssue({ title: "First", body: "body one", labels: ["ready-for-agent"], featureSlug: "feat" }, { mainRoot: root, exec });
  createIssue({ title: "Second", body: "body two", labels: ["ready-for-agent"], featureSlug: "feat" }, { mainRoot: root, exec });
  assert.equal(apiCreateCalls(exec).length, 1);
});

test("createIssue finds an existing milestone past the API's first page of 30 and makes no create request", () => {
  const root = repo();
  const others = Array.from({ length: 30 }, (_, i) => `other-${i}`);
  const exec = fakeGhWrite({ milestoneTitles: [...others, "feat"] });
  createIssue({ title: "First", body: "body", labels: ["ready-for-agent"], featureSlug: "feat" }, { mainRoot: root, exec });
  assert.equal(apiCreateCalls(exec).length, 0);
});

test("createIssue reopens the feature's closed milestone instead of creating a duplicate", () => {
  const root = repo();
  const exec = fakeGhWrite({ milestoneTitles: ["other"], closedMilestoneTitles: ["feat"] });
  createIssue({ title: "First", body: "body", labels: ["ready-for-agent"], featureSlug: "feat" }, { mainRoot: root, exec });
  assert.equal(apiCreateCalls(exec).filter((c) => !c.includes("PATCH")).length, 0);
  assert.ok(exec.calls.some((c) => c.join(" ").includes("-X PATCH repos/{owner}/{repo}/milestones/2 -f state=open")));
});

test("createIssue calls gh issue create with title, body-file, label and milestone; body passed through unmodified", () => {
  const root = repo();
  let bodyFileContentsAtCallTime = null;
  const exec = (cmd, args) => {
    if (args[0] === "issue" && args[1] === "create") {
      const bodyFileIdx = args.indexOf("--body-file");
      bodyFileContentsAtCallTime = readFileSync(args[bodyFileIdx + 1], "utf8");
      return { code: 0, stdout: "https://github.com/owner/name/issues/42\n", stderr: "" };
    }
    return { code: 0, stdout: "[]", stderr: "" };
  };
  const body = "## Blocked by\n\n- Issue 3\n\nSource: review\n";
  createIssue({ title: "New work", body, labels: ["ready-for-agent"], featureSlug: "feat" }, { mainRoot: root, exec });
  // The body-file is a throwaway temp file, cleaned up once gh issue create has read it —
  // so assert on the contents captured at call time, not on the (now-deleted) path.
  assert.equal(bodyFileContentsAtCallTime, body);
});

test("createIssue calls gh issue create with title, label and milestone flags", () => {
  const root = repo();
  const exec = fakeGhWrite();
  createIssue({ title: "New work", body: "b", labels: ["ready-for-agent"], featureSlug: "feat" }, { mainRoot: root, exec });
  const createCall = exec.calls.find((c) => c[1] === "issue" && c[2] === "create");
  assert.ok(createCall, "expected a gh issue create call");
  assert.match(createCall.join(" "), /--title New work/);
  assert.match(createCall.join(" "), /--label ready-for-agent/);
  assert.match(createCall.join(" "), /--milestone feat/);
  assert.ok(createCall.includes("--body-file"));
});

test("createIssue includes --repo only when readTrackerConfig names one", () => {
  const root = repo();
  writeTrackerConfig(root, "---\ntracker: github\nrepo: owner/name\n---\n");
  const exec = fakeGhWrite();
  createIssue({ title: "New work", body: "b", labels: [], featureSlug: "feat" }, { mainRoot: root, exec });
  const createCall = exec.calls.find((c) => c[1] === "issue" && c[2] === "create");
  assert.match(createCall.join(" "), /--repo owner\/name/);
});

test("createIssue surfaces a gh issue create failure rather than swallowing it", () => {
  const root = repo();
  const exec = (cmd, args) => {
    if (args[0] === "api") return { code: 0, stdout: "[]", stderr: "" };
    return { code: 1, stdout: "", stderr: "gh: something went wrong" };
  };
  assert.throws(
    () => createIssue({ title: "New work", body: "b", labels: [], featureSlug: "feat" }, { mainRoot: root, exec }),
    /gh issue create failed/,
  );
});

test("writeProgress always calls gh issue comment, never gh issue edit", () => {
  const root = repo();
  const exec = fakeGhWrite();
  const issue = { number: 3, text: "" };
  writeProgress(issue, "started work", { heading: "Progress", mainRoot: root, exec });
  assert.ok(exec.calls.some((c) => c[1] === "issue" && c[2] === "comment"));
  assert.ok(!exec.calls.some((c) => c[1] === "issue" && c[2] === "edit"));
});

test("a `## Blocked` write goes through the same writeProgress/comment path, with no `blocked` label", () => {
  const root = repo();
  const exec = fakeGhWrite();
  const issue = { number: 3, text: "" };
  writeProgress(issue, "waiting on issue 5", { heading: "Blocked", mainRoot: root, exec });
  const commentCall = exec.calls.find((c) => c[1] === "issue" && c[2] === "comment");
  assert.ok(commentCall, "expected a gh issue comment call");
  // The comment body legitimately says "## Blocked" — what must never appear is a
  // `--label` flag: there is no `blocked` *label* anywhere in this module.
  assert.ok(!commentCall.includes("--label"));
});

/** `gh issue list --state open` of a milestone: one payload of {number,title,labels}. */
const issue = (number, label, title = `Work ${number}`) => ({ number, title, labels: label ? [{ name: label }] : [] });
const prd = (number) => issue(number, "", "PRD: the feature");

test("closingRefs lists the milestone's open awaiting-merge issues as Closes lines, in number order", () => {
  const root = repo();
  const exec = fakeExec([issue(12, "awaiting-merge"), issue(3, "awaiting-merge")]);
  assert.deepEqual(closingRefs(root, { featureSlug: "feat", exec }), ["Closes #3", "Closes #12"]);
  const argv = exec.calls[0].join(" ");
  assert.match(argv, /issue list --milestone feat --state open .*--json number,title,labels/);
});

test("closingRefs adds the PRD's line when only awaiting-merge work issues are open, sorted by number", () => {
  const exec = fakeExec([issue(12, "awaiting-merge"), prd(2), issue(3, "awaiting-merge")]);
  assert.deepEqual(closingRefs(repo(), { featureSlug: "feat", exec }), ["Closes #2", "Closes #3", "Closes #12"]);
});

test("closingRefs omits the PRD's line while any open work issue is not awaiting-merge", () => {
  for (const label of ["ready-for-agent", "blocked", "ready-for-human", "needs-triage", ""]) {
    const exec = fakeExec([prd(2), issue(3, "awaiting-merge"), issue(4, label)]);
    assert.deepEqual(closingRefs(repo(), { featureSlug: "feat", exec }), ["Closes #3"], `label: ${label || "none"}`);
  }
});

test("closingRefs returns no lines when nothing is awaiting-merge, PRD or not", () => {
  assert.deepEqual(closingRefs(repo(), { featureSlug: "feat", exec: fakeExec([prd(2)]) }), []);
  assert.deepEqual(closingRefs(repo(), { featureSlug: "feat", exec: fakeExec([prd(2), issue(4, "ready-for-agent")]) }), []);
  assert.deepEqual(closingRefs(repo(), { featureSlug: "feat", exec: fakeExec([]) }), []);
});

test("closingRefs yields the work issues' lines alone for a milestone with no PRD issue", () => {
  const exec = fakeExec([issue(5, "awaiting-merge"), issue(4, "awaiting-merge")]);
  assert.deepEqual(closingRefs(repo(), { featureSlug: "feat", exec }), ["Closes #4", "Closes #5"]);
});

test("closingRefs does not list a closed PRD issue", () => {
  // `--state open` leaves a closed PRD out of the list; the query must say so.
  const exec = fakeExec([issue(3, "awaiting-merge")]);
  assert.deepEqual(closingRefs(repo(), { featureSlug: "feat", exec }), ["Closes #3"]);
  assert.ok(exec.calls[0].join(" ").includes("--state open"));
});

test("closingRefs surfaces a gh failure rather than reporting nothing to close", () => {
  const root = repo();
  assert.throws(() => closingRefs(root, { featureSlug: "feat", exec: failingExec("boom") }), /gh issue list failed/);
});

// link-blockers: native blocked_by relationships mirrored from the body's `## Blocked by`.
function fakeLink({ body, failLink = "", noBlocker = false }) {
  const calls = [];
  const exec = (cmd, args) => {
    calls.push([cmd, ...args]);
    if (args[0] === "issue" && args[1] === "view") return { code: 0, stdout: body, stderr: "" };
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
  const exec = fakeLink({ body: "## Blocked by\n\n- Issue #3\n- Issue #4\n\n## X\n" });
  assert.equal(linkBlockers(9, { mainRoot: repo(), exec, warn: () => {} }), 2);
  assert.deepEqual(posts(exec).map((c) => [c[4], c[6]]), [
    ["repos/{owner}/{repo}/issues/9/dependencies/blocked_by", "issue_id=3000"],
    ["repos/{owner}/{repo}/issues/9/dependencies/blocked_by", "issue_id=4000"],
  ]);
});

test("linkBlockers makes no dependency calls without ## Blocked by", () => {
  const exec = fakeLink({ body: "## What\nx\n" });
  linkBlockers(9, { mainRoot: repo(), exec, warn: () => {} });
  assert.equal(exec.calls.filter((c) => c[1] === "api").length, 0);
});

test("linkBlockers warns, never throws, on API error or missing blocker; already-linked is silent", () => {
  const warns = [];
  const warn = (m) => warns.push(m);
  linkBlockers(9, { mainRoot: repo(), exec: fakeLink({ body: "## Blocked by\n- Issue #3\n", failLink: "boom" }), warn });
  linkBlockers(9, { mainRoot: repo(), exec: fakeLink({ body: "## Blocked by\n- Issue #3\n", noBlocker: true }), warn });
  assert.equal(warns.length, 2);
  linkBlockers(9, { mainRoot: repo(), exec: fakeLink({ body: "## Blocked by\n- Issue #3\n", failLink: "Issue has already been taken" }), warn });
  assert.equal(warns.length, 2);
});

test("linkBlockers honours the repo override", () => {
  const root = repo();
  writeTrackerConfig(root, "---\ntracker: github\nrepo: acme/widgets\n---\n");
  const exec = fakeLink({ body: "## Blocked by\n- Issue #3\n" });
  linkBlockers(9, { mainRoot: root, exec, warn: () => {} });
  assert.ok(posts(exec)[0].includes("repos/acme/widgets/issues/9/dependencies/blocked_by"));
});

test("createIssue links blockers for the issue it created, and a link failure does not fail creation", () => {
  const root = repo();
  const inner = fakeGhWrite();
  const exec = (cmd, args) => {
    if (args[0] === "api" && args.includes("--jq") && !args[1].includes("/milestones")) return { code: 1, stdout: "", stderr: "nope" };
    return inner(cmd, args);
  };
  const r = createIssue({ title: "T", body: "## Blocked by\n- Issue #3\n", featureSlug: "feat" }, { mainRoot: root, exec });
  assert.equal(r.number, 42);
});

test("closingRefs adds Origin: issues exactly when the PRD's line is returned", () => {
  const calls = [];
  const mk = (issues) => (cmd, args) => {
    calls.push(args);
    if (args[1] === "view") return { code: 0, stdout: JSON.stringify({ body: "Actor: x\nOrigin: #7, #5\n" }), stderr: "" };
    return { code: 0, stdout: JSON.stringify(issues), stderr: "" };
  };
  assert.deepEqual(closingRefs(repo(), { featureSlug: "feat", exec: mk([prd(2), issue(3, "awaiting-merge")]) }),
    ["Closes #2", "Closes #3", "Closes #5", "Closes #7"]);
  assert.deepEqual(closingRefs(repo(), { featureSlug: "feat", exec: mk([prd(2), issue(3, "awaiting-merge"), issue(4, "blocked")]) }), ["Closes #3"]);
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
