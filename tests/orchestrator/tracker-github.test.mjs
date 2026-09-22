import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { listOpen, parseIssue, selectDispatchable } from "../../orchestrator/lib/trackers/github.mjs";

// github.mjs's read path (issue 04): listOpen/parseIssue/selectDispatchable, all `gh`
// calls stubbed via an injected fake exec — no real network access, no PATH stubbing.
// See tests/orchestrator/tracker.test.mjs for the equivalent local-backend coverage and
// tests/orchestrator/body-format.test.mjs for the shared markdown-body helpers this reuses.

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

test("listOpen issues exactly one gh issue list call, scoped to the milestone, all states", () => {
  const root = repo();
  const exec = fakeExec([]);
  listOpen(root, { featureSlug: "my-feature", exec });
  assert.equal(exec.calls.length, 1);
  const argv = exec.calls[0].join(" ");
  assert.equal(exec.calls[0][0], "gh");
  assert.match(argv, /issue list/);
  assert.match(argv, /--milestone my-feature/);
  assert.match(argv, /--state all/);
  assert.match(argv, /--json number,title,body,labels,state/);
  assert.doesNotMatch(argv, /--repo/);
});

test("listOpen includes --repo only when readTrackerConfig names one", () => {
  const root = repo();
  writeTrackerConfig(root, "---\ntracker: github\nrepo: owner/name\n---\n");
  const exec = fakeExec([]);
  listOpen(root, { featureSlug: "my-feature", exec });
  assert.match(exec.calls[0].join(" "), /--repo owner\/name/);
});

test("listOpen returns an empty list for a milestone that does not exist yet, not an error", () => {
  const root = repo();
  const exec = failingExec("gh: could not resolve to a Milestone with the name 'my-feature'.");
  assert.deepEqual(listOpen(root, { featureSlug: "my-feature", exec }), []);
});

test("listOpen returns an empty list when gh succeeds with an empty milestone", () => {
  const root = repo();
  const exec = fakeExec([]);
  assert.deepEqual(listOpen(root, { featureSlug: "my-feature", exec }), []);
});

test("listOpen throws on a real gh failure unrelated to the milestone", () => {
  const root = repo();
  const exec = failingExec("gh: authentication required");
  assert.throws(() => listOpen(root, { featureSlug: "my-feature", exec }), /gh issue list failed/);
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
});

test("parseIssue maps a closed issue's status to done regardless of any label still attached", () => {
  const i = parseIssue({ number: 9, title: "Old thing", body: "", labels: [{ name: "needs-triage" }], state: "CLOSED" });
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
