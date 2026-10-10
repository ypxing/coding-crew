/**
 * pane-host.test.mjs — the herdr and orca adapters behind orchestrator/lib/pane-host/.
 */

import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  closePaneLogTab,
  closePaneWorkspace,
  drainPaneNotices,
  ensurePaneWorkspace,
  ensureWatchSession,
  notifyWatchSession,
  preflightPaneHost,
  queuePaneNotice,
  queueRunStartNotice,
  settlePaneAgent,
} from "../../orchestrator/lib/pane-host/index.mjs";
import { levelFor } from "../../orchestrator/lib/log.mjs";
import { notifyMilestone } from "../../orchestrator/lib/pipeline/shared.mjs";

// A real herdr/orca session injects these, and this suite may itself run inside one. Left
// ambient, they leak into every "not inside a pane host" assertion below. Cleared for the
// whole file; tests that need a value set and restore it themselves.
const ambientPaneHostEnv = {
  HERDR_WORKSPACE_ID: process.env.HERDR_WORKSPACE_ID,
  HERDR_TAB_ID: process.env.HERDR_TAB_ID,
  HERDR_PANE_ID: process.env.HERDR_PANE_ID,
  ORCA_WORKTREE_ID: process.env.ORCA_WORKTREE_ID,
  ORCA_TAB_ID: process.env.ORCA_TAB_ID,
  ORCA_TERMINAL_HANDLE: process.env.ORCA_TERMINAL_HANDLE,
};
before(() => {
  for (const key of Object.keys(ambientPaneHostEnv)) delete process.env[key];
});
after(() => {
  for (const [key, value] of Object.entries(ambientPaneHostEnv)) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
});

function fixture() {
  return { root: mkdtempSync(join(tmpdir(), "crew-pane-host-")) };
}

test("notifyWatchSession is a no-op with no pane host selected, even inside a herdr pane", async () => {
  const prior = process.env.HERDR_PANE_ID;
  process.env.HERDR_PANE_ID = "w1:p1";
  try {
    const calls = [];
    const effects = { paneHost: null, spawnWithTimeout: async (...a) => calls.push(a) };
    const result = await notifyWatchSession(effects, "msg");
    assert.deepEqual(result, { sent: false, reason: "no pane host" });
    assert.equal(calls.length, 0);
  } finally {
    if (prior === undefined) delete process.env.HERDR_PANE_ID;
    else process.env.HERDR_PANE_ID = prior;
  }
});

/** `effects` with a watch agent recorded as already open at `handle`. */
function watching(effects, handle) {
  effects._paneWatch = { host: effects.paneHost, handle };
  return effects;
}

// ─── pane hosts, herdr (https://herdr.dev) and orca (https://onorca.dev): ambient only,
// nothing load-bearing ──────────────────────────────────────────────────────────────────
//
// Per-worker panes (dispatchViaHerdr) are gone: every coder/reviewer/triage dispatch is
// always headless now. crew-afk's own process is never relaunched into a hosted pane either
// (herdr's `pane run` cannot report a real exit code back, so an earlier design had to fake
// completion-detection with a sentinel-file poll and a blind timeout — removed rather than
// worked around). What's left of either host is: a shared workspace with one tab/terminal
// that just tails the sprint's own trace log (ensurePaneWorkspace/ensurePaneLogTab, closed
// by closePaneWorkspace/closePaneLogTab), and a best-effort, advisory nudge to the
// watch agent at the end of a run (notifyWatchSession). orca also hosts each headless
// dispatch in a terminal for watching; that is worker-terminal.test.mjs. The herdr fixtures below are
// the actual JSON shapes captured from a real herdr workspace/tab-create round-trip; the
// orca ones are from a real live spike against a running orca runtime (`orca terminal
// create`/`rename`/`send`/`close`, each with `--json`).

function fakePaneHostEffects(paneHost, responses, { mainRoot = "/root", dryRun = false } = {}) {
  const calls = [];
  const timeouts = [];
  return {
    paneHost,
    mainRoot,
    dryRun,
    _calls: calls,
    _timeouts: timeouts,
    spawnWithTimeout: async (cmd, args, { timeoutMs } = {}) => {
      calls.push([cmd, ...args]);
      timeouts.push(timeoutMs);
      const next = responses.shift();
      if (!next) throw new Error(`no more canned ${paneHost} responses — call was: ${cmd} ${args.join(" ")}`);
      return next;
    },
    gitRead: () => ({ code: 0, stdout: ".git\n", stderr: "" }),
  };
}
const fakeHerdrEffects = (responses, opts) => fakePaneHostEffects("herdr", responses, opts);
const fakeOrcaEffects = (responses, opts) => fakePaneHostEffects("orca", responses, opts);
const json = (obj) => ({ code: 0, stdout: JSON.stringify(obj), stderr: "" });

// Every canned-response list for ensurePaneWorkspace (herdr) that passes a logFile needs
// these two responses spliced in right after the workspace create/reuse response —
// ensurePaneLogTab always fires immediately after, in both branches.
const herdrLogTabResponses = () => [
  json({ result: { tab: { tab_id: "w1:log" }, root_pane: { pane_id: "w1:plog" } } }), // log tab create
  json({ result: { type: "ok" } }), // pane run tail -f
];

function withHerdrWorkspaceId(id, fn) {
  const prior = process.env.HERDR_WORKSPACE_ID;
  process.env.HERDR_WORKSPACE_ID = id;
  return Promise.resolve()
    .then(fn)
    .finally(() => {
      if (prior === undefined) delete process.env.HERDR_WORKSPACE_ID;
      else process.env.HERDR_WORKSPACE_ID = prior;
    });
}

function withHerdrTabId(id, fn) {
  const prior = process.env.HERDR_TAB_ID;
  process.env.HERDR_TAB_ID = id;
  return Promise.resolve()
    .then(fn)
    .finally(() => {
      if (prior === undefined) delete process.env.HERDR_TAB_ID;
      else process.env.HERDR_TAB_ID = prior;
    });
}

function withHerdrPaneId(id, fn) {
  const prior = process.env.HERDR_PANE_ID;
  process.env.HERDR_PANE_ID = id;
  return Promise.resolve()
    .then(fn)
    .finally(() => {
      if (prior === undefined) delete process.env.HERDR_PANE_ID;
      else process.env.HERDR_PANE_ID = prior;
    });
}

function withOrcaWorktreeId(id, fn) {
  const prior = process.env.ORCA_WORKTREE_ID;
  process.env.ORCA_WORKTREE_ID = id;
  return Promise.resolve()
    .then(fn)
    .finally(() => {
      if (prior === undefined) delete process.env.ORCA_WORKTREE_ID;
      else process.env.ORCA_WORKTREE_ID = prior;
    });
}

function withOrcaTerminalHandle(handle, fn) {
  const prior = process.env.ORCA_TERMINAL_HANDLE;
  process.env.ORCA_TERMINAL_HANDLE = handle;
  return Promise.resolve()
    .then(fn)
    .finally(() => {
      if (prior === undefined) delete process.env.ORCA_TERMINAL_HANDLE;
      else process.env.ORCA_TERMINAL_HANDLE = prior;
    });
}

test("ensurePaneWorkspace (herdr) creates a workspace and opens a log tab that tails logFile", async () => {
  const { root } = fixture();
  const logFile = join(root, "trace.log");
  const effects = fakeHerdrEffects(
    [
      json({ result: { workspace: { workspace_id: "w1" } } }), // workspace create
      ...herdrLogTabResponses(),
    ],
    { mainRoot: root },
  );

  const workspaceId = await ensurePaneWorkspace(effects, { featureSlug: "implement-user-auth", logFile });

  assert.equal(workspaceId, "w1");
  const workspaceCreate = effects._calls[0];
  assert.deepEqual(workspaceCreate.slice(0, 3), ["herdr", "workspace", "create"]);
  assert.equal(workspaceCreate[workspaceCreate.indexOf("--label") + 1], "implement-user-auth");

  const tabCreate = effects._calls[1];
  assert.deepEqual(tabCreate.slice(0, 6), ["herdr", "tab", "create", "--workspace", "w1", "--cwd"]);
  assert.equal(tabCreate[tabCreate.indexOf("--label") + 1], "implement-user-auth-log");

  assert.deepEqual(effects._calls.at(-1), ["herdr", "pane", "run", "w1:plog", "tail", "-f", logFile]);
});

test("ensurePaneWorkspace (herdr) opens the _feature worktree as the sprint workspace", async () => {
  const { root } = fixture();
  const effects = fakeHerdrEffects([json({ result: { workspace: { workspace_id: "w1" } } })], { mainRoot: root });
  effects.featureRoot = join(root, ".scratch/worktrees/crew/alpha/_feature");

  assert.equal(await ensurePaneWorkspace(effects, { featureSlug: "alpha" }), "w1");

  const open = effects._calls[0];
  assert.deepEqual(open.slice(0, 4), ["herdr", "worktree", "open", "--path"]);
  assert.equal(open[4], effects.featureRoot);
  assert.equal(open[open.indexOf("--label") + 1], "alpha");
});

test("ensurePaneWorkspace (herdr) never opens a log tab when no logFile is given", async () => {
  const { root } = fixture();
  const effects = fakeHerdrEffects([json({ result: { workspace: { workspace_id: "w1" } } })], { mainRoot: root });

  await ensurePaneWorkspace(effects, { featureSlug: "alpha" });

  assert.deepEqual(effects._calls, [effects._calls[0]], "only the workspace create — no tab was ever requested");
  assert.ok(!effects._calls.some((c) => c[1] === "tab"));
});

test("ensurePaneWorkspace (herdr) swallows a failed log tab create — cosmetic, not a reason to fail the run", async () => {
  const { root } = fixture();
  const logFile = join(root, "trace.log");
  const effects = fakeHerdrEffects(
    [
      json({ result: { workspace: { workspace_id: "w1" } } }),
      { code: 1, stdout: "", stderr: "herdr unreachable" }, // log tab create fails
    ],
    { mainRoot: root },
  );

  const workspaceId = await ensurePaneWorkspace(effects, { featureSlug: "alpha", logFile });

  assert.equal(workspaceId, "w1", "the workspace itself is still returned — only the log tab is best-effort");
  assert.ok(!effects._calls.some((c) => c[1] === "pane" && c[2] === "run"), "never attempted pane run without a pane id");
});

// The sprint's log tab and feature agent live in the feature worktree's own workspace, whatever
// workspace the launching pane is in: a checkout that launches several sprints must not pile them
// up in one workspace, and the launching pane's own tab is left as the human named it.
test("ensurePaneWorkspace (herdr) opens the _feature worktree's workspace and its log tab there, even when HERDR_WORKSPACE_ID names a triggering workspace", async () => {
  const { root } = fixture();
  const logFile = join(root, "trace.log");
  const effects = fakeHerdrEffects(
    [
      json({ result: { workspace: { workspace_id: "w9" } } }), // worktree open
      ...herdrLogTabResponses(),
    ],
    { mainRoot: root },
  );
  effects.featureRoot = join(root, ".scratch/worktrees/crew/alpha/_feature");

  const workspaceId = await withHerdrWorkspaceId("w1", () =>
    withHerdrTabId("w1:t1", () => ensurePaneWorkspace(effects, { featureSlug: "alpha", logFile })),
  );

  assert.equal(workspaceId, "w9", "the feature worktree's workspace, not the ambient one");
  assert.deepEqual(effects._calls[0].slice(0, 4), ["herdr", "worktree", "open", "--path"]);
  const tabCreate = effects._calls[1];
  assert.deepEqual(tabCreate.slice(0, 5), ["herdr", "tab", "create", "--workspace", "w9"]);
  assert.equal(tabCreate[tabCreate.indexOf("--cwd") + 1], effects.featureRoot);
  assert.ok(!effects._calls.some((c) => c[1] === "tab" && c[2] === "rename"), "the triggering tab is not renamed");
  assert.ok(!effects._calls.some((c) => c.includes("w1")), "nothing is opened in the triggering workspace");
});

test("closePaneWorkspace (herdr) closes the workspace ensurePaneWorkspace created, and is a no-op when nothing was ever created", async () => {
  const untouched = fakeHerdrEffects([], { mainRoot: "/root" });
  await closePaneWorkspace(untouched);
  assert.deepEqual(untouched._calls, [], "nothing to close — no run ever created a workspace on this effects instance");

  const { root } = fixture();
  const effects = fakeHerdrEffects([json({ result: { already_open: false, workspace: { workspace_id: "w1" } } }), json({ result: { type: "ok" } })], { mainRoot: root });
  await ensurePaneWorkspace(effects, { featureSlug: "alpha" });
  await closePaneWorkspace(effects);
  assert.deepEqual(effects._calls.at(-1), ["herdr", "workspace", "close", "w1"]);
});

// `worktree open` returns the workspace already open on `_feature` (a developer's own, or one a
// previous run's agent died in), flagged `already_open: true`: not this run's to close.
test("closePaneWorkspace (herdr) never closes a workspace `worktree open` returned already open, even when the agent's open fails", async () => {
  const { root } = fixture();
  const effects = fakeHerdrEffects([json({ result: { already_open: true, workspace: { workspace_id: "w3" } } }), { code: 1, stdout: "", stderr: "tab create failed" }], { mainRoot: root });
  effects.featureRoot = join(root, ".scratch/worktrees/crew/alpha/_feature");
  effects.log = () => {};
  effects.exec = () => ({ code: 0, stdout: "", stderr: "" });
  effects.env = {};

  await ensurePaneWorkspace(effects, { featureSlug: "alpha" });
  assert.equal(await ensureWatchSession(effects, { slug: "alpha", platform: "claude" }), null, "the agent did not open");
  await closePaneWorkspace(effects);

  assert.ok(!effects._calls.some((c) => c[1] === "workspace" && c[2] === "close"), JSON.stringify(effects._calls));
});

test("closePaneWorkspace (herdr) closes a workspace it made itself when there is no feature worktree to open", async () => {
  const { root } = fixture();
  const effects = fakeHerdrEffects([json({ result: { workspace: { workspace_id: "w2" } } }), json({ result: { type: "ok" } })], { mainRoot: root });

  await ensurePaneWorkspace(effects, { featureSlug: "alpha" });
  await closePaneWorkspace(effects);

  assert.deepEqual(effects._calls.at(-1), ["herdr", "workspace", "close", "w2"]);
});

test("closePaneWorkspace (herdr) leaves the workspace open while the feature agent lives in it", async () => {
  const { root } = fixture();
  const effects = watching(fakeHerdrEffects([json({ result: { workspace: { workspace_id: "w9" } } })], { mainRoot: root }), "w9:p1");
  effects.featureRoot = join(root, ".scratch/worktrees/crew/alpha/_feature");

  await ensurePaneWorkspace(effects, { featureSlug: "alpha" });
  await closePaneWorkspace(effects);

  assert.ok(
    !effects._calls.some((c) => c[1] === "workspace" && c[2] === "close"),
    "the agent is the developer's terminal now: its workspace is not closed out from under it",
  );
});

test("closePaneLogTab (herdr) closes the log tab ensurePaneWorkspace opened, and is a no-op when none was ever created", async () => {
  const untouched = fakeHerdrEffects([], { mainRoot: "/root" });
  await closePaneLogTab(untouched);
  assert.deepEqual(untouched._calls, [], "nothing to close — no run ever created a log tab on this effects instance");

  const { root } = fixture();
  const logFile = join(root, "trace.log");
  const effects = fakeHerdrEffects(
    [json({ result: { workspace: { workspace_id: "w1" } } }), ...herdrLogTabResponses(), json({ result: { type: "ok" } })],
    { mainRoot: root },
  );
  await ensurePaneWorkspace(effects, { featureSlug: "alpha", logFile });
  await closePaneLogTab(effects);
  assert.deepEqual(effects._calls.at(-1), ["herdr", "tab", "close", "w1:log"]);
});

// The workspace survives a live agent, but this run's own log tab inside it is still this run's to
// close — otherwise it tails the trace log forever after the run.
test("closePaneLogTab (herdr) closes this run's own log tab even when the workspace is kept for the feature agent", async () => {
  const { root } = fixture();
  const logFile = join(root, "trace.log");
  const effects = watching(
    fakeHerdrEffects([json({ result: { workspace: { workspace_id: "w9" } } }), ...herdrLogTabResponses(), json({ result: { type: "ok" } })], { mainRoot: root }),
    "w9:p1",
  );

  await ensurePaneWorkspace(effects, { featureSlug: "alpha", logFile });
  await closePaneWorkspace(effects);
  await closePaneLogTab(effects);

  assert.ok(!effects._calls.some((c) => c[1] === "workspace" && c[2] === "close"), "the workspace itself is left open");
  assert.deepEqual(effects._calls.at(-1), ["herdr", "tab", "close", "w1:log"], "but this run's own log tab is closed");
});

test("notifyWatchSession (herdr) pushes nowhere when no watch agent was opened, even from inside a herdr pane", async () => {
  const effects = fakeHerdrEffects([], { mainRoot: "/root" });
  const result = await withHerdrPaneId("w1:p1", () => notifyWatchSession(effects, "crew-afk (alpha): sprint finished."));
  assert.deepEqual(effects._calls, [], "HERDR_PANE_ID is never a push target");
  assert.deepEqual(result, { sent: false, reason: "no watch session" });
});

test("notifyWatchSession (herdr) prompts the watch agent by its recorded pane id, not HERDR_PANE_ID, waiting for herdr to confirm delivery", async () => {
  const effects = fakeHerdrEffects([json({ result: { type: "ok" } })], { mainRoot: "/root" });
  const result = await withHerdrPaneId("w1:trigger", () => notifyWatchSession(watching(effects, "w1:p1"), "crew-afk (alpha): sprint finished."));
  assert.deepEqual(effects._calls, [
    ["herdr", "agent", "prompt", "w1:p1", "crew-afk (alpha): sprint finished.", "--wait", "--until", "working", "--timeout", "2000"],
  ]);
  assert.deepEqual(result, { sent: true });
});

test("notifyWatchSession (herdr) reports a stalled push as a failure instead of a false success", async () => {
  const effects = fakeHerdrEffects([{ code: 1, stdout: "", stderr: "agent_prompt_stalled" }], { mainRoot: "/root" });
  const result = await notifyWatchSession(watching(effects, "w1:p1"), "crew-afk (alpha): sprint finished.");
  assert.equal(result.sent, false);
  assert.match(result.reason, /agent_prompt_stalled/);
});

test("notifyWatchSession (herdr) swallows a failed prompt — the sprint's own outcome is already decided by then", async () => {
  const calls = [];
  const effects = {
    paneHost: "herdr",
    mainRoot: "/root",
    spawnWithTimeout: async (cmd, args) => {
      calls.push([cmd, ...args]);
      throw new Error("herdr unreachable");
    },
  };
  const result = await notifyWatchSession(watching(effects, "w1:p1"), "crew-afk (alpha): sprint finished.");
  assert.equal(calls.length, 1, "still attempted once, just didn't throw");
  assert.equal(result.sent, false);
});

// ─── orca: same contract, no separate workspace object ─────────────────────────────────
//
// Confirmed live against a running orca runtime this session: a git checkout's own root is
// already an Orca-managed worktree with no `repo add`/`worktree create` needed (`orca
// worktree current` resolves it directly from cwd), so `terminal create --worktree
// path:<mainRoot>` is the whole story — there is no herdr-style workspace object to create, reuse, or close.

test("ensurePaneWorkspace (orca) creates a log terminal directly — no separate workspace-create call exists", async () => {
  const { root } = fixture();
  const logFile = join(root, "trace.log");
  const effects = fakeOrcaEffects([json({ result: { terminal: { handle: "term_1" } } })], { mainRoot: root });

  const workspaceId = await ensurePaneWorkspace(effects, { featureSlug: "implement-user-auth", logFile });

  assert.equal(workspaceId, null, "orca has no workspace object to return an id for");
  assert.equal(effects._calls.length, 1, "straight to the log terminal — no separate workspace/tab split exists in orca's model");
  const create = effects._calls[0];
  assert.deepEqual(create.slice(0, 4), ["orca", "terminal", "create", "--worktree"]);
  assert.equal(create[create.indexOf("--title") + 1], "implement-user-auth-log");
  assert.equal(create[create.indexOf("--worktree") + 1], `path:${root}`, "scoped to this checkout, not whatever worktree orca's GUI has active");
  assert.equal(create[create.indexOf("--command") + 1], `tail -f '${logFile}'`);
});

// `--command` is typed into the terminal's shell, not passed as argv — an unquoted path with
// a space or quote in it would tail the wrong file or leave the shell mid-quote.
test("ensurePaneWorkspace (orca) shell-quotes the log path it types into the new terminal", async () => {
  const effects = fakeOrcaEffects([json({ result: { terminal: { handle: "term_1" } } })], { mainRoot: "/root" });

  await ensurePaneWorkspace(effects, { featureSlug: "alpha", logFile: "/my repo/it's.log" });

  const create = effects._calls[0];
  assert.equal(create[create.indexOf("--command") + 1], `tail -f '/my repo/it'\\''s.log'`);
});

test("ensurePaneWorkspace (orca) never creates a terminal when no logFile is given", async () => {
  const { root } = fixture();
  const effects = fakeOrcaEffects([], { mainRoot: root });

  const workspaceId = await ensurePaneWorkspace(effects, { featureSlug: "alpha" });

  assert.equal(workspaceId, null);
  assert.deepEqual(effects._calls, []);
});

// Orca has no workspace create to fail loudly, so without this a failed log terminal (e.g.
// orca as pane host in a checkout orca doesn't manage) left no tab and no word of why. Rejecting is
// still not fatal: main.mjs catches it, prints it, and continues without a log tab.
test("ensurePaneWorkspace (orca) rejects with the reason when the log terminal create fails", async () => {
  const { root } = fixture();
  const logFile = join(root, "trace.log");
  const effects = fakeOrcaEffects([{ code: 1, stdout: "", stderr: "orca unreachable" }], { mainRoot: root });

  await assert.rejects(ensurePaneWorkspace(effects, { featureSlug: "alpha", logFile }), /orca terminal create failed: exit=1 orca unreachable/);
  assert.equal(effects._paneLogTabId, undefined, "nothing for closePaneLogTab to close");
});

// Orca is a desktop app that can be quit mid-run: an unbounded create blocks the sprint from
// starting, an unbounded close in main.mjs's `finally` blocks it from exiting.
test("every orca call is bounded by a timeout", async () => {
  const { root } = fixture();
  const logFile = join(root, "trace.log");
  const effects = fakeOrcaEffects(
    [
      json({ result: { rename: { title: "alpha" } } }), // terminal rename
      json({ result: { terminal: { handle: "term_2" } } }), // log terminal create
      json({ result: { closed: true } }), // log terminal close
      { code: 1, stdout: "", stderr: "no such terminal" }, // show: gone
    ],
    { mainRoot: root },
  );

  await withOrcaTerminalHandle("term_1", () => ensurePaneWorkspace(effects, { featureSlug: "alpha", logFile }));
  await closePaneLogTab(effects);

  assert.equal(effects._calls.length, 4);
  for (const [i, timeoutMs] of effects._timeouts.entries()) {
    assert.ok(timeoutMs > 0, `${effects._calls[i].slice(0, 3).join(" ")} has no timeout`);
  }
});

// The triggering terminal's own tab still shows whatever it was called before crew-afk
// started running in it — orca also injects that terminal's own handle as
// ORCA_TERMINAL_HANDLE, alongside ORCA_WORKTREE_ID for the enclosing worktree — so this is
// the one chance to relabel it, the same way herdr's reuse path does. Unlike herdr, no
// separate "reuse the workspace" call is needed: every terminal create is already scoped by
// --worktree path:<mainRoot>, so the ambient ORCA_WORKTREE_ID is returned for symmetry with herdr's
// return value, not because orca ever needs it again.
test("ensurePaneWorkspace (orca) renames the triggering terminal via ORCA_TERMINAL_HANDLE, and reuses ORCA_WORKTREE_ID implicitly", async () => {
  const { root } = fixture();
  const logFile = join(root, "trace.log");
  const effects = fakeOrcaEffects(
    [
      json({ result: { rename: { title: "implement-user-auth" } } }), // terminal rename
      json({ result: { terminal: { handle: "term_2" } } }), // log terminal create
    ],
    { mainRoot: root },
  );

  const workspaceId = await withOrcaWorktreeId("wt1", () =>
    withOrcaTerminalHandle("term_1", () => ensurePaneWorkspace(effects, { featureSlug: "implement-user-auth", logFile })),
  );

  assert.equal(workspaceId, "wt1");
  assert.deepEqual(effects._calls[0], ["orca", "terminal", "rename", "--terminal", "term_1", "--title", "implement-user-auth", "--json"]);
  assert.equal(effects._calls[1][4], `path:${root}`, "the log terminal is scoped by --worktree path:<mainRoot> — reuse needs nothing explicit");
});

test("ensurePaneWorkspace (orca) never renames the triggering terminal when no feature slug resolved", async () => {
  const { root } = fixture();
  const effects = fakeOrcaEffects([], { mainRoot: root });

  await withOrcaTerminalHandle("term_1", () => ensurePaneWorkspace(effects, {}));

  assert.deepEqual(effects._calls, [], "no feature slug resolved, so the terminal is left exactly as the human named it");
});

test("closePaneWorkspace (orca) is always a no-op — orca has no workspace object to close", async () => {
  const { root } = fixture();
  const logFile = join(root, "trace.log");
  const effects = fakeOrcaEffects([json({ result: { terminal: { handle: "term_1" } } })], { mainRoot: root });

  await ensurePaneWorkspace(effects, { featureSlug: "alpha", logFile });
  await closePaneWorkspace(effects);

  assert.deepEqual(effects._calls, [effects._calls[0]], "only the terminal create — close never called anything");
});

test("closePaneLogTab (orca) closes the log terminal ensurePaneWorkspace opened, and is a no-op when none was ever created", async () => {
  const untouched = fakeOrcaEffects([], { mainRoot: "/root" });
  await closePaneLogTab(untouched);
  assert.deepEqual(untouched._calls, []);

  const { root } = fixture();
  const logFile = join(root, "trace.log");
  const effects = fakeOrcaEffects([json({ result: { terminal: { handle: "term_1" } } }), json({}), { code: 1, stdout: "", stderr: "gone" }], { mainRoot: root });
  await ensurePaneWorkspace(effects, { featureSlug: "alpha", logFile });
  await closePaneLogTab(effects);
  assert.deepEqual(effects._calls.at(-2), ["orca", "terminal", "close", "--terminal", "term_1", "--json"]);
});

const gone = { code: 1, stdout: "", stderr: "no such terminal" };

test("orca worker terminal close that leaves the tab listed runs a second close", async () => {
  const { closeWorkerTerminal } = await import("../../orchestrator/lib/pane-host/orca.mjs");
  const effects = fakeOrcaEffects([json({}), json({ result: { terminal: { handle: "t9" } } }), json({}), gone]);
  await closeWorkerTerminal(effects, "t9");
  assert.deepEqual(effects._calls.map((c) => c[2]), ["close", "show", "close", "show"]);
});

test("orca terminal close that never succeeds is bounded and logged as a WARN with handle and output", async () => {
  const { closeWorkerTerminal, CLOSE_ATTEMPTS } = await import("../../orchestrator/lib/pane-host/orca.mjs");
  const responses = [];
  for (let i = 0; i < CLOSE_ATTEMPTS; i++) responses.push({ code: 1, stdout: "", stderr: "orca boom" }, json({ result: { terminal: {} } }));
  const effects = fakeOrcaEffects(responses);
  const logs = [];
  effects.log = (m) => logs.push(m);
  await closeWorkerTerminal(effects, "t9");
  assert.equal(effects._calls.length, CLOSE_ATTEMPTS * 2);
  assert.equal(logs.length, 1);
  assert.match(logs[0], /^WARN .*t9.*orca boom|^WARN .*t9/);
});

test("closePaneLogTab sweeps a worker terminal whose close never confirmed", async () => {
  const { openWorkerTerminal, closeWorkerTerminal, CLOSE_ATTEMPTS } = await import("../../orchestrator/lib/pane-host/orca.mjs");
  const responses = [json({ result: { terminal: { handle: "w1" } } })];
  for (let i = 0; i < CLOSE_ATTEMPTS; i++) responses.push(json({}), json({ result: { terminal: {} } }));
  responses.push(json({}), gone); // sweep
  const effects = fakeOrcaEffects(responses);
  effects.log = () => {};
  await openWorkerTerminal(effects, { title: "t", command: "true" });
  await closeWorkerTerminal(effects, "w1");
  await closePaneLogTab(effects);
  assert.deepEqual(effects._calls.at(-2), ["orca", "terminal", "close", "--terminal", "w1", "--json"]);
  assert.equal(effects._paneTerminals.size, 0);
});

test("notifyWatchSession (orca) pushes nowhere when no watch agent was opened, even from inside an orca terminal", async () => {
  const effects = fakeOrcaEffects([], { mainRoot: "/root" });
  const result = await withOrcaTerminalHandle("term_trigger", () => notifyWatchSession(effects, "crew-afk (alpha): sprint finished."));
  assert.deepEqual(effects._calls, [], "ORCA_TERMINAL_HANDLE is never a push target");
  assert.deepEqual(result, { sent: false, reason: "no watch session" });
});

// Confirmed live: sending into a plain shell terminal returned `accepted: true` but
// `prompt.observation: "unsupported"` — orca self-reports what it can't confirm rather than
// silently claiming success like herdr's pre-#4537-fix `agent prompt` did, so there is no
// `--wait`-style workaround needed here, just the `accepted` flag.
const orcaAgentShow = () => json({ result: { terminal: { handle: "term_1", agentIdentity: "claude" } } });

test("notifyWatchSession (orca) sends into the watch agent by its recorded handle, not ORCA_TERMINAL_HANDLE", async () => {
  const effects = fakeOrcaEffects(
    [orcaAgentShow(), json({ result: { send: { accepted: true, prompt: { observation: "supported" } } } })],
    { mainRoot: "/root" },
  );
  const result = await withOrcaTerminalHandle("term_trigger", () => notifyWatchSession(watching(effects, "term_1"), "crew-afk (alpha): sprint finished."));
  assert.deepEqual(effects._calls, [
    ["orca", "terminal", "show", "--terminal", "term_1", "--json"],
    ["orca", "terminal", "send", "--terminal", "term_1", "--text", "crew-afk (alpha): sprint finished.", "--enter", "--json"],
  ]);
  assert.deepEqual(result, { sent: true });
});

// orca's `terminal send` types into any terminal, agent or not, and reports `accepted: true`
// for a plain shell — where the message plus Enter runs as a shell command. Confirmed live:
// `terminal show` reports agentIdentity for a claude pane, and no such field for a shell.
test("notifyWatchSession (orca) never types into a watch terminal orca doesn't see an agent in", async () => {
  const effects = fakeOrcaEffects([json({ result: { terminal: { handle: "term_1", title: "bash" } } })], { mainRoot: "/root" });
  const result = await notifyWatchSession(watching(effects, "term_1"), "crew-afk (alpha): sprint finished.");
  assert.deepEqual(effects._calls, [["orca", "terminal", "show", "--terminal", "term_1", "--json"]], "a shell, not an agent — no send");
  assert.equal(result.sent, false);
  assert.match(result.reason, /not running an agent/);
});

test("notifyWatchSession (orca) never sends when terminal show itself fails", async () => {
  const effects = fakeOrcaEffects([{ code: 1, stdout: "", stderr: "terminal not found" }], { mainRoot: "/root" });
  const result = await notifyWatchSession(watching(effects, "term_1"), "crew-afk (alpha): sprint finished.");
  assert.equal(effects._calls.length, 1, "show only — an unknown pane is never typed into");
  assert.equal(result.sent, false);
  // orca quit or timing out is not "the pane isn't an agent": the log must say which.
  assert.match(result.reason, /terminal show exit=1 terminal not found/);
});

test("notifyWatchSession (orca) names show, not send, when show throws", async () => {
  const effects = { paneHost: "orca", mainRoot: "/root", spawnWithTimeout: async () => { throw new Error("spawn orca ENOENT"); } };
  const result = await notifyWatchSession(watching(effects, "term_1"), "msg");
  assert.equal(result.sent, false);
  assert.match(result.reason, /orca terminal show threw: spawn orca ENOENT/);
});

// Measured live: `terminal send` into an idle claude pane takes ~8s to return (it watches for
// turn start) — a 5s cap killed it at exit 124 after delivery, logging a false NOTIFY-FAIL.
test("notifyWatchSession (orca) gives terminal send long enough to return from a live agent pane", async () => {
  let timeoutMs;
  const effects = {
    paneHost: "orca",
    mainRoot: "/root",
    spawnWithTimeout: async (cmd, args, opts) => {
      if (args[1] === "show") return orcaAgentShow();
      timeoutMs = opts.timeoutMs;
      return json({ result: { send: { accepted: true } } });
    },
  };
  await notifyWatchSession(watching(effects, "term_1"), "crew-afk (alpha): sprint finished.");
  assert.ok(timeoutMs >= 20000, `timeout ${timeoutMs}ms is shorter than a live agent pane's ~8s send`);
});

test("notifyWatchSession (orca) reports an explicitly-not-accepted send as a failure", async () => {
  const effects = fakeOrcaEffects([orcaAgentShow(), json({ result: { send: { accepted: false } } })], { mainRoot: "/root" });
  const result = await notifyWatchSession(watching(effects, "term_1"), "crew-afk (alpha): sprint finished.");
  assert.equal(result.sent, false);
  assert.match(result.reason, /not accepted/);
});

test("notifyWatchSession (orca) swallows a failed send — the sprint's own outcome is already decided by then", async () => {
  const calls = [];
  const effects = {
    paneHost: "orca",
    mainRoot: "/root",
    spawnWithTimeout: async (cmd, args) => {
      calls.push([cmd, ...args]);
      if (args[1] === "show") return orcaAgentShow();
      throw new Error("orca unreachable");
    },
  };
  const result = await notifyWatchSession(watching(effects, "term_1"), "crew-afk (alpha): sprint finished.");
  assert.equal(calls.length, 2, "show, then the send attempted once — it just didn't throw");
  assert.equal(result.sent, false);
});

// ─── preflight ─────────────────────────────────────────────────────────────────────────

function fakeExecEffects(responses) {
  const calls = [];
  return {
    _calls: calls,
    exec: (cmd, args) => {
      calls.push([cmd, ...args]);
      return responses.shift();
    },
  };
}
const ok = (stdout = "") => ({ code: 0, stdout, stderr: "" });

test("preflightPaneHost checks nothing when no pane host is selected", () => {
  const effects = fakeExecEffects([]);
  assert.deepEqual(preflightPaneHost(effects, null), []);
  assert.equal(effects._calls.length, 0);
});

test("preflightPaneHost (herdr) fails when the server is not running", () => {
  const effects = fakeExecEffects([ok("/usr/bin/herdr\n"), ok("status: stopped\n")]);
  assert.match(preflightPaneHost(effects, "herdr")[0], /herdr server is not running/);
});

test("preflightPaneHost (herdr) passes when the server reports running", () => {
  const effects = fakeExecEffects([ok("/usr/bin/herdr\n"), ok("status: running\n")]);
  assert.deepEqual(preflightPaneHost(effects, "herdr"), []);
});

test("preflightPaneHost (orca) reads readiness from result.runtime.reachable, not the exit code", () => {
  const down = fakeExecEffects([ok("/usr/bin/orca\n"), ok(JSON.stringify({ result: { runtime: { reachable: false } } }))]);
  assert.match(preflightPaneHost(down, "orca")[0], /orca runtime is not reachable/);
  const up = fakeExecEffects([ok("/usr/bin/orca\n"), ok(JSON.stringify({ result: { runtime: { reachable: true } } })), ok("{}")]);
  assert.deepEqual(preflightPaneHost(up, "orca"), []);
});

// Live: `orca worktree show --worktree path:<dir>` exits 1 with selector_not_found for a git
// repo orca has never registered, and 0 for one it has.
test("preflightPaneHost (orca) fails for a checkout orca doesn't manage, instead of every dispatch falling back to headless", () => {
  const reachable = ok(JSON.stringify({ result: { runtime: { reachable: true } } }));
  const effects = { ...fakeExecEffects([ok("/usr/bin/orca\n"), reachable, { code: 1, stdout: '{"ok":false,"error":{"code":"selector_not_found"}}', stderr: "" }]), mainRoot: "/repo" };
  assert.deepEqual(preflightPaneHost(effects, "orca"), [
    "pane host orca, but orca does not manage /repo — add it as a repo in the orca app (on the host this runs on), or pick another pane host (CREW_PANE_HOST=none)",
  ]);
  assert.deepEqual(effects._calls[2], ["orca", "worktree", "show", "--worktree", "path:/repo", "--json"]);
});

test("preflightPaneHost (orca) names a missing CLI", () => {
  const effects = fakeExecEffects([{ code: 1, stdout: "", stderr: "" }]);
  assert.deepEqual(preflightPaneHost(effects, "orca"), ["pane host orca, but the orca CLI was not found on PATH"]);
});

test("preflightPaneHost bounds each host's status call, and names a timeout as one", () => {
  for (const [host, bin] of [["herdr", "/usr/bin/herdr\n"], ["orca", "/usr/bin/orca\n"]]) {
    const opts = [];
    const effects = {
      exec: (cmd, args, o) => {
        opts.push(o);
        return opts.length === 1 ? ok(bin) : { code: 124, stdout: "", stderr: "" };
      },
    };
    assert.match(preflightPaneHost(effects, host)[0], /timed out/, host);
    assert.ok(opts[1]?.timeoutMs > 0, `${host} status call has no timeout`);
  }
});

// ─── queued milestone pushes ───────────────────────────────────────────────────────────

test("queuePaneNotice returns before the push lands, sends one at a time in order, and drainPaneNotices waits for all", async () => {
  const sent = [];
  let inFlight = 0;
  let maxInFlight = 0;
  const releases = [];
  const effects = {
    paneHost: "herdr",
    mainRoot: "/root",
    spawnWithTimeout: (cmd, args) => {
      inFlight++;
      maxInFlight = Math.max(maxInFlight, inFlight);
      return new Promise((resolve) =>
        releases.push(() => {
          inFlight--;
          sent.push(args[3]);
          resolve({ code: 0, stdout: "", stderr: "" });
        }),
      );
    },
  };
  const reasons = [];
  watching(effects, "w1:p1");
  {
    queuePaneNotice(effects, "one", (r) => reasons.push(r));
    queuePaneNotice(effects, "two", (r) => reasons.push(r));
    let drained = false;
    const drain = drainPaneNotices(effects).then(() => (drained = true));
    while (sent.length < 2) {
      await new Promise((r) => setImmediate(r));
      releases.shift()?.();
    }
    await drain;
    assert.equal(drained, true);
  }
  assert.deepEqual(sent, ["one", "two"]);
  assert.equal(maxInFlight, 1, "pushes into one pane never overlap");
  assert.deepEqual(reasons.map((r) => r.sent), [true, true]);
});

test("of several MILESTONE-PUSH-SKIPPED in one run only the first is a warning; the rest are debug", async () => {
  const lines = [];
  const effects = {
    paneHost: "herdr",
    mainRoot: "/root",
    spawnWithTimeout: async () => ({ code: 1, stdout: "", stderr: "herdr: no such pane" }),
  };
  const ctx = { effects, sprint: { featureSlug: "demo" }, log: (text, level = levelFor(text)) => lines.push({ text, level }) };
  watching(effects, "w1:p1");
  for (const slug of ["alpha", "beta", "gamma"]) notifyMilestone(ctx, { slug }, "coder finished");
  await drainPaneNotices(effects);
  const skipped = lines.filter((l) => /\[MILESTONE-PUSH-SKIPPED\]/.test(l.text));
  assert.equal(skipped.length, 3, JSON.stringify(lines));
  assert.deepEqual(skipped.map((l) => l.level), ["warn", "debug", "debug"]);
});

test("drainPaneNotices is a no-op when nothing was queued", async () => {
  await drainPaneNotices({ paneHost: null });
});

// ─── the watch agent: one interactive agent per slug, in the main checkout ─────────────────
//
// ensureWatchSession opens it (or reuses the one `.scratch/<slug>/watch.json` records while the
// host still reports a live agent there); every push goes to its handle and nothing closes it.

import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { resolvePaneHost } from "../../orchestrator/lib/crew-config.mjs";
import { renderRolePrompt } from "../../orchestrator/lib/adapters/render.mjs";

/** A main checkout on disk, for watch.json and the launch files, with a fake host exec and `command -v`. */
function watchFixture(host, responses, { cliOnPath = true, env = { CREW_WATCH_PROBE: "from-crew-afk" }, ...opts } = {}) {
  const { root } = fixture();
  const effects = fakePaneHostEffects(host, responses, { mainRoot: root, ...opts });
  effects.featureRoot = join(root, ".scratch", "worktrees", "crew", "alpha", "_feature");
  effects.env = env;
  effects.log = (line) => (effects._logs ??= []).push(line);
  effects.exec = (cmd, args) => {
    (effects._execs ??= []).push([cmd, ...args]);
    return { code: cliOnPath ? 0 : 1, stdout: "", stderr: "" };
  };
  const watchFile = join(root, ".scratch", "alpha", "watch.json");
  const record = (value) => {
    mkdirSync(join(root, ".scratch", "alpha"), { recursive: true });
    writeFileSync(watchFile, typeof value === "string" ? value : JSON.stringify(value));
  };
  return { root, featureRoot: effects.featureRoot, effects, watchFile, record, saved: () => JSON.parse(readFileSync(watchFile, "utf8")) };
}
const WATCH = { slug: "alpha", platform: "claude", model: "sonnet" };
const orcaCreated = (handle = "term_w") => json({ result: { terminal: { handle } } });
const herdrTab = (tab = "w1:tw", pane = "w1:pw") => json({ result: { tab: { tab_id: tab }, root_pane: { pane_id: pane } } });
const herdrWorkspace = (ws = "w9", pane = "w9:p1") => json({ result: { workspace: { workspace_id: ws }, root_pane: { pane_id: pane } } });
const herdrPanes = (...panes) => json({ result: { panes } });

/** The launch script a host was told to run: the command is `bash <script>`. */
function launchScriptOf(command) {
  const m = command.match(/^bash '(.*)'$/);
  assert.ok(m, `the command a host is given runs one script: ${command}`);
  return { path: m[1], text: readFileSync(m[1], "utf8") };
}

test("ensureWatchSession (orca) with no usable watch.json creates <slug>-watch in the _feature worktree and records its handle", async () => {
  const { root, featureRoot, effects, saved } = watchFixture("orca", [orcaCreated("term_w")]);
  const watch = await ensureWatchSession(effects, WATCH);
  assert.equal(effects._calls.length, 1);
  const [cmd, ...args] = effects._calls[0];
  assert.equal(cmd, "orca");
  assert.deepEqual(args.slice(0, 7), ["terminal", "create", "--worktree", `path:${featureRoot}`, "--title", "alpha-watch", "--command"]);
  assert.equal(args[8], "--json");
  const { text } = launchScriptOf(args[7]);
  assert.ok(text.includes(`cd -P '${featureRoot}'`), "the agent starts in _feature");
  // The feature agent edits (permission prompts stay on): claude is not denied Edit/Write, only sub-agents.
  const argv = ["claude", renderRolePrompt("followup", "claude", { mainRoot: root }), "--add-dir", root, "--model", "sonnet", "--disallowedTools", "Agent"];
  const quoted = argv.map((a) => `'${a.replace(/'/g, `'\\''`)}'`).join(" ");
  assert.ok(text.includes(`exec ${quoted}`), "the argv carries the rendered feature-agent protocol as its initial prompt");
  assert.deepEqual(saved(), { host: "orca", handle: "term_w" });
  assert.equal(watch.handle, "term_w");
  assert.deepEqual(effects._paneWatch, { host: "orca", handle: "term_w" });
});

test("the log terminal and the agent terminal are both created with --worktree path:<featureRoot>, even from inside another orca worktree", async () => {
  const { featureRoot, root, effects } = watchFixture("orca", [orcaCreated("term_log"), orcaCreated("term_w")]);
  await withOrcaWorktreeId("wt-trigger", async () => {
    await ensurePaneWorkspace(effects, { featureSlug: "alpha", logFile: join(root, "trace.log") });
    await ensureWatchSession(effects, WATCH);
  });
  const worktrees = effects._calls.filter((c) => c[2] === "create").map((c) => c[c.indexOf("--worktree") + 1]);
  assert.deepEqual(worktrees, [`path:${featureRoot}`, `path:${featureRoot}`]);
});

test("ensureWatchSession gives the host a command that sources crew-afk's env.sh before the interactive argv, then deletes it", async () => {
  for (const [host, responses, setup] of [
    ["orca", [orcaCreated()], () => {}],
    ["herdr", [herdrWorkspace(), herdrTab(), json({ result: { type: "ok" } })], () => {}],
  ]) {
    setup();
    const { effects } = watchFixture(host, responses, { env: { CREW_WATCH_PROBE: "it's from crew-afk" } });
    await ensureWatchSession(effects, WATCH);
    const command = host === "orca" ? effects._calls[0][8] : effects._calls[2][4];
    const { path, text } = launchScriptOf(command);
    const lines = text.split("\n");
    const source = lines.findIndex((l) => /^\. '.*env\.sh'; rm -f '.*env\.sh'$/.test(l));
    const exec = lines.findIndex((l) => l.startsWith("exec 'claude'"));
    assert.ok(source >= 0 && exec > source, `${host}: env.sh is sourced (then removed) before the argv runs:\n${text}`);
    const envFile = lines[source].match(/^\. '(.*?)';/)[1];
    assert.equal(envFile, join(path, "..", "env.sh"));
    assert.equal(statSync(envFile).mode & 0o777, 0o600, "holds credentials");
    assert.match(readFileSync(envFile, "utf8"), /export CREW_WATCH_PROBE='it'\\''s from crew-afk'/);
  }
});

test("ensureWatchSession puts CREW_PANE_HOST=<effects.paneHost> in the launch env, so a crew-afk command run from the watch agent resolves the host `run --pane-host` chose", async () => {
  // `run --pane-host orca` sets effects.paneHost; the agent's own shell has neither the flag nor the legacy ORCA_ENV.
  const { effects } = watchFixture("orca", [orcaCreated()], { env: {} });
  await ensureWatchSession(effects, WATCH);
  const envFile = join(launchScriptOf(effects._calls[0][8]).path, "..", "env.sh");
  const env = Object.fromEntries(
    execFileSync("bash", ["-c", `. '${envFile}'; env -0`], { env: { PATH: process.env.PATH }, encoding: "utf8" })
      .split("\0")
      .filter((l) => l.includes("="))
      .map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)]),
  );
  assert.equal(env.CREW_PANE_HOST, "orca");
  assert.equal(resolvePaneHost({ env, cli: {} }).paneHost, "orca");
});

test("a failed openWatch deletes the env.sh it wrote on both hosts, and so does a host call that throws", async () => {
  const envFiles = (root) => {
    const dir = join(root, ".scratch", "alpha", "watch");
    return existsSync(dir) ? readdirSync(dir).filter((f) => f === "env.sh") : [];
  };
  for (const [host, responses] of [
    ["orca", [{ code: 1, stdout: "", stderr: "orca: no such worktree" }]],
    ["herdr", [herdrWorkspace(), { code: 1, stdout: "", stderr: "pane not found" }]],
  ]) {
    const { root, effects } = watchFixture(host, responses);
    assert.equal(await ensureWatchSession(effects, WATCH), null, host);
    assert.ok(existsSync(join(root, ".scratch", "alpha", "watch", "launch.sh")), `${host}: the script was written`);
    assert.deepEqual(envFiles(root), [], `${host}: no env.sh (it holds credentials) left behind`);
  }
  const { root, effects } = watchFixture("herdr", []);
  effects.spawnWithTimeout = async () => {
    throw new Error("spawn herdr ENOENT");
  };
  assert.equal(await ensureWatchSession(effects, WATCH), null);
  assert.deepEqual(envFiles(root), [], "a throw leaves no env.sh either");
});

test("ensureWatchSession (herdr) closes the tab it made when pane run fails, leaving no empty <slug>-watch behind", async () => {
  const run = watchFixture("herdr", [herdrWorkspace("w9", "w9:p1"), herdrTab("w9:tw", "w9:pw"), { code: 1, stdout: "", stderr: "pane not found" }, json({})]);
  assert.equal(await ensureWatchSession(run.effects, WATCH), null);
  assert.deepEqual(run.effects._calls[3], ["herdr", "tab", "close", "w9:tw"]);
  assert.ok(!run.effects._calls.some((c) => c[1] === "workspace" && c[2] === "close"), "the workspace is the sprint's, not the agent's to close");
  assert.equal(existsSync(run.watchFile), false, "nothing recorded");
});

test("ensureWatchSession (orca) reuses the recorded handle while terminal show reports an agentIdentity, creating nothing", async () => {
  const { effects, record, saved } = watchFixture("orca", [json({ result: { terminal: { handle: "term_w", agentIdentity: "claude" } } })]);
  record({ host: "orca", handle: "term_w" });
  const watch = await ensureWatchSession(effects, WATCH);
  assert.deepEqual(effects._calls, [["orca", "terminal", "show", "--terminal", "term_w", "--json"]]);
  assert.equal(watch.handle, "term_w");
  assert.deepEqual(saved(), { host: "orca", handle: "term_w" });
  assert.deepEqual(effects._paneWatch, { host: "orca", handle: "term_w" });
});

test("ensureWatchSession (orca) replaces a recorded handle that is dead, shows no agent or was never recorded, and rewrites watch.json", async () => {
  const cases = {
    "a failed show": { code: 1, stdout: "", stderr: "no such terminal" },
    "a shell, no agentIdentity": json({ result: { terminal: { handle: "term_old", title: "bash" } } }),
  };
  for (const [name, show] of Object.entries(cases)) {
    const { effects, record, saved } = watchFixture("orca", [show, orcaCreated("term_new")]);
    record({ host: "orca", handle: "term_old" });
    await ensureWatchSession(effects, WATCH);
    assert.equal(effects._calls[1][2], "create", name);
    assert.deepEqual(saved(), { host: "orca", handle: "term_new" }, name);
  }
  for (const [name, content] of [["unparseable", "{nope"], ["no handle", { host: "orca" }], ["another host's", { host: "herdr", handle: "w1:p1" }]]) {
    const { effects, record, saved } = watchFixture("orca", [orcaCreated("term_new")]);
    record(content);
    await ensureWatchSession(effects, WATCH);
    assert.deepEqual(effects._calls.map((c) => c[2]), ["create"], `${name} watch.json: nothing to show`);
    assert.deepEqual(saved(), { host: "orca", handle: "term_new" }, name);
  }
});

test("ensureWatchSession (herdr) opens its tab in the feature worktree's workspace, never the triggering one", async () => {
  const { featureRoot, effects, saved } = watchFixture("herdr", [herdrWorkspace("w9", "w9:p1"), herdrTab("w9:tw", "w9:pw"), json({ result: { type: "ok" } })]);
  await withHerdrWorkspaceId("w1", () => ensureWatchSession(effects, WATCH));
  assert.deepEqual(effects._calls[0].slice(0, 5), ["herdr", "worktree", "open", "--path", featureRoot]);
  assert.deepEqual(effects._calls[1], ["herdr", "tab", "create", "--workspace", "w9", "--cwd", featureRoot, "--label", "alpha-watch", "--no-focus"]);
  assert.deepEqual(effects._calls[2].slice(0, 4), ["herdr", "pane", "run", "w9:pw"]);
  launchScriptOf(effects._calls[2][4]);
  assert.deepEqual(saved(), { host: "herdr", handle: "w9:pw" });
});

test("ensureWatchSession (herdr) puts the agent in the workspace ensurePaneWorkspace already opened, with no second worktree open", async () => {
  const { root, featureRoot, effects } = watchFixture("herdr", [herdrWorkspace("w9", "w9:p1"), ...herdrLogTabResponses(), herdrTab("w9:tw", "w9:pw"), json({ result: { type: "ok" } })]);
  await ensurePaneWorkspace(effects, { featureSlug: "alpha", logFile: join(root, "trace.log") });
  await ensureWatchSession(effects, WATCH);
  assert.equal(effects._calls.filter((c) => c[1] === "worktree").length, 1);
  const tabs = effects._calls.filter((c) => c[1] === "tab" && c[2] === "create");
  assert.deepEqual(tabs.map((c) => c[4]), ["w9", "w9"]);
  assert.deepEqual(tabs.map((c) => c[c.indexOf("--cwd") + 1]), [featureRoot, featureRoot]);
});

test("ensureWatchSession (herdr) reuses the recorded pane while pane list reports an agent_status other than unknown", async () => {
  const live = watchFixture("herdr", [herdrPanes({ pane_id: "w1:other", agent_status: "idle" }, { pane_id: "w9:p1", agent_status: "working" })]);
  live.record({ host: "herdr", handle: "w9:p1" });
  await ensureWatchSession(live.effects, WATCH);
  assert.deepEqual(live.effects._calls, [["herdr", "pane", "list"]]);
  assert.deepEqual(live.effects._paneWatch, { host: "herdr", handle: "w9:p1" });

  for (const [name, list] of [
    ["agent_status unknown", herdrPanes({ pane_id: "w9:p1", agent_status: "unknown" })],
    ["pane gone", herdrPanes({ pane_id: "w1:other", agent_status: "idle" })],
    ["list failed", { code: 1, stdout: "", stderr: "herdr: down" }],
  ]) {
    const dead = watchFixture("herdr", [list, herdrWorkspace("w10", "w10:p1"), herdrTab("w10:t", "w10:pn"), json({ result: { type: "ok" } })]);
    dead.record({ host: "herdr", handle: "w9:p1" });
    await ensureWatchSession(dead.effects, WATCH);
    assert.equal(dead.effects._calls[1][2], "open", name);
    assert.deepEqual(dead.saved(), { host: "herdr", handle: "w10:pn" }, name);
  }
});

test("pushes go to the watch handle on both hosts and never to ORCA_TERMINAL_HANDLE or HERDR_PANE_ID", async () => {
  const orca = watchFixture("orca", [orcaCreated("term_w"), json({ result: { terminal: { agentIdentity: "claude" } } }), json({ result: { send: { accepted: true } } })]);
  await withOrcaTerminalHandle("term_trigger", async () => {
    await ensureWatchSession(orca.effects, WATCH);
    queuePaneNotice(orca.effects, "[alpha] a: coder finished");
    await drainPaneNotices(orca.effects);
  });
  const orcaTargets = orca.effects._calls.slice(1).map((c) => c[c.indexOf("--terminal") + 1]);
  assert.deepEqual(orcaTargets, ["term_w", "term_w"]);

  const herdr = watchFixture("herdr", [herdrWorkspace("w9", "w9:p1"), herdrTab("w9:t", "w9:p1"), json({ result: { type: "ok" } }), json({ result: { type: "ok" } })]);
  await withHerdrPaneId("w1:trigger", async () => {
    await ensureWatchSession(herdr.effects, WATCH);
    queuePaneNotice(herdr.effects, "[alpha] a: coder finished");
    await drainPaneNotices(herdr.effects);
  });
  assert.deepEqual(herdr.effects._calls.at(-1).slice(0, 4), ["herdr", "agent", "prompt", "w9:p1"]);
});

test("no ending closes the watch agent: its handle is never tracked, and the end-of-run closes never receive it", async () => {
  const orca = watchFixture("orca", [orcaCreated("term_w"), orcaCreated("term_log"), json({}), { code: 1, stdout: "", stderr: "gone" }]);
  await ensureWatchSession(orca.effects, WATCH);
  assert.ok(!orca.effects._paneTerminals?.has("term_w"));
  await ensurePaneWorkspace(orca.effects, { featureSlug: "alpha", logFile: join(orca.root, "trace.log") });
  await closePaneWorkspace(orca.effects);
  await closePaneLogTab(orca.effects);
  assert.ok(!orca.effects._calls.some((c) => c.includes("term_w") && c.includes("close")), JSON.stringify(orca.effects._calls));
  assert.ok(existsSync(join(orca.root, ".scratch", "alpha", "watch.json")));

  const herdr = watchFixture("herdr", [herdrWorkspace("w9", "w9:p1"), herdrTab("w9:log", "w9:plog"), json({ result: { type: "ok" } }), herdrTab("w9:t", "w9:pw"), json({ result: { type: "ok" } }), json({})]);
  await ensurePaneWorkspace(herdr.effects, { featureSlug: "alpha", logFile: join(herdr.root, "trace.log") });
  await ensureWatchSession(herdr.effects, WATCH);
  await closePaneWorkspace(herdr.effects);
  await closePaneLogTab(herdr.effects);
  const closes = herdr.effects._calls.filter((c) => c[2] === "close");
  assert.deepEqual(closes.map((c) => c[3]), ["w9:log"], "the log tab only: the agent's tab and the workspace holding it stay");
});

test("ensureWatchSession opens nothing and writes no watch.json under --dry-run, CREW_PANE_HOST=none or no pane host", async () => {
  const dry = watchFixture("orca", [], { dryRun: true });
  assert.equal(await ensureWatchSession(dry.effects, WATCH), null);
  const none = watchFixture("orca", []);
  none.effects.paneHost = null;
  assert.equal(await ensureWatchSession(none.effects, WATCH), null);
  for (const { effects, watchFile } of [dry, none]) {
    assert.deepEqual(effects._calls, []);
    assert.deepEqual(effects._execs ?? [], []);
    assert.equal(existsSync(watchFile), false);
    assert.equal(effects._paneWatch ?? null, null);
  }
});

test("a failed create logs WARN, leaves no watch agent, and every later push is skipped with MILESTONE-PUSH-SKIPPED", async () => {
  for (const [host, responses] of [
    ["orca", [{ code: 1, stdout: "", stderr: "orca: no such worktree" }]],
    ["herdr", [{ code: 1, stdout: "", stderr: "herdr: down" }]],
  ]) {
    const { effects, watchFile } = watchFixture(host, responses);
    const watch = await ensureWatchSession(effects, WATCH);
    assert.equal(watch, null, host);
    assert.equal(effects._paneWatch, null, host);
    assert.ok(effects._logs.some((l) => /^WARN /.test(l)), `${host}: ${effects._logs}`);
    assert.equal(existsSync(watchFile), false);

    const lines = [];
    const ctx = { effects, sprint: { featureSlug: "alpha" }, log: (text, level = levelFor(text)) => lines.push({ text, level }) };
    notifyMilestone(ctx, { slug: "a" }, "coder finished");
    notifyMilestone(ctx, { slug: "b" }, "coder finished");
    await drainPaneNotices(effects);
    const skipped = lines.filter((l) => /\[MILESTONE-PUSH-SKIPPED\]/.test(l.text));
    assert.deepEqual(skipped.map((l) => l.level), ["warn", "debug"], host);
    assert.equal(effects._calls.length, 1, `${host}: only the failed create — nothing pushed`);
  }
});

test("a platform CLI missing from PATH logs WARN and creates nothing", async () => {
  const { effects, watchFile } = watchFixture("orca", [], { cliOnPath: false });
  assert.equal(await ensureWatchSession(effects, WATCH), null);
  assert.deepEqual(effects._calls, []);
  assert.match(effects._logs.join("\n"), /^WARN .*claude/m);
  assert.equal(existsSync(watchFile), false);
});

test("ensureWatchSession never throws: a host call that throws is a WARN", async () => {
  const { effects } = watchFixture("herdr", []);
  effects.spawnWithTimeout = async () => {
    throw new Error("spawn herdr ENOENT");
  };
  assert.equal(await ensureWatchSession(effects, WATCH), null);
  assert.match(effects._logs.join("\n"), /^WARN .*ENOENT/m);
});

// ─── the launching pane as the agent (D6) ──────────────────────────────────────────────────────

const orcaAgent = (handle = "term_l") => json({ result: { terminal: { handle, agentIdentity: "claude" } } });

/** Runs `fn` with cwd inside `dir` (made when missing), and restores it. */
async function inDir(dir, fn) {
  mkdirSync(dir, { recursive: true });
  const prior = process.cwd();
  process.chdir(dir);
  try {
    return await fn();
  } finally {
    process.chdir(prior);
  }
}

test("a launching orca terminal inside _feature that shows an agent is recorded as the agent and receives every push; no agent opens", async () => {
  const { featureRoot, effects, saved } = watchFixture("orca", [orcaAgent("term_l"), orcaAgent("term_l"), json({ result: { send: { accepted: true } } })]);
  const watch = await withOrcaTerminalHandle("term_l", () => inDir(join(featureRoot, "src"), () => ensureWatchSession(effects, WATCH)));
  assert.deepEqual(watch, { host: "orca", handle: "term_l" });
  assert.deepEqual(saved(), { host: "orca", handle: "term_l" });
  assert.deepEqual(effects._calls, [["orca", "terminal", "show", "--terminal", "term_l", "--json"]], "only the liveness check: nothing created");
  assert.deepEqual(effects._execs ?? [], [], "no platform CLI lookup either");

  const sent = await notifyWatchSession(effects, "[alpha] a: coder finished");
  assert.deepEqual(sent, { sent: true });
  const send = effects._calls.at(-1);
  assert.equal(send[2], "send");
  assert.equal(send[send.indexOf("--terminal") + 1], "term_l");
});

test("a launching herdr pane inside _feature whose agent_status is not unknown is adopted the same way", async () => {
  const { featureRoot, effects, saved } = watchFixture("herdr", [herdrPanes({ pane_id: "w1:pl", agent_status: "idle" })]);
  const watch = await withHerdrPaneId("w1:pl", () => inDir(featureRoot, () => ensureWatchSession(effects, WATCH)));
  assert.deepEqual(watch, { host: "herdr", handle: "w1:pl" });
  assert.deepEqual(saved(), { host: "herdr", handle: "w1:pl" });
  assert.deepEqual(effects._calls, [["herdr", "pane", "list"]]);
});

test("the launching pane is not adopted from outside _feature, or when it shows no agent: a new agent opens", async () => {
  const outside = watchFixture("orca", [orcaCreated("term_w")]);
  const watch = await withOrcaTerminalHandle("term_l", () => inDir(join(outside.root, "elsewhere"), () => ensureWatchSession(outside.effects, WATCH)));
  assert.equal(watch.handle, "term_w");
  assert.equal(outside.effects._calls[0][2], "create", "no liveness probe of a launcher outside _feature");

  const shell = watchFixture("orca", [json({ result: { terminal: { handle: "term_l" } } }), orcaCreated("term_w")]);
  const opened = await withOrcaTerminalHandle("term_l", () => inDir(shell.featureRoot, () => ensureWatchSession(shell.effects, WATCH)));
  assert.equal(opened.handle, "term_w", "a plain shell is not an agent");
  assert.deepEqual(shell.effects._calls.map((c) => c[2]), ["show", "create"]);
});

test("a live recorded agent is reused instead of the launching pane", async () => {
  const { featureRoot, effects, record, saved } = watchFixture("orca", [orcaAgent("term_rec")]);
  record({ host: "orca", handle: "term_rec" });
  const watch = await withOrcaTerminalHandle("term_l", () => inDir(featureRoot, () => ensureWatchSession(effects, WATCH)));
  assert.deepEqual(watch, { host: "orca", handle: "term_rec" });
  assert.deepEqual(saved(), { host: "orca", handle: "term_rec" });
  assert.deepEqual(effects._calls, [["orca", "terminal", "show", "--terminal", "term_rec", "--json"]]);
});

test("an adopted launching pane is never closed by an ending, and its workspace is kept", async () => {
  const { root, featureRoot, effects } = watchFixture("herdr", [herdrWorkspace("w9", "w9:p1"), ...herdrLogTabResponses(), herdrPanes({ pane_id: "w9:pl", agent_status: "working" }), json({ result: { type: "ok" } })]);
  await ensurePaneWorkspace(effects, { featureSlug: "alpha", logFile: join(root, "trace.log") });
  await withHerdrPaneId("w9:pl", () => inDir(featureRoot, () => ensureWatchSession(effects, WATCH)));
  await closePaneWorkspace(effects);
  await closePaneLogTab(effects);
  assert.deepEqual(effects._calls.filter((c) => c[2] === "close").map((c) => c[3]), ["w1:log"]);
});

// A reused or adopted agent may have been handed the checkout at an earlier run's end notice, so
// a new run tells it that the sprint is merging into the checkout again (followup.md).
test("a run that reuses or adopts the feature agent pushes it a run-start notice; one that opens a new agent does not", async () => {
  const reused = watchFixture("orca", [orcaAgent("term_rec"), orcaAgent("term_rec"), json({ result: { send: { accepted: true } } })]);
  reused.record({ host: "orca", handle: "term_rec" });
  await ensureWatchSession(reused.effects, WATCH);
  queueRunStartNotice(reused.effects, "alpha");
  await drainPaneNotices(reused.effects);
  const send = reused.effects._calls.at(-1);
  assert.equal(send[2], "send");
  assert.equal(send[send.indexOf("--terminal") + 1], "term_rec");
  const text = send[send.indexOf("--text") + 1];
  assert.match(text, /^\[alpha\] .*run started/, text);
  assert.match(text, /until the end notice/, text);

  const adopted = watchFixture("herdr", [herdrPanes({ pane_id: "w1:pl", agent_status: "idle" }), json({ result: { type: "ok" } })]);
  await withHerdrPaneId("w1:pl", () => inDir(adopted.featureRoot, () => ensureWatchSession(adopted.effects, WATCH)));
  queueRunStartNotice(adopted.effects, "alpha");
  await drainPaneNotices(adopted.effects);
  assert.deepEqual(adopted.effects._calls.at(-1).slice(0, 4), ["herdr", "agent", "prompt", "w1:pl"]);
  assert.match(adopted.effects._calls.at(-1)[4], /^\[alpha\] .*run started/);

  const opened = watchFixture("orca", [orcaCreated("term_new")]);
  await ensureWatchSession(opened.effects, WATCH);
  queueRunStartNotice(opened.effects, "alpha");
  await drainPaneNotices(opened.effects);
  assert.equal(opened.effects._calls.length, 1, "a new agent's brief is its start: only the create");
});

// The agent's cwd is `_feature`, where `.scratch/` and (when gitignored) `.coding-crew/` are not:
// the brief names every sprint source under the main checkout and says how to find it.
test("the feature agent's brief names sprint sources under the main checkout, found from _feature by the git common dir", () => {
  const brief = renderRolePrompt("followup", "claude", { mainRoot: "/main" });
  const common = '$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")';
  assert.ok(brief.includes(common), "how to find the main checkout from _feature");
  assert.ok(brief.includes(`${common}/.coding-crew/tracker/cli.mjs`), "the tracker CLI resolves under the main checkout");
  assert.match(brief, /run-start notice/i, "a run-start notice returns the agent to the until-the-end-notice rules");
  // A source path is `.scratch/<x>` or `.coding-crew/<x>`; the bare directory names in the prose are not.
  for (const line of brief.split("\n")) {
    assert.ok(!/(^|[\s`(])\.scratch\/[^\s`]/.test(line), `a source path resolving inside _feature: ${line}`);
    assert.ok(!/(^|[\s`(])(node )?\.coding-crew\/[^\s`]/.test(line), `a source path resolving inside _feature: ${line}`);
  }
});

// At the run's end `_feature` and the agent's workspace are kept only for an agent that still lives:
// a dead one (its pane closed, its CLI exited) leaves nothing to keep them for.
test("settlePaneAgent keeps a live agent and drops one the host no longer reports, so its workspace closes", async () => {
  const orcaExec = (terminal) => (_cmd, args) => (args.includes("show") ? { code: terminal ? 0 : 1, stdout: JSON.stringify({ result: { terminal } }), stderr: "" } : { code: 0, stdout: "", stderr: "" });
  const live = watchFixture("orca", []);
  live.effects._paneWatch = { host: "orca", handle: "term_w" };
  live.effects.exec = orcaExec({ handle: "term_w", agentIdentity: "claude" });
  assert.equal(settlePaneAgent(live.effects), true);
  assert.deepEqual(live.effects._paneWatch, { host: "orca", handle: "term_w" });

  for (const [name, terminal] of [["a closed terminal", null], ["a shell, no agentIdentity", { handle: "term_w" }]]) {
    const dead = watchFixture("orca", []);
    dead.effects._paneWatch = { host: "orca", handle: "term_w" };
    dead.effects._paneWatchReused = true; // a reused agent was identified once; an opened one is judged by presence
    dead.effects.exec = orcaExec(terminal);
    assert.equal(settlePaneAgent(dead.effects), false, name);
    assert.equal(dead.effects._paneWatch, null, name);
  }

  const none = watchFixture("herdr", []);
  assert.equal(settlePaneAgent(none.effects), false, "no agent was ever opened");

  const herdr = watchFixture("herdr", [json({ result: { workspace: { workspace_id: "w9" }, already_open: false } }), json({ result: { type: "ok" } })]);
  await ensurePaneWorkspace(herdr.effects, { featureSlug: "alpha" });
  herdr.effects._paneWatch = { host: "herdr", handle: "w9:p1" };
  herdr.effects._paneWatchReused = true;
  herdr.effects.exec = () => ({ code: 0, stdout: JSON.stringify({ result: { panes: [{ pane_id: "w9:p1", agent_status: "unknown" }] } }), stderr: "" });
  assert.equal(settlePaneAgent(herdr.effects), false);
  await closePaneWorkspace(herdr.effects);
  assert.deepEqual(herdr.effects._calls.at(-1), ["herdr", "workspace", "close", "w9"], "a dead agent's workspace is closed like any other");
});

// A run can end seconds after it opened the agent (lint errors, sync conflict), before the host has
// identified the starting CLI as an agent: only a pane or terminal the host no longer lists is gone.
test("settlePaneAgent keeps an agent this run just opened while the host lists it but has not yet identified it", async () => {
  const herdr = watchFixture("herdr", [json({ result: { workspace: { workspace_id: "w9" }, already_open: false } })]);
  await ensurePaneWorkspace(herdr.effects, { featureSlug: "alpha" });
  herdr.effects._paneWatch = { host: "herdr", handle: "w9:p1" };
  herdr.effects._paneWatchReused = false;
  herdr.effects.exec = () => ({ code: 0, stdout: JSON.stringify({ result: { panes: [{ pane_id: "w9:p1", agent_status: "unknown" }] } }), stderr: "" });
  assert.equal(settlePaneAgent(herdr.effects), true, "listed pane, agent_status unknown");
  const before = herdr.effects._calls.length;
  await closePaneWorkspace(herdr.effects);
  assert.equal(herdr.effects._calls.length, before, "no workspace close while the agent lives");

  const gone = watchFixture("herdr", []);
  gone.effects._paneWatch = { host: "herdr", handle: "w9:p1" };
  gone.effects._paneWatchReused = false;
  gone.effects.exec = () => ({ code: 0, stdout: JSON.stringify({ result: { panes: [] } }), stderr: "" });
  assert.equal(settlePaneAgent(gone.effects), false, "a pane the host no longer lists is gone");

  const orca = watchFixture("orca", []);
  orca.effects._paneWatch = { host: "orca", handle: "term_w" };
  orca.effects._paneWatchReused = false;
  orca.effects.exec = () => ({ code: 0, stdout: JSON.stringify({ result: { terminal: { handle: "term_w" } } }), stderr: "" });
  assert.equal(settlePaneAgent(orca.effects), true, "orca terminal present, no agentIdentity yet");
  orca.effects.exec = () => ({ code: 1, stdout: "", stderr: "" });
  orca.effects._paneWatch = { host: "orca", handle: "term_w" };
  assert.equal(settlePaneAgent(orca.effects), false, "orca terminal show fails");
});
