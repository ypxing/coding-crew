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
  awaitFollowup,
  openFollowup,
  preflightPaneHost,
  queuePaneNotice,
  replyFollowup,
  supportsFollowups,
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

// The reused pane's own tab still shows whatever it was called before crew-afk started
// running in it — herdr also injects that pane's own tab as HERDR_TAB_ID, so this is the
// one chance to relabel it to the sprint's feature slug, the same way a freshly created
// workspace already is. The run's own log tab still opens inside the reused workspace too.
test("ensurePaneWorkspace (herdr) reuses an ambient HERDR_WORKSPACE_ID, renames the triggering tab, and still opens its own log tab", async () => {
  const { root } = fixture();
  const logFile = join(root, "trace.log");
  const effects = fakeHerdrEffects(
    [
      json({ result: { type: "ok" } }), // tab rename
      ...herdrLogTabResponses(),
    ],
    { mainRoot: root },
  );

  const workspaceId = await withHerdrWorkspaceId("w1", () =>
    withHerdrTabId("w1:t1", () => ensurePaneWorkspace(effects, { featureSlug: "implement-user-auth", logFile })),
  );

  assert.equal(workspaceId, "w1", "the ambient workspace is reused, not created");
  assert.ok(!effects._calls.some((c) => c[1] === "workspace" && c[2] === "create"));
  assert.deepEqual(effects._calls[0], ["herdr", "tab", "rename", "w1:t1", "implement-user-auth"]);
  assert.deepEqual(effects._calls.at(-1), ["herdr", "pane", "run", "w1:plog", "tail", "-f", logFile]);
});

test("ensurePaneWorkspace (herdr) never renames the triggering pane's own tab when no feature slug resolved", async () => {
  const { root } = fixture();
  const effects = fakeHerdrEffects([], { mainRoot: root });

  await withHerdrWorkspaceId("w1", () => withHerdrTabId("w1:t1", () => ensurePaneWorkspace(effects, {})));

  assert.deepEqual(effects._calls, [], "no feature slug resolved, so the pane's own tab is left exactly as the human named it");
});

test("closePaneWorkspace (herdr) closes the workspace ensurePaneWorkspace created, and is a no-op when nothing was ever created", async () => {
  const untouched = fakeHerdrEffects([], { mainRoot: "/root" });
  await closePaneWorkspace(untouched);
  assert.deepEqual(untouched._calls, [], "nothing to close — no run ever created a workspace on this effects instance");

  const { root } = fixture();
  const effects = fakeHerdrEffects([json({ result: { workspace: { workspace_id: "w1" } } }), json({ result: { type: "ok" } })], { mainRoot: root });
  await ensurePaneWorkspace(effects, { featureSlug: "alpha" });
  await closePaneWorkspace(effects);
  assert.deepEqual(effects._calls.at(-1), ["herdr", "workspace", "close", "w1"]);
});

test("closePaneWorkspace (herdr) never closes a workspace reused via HERDR_WORKSPACE_ID — that would close the pane crew-afk was launched from", async () => {
  const { root } = fixture();
  const effects = fakeHerdrEffects([], { mainRoot: root });

  await withHerdrWorkspaceId("w1", () => ensurePaneWorkspace(effects, { featureSlug: "alpha" }));
  await closePaneWorkspace(effects);

  assert.ok(
    !effects._calls.some((c) => c[1] === "workspace" && c[2] === "close"),
    "the reused workspace is left open — it belongs to whoever is still using that pane",
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

// The case closePaneWorkspace's own reuse test above leaves unclosed: a workspace reused
// via HERDR_WORKSPACE_ID survives (it belongs to whoever's pane triggered the run), but this
// run's own log tab inside it is still this run's to close — otherwise it tails the trace
// log forever after a run launched from inside an existing herdr pane.
test("closePaneLogTab (herdr) closes this run's own log tab even when the workspace it lives in was reused, not created", async () => {
  const { root } = fixture();
  const logFile = join(root, "trace.log");
  const effects = fakeHerdrEffects([...herdrLogTabResponses(), json({ result: { type: "ok" } })], { mainRoot: root });

  await withHerdrWorkspaceId("w1", () => ensurePaneWorkspace(effects, { featureSlug: "alpha", logFile }));
  await closePaneWorkspace(effects);
  await closePaneLogTab(effects);

  assert.ok(!effects._calls.some((c) => c[1] === "workspace" && c[2] === "close"), "the reused workspace itself is still left open");
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
  return { root, effects, watchFile, record, saved: () => JSON.parse(readFileSync(watchFile, "utf8")) };
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

test("ensureWatchSession (orca) with no usable watch.json creates <slug>-watch in the main checkout and records its handle", async () => {
  const { root, effects, saved } = watchFixture("orca", [orcaCreated("term_w")]);
  const watch = await ensureWatchSession(effects, WATCH);
  assert.equal(effects._calls.length, 1);
  const [cmd, ...args] = effects._calls[0];
  assert.equal(cmd, "orca");
  assert.deepEqual(args.slice(0, 7), ["terminal", "create", "--worktree", `path:${root}`, "--title", "alpha-watch", "--command"]);
  assert.equal(args[8], "--json");
  const { text } = launchScriptOf(args[7]);
  const argv = ["claude", renderRolePrompt("watcher", "claude", { mainRoot: root }), "--add-dir", root, "--model", "sonnet", "--disallowedTools", "Edit", "Write", "NotebookEdit", "Agent"];
  const quoted = argv.map((a) => `'${a.replace(/'/g, `'\\''`)}'`).join(" ");
  assert.ok(text.includes(`exec ${quoted}`), "the argv carries the rendered watcher protocol as its initial prompt");
  assert.deepEqual(saved(), { host: "orca", handle: "term_w" });
  assert.equal(watch.handle, "term_w");
  assert.deepEqual(effects._paneWatch, { host: "orca", handle: "term_w" });
});

test("ensureWatchSession gives the host a command that sources crew-afk's env.sh before the interactive argv, then deletes it", async () => {
  for (const [host, responses, setup] of [
    ["orca", [orcaCreated()], () => {}],
    ["herdr", [herdrWorkspace(), json({ result: { type: "ok" } })], () => {}],
  ]) {
    setup();
    const { effects } = watchFixture(host, responses, { env: { CREW_WATCH_PROBE: "it's from crew-afk" } });
    await ensureWatchSession(effects, WATCH);
    const command = host === "orca" ? effects._calls[0][8] : effects._calls[1][4];
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

test("ensureWatchSession puts CREW_PANE_HOST=<effects.paneHost> in the launch env, so `followup start` run from the watch agent resolves the host `run --pane-host` chose", async () => {
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

test("ensureWatchSession (herdr) closes the tab or workspace it made when pane run fails, leaving no empty <slug>-watch behind", async () => {
  const outside = watchFixture("herdr", [herdrWorkspace("w9", "w9:p1"), { code: 1, stdout: "", stderr: "pane not found" }, json({})]);
  assert.equal(await ensureWatchSession(outside.effects, WATCH), null);
  assert.deepEqual(outside.effects._calls[2], ["herdr", "workspace", "close", "w9"]);
  assert.equal(existsSync(outside.watchFile), false, "nothing recorded");

  const inside = watchFixture("herdr", [herdrTab("w1:tw", "w1:pw"), { code: 1, stdout: "", stderr: "pane not found" }, json({})]);
  assert.equal(await withHerdrWorkspaceId("w1", () => ensureWatchSession(inside.effects, WATCH)), null);
  assert.deepEqual(inside.effects._calls[2], ["herdr", "tab", "close", "w1:tw"]);
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

test("ensureWatchSession (herdr) inside herdr opens a new tab in HERDR_WORKSPACE_ID and starts the agent with pane run", async () => {
  const { root, effects, saved } = watchFixture("herdr", [herdrTab("w1:tw", "w1:pw"), json({ result: { type: "ok" } })]);
  await withHerdrWorkspaceId("w1", () => ensureWatchSession(effects, WATCH));
  assert.deepEqual(effects._calls[0], ["herdr", "tab", "create", "--workspace", "w1", "--cwd", root, "--label", "alpha-watch", "--no-focus"]);
  assert.deepEqual(effects._calls[1].slice(0, 4), ["herdr", "pane", "run", "w1:pw"]);
  launchScriptOf(effects._calls[1][4]);
  assert.deepEqual(saved(), { host: "herdr", handle: "w1:pw" });
});

test("ensureWatchSession (herdr) outside herdr opens a <slug>-watch workspace on the main checkout", async () => {
  const { root, effects, saved } = watchFixture("herdr", [herdrWorkspace("w9", "w9:p1"), json({ result: { type: "ok" } })]);
  await ensureWatchSession(effects, WATCH);
  assert.deepEqual(effects._calls[0], ["herdr", "workspace", "create", "--cwd", root, "--label", "alpha-watch", "--no-focus"]);
  assert.deepEqual(effects._calls[1].slice(0, 4), ["herdr", "pane", "run", "w9:p1"]);
  assert.deepEqual(saved(), { host: "herdr", handle: "w9:p1" });
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
    const dead = watchFixture("herdr", [list, herdrWorkspace("w10", "w10:p1"), json({ result: { type: "ok" } })]);
    dead.record({ host: "herdr", handle: "w9:p1" });
    await ensureWatchSession(dead.effects, WATCH);
    assert.equal(dead.effects._calls[1][2], "create", name);
    assert.deepEqual(dead.saved(), { host: "herdr", handle: "w10:p1" }, name);
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

  const herdr = watchFixture("herdr", [herdrWorkspace("w9", "w9:p1"), json({ result: { type: "ok" } }), json({ result: { type: "ok" } })]);
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

  const herdr = watchFixture("herdr", [herdrWorkspace("w9", "w9:p1"), json({ result: { type: "ok" } }), herdrWorkspace("w2", "w2:p1"), herdrTab("w2:log", "w2:plog"), json({ result: { type: "ok" } }), json({}), json({})]);
  await ensureWatchSession(herdr.effects, WATCH);
  await ensurePaneWorkspace(herdr.effects, { featureSlug: "alpha", logFile: join(herdr.root, "trace.log") });
  await closePaneWorkspace(herdr.effects);
  await closePaneLogTab(herdr.effects);
  const closes = herdr.effects._calls.filter((c) => c[2] === "close");
  assert.deepEqual(closes.map((c) => c[3]).sort(), ["w2", "w2:log"], "the sprint's own workspace and log tab only");
  assert.ok(closes.every((c) => !String(c[3]).startsWith("w9")), "the watch workspace is never closed");
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

// ─── follow-up workers: openFollowup / awaitFollowup / replyFollowup ─────────────────────────
//
// The command (`crew-afk followup`) over a fake host is followup.test.mjs; these pin each
// adapter's ops and the dispatch through index.mjs.

const FOLLOWUP = { slug: "alpha", worktree: "/root/.scratch/worktrees/crew/alpha/_followup", command: "bash '/launch.sh'", spec: "BRIEF + TASK", coordinator: "term_watch" };

test("supportsFollowups is true for orca and herdr and false with no host", () => {
  assert.equal(supportsFollowups({ paneHost: "orca" }), true);
  assert.equal(supportsFollowups({ paneHost: "herdr" }), true);
  assert.equal(supportsFollowups({ paneHost: null }), false);
});

test("openFollowup (orca) creates a Run from the watch handle, a terminal in the follow-up worktree, then starts it as the Run's worker", async () => {
  const effects = fakeOrcaEffects([json({ result: { run: { id: "run_9" } } }), orcaCreated("term_f"), json({ result: {} })]);
  const opened = await openFollowup(effects, FOLLOWUP);
  assert.deepEqual(opened, { runId: "run_9", terminal: "term_f", coordinator: "term_watch" });
  assert.deepEqual(effects._calls.map((c) => c.slice(0, 3)), [
    ["orca", "orchestration", "run-create"],
    ["orca", "terminal", "create"],
    ["orca", "orchestration", "worker-start"],
  ]);
  assert.ok(effects._calls[0].join(" ").includes("--from term_watch"));
  assert.ok(effects._calls[1].join(" ").includes(`--worktree path:${FOLLOWUP.worktree}`));
  assert.ok(effects._calls[2].join(" ").includes(`--run run_9 --worktree path:${FOLLOWUP.worktree} --terminal term_f --spec BRIEF + TASK`));
  assert.ok(effects._timeouts.every((t) => t === 10000), "every call is bounded");
  assert.equal(effects._paneTerminals?.has("term_f") ?? false, false, "the follow-up terminal is not swept by the run's own close");
});

test("openFollowup (orca) with no coordinator handle fails before any host call", async () => {
  const effects = fakeOrcaEffects([]);
  const opened = await openFollowup(effects, { ...FOLLOWUP, coordinator: undefined });
  assert.match(opened.failure, /no watch agent handle/);
  assert.equal(effects._calls.length, 0);
});

test("awaitFollowup (orca) prefers the worker_done over an unanswered question, and skips answered ones", async () => {
  const msg = (m) => ({ to_handle: "run:run_9", ...m });
  const effects = fakeOrcaEffects([
    json({ result: { messages: [msg({ id: "q1", type: "question", sequence: 2, body: "old?" }), msg({ id: "q2", type: "question", sequence: 4, body: "new?" })] } }),
    json({ result: { messages: [msg({ id: "q1", type: "question", sequence: 2, body: "old?" }), msg({ id: "d", type: "worker_done", sequence: 6, body: "done" })] } }),
  ]);
  const rec = { runId: "run_9", answered: ["q1"] };
  assert.deepEqual(await awaitFollowup(effects, rec, { pollMs: 1 }), { kind: "question", text: "new?", messageId: "q2" });
  assert.deepEqual(await awaitFollowup(effects, rec, { pollMs: 1 }), { kind: "done", text: "done", messageId: "d" });
});

test("replyFollowup (orca) is orchestration reply --id of the pending question; with none it fails without a host call", async () => {
  const effects = fakeOrcaEffects([json({ result: {} })]);
  assert.match((await replyFollowup(effects, { runId: "run_9" }, "x")).failure, /no open question/);
  assert.equal(effects._calls.length, 0);
  const sent = await replyFollowup(effects, { runId: "run_9", coordinator: "term_watch", pending: { messageId: "q2" } }, "yes");
  assert.deepEqual(sent, { messageId: "q2" });
  assert.deepEqual(effects._calls[0], ["orca", "orchestration", "reply", "--id", "q2", "--body", "yes", "--run", "run_9", "--from", "term_watch", "--json"]);
});

test("openFollowup (herdr) never throws: a host call that throws is a failure with its text", async () => {
  const effects = fakeHerdrEffects([]);
  const opened = await openFollowup(effects, FOLLOWUP);
  assert.match(opened.failure, /no more canned herdr responses/);
});

test("openFollowup (herdr) waits for the started agent's first turn to end before prompting the spec", async () => {
  const effects = fakeHerdrEffects([herdrWorkspace("w2", "w2:p1"), json({}), json({}), json({})]);
  const opened = await openFollowup(effects, FOLLOWUP);
  assert.deepEqual(opened, { handle: "w2:p1" });
  assert.deepEqual(effects._calls.map((c) => c.slice(0, 4)), [
    ["herdr", "workspace", "create", "--cwd"],
    ["herdr", "pane", "run", "w2:p1"],
    ["herdr", "agent", "wait", "w2:p1"],
    ["herdr", "agent", "prompt", "w2:p1"],
  ]);
  const wait = effects._calls[2];
  assert.ok(wait.includes("--until") && wait.includes("idle") && wait.includes("done"), `the first turn ends as idle or done: ${wait}`);
  assert.ok(!wait.includes("working"), "not the state the first prompt is already in");
  assert.ok(wait.includes("--timeout"), "a stalled start fails rather than hanging");
  assert.equal(effects._calls[3][4], "BRIEF + TASK");
});

test("openFollowup (herdr) retries the first-turn wait while herdr has not detected the agent yet (agent_not_found), then prompts the spec", async () => {
  const notYet = { code: 1, stdout: JSON.stringify({ error: { code: "agent_not_found", message: "agent target w2:p1 not found" } }), stderr: "" };
  const effects = fakeHerdrEffects([herdrWorkspace("w2", "w2:p1"), json({}), notYet, notYet, json({}), json({})]);
  const slept = [];
  const opened = await openFollowup(effects, { ...FOLLOWUP, sleep: async (ms) => slept.push(ms) });
  assert.deepEqual(opened, { handle: "w2:p1" });
  assert.deepEqual(effects._calls.map((c) => c.slice(1, 3).join(" ")), ["workspace create", "pane run", "agent wait", "agent wait", "agent wait", "agent prompt"]);
  assert.equal(slept.length, 2, "one pause per not-yet-detected answer");
});

test("openFollowup (herdr) gives up on an agent herdr never detects, closing the pane it made", async () => {
  const notYet = { code: 1, stdout: JSON.stringify({ error: { code: "agent_not_found", message: "agent target w2:p1 not found" } }), stderr: "" };
  const effects = fakeHerdrEffects([herdrWorkspace("w2", "w2:p1"), json({}), ...Array.from({ length: 500 }, () => notYet), json({})]);
  let now = 0;
  const opened = await openFollowup(effects, { ...FOLLOWUP, sleep: async (ms) => (now += ms), now: () => now });
  assert.match(opened.failure, /herdr agent wait exit=1 .*agent_not_found/);
  assert.ok(!effects._calls.some((c) => c[2] === "prompt"), "the spec was never sent");
  assert.deepEqual(effects._calls.at(-1), ["herdr", "workspace", "close", "w2"]);
});

test("openFollowup (herdr) whose first turn never ends fails with the host's text, never prompts the spec, and closes the pane it made", async () => {
  const effects = fakeHerdrEffects([herdrWorkspace("w2", "w2:p1"), json({}), { code: 124, stdout: "", stderr: "timeout" }, json({})]);
  const opened = await openFollowup(effects, FOLLOWUP);
  assert.match(opened.failure, /herdr agent wait exit=124 \(timed out/);
  assert.ok(!effects._calls.some((c) => c[2] === "prompt"), "the spec was never sent");
  assert.deepEqual(effects._calls.at(-1), ["herdr", "workspace", "close", "w2"]);
});

// What herdr's pane shows after each turn: the echoed prompt, then the worker's output.
const read = (text) => json({ result: { read: { text } } });
const turnEnded = () => json({});

test("awaitFollowup (herdr) takes only a marker after the last answer crew-afk sent: a second turn with no marker is the no-marker failure, not the earlier question", async () => {
  const pane = "⏺ Looking.\nQUESTION: keep the old API?\n\n> yes\n⏺ Working on it, tests pass.\n";
  const effects = fakeHerdrEffects([turnEnded(), read(pane)]);
  const answer = await awaitFollowup(effects, { handle: "w2:p1", lastAnswer: "yes" });
  assert.match(answer.failure, /ended with no QUESTION:\/DONE: line/);
  assert.match(answer.failure, /Working on it/);
});

test("awaitFollowup (herdr) returns a marker the worker wrote after the echoed answer, and one before it is ignored", async () => {
  const pane = "QUESTION: keep the old API?\n\n> yes\n⏺ Kept it.\n⏺ DONE: kept the old API; committed 9f2e\n";
  const effects = fakeHerdrEffects([turnEnded(), read(pane)]);
  assert.deepEqual(await awaitFollowup(effects, { handle: "w2:p1", lastAnswer: "yes" }), { kind: "done", text: "kept the old API; committed 9f2e" });
});

test("awaitFollowup (herdr) fails, rather than guess, when the answer it sent is not in the pane's recent text", async () => {
  const effects = fakeHerdrEffects([turnEnded(), read("QUESTION: keep the old API?\nsome other output\n")]);
  const answer = await awaitFollowup(effects, { handle: "w2:p1", lastAnswer: "yes" });
  assert.match(answer.failure, /answer crew-afk sent is not in the pane/);
});

test("awaitFollowup (herdr) finds an answer the worker's TUI hard-wrapped across several pane lines", async () => {
  const lastAnswer = "keep the old API but deprecate it, and move every caller in orchestrator/lib to the new one";
  const pane = "QUESTION: keep the old API?\n\n> keep the old API but deprecate it, and move every caller in\n  orchestrator/lib to the new one\n⏺ DONE: deprecated it; committed 9f2e\n";
  const effects = fakeHerdrEffects([turnEnded(), read(pane)]);
  assert.deepEqual(await awaitFollowup(effects, { handle: "w2:p1", lastAnswer }), { kind: "done", text: "deprecated it; committed 9f2e" });
});

test("awaitFollowup (herdr) whose answer's echo scrolled out of a full read takes the whole read as this turn", async () => {
  const pane = [...Array.from({ length: 399 }, (_, i) => `⏺ step ${i}`), "⏺ QUESTION: also drop the shim?"].join("\n");
  const effects = fakeHerdrEffects([turnEnded(), read(pane)]);
  assert.deepEqual(await awaitFollowup(effects, { handle: "w2:p1", lastAnswer: "yes" }), { kind: "question", text: "also drop the shim?" });
});

test("awaitFollowup (herdr) with a wrapped echo and no marker after it is still the no-marker failure", async () => {
  const lastAnswer = "keep the old API but deprecate it, and move every caller in orchestrator/lib to the new one";
  const pane = "QUESTION: keep the old API?\n\n> keep the old API but deprecate it, and move every caller in\n  orchestrator/lib to the new one\n⏺ Working on it.\n";
  const effects = fakeHerdrEffects([turnEnded(), read(pane)]);
  assert.match((await awaitFollowup(effects, { handle: "w2:p1", lastAnswer })).failure, /ended with no QUESTION:\/DONE: line/);
});

test("awaitFollowup (herdr) with no answer sent yet (the first turn) takes the last marker in the pane", async () => {
  const effects = fakeHerdrEffects([turnEnded(), read("⏺ working\nQUESTION: which branch?\n")]);
  assert.deepEqual(await awaitFollowup(effects, { handle: "w2:p1" }), { kind: "question", text: "which branch?" });
});
