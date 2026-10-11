/**
 * Sprint suite — a run under a pane host: the feature agent, the _feature worktree, and the end-of-run push.
 * Shared helpers: ./helpers/sprint.mjs.
 */

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cpSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { REPO, MAIN, TMPDIR, SCRIPTS, INSTALL_DIR, FAKE, EMPTY_HOME, sh, sprintEnv, FIXTURE_ROOTS, fixtureRepo, addIssue, BRANCH_REVIEW, runSprint, traceLog, state, fake, privateScripts, failFirstCall, commandLines, sprintReport, test } from "./helpers/sprint.mjs";

// A run under a pane host: `herdr` and `pi` stubs on PATH, the first logging every call and
// answering what crew-afk reads from it. Spawned directly, since sh() strips the pane-host env.
// The sprint's workspace is w5 (`worktree open`); the log tab and the agent's tab are made in it,
// the agent's pane being w9:pl. `agentPromptExit` / `paneRunExit` make the end push or the agent's
// start fail; `agentStatus: "gone"` drops the agent's pane from the host's list (a dead one), "unknown"
// lists it with no agent detected yet (a CLI still starting, which a run's end keeps).
function herdrEnv(root, { agentPromptExit = 0, paneRunExit = 0, agentStatus = "idle" } = {}) {
  const bin = mkdtempSync(join(TMPDIR, "crew-fake-herdr-"));
  FIXTURE_ROOTS.push(bin);
  const log = join(bin, "calls.log");
  const reply = (obj) => `printf '%s\\n' '${JSON.stringify(obj)}'`;
  writeFileSync(
    join(bin, "herdr"),
    [
      "#!/bin/sh",
      `printf '%s\\n' "$*" >> '${log}'`,
      'case "$1 $2" in',
      `  "workspace create") ${reply({ result: { workspace: { workspace_id: "w9" }, root_pane: { pane_id: "w9:p1" } } })};;`,
      `  "worktree open") ${reply({ result: { already_open: false, workspace: { workspace_id: "w5" }, root_pane: { pane_id: "w5:p1" } } })};;`,
      `  "tab create") ${reply({ result: { tab: { tab_id: "w5:t" }, root_pane: { pane_id: "w9:pl" } } })};;`,
      `  "pane list") ${reply({ result: { panes: [{ pane_id: "w9:p1", agent_status: "idle" }, ...(agentStatus === "gone" ? [] : [{ pane_id: "w9:pl", agent_status: agentStatus }])] } })};;`,
      `  "pane run") [ "$3" = "w9:pl" ] && case "$4" in tail) ;; *) exit ${paneRunExit};; esac;;`,
      `  "agent prompt") exit ${agentPromptExit};;`,
      "esac",
      '[ "$1" = status ] && echo "status: running"',
      "exit 0",
      "",
    ].join("\n"),
    { mode: 0o755 },
  );
  writeFileSync(join(bin, "pi"), "#!/bin/sh\nexit 0\n", { mode: 0o755 });
  const env = sprintEnv({
    ...process.env,
    PATH: `${bin}:${process.env.PATH}`,
    CREW_SCRIPTS: SCRIPTS,
    CREW_FAKE_DISPATCH: FAKE,
    CREW_FAKE_DIR: join(root, ".scratch/fake"),
    MAIN_ROOT: root,
    HERDR_PANE_ID: "trigger:p9",
  });
  env.CREW_PANE_HOST = "herdr";
  return { env, calls: () => (existsSync(log) ? readFileSync(log, "utf8").split("\n").filter(Boolean) : []) };
}

/** `slug: null` passes no --feature-slug; `cwd` is where the run is launched from. */
function herdrRun(root, extraArgs = [], { cwd = root, slug = "demo", ...hostOpts } = {}) {
  const host = herdrEnv(root, hostOpts);
  const slugArgs = slug ? ["--feature-slug", slug] : [];
  const r = spawnSync("node", [MAIN, "run", "--platform", "pi", ...slugArgs, "--no-baseline", "--no-integration-check", ...extraArgs], { cwd, encoding: "utf8", env: host.env });
  return { code: r.status, stdout: r.stdout ?? "", stderr: r.stderr ?? "", calls: host.calls() };
}

const featureWt = (root) => join(root, ".scratch/worktrees/crew/demo/_feature");
const summaryOf = (root) => {
  const traces = join(root, ".scratch/demo/traces");
  const [name] = readdirSync(traces).filter((f) => /^summary-.*\.md$/.test(f));
  return name ? join(traces, name) : null;
};
const worktreeListed = (root, path) => sh("git", ["-C", root, "worktree", "list", "--porcelain"]).stdout.includes(`worktree ${path}\n`);

test("under a pane host the run opens the feature agent in _feature, keeps _feature, and stdout ends with one pointer line", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const r = herdrRun(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.deepEqual(JSON.parse(readFileSync(join(root, ".scratch/demo/watch.json"), "utf8")), { host: "herdr", handle: "w9:pl" });
  // Both tabs open in the feature worktree's workspace (w5) with cwd _feature, never the triggering one.
  assert.ok(r.calls.some((c) => c.startsWith(`worktree open --path ${featureWt(root)} `)), r.calls.join("\n"));
  const tabs = r.calls.filter((c) => c.startsWith("tab create "));
  assert.equal(tabs.length, 2, tabs.join("\n"));
  for (const t of tabs) assert.match(t, new RegExp(`^tab create --workspace w5 --cwd ${featureWt(root)} `));
  assert.ok(r.calls.find((c) => c.startsWith("pane run w9:pl ")), r.calls.join("\n"));
  // The summary file holds everything ctx.out printed, under the run id with its colons replaced.
  const summary = summaryOf(root);
  assert.ok(summary, "no summary file");
  assert.match(summary, /summary-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}\.\d{3}Z\.md$/);
  assert.match(readFileSync(summary, "utf8"), /NO MORE TASKS/);
  // stdout: that text went only to the file; the run ends with a pointer at it.
  assert.doesNotMatch(r.stdout, /NO MORE TASKS/);
  assert.equal(
    r.stdout.trim().split("\n").at(-1),
    `crew-afk: summary sent to the demo agent in ${featureWt(root)} — also at ${summary}`,
  );
  // Every push, the last one included, went to the agent: never HERDR_PANE_ID.
  const prompts = r.calls.filter((c) => c.startsWith("agent prompt "));
  assert.ok(prompts.length >= 2, r.calls.join("\n"));
  assert.ok(prompts.every((c) => c.startsWith("agent prompt w9:pl ")), prompts.join("\n"));
  assert.equal(r.calls.filter((c) => c.includes("trigger:p9")).length, 0, "nothing targets the triggering pane");
  assert.ok(prompts.at(-1).includes(summary), prompts.at(-1));
  // The log tab closed; the workspace holding the agent, the agent and `_feature` did not.
  assert.deepEqual(r.calls.filter((c) => /^(workspace|tab|pane) close/.test(c)), ["tab close w5:t"]);
  assert.equal(worktreeListed(root, featureWt(root)), true);
  assert.equal(existsSync(featureWt(root)), true);
});

test("a re-run launched from inside _feature with no slug runs that feature, reuses the live agent and the worktree in place", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  assert.equal(herdrRun(root).code, 0);
  writeFileSync(join(root, ".git/info/exclude"), "keep.me\n");
  writeFileSync(join(featureWt(root), "keep.me"), "still here\n");
  addIssue(root, "02-beta.md");
  const r = herdrRun(root, [], { cwd: join(featureWt(root)), slug: null });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.deepEqual(state(root).completed_slugs.sort(), ["alpha", "beta"]);
  assert.equal(readFileSync(join(featureWt(root), "keep.me"), "utf8"), "still here\n", "_feature was reused, not recreated");
  assert.deepEqual(JSON.parse(readFileSync(join(root, ".scratch/demo/watch.json"), "utf8")), { host: "herdr", handle: "w9:pl" });
  assert.equal(r.calls.filter((c) => c.startsWith("pane run w9:pl ") && !c.includes("tail")).length, 0, "no second agent started");
  assert.equal(worktreeListed(root, featureWt(root)), true);
  // The reused agent may hold the checkout from the first run's end notice: this run says it has begun.
  const prompts = r.calls.filter((c) => c.startsWith("agent prompt w9:pl "));
  assert.match(prompts[0], /\[demo\] .*run started.*until the end notice/, prompts.join("\n"));
});

test("an explicit --feature-slug naming another feature than the _feature checkout refuses with both slugs, before taking anything", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  assert.equal(herdrRun(root).code, 0);
  const r = herdrRun(root, [], { cwd: featureWt(root), slug: "other" });
  assert.equal(r.code, 1, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stderr, /--feature-slug other/);
  assert.match(r.stderr, /'demo'/);
  assert.equal(existsSync(join(root, ".scratch/other")), false, "nothing was created for the other slug");
  assert.deepEqual(r.calls, [], "no host call");
});

test("a run that ends before ctx has no summary file, its final push carries the error's first line, and _feature is still kept", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md", { blockedBy: ["02-beta.md"] });
  addIssue(root, "02-beta.md", { blockedBy: ["01-alpha.md"] });
  const r = herdrRun(root);
  assert.equal(r.code, 1, `${r.stdout}\n${r.stderr}`);
  const traces = join(root, ".scratch/demo/traces");
  assert.deepEqual(readdirSync(traces).filter((f) => f.startsWith("summary-")), []);
  const last = r.calls.filter((c) => c.startsWith("agent prompt w9:pl ")).at(-1);
  assert.ok(last, r.calls.join("\n"));
  assert.doesNotMatch(last, /summary-/);
  assert.match(last, /sprint setup failed/);
  assert.match(last, /structural errors/);
  assert.doesNotMatch(r.stdout, /crew-afk: summary sent/);
  assert.equal(worktreeListed(root, featureWt(root)), true, "the agent is live, so its worktree stays on every ending");
});

test("an end push that did not land puts the whole summary on stdout, and _feature is still kept", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const r = herdrRun(root, [], { agentPromptExit: 1 });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const summary = summaryOf(root);
  assert.equal(r.stdout, readFileSync(summary, "utf8"));
  assert.match(r.stdout, /NO MORE TASKS/);
  assert.doesNotMatch(r.stdout, /crew-afk: summary sent/);
  assert.equal(worktreeListed(root, featureWt(root)), true);
});

test("an agent that failed to open is a WARN: exit code unchanged, no env.sh left, stdout the whole summary, _feature removed as before", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const r = herdrRun(root, [], { paneRunExit: 1 });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(traceLog(root), / WARN {2}watch session \(herdr\): .*no watch agent, pushes are skipped/);
  assert.match(r.stdout, /NO MORE TASKS/);
  assert.equal(existsSync(join(root, ".scratch/demo/watch.json")), false);
  assert.equal(existsSync(join(root, ".scratch/demo/watch/env.sh")), false);
  assert.equal(worktreeListed(root, featureWt(root)), false);
  assert.equal(existsSync(featureWt(root)), false);
});

test("a run ended by SIGTERM with a live agent leaves _feature registered and on disk, and closes neither the agent nor its workspace", async () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.worker-sleep", "30");
  const host = herdrEnv(root);
  const { spawn } = await import("node:child_process");
  const child = spawn("node", [MAIN, "run", "--platform", "pi", "--feature-slug", "demo", "--no-baseline", "--no-integration-check"], { cwd: root, env: host.env, stdio: "ignore" });
  const exited = new Promise((res) => child.on("exit", (code) => res(code)));
  const calls = join(root, ".scratch/fake/alpha.worker-sleep.calls");
  for (let i = 0; i < 300 && !existsSync(calls); i++) await new Promise((res) => setTimeout(res, 100));
  assert.ok(existsSync(calls), "the worker never started");
  child.kill("SIGTERM");
  assert.equal(await exited, 143);
  assert.equal(worktreeListed(root, featureWt(root)), true);
  assert.equal(existsSync(featureWt(root)), true);
  assert.deepEqual(host.calls().filter((c) => /^(workspace|pane) close/.test(c)), []);
});

test("an agent the host no longer reports at the end of the run is dead: _feature is removed and its workspace closed, stdout is the whole summary", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const r = herdrRun(root, [], { agentStatus: "gone" });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(worktreeListed(root, featureWt(root)), false);
  assert.equal(existsSync(featureWt(root)), false);
  assert.ok(r.calls.includes("workspace close w5"), r.calls.join("\n"));
  assert.match(r.stdout, /NO MORE TASKS/);
  assert.doesNotMatch(r.stdout, /crew-afk: summary sent/);
});

test("a run ended by SIGTERM whose agent is dead removes _feature and closes the workspace this run made", async () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.worker-sleep", "30");
  const host = herdrEnv(root, { agentStatus: "gone" });
  const { spawn } = await import("node:child_process");
  const child = spawn("node", [MAIN, "run", "--platform", "pi", "--feature-slug", "demo", "--no-baseline", "--no-integration-check"], { cwd: root, env: host.env, stdio: "ignore" });
  const exited = new Promise((res) => child.on("exit", (code) => res(code)));
  const calls = join(root, ".scratch/fake/alpha.worker-sleep.calls");
  for (let i = 0; i < 300 && !existsSync(calls); i++) await new Promise((res) => setTimeout(res, 100));
  assert.ok(existsSync(calls), "the worker never started");
  child.kill("SIGTERM");
  assert.equal(await exited, 143);
  assert.equal(worktreeListed(root, featureWt(root)), false);
  assert.equal(existsSync(featureWt(root)), false);
  assert.ok(host.calls().includes("workspace close w5"), host.calls().join("\n"));
});

test("--dry-run opens no watch agent and writes no watch.json", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const r = herdrRun(root, ["--dry-run"]);
  assert.equal(existsSync(join(root, ".scratch/demo/watch.json")), false, r.stderr);
  assert.deepEqual(r.calls.filter((c) => /^(workspace create|tab create|pane run|agent prompt)/.test(c)), []);
});
