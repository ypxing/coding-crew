/**
 * pane-host.test.mjs — the herdr and orca adapters behind orchestrator/lib/pane-host/.
 */

import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  closePaneLogTab,
  closePaneWorkspace,
  drainPaneNotices,
  ensurePaneWorkspace,
  notifyTriggeringPane,
  preflightPaneHost,
  queuePaneNotice,
} from "../../orchestrator/lib/pane-host/index.mjs";

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

test("notifyTriggeringPane is a no-op with no pane host selected, even inside a herdr pane", async () => {
  const prior = process.env.HERDR_PANE_ID;
  process.env.HERDR_PANE_ID = "w1:p1";
  try {
    const calls = [];
    const effects = { paneHost: null, spawnWithTimeout: async (...a) => calls.push(a) };
    const result = await notifyTriggeringPane(effects, "msg");
    assert.deepEqual(result, { sent: false, reason: "no pane host" });
    assert.equal(calls.length, 0);
  } finally {
    if (prior === undefined) delete process.env.HERDR_PANE_ID;
    else process.env.HERDR_PANE_ID = prior;
  }
});

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
// triggering pane at the end of a run (notifyTriggeringPane). orca also hosts each headless
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

test("notifyTriggeringPane (herdr) is a no-op when not running inside herdr — no HERDR_PANE_ID", async () => {
  const effects = fakeHerdrEffects([], { mainRoot: "/root" });
  await notifyTriggeringPane(effects, "crew-afk (alpha): sprint finished.");
  assert.deepEqual(effects._calls, [], "nothing to notify — the run wasn't launched inside a herdr pane");
});

test("notifyTriggeringPane (herdr) prompts the triggering pane directly by its injected HERDR_PANE_ID, waiting for herdr to confirm delivery", async () => {
  const effects = fakeHerdrEffects([json({ result: { type: "ok" } })], { mainRoot: "/root" });
  const result = await withHerdrPaneId("w1:p1", () => notifyTriggeringPane(effects, "crew-afk (alpha): sprint finished."));
  assert.deepEqual(effects._calls, [
    ["herdr", "agent", "prompt", "w1:p1", "crew-afk (alpha): sprint finished.", "--wait", "--until", "working", "--timeout-ms", "2000"],
  ]);
  assert.deepEqual(result, { sent: true });
});

test("notifyTriggeringPane (herdr) reports a stalled push as a failure instead of a false success", async () => {
  const effects = fakeHerdrEffects([{ code: 1, stdout: "", stderr: "agent_prompt_stalled" }], { mainRoot: "/root" });
  const result = await withHerdrPaneId("w1:p1", () => notifyTriggeringPane(effects, "crew-afk (alpha): sprint finished."));
  assert.equal(result.sent, false);
  assert.match(result.reason, /agent_prompt_stalled/);
});

test("notifyTriggeringPane (herdr) swallows a failed prompt — the sprint's own outcome is already decided by then", async () => {
  const calls = [];
  const effects = {
    paneHost: "herdr",
    mainRoot: "/root",
    spawnWithTimeout: async (cmd, args) => {
      calls.push([cmd, ...args]);
      throw new Error("herdr unreachable");
    },
  };
  const result = await withHerdrPaneId("w1:p1", () => notifyTriggeringPane(effects, "crew-afk (alpha): sprint finished."));
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
    ],
    { mainRoot: root },
  );

  await withOrcaTerminalHandle("term_1", () => ensurePaneWorkspace(effects, { featureSlug: "alpha", logFile }));
  await closePaneLogTab(effects);

  assert.equal(effects._calls.length, 3);
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
  const effects = fakeOrcaEffects([json({ result: { terminal: { handle: "term_1" } } })], { mainRoot: root });
  await ensurePaneWorkspace(effects, { featureSlug: "alpha", logFile });
  await closePaneLogTab(effects);
  assert.deepEqual(effects._calls.at(-1), ["orca", "terminal", "close", "--terminal", "term_1", "--json"]);
});

test("notifyTriggeringPane (orca) is a no-op when not running inside orca — no ORCA_TERMINAL_HANDLE", async () => {
  const effects = fakeOrcaEffects([], { mainRoot: "/root" });
  const result = await notifyTriggeringPane(effects, "crew-afk (alpha): sprint finished.");
  assert.deepEqual(effects._calls, [], "nothing to notify — the run wasn't launched inside an orca terminal");
  assert.equal(result.sent, false);
});

// Confirmed live: sending into a plain shell terminal returned `accepted: true` but
// `prompt.observation: "unsupported"` — orca self-reports what it can't confirm rather than
// silently claiming success like herdr's pre-#4537-fix `agent prompt` did, so there is no
// `--wait`-style workaround needed here, just the `accepted` flag.
const orcaAgentShow = () => json({ result: { terminal: { handle: "term_1", agentIdentity: "claude" } } });

test("notifyTriggeringPane (orca) sends into the triggering terminal by its injected ORCA_TERMINAL_HANDLE", async () => {
  const effects = fakeOrcaEffects(
    [orcaAgentShow(), json({ result: { send: { accepted: true, prompt: { observation: "supported" } } } })],
    { mainRoot: "/root" },
  );
  const result = await withOrcaTerminalHandle("term_1", () => notifyTriggeringPane(effects, "crew-afk (alpha): sprint finished."));
  assert.deepEqual(effects._calls, [
    ["orca", "terminal", "show", "--terminal", "term_1", "--json"],
    ["orca", "terminal", "send", "--terminal", "term_1", "--text", "crew-afk (alpha): sprint finished.", "--enter", "--json"],
  ]);
  assert.deepEqual(result, { sent: true });
});

// orca's `terminal send` types into any terminal, agent or not, and reports `accepted: true`
// for a plain shell — where the message plus Enter runs as a shell command. Confirmed live:
// `terminal show` reports agentIdentity for a claude pane, and no such field for a shell.
test("notifyTriggeringPane (orca) never types into a triggering terminal orca doesn't see an agent in", async () => {
  const effects = fakeOrcaEffects([json({ result: { terminal: { handle: "term_1", title: "bash" } } })], { mainRoot: "/root" });
  const result = await withOrcaTerminalHandle("term_1", () => notifyTriggeringPane(effects, "crew-afk (alpha): sprint finished."));
  assert.deepEqual(effects._calls, [["orca", "terminal", "show", "--terminal", "term_1", "--json"]], "a shell, not an agent — no send");
  assert.equal(result.sent, false);
  assert.match(result.reason, /not running an agent/);
});

test("notifyTriggeringPane (orca) never sends when terminal show itself fails", async () => {
  const effects = fakeOrcaEffects([{ code: 1, stdout: "", stderr: "terminal not found" }], { mainRoot: "/root" });
  const result = await withOrcaTerminalHandle("term_1", () => notifyTriggeringPane(effects, "crew-afk (alpha): sprint finished."));
  assert.equal(effects._calls.length, 1, "show only — an unknown pane is never typed into");
  assert.equal(result.sent, false);
  // orca quit or timing out is not "the pane isn't an agent": the log must say which.
  assert.match(result.reason, /terminal show exit=1 terminal not found/);
});

test("notifyTriggeringPane (orca) names show, not send, when show throws", async () => {
  const effects = { paneHost: "orca", mainRoot: "/root", spawnWithTimeout: async () => { throw new Error("spawn orca ENOENT"); } };
  const result = await withOrcaTerminalHandle("term_1", () => notifyTriggeringPane(effects, "msg"));
  assert.equal(result.sent, false);
  assert.match(result.reason, /orca terminal show threw: spawn orca ENOENT/);
});

// Measured live: `terminal send` into an idle claude pane takes ~8s to return (it watches for
// turn start) — a 5s cap killed it at exit 124 after delivery, logging a false NOTIFY-FAIL.
test("notifyTriggeringPane (orca) gives terminal send long enough to return from a live agent pane", async () => {
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
  await withOrcaTerminalHandle("term_1", () => notifyTriggeringPane(effects, "crew-afk (alpha): sprint finished."));
  assert.ok(timeoutMs >= 20000, `timeout ${timeoutMs}ms is shorter than a live agent pane's ~8s send`);
});

test("notifyTriggeringPane (orca) reports an explicitly-not-accepted send as a failure", async () => {
  const effects = fakeOrcaEffects([orcaAgentShow(), json({ result: { send: { accepted: false } } })], { mainRoot: "/root" });
  const result = await withOrcaTerminalHandle("term_1", () => notifyTriggeringPane(effects, "crew-afk (alpha): sprint finished."));
  assert.equal(result.sent, false);
  assert.match(result.reason, /not accepted/);
});

test("notifyTriggeringPane (orca) swallows a failed send — the sprint's own outcome is already decided by then", async () => {
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
  const result = await withOrcaTerminalHandle("term_1", () => notifyTriggeringPane(effects, "crew-afk (alpha): sprint finished."));
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
  await withHerdrPaneId("w1:p1", async () => {
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
  });
  assert.deepEqual(sent, ["one", "two"]);
  assert.equal(maxInFlight, 1, "pushes into one pane never overlap");
  assert.deepEqual(reasons.map((r) => r.sent), [true, true]);
});

test("drainPaneNotices is a no-op when nothing was queued", async () => {
  await drainPaneNotices({ paneHost: null });
});
