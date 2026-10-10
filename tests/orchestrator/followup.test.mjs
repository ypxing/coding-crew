/**
 * followup.test.mjs — `crew-afk followup start|wait|reply` (orchestrator/lib/followup.mjs) on a
 * real git repo, with the pane host's CLI replaced by a fake that records each call and answers
 * from a queue. The host's own adapters are pane-host.test.mjs.
 */

import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { Effects } from "../../orchestrator/lib/effects.mjs";
import { renderRolePrompt } from "../../orchestrator/lib/adapters/render.mjs";
import { runFollowup } from "../../orchestrator/lib/followup.mjs";
import { ensureWorktree, featureWorktreePath, followupWorktreePath } from "../../orchestrator/lib/worktree.mjs";

// A real orca/herdr session injects these, and the suite may itself run inside one.
const AMBIENT = ["HERDR_WORKSPACE_ID", "HERDR_TAB_ID", "HERDR_PANE_ID", "ORCA_WORKTREE_ID", "ORCA_TAB_ID", "ORCA_TERMINAL_HANDLE", "CREW_WORKTREE_ROOT"];
const saved = Object.fromEntries(AMBIENT.map((k) => [k, process.env[k]]));
before(() => AMBIENT.forEach((k) => delete process.env[k]));
after(() => {
  for (const [k, v] of Object.entries(saved)) {
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
});

const json = (obj) => ({ code: 0, stdout: JSON.stringify(obj), stderr: "" });
const ok = () => ({ code: 0, stdout: "", stderr: "" });
const orcaRun = (id = "run_1") => json({ result: { run: { id } } });
const orcaTerminal = (handle = "term_f") => json({ result: { terminal: { handle } } });
const orcaInbox = (...messages) => json({ result: { messages } });
const orcaMessage = (m) => ({ run_id: "run_1", to_handle: "run:run_1", sequence: 1, ...m });
const herdrTab = (pane = "w1:pf") => json({ result: { tab: { tab_id: "w1:tf" }, root_pane: { pane_id: pane } } });
const herdrWorkspace = (pane = "w2:p1") => json({ result: { workspace: { workspace_id: "w2" }, root_pane: { pane_id: pane } } });

/**
 * A repo whose `feature/demo` has a commit of its own, an Effects on it, and a fake pane host:
 * `calls` is every host CLI call (`[cmd, ...args]`), `responses` its queue (shifted per call).
 */
function setup({ host = "orca", responses = [], owner = null, watch = true } = {}) {
  const mainRoot = mkdtempSync(join(tmpdir(), "crew-followup-"));
  const git = (...args) => execFileSync("git", ["-C", mainRoot, ...args], { encoding: "utf8" });
  git("init", "-q", "-b", "main");
  git("config", "user.email", "test@example.com");
  git("config", "user.name", "Test");
  writeFileSync(join(mainRoot, "README.md"), "seed\n");
  git("add", "-A");
  git("commit", "-q", "-m", "seed");
  git("checkout", "-q", "-b", "feature/demo");
  writeFileSync(join(mainRoot, "feature.txt"), "feature work\n");
  git("add", "-A");
  git("commit", "-q", "-m", "feature work");
  git("checkout", "-q", "main");

  const effects = new Effects({ scriptsDir: mainRoot, mainRoot, dryRun: false, env: { MAIN_ROOT: mainRoot } });
  effects.paneHost = host;
  effects.env = { CREW_FOLLOWUP_PROBE: "from-crew-afk" };
  const calls = [];
  const adopted = [];
  const real = effects.exec.bind(effects);
  effects.exec = (cmd, args, opts) => {
    if (cmd === "sh") return ok(); // `command -v <cli>`
    if (cmd === "orca") {
      adopted.push([cmd, ...args]);
      return ok();
    }
    return real(cmd, args, opts);
  };
  effects.spawnWithTimeout = async (cmd, args) => {
    calls.push([cmd, ...args]);
    const next = responses.shift();
    if (!next) throw new Error(`no more canned ${host} responses — call was: ${cmd} ${args.join(" ")}`);
    return next;
  };
  const leaseCalls = [];
  effects.bash = (name, args) => {
    leaseCalls.push([name, ...args]);
    return owner ? { code: 0, stdout: `SHA abc123\nOWNER ${owner}\n`, stderr: "" } : { code: 0, stdout: "", stderr: "" };
  };
  if (watch) {
    mkdirSync(join(mainRoot, ".scratch", "demo"), { recursive: true });
    writeFileSync(join(mainRoot, ".scratch", "demo", "watch.json"), JSON.stringify({ host, handle: host === "orca" ? "term_watch" : "w1:pwatch" }));
  }
  const out = [];
  const err = [];
  const io = { out: (l) => out.push(l), err: (l) => err.push(l) };
  const run = (o) =>
    runFollowup(effects, {
      platform: "claude",
      model: "sonnet",
      resolveBranch: () => "feature/demo",
      useLease: true,
      pollMs: 1,
      io,
      ...o,
    });
  const recordFile = join(mainRoot, ".scratch", "demo", "followup.json");
  return {
    mainRoot,
    git,
    effects,
    calls,
    adopted,
    leaseCalls,
    out,
    err,
    run,
    recordFile,
    record: () => JSON.parse(readFileSync(recordFile, "utf8")),
    worktree: followupWorktreePath(mainRoot, "demo"),
  };
}

const START = { action: "start", slug: "demo", task: "/crew-address-findings" };

// ─── start ──────────────────────────────────────────────────────────────────────────────────

test("followup start (orca) makes _followup on the feature branch, adopts it, and runs run-create, terminal create and worker-start in order", async () => {
  const t = setup({ responses: [orcaRun("run_1"), orcaTerminal("term_f"), ok()] });
  const code = await t.run(START);
  assert.equal(code, 0, t.err.join("\n"));

  assert.equal(t.git("-C", t.worktree, "branch", "--show-current").trim(), "feature/demo");
  assert.ok(existsSync(join(t.worktree, "feature.txt")), "checked out the feature branch's content");
  assert.ok(
    t.adopted.some((c) => c.join(" ").startsWith(`orca worktree set --worktree path:${t.worktree} --display-name demo-followup`)),
    `adopted in orca: ${JSON.stringify(t.adopted)}`,
  );

  assert.equal(t.calls.length, 3);
  assert.deepEqual(t.calls[0], ["orca", "orchestration", "run-create", "--objective", "demo: follow-up on the feature branch", "--from", "term_watch", "--json"]);
  const create = t.calls[1];
  assert.deepEqual(create.slice(0, 7), ["orca", "terminal", "create", "--worktree", `path:${t.worktree}`, "--title", "demo-followup"]);
  assert.equal(create[7], "--command");
  assert.match(create[8], /^bash '.*launch\.sh'$/);
  assert.equal(create[9], "--json");
  const start = t.calls[2];
  assert.deepEqual(start.slice(0, 10), ["orca", "orchestration", "worker-start", "--run", "run_1", "--worktree", `path:${t.worktree}`, "--terminal", "term_f", "--spec"]);
  const brief = renderRolePrompt("followup", "claude", { mainRoot: t.mainRoot });
  assert.ok(start[10].includes(brief), "the spec carries the follow-up brief");
  assert.ok(start[10].includes("/crew-address-findings"), "and the task");
  assert.equal(start[11], "--json");

  assert.equal(t.out.length, 1);
  const rec = t.record();
  assert.equal(rec.id, t.out[0], "the printed id is the recorded one");
  assert.deepEqual(
    { state: rec.state, host: rec.host, runId: rec.runId, handle: rec.handle, coordinator: rec.coordinator, branch: rec.branch, worktree: rec.worktree },
    { state: "open", host: "orca", runId: "run_1", handle: "term_f", coordinator: "term_watch", branch: "feature/demo", worktree: t.worktree },
  );
});

test("followup start gives the host a launch script that sources crew-afk's env first and runs the follow-up brief as the interactive argv", async () => {
  const t = setup({ responses: [orcaRun(), orcaTerminal(), ok()] });
  assert.equal(await t.run(START), 0, t.err.join("\n"));
  const path = /^bash '(.*)'$/.exec(t.calls[1][8])[1];
  const text = readFileSync(path, "utf8");
  assert.match(text, /^\. '.*env\.sh'; rm -f '.*env\.sh'$/m);
  assert.match(text, new RegExp(`cd -P '${t.worktree.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}'`));
  const brief = renderRolePrompt("followup", "claude", { mainRoot: t.mainRoot });
  const quoted = (a) => `'${a.replace(/'/g, `'\\''`)}'`;
  assert.ok(text.includes(`exec 'claude' ${quoted(brief)} '--add-dir'`), "claude, interactive, the brief as its initial prompt");
  assert.ok(!text.includes("'Edit'"), "a follow-up worker edits: no read-only policy");
});

test("followup start (herdr) opens a pane with cwd _followup, runs the argv with pane run, waits out the first turn, then prompts the brief and task with --wait --until working", async () => {
  const t = setup({ host: "herdr", responses: [herdrWorkspace("w2:p1"), ok(), ok(), ok()] });
  const code = await t.run(START);
  assert.equal(code, 0, t.err.join("\n"));
  assert.equal(t.calls.length, 4);
  assert.deepEqual(t.calls[0], ["herdr", "workspace", "create", "--cwd", t.worktree, "--label", "demo-followup", "--no-focus"]);
  assert.deepEqual(t.calls[1].slice(0, 4), ["herdr", "pane", "run", "w2:p1"]);
  assert.match(t.calls[1][4], /^bash '.*launch\.sh'$/);
  assert.deepEqual(t.calls[2].slice(0, 4), ["herdr", "agent", "wait", "w2:p1"]);
  const prompt = t.calls[3];
  assert.deepEqual(prompt.slice(0, 4), ["herdr", "agent", "prompt", "w2:p1"]);
  assert.ok(prompt[4].includes(renderRolePrompt("followup", "claude", { mainRoot: t.mainRoot })));
  assert.ok(prompt[4].includes("/crew-address-findings"));
  assert.deepEqual(prompt.slice(5, 8), ["--wait", "--until", "working"]);
  assert.equal(t.record().handle, "w2:p1");
  assert.equal(t.out[0], t.record().id);
});

test("followup start (herdr) inside herdr opens a new tab in the watch workspace", async () => {
  process.env.HERDR_WORKSPACE_ID = "w1";
  try {
    const t = setup({ host: "herdr", responses: [herdrTab("w1:pf"), ok(), ok(), ok()] });
    assert.equal(await t.run(START), 0, t.err.join("\n"));
    assert.deepEqual(t.calls[0], ["herdr", "tab", "create", "--workspace", "w1", "--cwd", t.worktree, "--label", "demo-followup", "--no-focus"]);
  } finally {
    delete process.env.HERDR_WORKSPACE_ID;
  }
});

// ─── refusals and failures ─────────────────────────────────────────────────────────────────

test("every followup subcommand exits 1 saying follow-ups need orca or herdr when there is no pane host", async () => {
  for (const o of [START, { action: "wait", id: "demo-fu-1" }, { action: "reply", id: "demo-fu-1", answer: "yes" }]) {
    const t = setup({ host: null });
    assert.equal(await t.run(o), 1, o.action);
    assert.match(t.err.join("\n"), /follow-ups need orca or herdr/, o.action);
    assert.equal(t.calls.length, 0);
    assert.equal(existsSync(t.worktree), false);
  }
});

test("followup start exits non-zero naming the owner while lease.sh owner reports a holder, and creates no worktree", async () => {
  const t = setup({ owner: "run=2026-10-10T01-00-00Z host=ci-box pid=4242 at=2026-10-10T01:00:00Z" });
  assert.equal(await t.run(START), 1);
  assert.match(t.err.join("\n"), /feature demo is leased by run 2026-10-10T01-00-00Z on ci-box/);
  assert.deepEqual(t.leaseCalls, [["lease.sh", "owner", "--slug", "demo"]]);
  assert.equal(existsSync(t.worktree), false, "no worktree");
  assert.equal(t.calls.length, 0, "no host call");
  assert.equal(existsSync(t.recordFile), false);
});

test("followup start exits non-zero while a follow-up for the slug is open, and creates no worktree", async () => {
  const first = setup({ responses: [orcaRun(), orcaTerminal(), ok()] });
  assert.equal(await first.run(START), 0, first.err.join("\n"));
  const id = first.out[0];

  first.out.length = 0;
  first.err.length = 0;
  first.calls.length = 0;
  first.git("worktree", "remove", "--force", first.worktree);
  assert.equal(await first.run(START), 1);
  assert.match(first.err.join("\n"), new RegExp(`already open \\(${id}\\)`));
  assert.equal(existsSync(first.worktree), false, "no worktree");
  assert.equal(first.calls.length, 0);
});

test("followup start refuses while a live run's sprint lock names this process, without the lease check being what stops it", async () => {
  const t = setup({});
  writeFileSync(join(t.mainRoot, ".scratch", "demo", ".crew-afk.lock"), JSON.stringify({ pid: process.pid, startedAt: "2026-10-10T00:00:00Z" }));
  assert.equal(await t.run({ ...START, useLease: false }), 1);
  assert.match(t.err.join("\n"), /a sprint for demo is running/);
  assert.equal(existsSync(t.worktree), false);
});

test("followup start with a branch that does not exist exits 1 and makes no worktree", async () => {
  const t = setup({});
  assert.equal(await t.run({ ...START, resolveBranch: () => "feature/nope" }), 1);
  assert.match(t.err.join("\n"), /feature branch feature\/nope does not exist/);
  assert.equal(existsSync(t.worktree), false);
});

test("a failing host call fails start with the host's own text and leaves no record, no worktree and no terminal", async () => {
  const cases = [
    {
      host: "orca",
      responses: [{ code: 1, stdout: "", stderr: "orca: runtime not reachable" }],
      text: /orchestration run-create exit=1 orca: runtime not reachable/,
      calls: 1,
    },
    {
      host: "orca",
      responses: [orcaRun(), { code: 1, stdout: "", stderr: "selector_not_found" }],
      text: /terminal create exit=1 selector_not_found/,
      calls: 2,
    },
    {
      host: "orca",
      // worker-start fails: the terminal made before it is closed again (close, then show says gone)
      responses: [orcaRun(), orcaTerminal("term_f"), { code: 1, stdout: "", stderr: "Terminal does not belong to worktree" }, ok(), { code: 1, stdout: "", stderr: "" }],
      text: /worker-start exit=1 Terminal does not belong to worktree/,
      calls: 5,
      closed: "term_f",
    },
    {
      host: "orca",
      responses: [{ code: 124, stdout: "", stderr: "" }],
      text: /run-create exit=124 \(timed out after 10s\)/,
      calls: 1,
    },
    {
      host: "herdr",
      responses: [herdrWorkspace(), { code: 1, stdout: "", stderr: "pane not found" }, ok()],
      text: /herdr pane run exit=1 pane not found/,
      calls: 3,
      closed: "w2",
    },
    {
      host: "herdr",
      responses: [herdrWorkspace(), ok(), ok(), { code: 124, stdout: "", stderr: "timeout" }, ok()],
      text: /herdr agent prompt exit=124 \(timed out after 60s\) timeout/,
      calls: 5,
      closed: "w2",
    },
    {
      host: "herdr",
      // the first turn never ends: the spec is not sent, the pane is closed again
      responses: [herdrWorkspace(), ok(), { code: 124, stdout: "", stderr: "" }, ok()],
      text: /herdr agent wait exit=124 \(timed out after 120s\)/,
      calls: 4,
      closed: "w2",
    },
  ];
  for (const c of cases) {
    const t = setup({ host: c.host, responses: c.responses });
    assert.equal(await t.run(START), 1, JSON.stringify(c));
    assert.match(t.err.join("\n"), c.text);
    assert.equal(t.calls.length, c.calls, `${c.host}: ${JSON.stringify(t.calls)}`);
    if (c.closed) assert.ok(t.calls.some((call) => call.includes("close") && call.includes(c.closed)), `closed ${c.closed}: ${JSON.stringify(t.calls)}`);
    assert.equal(existsSync(t.recordFile), false, "no half-recorded follow-up");
    assert.equal(existsSync(t.worktree), false, "the worktree is removed again");
    assert.equal(t.out.length, 0, "no id printed");
  }
});

test("followup start refuses an existing _followup with uncommitted changes, naming it and the commit-or-discard remedy, and keeps its work", async () => {
  const t = setup({ responses: [orcaRun(), orcaTerminal(), ok()] });
  assert.equal(await t.run(START), 0, t.err.join("\n"));
  writeFileSync(join(t.worktree, "wip.txt"), "uncommitted\n");
  // the first follow-up finished, so nothing but the worktree's own state stops a second start
  writeFileSync(t.recordFile, JSON.stringify({ ...t.record(), state: "done" }));
  t.calls.length = 0;
  t.err.length = 0;
  t.out.length = 0;

  assert.equal(await t.run(START), 1);
  const text = t.err.join("\n");
  assert.ok(text.includes(t.worktree), `names the path: ${text}`);
  assert.match(text, /commit or discard them/);
  assert.equal(readFileSync(join(t.worktree, "wip.txt"), "utf8"), "uncommitted\n", "the follow-up's work is untouched");
  assert.equal(t.calls.length, 0, "no host call");
  assert.equal(t.out.length, 0);
  assert.equal(t.record().state, "done", "the record is unchanged");
});

test("followup start replaces a clean _followup left by a finished follow-up", async () => {
  const t = setup({ responses: [orcaRun("run_1"), orcaTerminal(), ok(), orcaRun("run_2"), orcaTerminal(), ok()] });
  assert.equal(await t.run(START), 0, t.err.join("\n"));
  writeFileSync(t.recordFile, JSON.stringify({ ...t.record(), state: "done" }));
  assert.equal(await t.run(START), 0, t.err.join("\n"));
  assert.equal(t.record().runId, "run_2");
});

test("a failed host call leaves no env.sh behind: the launch script stays, the credentials file is deleted", async () => {
  for (const [host, responses] of [
    ["orca", [orcaRun(), { code: 1, stdout: "", stderr: "selector_not_found" }]],
    ["herdr", [herdrWorkspace(), { code: 1, stdout: "", stderr: "pane not found" }, ok()]],
  ]) {
    const t = setup({ host, responses });
    assert.equal(await t.run(START), 1);
    const dir = join(t.mainRoot, ".scratch", "demo", "followup");
    const files = readdirSync(dir).flatMap((id) => readdirSync(join(dir, id)));
    assert.deepEqual(files, ["launch.sh"], `${host}: only the script remains`);
  }
});

// ─── wait and reply ────────────────────────────────────────────────────────────────────────

/** A started orca follow-up. */
async function startedOrca(extra = []) {
  const t = setup({ responses: [orcaRun("run_1"), orcaTerminal("term_f"), ok(), ...extra] });
  assert.equal(await t.run(START), 0, t.err.join("\n"));
  const id = t.out.shift();
  t.calls.length = 0;
  return { t, id };
}

test("followup wait (orca) returns a question distinct from a final result, followup reply answers it, and the next wait returns the worker_done", async () => {
  const { t, id } = await startedOrca([
    orcaInbox(orcaMessage({ id: "msg_q", type: "question", sequence: 3, body: "which package?" })),
    ok(), // orchestration reply
    orcaInbox(
      orcaMessage({ id: "msg_q", type: "question", sequence: 3, body: "which package?" }),
      orcaMessage({ id: "msg_d", type: "worker_done", sequence: 5, body: "fixed 3 findings, committed abc123" }),
    ),
    orcaInbox(orcaMessage({ id: "msg_d", type: "worker_done", sequence: 5, body: "fixed 3 findings, committed abc123" })),
  ]);

  assert.equal(await t.run({ action: "wait", id }), 0, t.err.join("\n"));
  assert.deepEqual(t.out, ["QUESTION: which package?"]);
  assert.deepEqual(t.calls[0], ["orca", "orchestration", "inbox", "--limit", "200", "--json"]);
  assert.deepEqual(t.record().pending, { messageId: "msg_q", text: "which package?" });
  assert.equal(t.record().state, "open");

  t.out.length = 0;
  assert.equal(await t.run({ action: "reply", id, answer: "orchestrator" }), 0, t.err.join("\n"));
  assert.deepEqual(t.calls[1], ["orca", "orchestration", "reply", "--id", "msg_q", "--body", "orchestrator", "--run", "run_1", "--from", "term_watch", "--json"]);
  assert.equal(t.record().pending, null);
  assert.deepEqual(t.record().answered, ["msg_q"]);

  // the answered question is not returned again; the worker_done (last word) is
  assert.equal(await t.run({ action: "wait", id }), 0, t.err.join("\n"));
  assert.deepEqual(t.out, ["DONE: fixed 3 findings, committed abc123"]);
  assert.equal(t.record().state, "done");
  assert.equal(t.record().result, "fixed 3 findings, committed abc123");

  // read back later; and the finished follow-up no longer blocks a new one
  t.out.length = 0;
  assert.equal(await t.run({ action: "wait", id }), 0);
  assert.deepEqual(t.out, ["DONE: fixed 3 findings, committed abc123"]);
});

test("followup wait (orca) polls the inbox until the worker's message arrives, ignoring other runs' and other recipients' messages", async () => {
  const { t, id } = await startedOrca([
    orcaInbox(),
    orcaInbox(orcaMessage({ id: "m1", type: "worker_done", to_handle: "run:run_other", body: "someone else's" }), orcaMessage({ id: "m2", type: "status", body: "progress" })),
    orcaInbox(orcaMessage({ id: "m3", type: "worker_done", sequence: 9, body: "all done" })),
  ]);
  assert.equal(await t.run({ action: "wait", id }), 0, t.err.join("\n"));
  assert.equal(t.calls.length, 3);
  assert.deepEqual(t.out, ["DONE: all done"]);
});

test("followup reply with no open question exits 1 under orca, without calling the host", async () => {
  const { t, id } = await startedOrca();
  assert.equal(await t.run({ action: "reply", id, answer: "yes" }), 1);
  assert.match(t.err.join("\n"), /no open question/);
  assert.equal(t.calls.length, 0);
});

test("followup wait exits non-zero with the host's own error text when the host call fails, changing nothing recorded", async () => {
  const { t, id } = await startedOrca([{ code: 1, stdout: "", stderr: "orca: inbox unavailable" }]);
  const before = readFileSync(t.recordFile, "utf8");
  assert.equal(await t.run({ action: "wait", id }), 1);
  assert.match(t.err.join("\n"), /orchestration inbox exit=1 orca: inbox unavailable/);
  assert.equal(readFileSync(t.recordFile, "utf8"), before);
});

test("followup wait and reply for an unknown id exit 1", async () => {
  const t = setup({});
  for (const o of [{ action: "wait", id: "nope" }, { action: "reply", id: "nope", answer: "x" }]) {
    t.err.length = 0;
    assert.equal(await t.run(o), 1);
    assert.match(t.err.join("\n"), /no follow-up nope/);
  }
});

test("followup wait (herdr) waits for done, idle or blocked, then returns the last QUESTION:/DONE: line of the recent text", async () => {
  const t = setup({
    host: "herdr",
    responses: [
      herdrWorkspace("w2:p1"),
      ok(), // pane run
      ok(), // agent wait: the first turn ends
      ok(), // agent prompt: the spec
      ok(), // agent wait
      { code: 0, stdout: "⏺ Looking at the findings.\nDONE: old result\nmore work\n⏺ QUESTION: keep the old API?\n\n  ⏵⏵ bypass permissions on\n", stderr: "" },
      ok(), // agent prompt (reply)
      ok(), // agent wait
      { code: 0, stdout: "QUESTION: keep the old API?\n> yes\n⏺ DONE: kept the old API; committed 9f2e\n", stderr: "" },
    ],
  });
  assert.equal(await t.run(START), 0, t.err.join("\n"));
  const id = t.out.shift();
  t.calls.length = 0;

  assert.equal(await t.run({ action: "wait", id }), 0, t.err.join("\n"));
  assert.deepEqual(t.calls[0], ["herdr", "agent", "wait", "w2:p1", "--until", "done", "--until", "idle", "--until", "blocked"]);
  assert.deepEqual(t.calls[1].slice(0, 6), ["herdr", "agent", "read", "w2:p1", "--source", "recent-unwrapped"]);
  assert.deepEqual(t.out, ["QUESTION: keep the old API?"]);

  t.out.length = 0;
  assert.equal(await t.run({ action: "reply", id, answer: "yes" }), 0, t.err.join("\n"));
  assert.deepEqual(t.calls[2].slice(0, 5), ["herdr", "agent", "prompt", "w2:p1", "yes"]);
  assert.deepEqual(t.calls[2].slice(5, 8), ["--wait", "--until", "working"]);

  assert.equal(await t.run({ action: "wait", id }), 0, t.err.join("\n"));
  assert.deepEqual(t.out, ["DONE: kept the old API; committed 9f2e"]);
  assert.equal(t.record().state, "done");
});

test("followup wait (herdr) exits non-zero showing the pane's tail when a turn ended with neither marker", async () => {
  const t = setup({ host: "herdr", responses: [herdrWorkspace(), ok(), ok(), ok(), ok(), { code: 0, stdout: "I did some things.\n", stderr: "" }] });
  assert.equal(await t.run(START), 0, t.err.join("\n"));
  const id = t.out.shift();
  assert.equal(await t.run({ action: "wait", id }), 1);
  assert.match(t.err.join("\n"), /no QUESTION:\/DONE: line[\s\S]*I did some things\./);
  assert.equal(t.record().state, "open");
});

// ─── a later run takes the branch back ─────────────────────────────────────────────────────

test("a later run's checkout of the feature branch removes a clean _followup before taking the branch", async () => {
  const t = setup({ responses: [orcaRun(), orcaTerminal(), ok()] });
  assert.equal(await t.run(START), 0, t.err.join("\n"));
  assert.ok(existsSync(t.worktree));

  const wt = ensureWorktree(t.effects, {
    mainRoot: t.mainRoot,
    branch: "feature/demo",
    base: "main",
    mode: "checkout",
    path: featureWorktreePath(t.mainRoot, "demo"),
  });
  assert.equal(wt.stale, undefined, wt.reason);
  assert.equal(wt.created, true);
  assert.equal(existsSync(t.worktree), false, "_followup is gone");
  assert.equal(t.git("-C", wt.path, "branch", "--show-current").trim(), "feature/demo");
  assert.equal(t.git("worktree", "list", "--porcelain").includes("_followup"), false);
});

test("a later run refuses a dirty _followup with the commit-or-discard message and keeps it", async () => {
  const t = setup({ responses: [orcaRun(), orcaTerminal(), ok()] });
  assert.equal(await t.run(START), 0, t.err.join("\n"));
  writeFileSync(join(t.worktree, "wip.txt"), "uncommitted\n");

  const wt = ensureWorktree(t.effects, {
    mainRoot: t.mainRoot,
    branch: "feature/demo",
    base: "main",
    mode: "checkout",
    path: featureWorktreePath(t.mainRoot, "demo"),
  });
  assert.equal(wt.stale, true);
  assert.match(wt.reason, /checked out by another worktree at .*_followup.* with uncommitted changes; commit or discard them/);
  assert.ok(existsSync(join(t.worktree, "wip.txt")), "the follow-up's work is untouched");
});

// ─── the crew-afk command ──────────────────────────────────────────────────────────────────

import { spawnSync } from "node:child_process";
const MAIN = join(import.meta.dirname, "../../orchestrator/main.mjs");

test("`crew-afk followup <action>` with no pane host exits 1 saying follow-ups need orca or herdr, whatever the action", () => {
  const root = mkdtempSync(join(tmpdir(), "crew-followup-cli-"));
  execFileSync("git", ["-C", root, "init", "-q", "-b", "main"]);
  const env = { ...process.env, CREW_PANE_HOST: "none" };
  for (const args of [
    ["start", "demo", "fix the findings"],
    ["wait", "demo-fu-1"],
    ["reply", "demo-fu-1", "yes, keep it"],
    [],
  ]) {
    const r = spawnSync("node", [MAIN, "followup", ...args, "--platform", "claude"], { cwd: root, env, encoding: "utf8" });
    assert.equal(r.status, 1, `${args[0]}: ${r.stdout}${r.stderr}`);
    assert.match(r.stderr, /follow-ups need orca or herdr/);
    assert.doesNotMatch(r.stderr, /unrecognized argument/, "the task and the answer are positional, not unknown arguments");
  }
});
