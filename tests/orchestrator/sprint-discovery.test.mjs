/**
 * Sprint suite — one-time command discovery, and rejecting unrecognized arguments.
 * Shared helpers: ./helpers/sprint.mjs.
 */

import assert from "node:assert/strict";
import { chmodSync, cpSync, mkdirSync, mkdtempSync, readFileSync, renameSync, writeFileSync, existsSync, unlinkSync } from "node:fs";
import { join } from "node:path";
import { MAIN, TMPDIR, SCRIPTS, INSTALL_DIR, FAKE, FIXTURE_ROOTS, sh, fixtureRepo, githubFixtureRepo, stubGh, GH_ALPHA, addIssue, runSprint, traceLog, state, fake, workerReport, coderSpawns, commandLines, privateScripts, test } from "./helpers/sprint.mjs";

// ─── one-time command discovery ───────────────────────────────────────────────
//
// discover-commands.sh / write-commands-cache.sh mechanically build the prompt and persist
// the answer; the model call itself is faked here (fake-dispatch.sh's "commands-discovery"
// branch), the seam every agent-less dispatch uses for the same reason.

test("command discovery writes .coding-crew/dev-commands.json from the repo's own Makefile", () => {
  const root = fixtureRepo(); // fixtureRepo() always seeds a Makefile with test/lint/typecheck
  addIssue(root, "01-alpha.md");

  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);

  const cacheFile = join(root, ".coding-crew/dev-commands.json");
  assert.equal(existsSync(cacheFile), true);
  const cache = JSON.parse(readFileSync(cacheFile, "utf8"));
  assert.equal(cache.test, "make test");
  assert.equal(cache.lint, "make lint");
  assert.equal(cache.typecheck, "make typecheck");
  assert.equal(cache.sourceHash, undefined, "the committed cache has no sourceHash field");
  assert.deepEqual(
    Object.keys(cache).sort(),
    ["coverage", "credential_target", "env", "install", "integration", "lint", "test", "typecheck"],
  );
});

test("a CLAUDE.md that happens to contain the word 'skipped' does not silently cancel discovery", () => {
  // Regression: commands.mjs used to test /skipped/i against discover-commands.sh's *entire*
  // stdout, which is the whole prompt plus every quoted candidate file's content, not just
  // discover-commands.sh's own one-line skip message. A real AGENTS.md/CLAUDE.md quoted in
  // full (one real repo's own docs said "...because I skipped this; don't repeat the mistake.")
  // made that regex match, so the step silently returned before ever calling the model —
  // no dispatch, no commands-response.md, no commands.json, and no log line to explain why,
  // because the short-circuit fires before any of the branches that do log.
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  writeFileSync(
    join(root, "CLAUDE.md"),
    "Typecheck: `make tsc`. PR #149 shipped a bug because I skipped this; don't repeat it.\n",
  );

  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(existsSync(join(root, ".coding-crew/dev-commands.json")), true, "the word 'skipped' inside a quoted file must not cancel discovery");
  assert.doesNotMatch(r.stderr, /Command discovery: skipped/);
});

test("command discovery's own log lines survive in the trace log, not just the live terminal", () => {
  // Runs once, unattended, before any worktree exists -- a bad model response or a dispatch
  // failure here was previously visible only in whatever captured the live process's stderr.
  // No artifact was left to diagnose it from afterwards, unlike every other pipeline step.
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");

  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stderr, /Command discovery:/);
  assert.match(traceLog(root), /Command discovery:/);
});

test("command discovery's prompt goes to its own file; the log and stderr get one line naming it", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const log = traceLog(root);
  assert.doesNotMatch(`${log}\n${r.stderr}`, /command discovery prompt/);
  assert.match(log, /^\S+Z INFO  Command discovery: \d+ source file/m);
  const m = /^\S+Z DEBUG Command discovery: prompt kept at (\S+)$/m.exec(log);
  assert.ok(m, log);
  assert.match(readFileSync(join(root, m[1]), "utf8"), /command discovery prompt/);
});

test("a script's summary line echoed after its own trace line is debug; no pane host is not a warning", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const log = traceLog(root);
  assert.match(log, /^\S+Z DEBUG FLUSH: /m);
  assert.match(log, /^\S+Z DEBUG CLEANUP: /m);
  assert.doesNotMatch(r.stderr, /^(FLUSH|CLEANUP): /m);
  assert.match(log, /^\S+Z DEBUG \[MILESTONE-PUSH-SKIPPED\] 01-alpha: no pane host$/m);
  assert.doesNotMatch(r.stderr, /MILESTONE-PUSH-SKIPPED/);
});

test("command discovery is skipped, at zero cost, when there is nothing to read", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  // discover-commands.sh reads the working directory, not git history — removing the
  // Makefile here does not affect the worktree verify-worktree.sh checks out from HEAD,
  // so this isolates the discovery step from the rest of the pipeline.
  unlinkSync(join(root, "Makefile"));

  const r = runSprint(root, ["--allow-dirty"]);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(existsSync(join(root, ".coding-crew/dev-commands.json")), false);
  assert.match(r.stderr, /Command discovery: skipped/);
});

test("a second sprint reuses the cached commands instead of discovering again (bootstrap-once, no staleness re-check)", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const first = runSprint(root);
  assert.equal(first.code, 0, `${first.stdout}\n${first.stderr}`);
  const cacheAfterFirst = readFileSync(join(root, ".coding-crew/dev-commands.json"), "utf8");

  // Even a source-doc change between sprints must not trigger re-discovery: once the
  // committed cache exists, only --refresh forces a rebuild.
  writeFileSync(join(root, "Makefile"), "test:\n\t@echo totally-different-now\n");

  addIssue(root, "02-beta.md");
  const second = runSprint(root, ["--allow-dirty"]);
  assert.equal(second.code, 0, `${second.stdout}\n${second.stderr}`);
  assert.match(second.stderr, /already cached/);
  assert.equal(readFileSync(join(root, ".coding-crew/dev-commands.json"), "utf8"), cacheAfterFirst);
});

test("CREW_COMMANDS_REFRESH=1 forces rediscovery and overwrites an existing cache", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const first = runSprint(root);
  assert.equal(first.code, 0, `${first.stdout}\n${first.stderr}`);
  const cacheAfterFirst = readFileSync(join(root, ".coding-crew/dev-commands.json"), "utf8");

  writeFileSync(join(root, "Makefile"), "totally-different-now:\n\t@echo ok\nlint2:\n\t@echo ok\ntc2:\n\t@echo ok\n");
  sh("git", ["-C", root, "add", "-A"]);
  sh("git", ["-C", root, "commit", "-q", "-m", "new makefile targets"]);
  fake(
    root,
    "commands.response",
    '{"test": "make totally-different-now", "lint": "make lint2", "typecheck": "make tc2"}',
  );

  addIssue(root, "02-beta.md");
  const second = sh("node", [MAIN, "run", "--platform", "pi", "--feature-slug", "demo"], {
    cwd: root,
    env: {
      ...process.env,
      CREW_SCRIPTS: SCRIPTS,
      CREW_FAKE_DISPATCH: FAKE,
      CREW_FAKE_DIR: join(root, ".scratch/fake"),
      MAIN_ROOT: root,
      CREW_COMMANDS_REFRESH: "1",
    },
  });
  assert.equal(second.code, 0, `${second.stdout}\n${second.stderr}`);
  assert.doesNotMatch(second.stderr, /already cached/);
  const cacheAfterSecond = readFileSync(join(root, ".coding-crew/dev-commands.json"), "utf8");
  assert.notEqual(cacheAfterSecond, cacheAfterFirst);
  assert.match(cacheAfterSecond, /make totally-different-now/);
});

test("CREW_NO_COMMANDS skips command discovery entirely", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");

  const r = runSprint(root, ["--no-commands"]);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(existsSync(join(root, ".coding-crew/dev-commands.json")), false);
  assert.doesNotMatch(r.stderr, /Command discovery/);
});

test("discover-commands.sh failing outright is surfaced and does not send a broken prompt onward", () => {
  // Regression: commands.mjs used to check only the model dispatch's exit code, not
  // discover-commands.sh's own — a crash there (e.g. a candidate file going unreadable
  // mid-run) fell through into dispatching whatever partial/garbage stdout survived, as if
  // it were a real prompt, with no error left anywhere to diagnose it from. CLAUDE.md is
  // untracked and lives only in the main checkout, so making it unreadable cannot also
  // break the worktree's own git status (unlike doing the same to the tracked Makefile).
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  writeFileSync(join(root, "CLAUDE.md"), "test: npm test\n");
  chmodSync(join(root, "CLAUDE.md"), 0o000);

  const r = runSprint(root);
  chmodSync(join(root, "CLAUDE.md"), 0o644); // restore before any cleanup touches it
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`); // advisory: never fails the sprint
  assert.equal(existsSync(join(root, ".coding-crew/dev-commands.json")), false);
  assert.match(r.stderr, /Command discovery: discover-commands\.sh failed/);
});

// Regression: a bare word that is neither a recognised flag nor a .scratch/ path used to
// be forwarded unexamined through Sprint.init into session-init.sh, then into
// the retired feature-branch-setup.sh (--jira only), which died with a confusing "Unknown argument"
// two hops from where the mistake was made. It must now be rejected here, immediately,
// before any script even runs.
test("an unrecognized bare argument fails fast with the accepted forms, not two hops down", () => {
  const root = fixtureRepo();
  const r = sh("node", [MAIN, "run", "--platform", "pi", "qa-slo-emmission"], {
    cwd: root,
    env: { ...process.env, MAIN_ROOT: root },
  });
  assert.equal(r.code, 1);
  assert.match(r.stderr, /unrecognized argument: qa-slo-emmission/);
  assert.match(r.stderr, /Accepted forms: --feature-slug/);
  assert.doesNotMatch(r.stderr, /session-init\.sh/);
  assert.doesNotMatch(r.stderr, /Unknown argument/); // the retired script's own message
});

test("an unrecognized argument close to an existing .scratch/<feature-slug> dir is suggested", () => {
  const root = fixtureRepo(); // fixtureRepo() already creates .scratch/demo/
  const r = sh("node", [MAIN, "run", "--platform", "pi", "deno"], {
    cwd: root,
    env: { ...process.env, MAIN_ROOT: root },
  });
  assert.equal(r.code, 1);
  assert.match(r.stderr, /Did you mean --feature-slug demo\?/);
});

test("free-form prose fails on the first unrecognized word, still with a helpful message", () => {
  const root = fixtureRepo();
  const r = sh("node", [MAIN, "run", "--platform", "pi", "on", "issues", "under", "qa-slo-emmission"], {
    cwd: root,
    env: { ...process.env, MAIN_ROOT: root },
  });
  assert.equal(r.code, 1);
  assert.match(r.stderr, /unrecognized arguments: on issues under qa-slo-emmission/);
});

test("a legitimate --jira value is not treated as an unrecognized argument", () => {
  const root = fixtureRepo();
  const r = sh("node", [MAIN, "plan", "--platform", "pi", "--jira", "ABC-123"], {
    cwd: root,
    env: { ...process.env, MAIN_ROOT: root },
  });
  assert.doesNotMatch(r.stderr, /unrecognized argument/);
});
