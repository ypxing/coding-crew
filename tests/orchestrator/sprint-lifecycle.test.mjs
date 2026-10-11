/**
 * Sprint suite — a run end to end: pane-host choice, plan, a clean issue, how a run ends and what its summary says, async verify.
 * Shared helpers: ./helpers/sprint.mjs.
 */

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cpSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { REPO, MAIN, TMPDIR, SCRIPTS, INSTALL_DIR, FAKE, EMPTY_HOME, sh, sprintEnv, FIXTURE_ROOTS, fixtureRepo, addIssue, BRANCH_REVIEW, runSprint, traceLog, state, fake, privateScripts, failFirstCall, commandLines, sprintReport, test } from "./helpers/sprint.mjs";

// Spawned directly, not through sh(): sh() strips both vars, which is exactly what this
// test needs set. `plan`, so no orca is ever called.
test("HERDR_ENV and ORCA_ENV both set: orca, with a notice", () => {
  const root = fixtureRepo();
  const env = { ...process.env, HOME: EMPTY_HOME, HERDR_ENV: "1", ORCA_ENV: "1", HERDR_PANE_ID: "", ORCA_TERMINAL_HANDLE: "", CREW_SCRIPTS: SCRIPTS, CREW_FAKE_DISPATCH: FAKE };
  delete env.CREW_PANE_HOST;
  const r = spawnSync("node", [MAIN, "plan", "--platform", "pi", "--feature-slug", "demo"], { cwd: root, encoding: "utf8", env });
  assert.match(r.stderr, /ORCA_ENV=1 and HERDR_ENV=1 are both set — using orca/);
  assert.match(r.stdout, /pane host: orca {2}\[ORCA_ENV\]/);
});

test("run names the resolved pane host before anything else it does", () => {
  const root = fixtureRepo();
  const r = sh("node", [MAIN, "run", "--dry-run", "--platform", "pi", "--feature-slug", "demo"], {
    cwd: root,
    env: { ...process.env, CREW_SCRIPTS: SCRIPTS, CREW_FAKE_DISPATCH: FAKE },
  });
  assert.match(r.stderr, /^PANE-HOST: none$/m);
});

// A repo can hold installs for several platforms, but only its own has pi's or codex's
// dispatcher. The first install found used to win whatever --platform said, so a codex
// sprint in a repo also installed for pi ran .pi/…/dispatch-codex-agent.sh, which isn't there.
test("the running platform's own install supplies the scripts dir, not whichever is found first", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const dirs = { pi: ".pi/skills", codex: ".agents/skills", claude: ".claude/skills", copilot: ".github/skills" };
  for (const d of Object.values(dirs)) cpSync(SCRIPTS, join(root, d, "crew-afk/scripts"), { recursive: true });
  const home = mkdtempSync(join(TMPDIR, "crew-home-"));
  for (const [platform, d] of Object.entries(dirs)) {
    const r = sh("node", [MAIN, "plan", "--platform", platform], { cwd: root, env: { ...process.env, HOME: home, CREW_SCRIPTS: "" } });
    assert.equal(r.code, 0, r.stderr);
    assert.match(r.stdout, new RegExp(`^scripts: +${join(root, d, "crew-afk/scripts").replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}$`, "m"), platform);
  }
});

test("plan lists dispatchable issues and changes nothing", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-parked.md", { status: "deferred-findings" });
  addIssue(root, "03-blocked.md", { blockedBy: ["01-alpha.md"] });
  const r = sh("node", [MAIN, "plan", "--platform", "pi"], {
    cwd: root,
    env: { ...process.env, CREW_SCRIPTS: SCRIPTS, CREW_FAKE_DISPATCH: FAKE },
  });
  assert.equal(r.code, 0, r.stderr);
  assert.match(r.stdout, /dispatchable now \(1\):/);
  assert.match(r.stdout, /- alpha/);
  assert.match(r.stdout, /parked fix issues \(1\): parked/);
  assert.doesNotMatch(r.stdout, /- blocked/);
  assert.equal(existsSync(join(root, ".scratch/demo/sprint-state.json")), false);
});

test("a clean issue is verified, reviewed, merged and closed", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const s = state(root);
  assert.deepEqual(s.completed_slugs, ["alpha"]);
  assert.deepEqual(s.merged_branches, ["crew/demo/alpha"]);
  assert.equal(existsSync(join(root, ".scratch/demo/issues/done/01-alpha.md")), true);
  assert.equal(existsSync(join(root, ".scratch/demo/issues/open/01-alpha.md")), false);
  // The gate receipts both exist and the sprint ends cleanly.
  assert.equal(existsSync(join(root, ".scratch/demo/dispatch/01-alpha/verify.json")), true);
  assert.equal(existsSync(join(root, ".scratch/demo/dispatch/01-alpha/ac.ok")), true);
  assert.match(r.stdout, /NO MORE TASKS/);
  // Why it ended, for the next run's summary.
  assert.deepEqual([s.last_exit.run, s.last_exit.reason, s.last_exit.code], [s.current_run, "finished", 0]);
  // The reviewer was handed the verification result, so a criterion that ends "and the
  // tests pass" is answerable by the read-only reviewer instead of stalling the branch.
  const reviewPromptText = readFileSync(join(root, ".scratch/demo/dispatch/01-alpha/review-prompt.md"), "utf8");
  assert.match(reviewPromptText, /Checks already run by the pipeline/);
  assert.match(reviewPromptText, /test=pass/);
  // The install this run resolved, once — the reviewer never searches for its assets.
  assert.ok(reviewPromptText.includes(`Review assets: ${join(INSTALL_DIR, "crew-afk/roles/reviewer")}\n`), reviewPromptText);
  // Nor the coder for the project's config, which its worktree does not hold.
  const coderPromptText = readFileSync(join(root, ".scratch/demo/dispatch/01-alpha/prompt.md"), "utf8");
  assert.ok(coderPromptText.includes(`Project config: ${join(root, ".coding-crew")} `), coderPromptText);
});

test("a run that stops at its per-issue attempt cap records `attempt cap` as why it ended, not `finished`", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.review-once", "2");
  const r = runSprint(root, ["--max-rounds", "1"]);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(traceLog(root), /Round cap reached/);
  const s = state(root);
  assert.deepEqual([s.last_exit.run, s.last_exit.reason], [s.current_run, "attempt cap"]);
});

test("a run ended by SIGTERM after run-start records `signal SIGTERM` as why it ended, not killed or crashed", async () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.worker-sleep", "30");
  const { spawn } = await import("node:child_process");
  const child = spawn("node", [MAIN, "run", "--platform", "pi", "--feature-slug", "demo", "--no-baseline", "--no-integration-check"], {
    cwd: root,
    env: sprintEnv({ ...process.env, CREW_SCRIPTS: SCRIPTS, CREW_FAKE_DISPATCH: FAKE, CREW_FAKE_DIR: join(root, ".scratch/fake"), MAIN_ROOT: root }),
    stdio: "ignore",
  });
  const exited = new Promise((res) => child.on("exit", (code) => res(code)));
  // The worker is asleep once its counter exists: run-start is long past.
  const calls = join(root, ".scratch/fake/alpha.worker-sleep.calls");
  for (let i = 0; i < 300 && !existsSync(calls); i++) await new Promise((res) => setTimeout(res, 100));
  assert.ok(existsSync(calls), "the worker never started");
  child.kill("SIGTERM");
  assert.equal(await exited, 143);
  const s = state(root);
  assert.deepEqual([s.last_exit.run, s.last_exit.reason, s.last_exit.code], [s.current_run, "signal SIGTERM", 143]);
});

test("openPr off, something merged, local tracker: the summary ends with ## Next naming gh pr create and --open-pr", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.deepEqual(state(root).completed_slugs, ["alpha"]);
  const next = r.stdout.slice(r.stdout.lastIndexOf("\n## Next\n") + 1);
  assert.match(next, /^## Next\n/);
  assert.match(next, /gh pr create --head feature\/demo --title demo/);
  assert.match(next, /--open-pr/);
  assert.match(next, /afk\.openPr/);
  assert.doesNotMatch(next, /Closes #/, "a local tracker has no closing lines");
  assert.match(next, /NO MORE TASKS\s*$/);
});

test("openPr off and nothing merged: no ## Next section", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.nocommit");
  fake(
    root,
    "alpha.worker",
    ['## Issue: alpha', 'Status: complete', '', '```json', '{"status":"complete","checks":{"test":"fail","lint":"pass","typecheck":"pass"},"progress":"tests red"}', '```'].join("\n"),
  );
  const r = runSprint(root);
  assert.equal(r.code, 2, "the issue spends its retries and stays blocked");
  assert.deepEqual(state(root).merged_branches ?? [], []);
  assert.doesNotMatch(r.stdout, /^## Next$/m);
});

test("a local run stalled on a ready-for-human issue names its file and title under ## Waiting on a person", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-vendor.md", { status: "ready-for-human" });
  const r = runSprint(root);
  assert.match(r.stdout, /^## Waiting on a person\n\n- 02-vendor\.md vendor\n\nWhen they are done \(cli\.mjs mark-done\), re-run: \/crew-afk demo$/m, `${r.stdout}\n${r.stderr}`);
  assert.doesNotMatch(r.stdout, /- 01-alpha\.md/);
  assert.ok(r.stdout.indexOf("NO MORE TASKS") > r.stdout.indexOf("## Waiting on a person"));
});

test("a run stalled only by a blocked ready-for-agent issue prints no ## Waiting on a person", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.nocommit");
  fake(
    root,
    "alpha.worker",
    ['## Issue: alpha', 'Status: complete', '', '```json', '{"status":"complete","checks":{"test":"fail","lint":"pass","typecheck":"pass"},"progress":"tests red"}', '```'].join("\n"),
  );
  const r = runSprint(root);
  assert.equal(r.code, 2, `${r.stdout}\n${r.stderr}`);
  assert.doesNotMatch(r.stdout, /Waiting on a person/);
});

test("a local run that finishes without stalling prints no ## Waiting on a person", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.doesNotMatch(r.stdout, /Waiting on a person/);
});

test("a run whose install is missing an asset stops before any dispatch, naming the path", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const partial = mkdtempSync(join(TMPDIR, "crew-install-"));
  FIXTURE_ROOTS.push(partial);
  cpSync(join(INSTALL_DIR, "dep-install"), join(partial, "dep-install"), { recursive: true });
  cpSync(join(INSTALL_DIR, "solve-issue"), join(partial, "solve-issue"), { recursive: true });
  cpSync(join(INSTALL_DIR, "to-issues"), join(partial, "to-issues"), { recursive: true });
  const r = runSprint(root, [], { CREW_INSTALL_DIR: partial });
  assert.equal(r.code, 1, `${r.stdout}\n${r.stderr}`);
  assert.ok(r.stderr.includes(`reviewer: ${join(partial, "crew-afk/roles/reviewer/scripts/review-context.sh")}`), r.stderr);
  assert.match(r.stderr, /Re-run install\.sh/);
  assert.doesNotMatch(r.stderr, /depInstall:|solveIssue:/);
  assert.equal(existsSync(join(root, ".scratch/demo/dispatch")), false, "nothing was dispatched");
});

// ─── verify runs asynchronously ───────────────────────────────────────────────
//
// verify-worktree.sh runs the project's whole test suite. Run through spawnSync it froze the
// event loop: one verify at a time across every worker loop, and no coder dispatched meanwhile.

/** A verify-worktree.sh that records start/end (ms) per stem to <log>, sleeps <slow[stem]> s, then runs the real one. */
function timedVerify(scripts, log, secondsFor) {
  const real = join(scripts, "_real-verify-worktree.sh");
  cpSync(join(scripts, "verify-worktree.sh"), real);
  const cases = Object.entries(secondsFor).map(([stem, s]) => `  *${stem}*) SLEEP=${s} ;;`).join("\n");
  writeFileSync(
    join(scripts, "verify-worktree.sh"),
    [
      "#!/usr/bin/env bash",
      'now() { node -p "Date.now()"; }',
      "SLEEP=0",
      'case " $* " in',
      cases,
      "esac",
      'STEM=$(echo "$*" | sed -E "s/.*--stem ([^ ]+).*/\\1/")',
      `echo "verify-start $STEM $(now)" >> ${JSON.stringify(log)}`,
      'sleep "$SLEEP"',
      `echo "verify-end $STEM $(now)" >> ${JSON.stringify(log)}`,
      `exec bash ${JSON.stringify(real)} "$@"`,
      "",
    ].join("\n"),
  );
}

/** A dispatch wrapper that records when each coder is dispatched, then behaves as the fake. */
function timedDispatch(dir, log) {
  const f = join(dir, "timed-dispatch.sh");
  writeFileSync(
    f,
    [
      "#!/usr/bin/env bash",
      'case " $* " in *" --agent crew-coder "*)',
      '  SLUG=$(echo "$*" | sed -E "s/.*--slug ([^ ]+).*/\\1/")',
      `  echo "coder-start $SLUG $(node -p "Date.now()")" >> ${JSON.stringify(log)} ;;`,
      "esac",
      `exec bash ${JSON.stringify(FAKE)} "$@"`,
      "",
    ].join("\n"),
  );
  return f;
}

const readTimes = (log) =>
  Object.fromEntries(
    readFileSync(log, "utf8").trim().split("\n").map((l) => {
      const [what, stem, ms] = l.split(" ");
      return [`${what} ${stem.replace(/^\d+-/, "")}`, Number(ms)];
    }),
  );

test("two branches whose coders finish together are verified concurrently", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-beta.md");
  const scripts = privateScripts();
  const log = join(root, "times.log");
  timedVerify(scripts, log, { alpha: 2, beta: 2 });
  const { r } = commandLines(root, ["--max-parallel", "2"], { scripts });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.deepEqual(state(root).completed_slugs.sort(), ["alpha", "beta"]);
  const t = readTimes(log);
  assert.ok(t["verify-start beta"] < t["verify-end alpha"], "beta's verify only started after alpha's ended: the verifies were serialized");
  assert.ok(t["verify-start alpha"] < t["verify-end beta"], "alpha's verify did not overlap beta's");
});

test("a slow verify does not delay dispatching another ready issue into a free slot", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-beta.md");
  addIssue(root, "03-gamma.md");
  const scripts = privateScripts();
  const log = join(root, "times.log");
  timedVerify(scripts, log, { alpha: 5 });
  const dispatcher = timedDispatch(root, log);
  const { r } = commandLines(root, ["--max-parallel", "2"], { scripts, env: { CREW_FAKE_DISPATCH: dispatcher } });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.deepEqual(state(root).completed_slugs.sort(), ["alpha", "beta", "gamma"]);
  const t = readTimes(log);
  assert.ok(t["coder-start gamma"] < t["verify-end alpha"], "gamma waited for alpha's slow verify before its coder was dispatched");
});

test("merges stay serialized while verifies overlap", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-beta.md");
  const scripts = privateScripts();
  timedVerify(scripts, join(root, "times.log"), { alpha: 1, beta: 1 });
  const { r, lines } = commandLines(root, ["--max-parallel", "2"], { scripts });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  // Every merge is one blocking effect whose own RUN line follows its checkout directly: no
  // other command is interleaved between a merge's checkout and its close.
  const merges = lines.filter((l) => /merge-branches\.sh/.test(l));
  assert.equal(merges.length, 2);
  const at = (re) => lines.map((l, i) => (re.test(l) ? i : -1)).filter((i) => i >= 0);
  const [m1, m2] = at(/merge-branches\.sh/);
  const closes = at(/close-issue\.sh/);
  assert.ok(m1 < closes[0] && closes[0] < m2, `merge/close pairs interleaved:\n${lines.join("\n")}`);
  assert.deepEqual(state(root).merged_branches.sort(), ["crew/demo/alpha", "crew/demo/beta"]);
});

test("the branch review prompt judges criteria only: no PRD decisions block, even for an issue whose ## Implements names a PRD line", () => {
  const root = fixtureRepo();
  writeFileSync(join(root, ".scratch/demo/PRD.md"), "# PRD\n\n- **D2** — **Adapters.** one per CLI\n");
  addIssue(root, "01-alpha.md", { body: "## Implements\n\nD2" });
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const prompt = readFileSync(join(root, ".scratch/demo/dispatch/01-alpha/review-prompt.md"), "utf8");
  assert.match(prompt, /^Acceptance criteria:$/m);
  assert.doesNotMatch(prompt, /PRD decisions/);
  assert.doesNotMatch(prompt, /Adapters/);
});

test("the branch review prompt names the PRD file on a `PRD:` line when there is one, and has no such line otherwise", () => {
  const withPrd = fixtureRepo();
  writeFileSync(join(withPrd, ".scratch/demo/PRD.md"), "# PRD\n");
  addIssue(withPrd, "01-alpha.md");
  let r = runSprint(withPrd);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const prompt = readFileSync(join(withPrd, ".scratch/demo/dispatch/01-alpha/review-prompt.md"), "utf8");
  assert.ok(prompt.split("\n").includes(`PRD: ${join(withPrd, ".scratch/demo/PRD.md")}`), prompt);

  const without = fixtureRepo();
  addIssue(without, "01-alpha.md");
  r = runSprint(without);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.doesNotMatch(readFileSync(join(without, ".scratch/demo/dispatch/01-alpha/review-prompt.md"), "utf8"), /^PRD: /m);
});
