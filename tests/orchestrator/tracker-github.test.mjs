import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { createIssue, listOpen, markDone, parseIssue, selectDispatchable, writeProgress } from "../../orchestrator/lib/trackers/github.mjs";

// github.mjs's read path (issue 04): listOpen/parseIssue/selectDispatchable, all `gh`
// calls stubbed via an injected fake exec — no real network access, no PATH stubbing.
// See tests/orchestrator/tracker.test.mjs for the equivalent local-backend coverage and
// tests/orchestrator/body-format.test.mjs for the shared markdown-body helpers this reuses.
//
// The write path (issue 05) — createIssue/markDone/writeProgress — is covered further
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

// ─────────────────────────────── write path (issue 05) ───────────────────────────────
//
// createIssue/markDone/writeProgress, all `gh` calls stubbed via an injected fake exec.

/**
 * A stateful fake `exec` that models just enough of `gh api .../milestones` and
 * `gh issue create/view/close/comment` to exercise the write path without a real
 * network call: a "list" milestones call (no `-f`) reflects whichever milestone
 * titles have been "created" so far (an actual create call carries `-f`), and
 * `gh issue view --json body` returns whatever `body` was last set (defaults to
 * `initialViewBody`), independent of whatever the caller's own cached `issue.text` says.
 */
function fakeGhWrite({ milestoneTitles = [], viewBody = "" } = {}) {
  const calls = [];
  const milestones = new Set(milestoneTitles);
  const exec = (cmd, args) => {
    calls.push([cmd, ...args]);
    if (args[0] === "api") {
      const createMatch = args.indexOf("-f");
      if (createMatch !== -1) {
        const title = args[createMatch + 1].replace(/^title=/, "");
        milestones.add(title);
        return { code: 0, stdout: "", stderr: "" };
      }
      return { code: 0, stdout: JSON.stringify([...milestones].map((title) => ({ title }))), stderr: "" };
    }
    if (args[0] === "issue" && args[1] === "create") {
      return { code: 0, stdout: "https://github.com/owner/name/issues/42\n", stderr: "" };
    }
    if (args[0] === "issue" && args[1] === "view") {
      return { code: 0, stdout: `${viewBody}\n`, stderr: "" };
    }
    if (args[0] === "issue" && (args[1] === "close" || args[1] === "comment")) {
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

test("markDone issues a gh issue view call before gh issue close, and closes with --reason completed", () => {
  const root = repo();
  const exec = fakeGhWrite({ viewBody: "## Acceptance criteria\n\n- [x] done already\n" });
  const issue = { number: 7, text: "## Acceptance criteria\n\n- [ ] not actually done\n" };
  markDone(issue, { mainRoot: root, exec });
  const relevant = exec.calls.filter((c) => c[1] === "issue");
  assert.equal(relevant[0][2], "view");
  assert.equal(relevant[1][2], "close");
  assert.equal(relevant[0][1], "issue");
  const closeCall = relevant[1];
  assert.match(closeCall.join(" "), /--reason completed/);
  assert.doesNotMatch(closeCall.join(" "), /--label|--add-label|--remove-label/);
});

test("markDone checks criteria against the fresh gh issue view fetch, not any cached issue.text", () => {
  const root = repo();
  // issue.text (stale/cached, as if held from an earlier listOpen) has every box
  // checked — closing off that alone would wrongly succeed. The freshly-fetched body
  // (what the stubbed `gh issue view` returns) still has an unchecked box, so the
  // re-fetch, not the cache, must be what decides — and it must fail.
  const staleText = "## Acceptance criteria\n\n- [x] a\n";
  const freshBody = "## Acceptance criteria\n\n- [ ] a\n";
  const exec = fakeGhWrite({ viewBody: freshBody });
  const issue = { number: 9, text: staleText };
  assert.throws(() => markDone(issue, { mainRoot: root, exec }), /unchecked/i);
  // And, having refused, it must never have reached the close call.
  assert.ok(!exec.calls.some((c) => c[1] === "issue" && c[2] === "close"));
});

test("markDone surfaces a gh issue close failure rather than swallowing it", () => {
  const root = repo();
  const exec = (cmd, args) => {
    if (args[0] === "issue" && args[1] === "view") return { code: 0, stdout: "## Acceptance criteria\n\n- [x] a\n", stderr: "" };
    if (args[0] === "issue" && args[1] === "close") return { code: 1, stdout: "", stderr: "gh: close failed" };
    return { code: 0, stdout: "", stderr: "" };
  };
  const issue = { number: 9, text: "" };
  assert.throws(() => markDone(issue, { mainRoot: root, exec }), /gh issue close failed/);
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
