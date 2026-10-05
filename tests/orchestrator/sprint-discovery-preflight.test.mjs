/**
 * Sprint suite — command discovery, argument errors, preflight, dirty checkouts and the cost ledger.
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
// branch), exactly the seam the PRD audit already uses for the same reason.

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
// feature-branch-setup.sh (--jira only), which died with a confusing "Unknown argument"
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
  assert.doesNotMatch(r.stderr, /Unknown argument/); // feature-branch-setup.sh's own message
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

// ─── preflight: a clean main checkout, and a green feature branch ─────────────────────

test("uncommitted changes to a tracked file stop the run before anything is dispatched", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  writeFileSync(join(root, "Makefile"), "test:\n\t@echo edited\nlint:\n\t@echo ok\ntypecheck:\n\t@echo ok\n");
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 1, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stderr, /the main checkout \(\S+\) has uncommitted changes to tracked files/);
  assert.match(r.stderr, /^  Makefile$/m);
  assert.equal(lines.filter((l) => /^SPAWN /.test(l)).length, 0);
  assert.equal(existsSync(join(root, ".scratch/demo/sprint-state.json")), false, "stopped before session-init");
});

test("--allow-dirty runs anyway, and crew-afk's own files never count as dirty", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  mkdirSync(join(root, ".coding-crew"), { recursive: true });
  writeFileSync(join(root, ".coding-crew/dev-commands.json"), '{"test": "make test"}');
  sh("git", ["-C", root, "add", "-A"]);
  sh("git", ["-C", root, "commit", "-q", "-m", "cache"]);
  writeFileSync(join(root, ".coding-crew/dev-commands.json"), '{"test": "make test", "lint": "make lint"}');
  assert.equal(runSprint(root).code, 0, "a rewritten commands cache is crew-afk's own write");

  // Unstaged, and in a file no branch touches. (A *staged* change would refuse every merge:
  // git will not record index changes unrelated to the merge in its commit.)
  const other = fixtureRepo();
  addIssue(other, "01-alpha.md");
  writeFileSync(join(other, "README.md"), "x\n");
  sh("git", ["-C", other, "add", "README.md"]);
  sh("git", ["-C", other, "commit", "-q", "-m", "readme"]);
  writeFileSync(join(other, "README.md"), "local edit\n");
  const r = runSprint(other, ["--allow-dirty"]);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
});

test("a run leaves no .worktreeinclude behind in a repo that had none", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  assert.equal(runSprint(root).code, 0);
  assert.equal(existsSync(join(root, ".worktreeinclude")), false);
});

test("plan names a dirty main checkout", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  writeFileSync(join(root, "Makefile"), "test:\n\t@echo edited\n");
  const r = sh("node", [MAIN, "plan", "--platform", "pi", "--feature-slug", "demo"], { cwd: root, env: { ...process.env, MAIN_ROOT: root } });
  assert.match(r.stdout, /main tree: 1 tracked file\(s\) with uncommitted changes .*Makefile/);
});

test("a feature branch that fails its own checks stops the run, and no issue is verified past it", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  writeFileSync(join(root, "Makefile"), "test:\n\t@echo boom && exit 1\nlint:\n\t@echo ok\ntypecheck:\n\t@echo ok\n");
  sh("git", ["-C", root, "add", "-A"]);
  sh("git", ["-C", root, "commit", "-q", "-m", "red"]);
  const { r, lines } = commandLines(root, [], { baseline: true });
  assert.equal(r.code, 1, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stderr, /feature\/demo fails its own checks before any issue has touched it/);
  assert.match(traceLog(root), /^\S+Z FATAL \[ABORT\] .*feature\/demo fails its own checks/m);
  assert.match(traceLog(root), /^\S+Z ERROR \[VERIFY-OUTPUT\] step=baseline result=fail file=\S+\/_baseline\/verify\.out$/m);
  assert.match(r.stderr, /^  test: fail — \S+\/dispatch\/_baseline\/verify-test\.log$/m);
  assert.match(r.stderr, /--no-baseline/);
  assert.equal(lines.filter((l) => /^SPAWN .*--agent crew-(?!coder)/.test(l)).length, 0, "no reviewer or triage");
  assert.equal(lines.filter((l) => /verify-worktree\.sh --dir \S+ --stem alpha/.test(l)).length, 0, "no issue is verified before the baseline verdict");
  assert.equal(state(root).baseline.verdict, "fail");
  // The throwaway worktree and its branch are gone.
  assert.equal(sh("git", ["-C", root, "branch", "--list", "crew/demo/_baseline"]).stdout.trim(), "");
  assert.equal(existsSync(join(root, ".scratch/worktrees/crew/demo/_baseline")), false);
});

test("a red baseline with two issues: coders start alongside it, no issue is verified, branches are kept, exit 1", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-beta.md");
  writeFileSync(join(root, "Makefile"), "test:\n\t@echo boom && exit 1\nlint:\n\t@echo ok\ntypecheck:\n\t@echo ok\n");
  sh("git", ["-C", root, "add", "-A"]);
  sh("git", ["-C", root, "commit", "-q", "-m", "red"]);
  const { r, lines } = commandLines(root, ["--max-parallel", "2"], { baseline: true });
  assert.equal(r.code, 1, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stderr, /feature\/demo fails its own checks before any issue has touched it/);
  const coders = lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length;
  assert.ok(coders >= 1 && coders <= 2, `coders start alongside the baseline, not behind it (${coders} spawned)`);
  assert.equal(lines.filter((l) => /verify-worktree\.sh --dir \S+ --stem (alpha|beta)/.test(l)).length, 0);
  assert.equal(state(root).baseline.verdict, "fail");
});

test("a red baseline stops the coders already running: the run ends at once, their branches kept for the next run", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  writeFileSync(join(root, "Makefile"), "test:\n\t@echo boom && exit 1\nlint:\n\t@echo ok\ntypecheck:\n\t@echo ok\n");
  sh("git", ["-C", root, "add", "-A"]);
  sh("git", ["-C", root, "commit", "-q", "-m", "red"]);
  // The coder commits, then would run for a minute: the red baseline must not wait for it.
  fake(root, "alpha.worker-sleep", "60\n");
  const t0 = Date.now();
  const { r } = commandLines(root, [], { baseline: true });
  assert.equal(r.code, 1, `${r.stdout}\n${r.stderr}`);
  assert.ok(Date.now() - t0 < 30_000, `the run ended after ${Date.now() - t0} ms`);
  assert.match(traceLog(root), /\[BASELINE-RED\] .*stopping \d+ running dispatch/);
  assert.match(state(root).retention.alpha.reason, /baseline failed/);
  // Its coder was stopped mid-work: the next run sends a coder, not a verify-only retry.
  assert.doesNotMatch(state(root).retention.alpha.reason, /verify-interrupted/);
});

test("a red baseline that stops a review-only retry keeps its reason, so the next run still sends no coder", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.review-once", "2");
  const first = commandLines(root, ["--max-rounds", "1"]);
  assert.equal(first.r.code, 0, `${first.r.stdout}\n${first.r.stderr}`);
  assert.match(state(root).retention.alpha.reason, /^review-not-run — /);

  writeFileSync(join(root, "Makefile"), "test:\n\t@echo boom && exit 1\nlint:\n\t@echo ok\ntypecheck:\n\t@echo ok\n");
  sh("git", ["-C", root, "add", "-A"]);
  sh("git", ["-C", root, "commit", "-q", "-m", "red"]);
  // alpha's deps outlast the baseline, so the red verdict lands before its review-only retry returns.
  const scripts = privateScripts();
  renameSync(join(scripts, "ensure-deps.sh"), join(scripts, "ensure-deps.real.sh"));
  writeFileSync(
    join(scripts, "ensure-deps.sh"),
    '#!/usr/bin/env bash\ncase " $* " in *" --slug alpha "*) sleep 6 ;; esac\nexec bash "$(dirname "$0")/ensure-deps.real.sh" "$@"\n',
  );
  chmodSync(join(scripts, "ensure-deps.sh"), 0o755);
  const { r } = commandLines(root, [], { baseline: true, scripts });
  assert.equal(r.code, 1, `${r.stdout}\n${r.stderr}`);
  assert.match(traceLog(root), /\[BASELINE-RED\] slug=alpha /);
  assert.match(state(root).retention.alpha.reason, /^review-not-run — /, "not re-retained as a stopped coder");
});

// A check command that is not installed exits 127: an environment problem, never the branch's.
function missingTool(root) {
  mkdirSync(join(root, ".coding-crew"), { recursive: true });
  writeFileSync(
    join(root, ".coding-crew/dev-commands.json"),
    JSON.stringify({ test: "crew-no-such-tool tests/*.bats", lint: "make lint", typecheck: "make typecheck", coverage: null, integration: null }),
  );
  sh("git", ["-C", root, "add", "-A"]);
  sh("git", ["-C", root, "commit", "-q", "-m", "cache"]);
  fake(root, "commands.response", '{"install": null, "env": null, "credential_target": null}');
}

test("a baseline check whose command is not installed is reported as the environment, not a red branch", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  missingTool(root);
  const { r, lines } = commandLines(root, [], { baseline: true });
  assert.equal(r.code, 1, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stderr, /feature\/demo's checks cannot run here: `crew-no-such-tool` is not installed — an environment problem, not a red branch/);
  assert.match(r.stderr, /^  test: fail — command not found: crew-no-such-tool — \S+\/dispatch\/_baseline\/verify-test\.log$/m);
  assert.match(r.stderr, /Install it where the checks run \(or give \.coding-crew\/dev-commands\.json an `install` command that does\), then re-run\./);
  assert.doesNotMatch(r.stderr, /Fix it on the feature branch/);
  assert.match(r.stderr, /--no-baseline/);
  assert.equal(lines.filter((l) => /^SPAWN .*--agent crew-(?!coder)/.test(l)).length, 0, "no reviewer or triage");
  assert.equal(lines.filter((l) => /verify-worktree\.sh --dir \S+ --stem alpha/.test(l)).length, 0, "no issue is verified before the baseline verdict");
});

test("an issue's verify failing on a command that is not installed skips triage and never re-dispatches the coder", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  missingTool(root);
  fake(root, "alpha.worker", workerReport({ status: "complete", checks: { test: "pass", lint: "pass", typecheck: "pass" }, progress: "" }));
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 2, `${r.stdout}\n${r.stderr}`);
  assert.equal(coderSpawns(lines), 1, "a missing command is not fixable by more code");
  assert.equal(lines.filter((l) => /^SPAWN .*--agent crew-triage/.test(l)).length, 0, "nothing for triage to judge");
  assert.match(traceLog(root), /\[SKIP-WORKER\] slug=alpha reason=not-fixable-recheck/);
  assert.match(
    state(root).retention.alpha.reason,
    /^blocked — retry limit reached \(2 attempts\) — verification-failed:not-fixable — missing command: crew-no-such-tool is not installed \(test\)/,
  );
});

test("a green baseline is run once per feature-branch commit, then reused", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const tip = sh("git", ["-C", root, "rev-parse", "feature/demo"]).stdout.trim();
  const first = commandLines(root, ["--max-rounds", "1"], { baseline: true });
  assert.equal(first.r.code, 0, `${first.r.stdout}\n${first.r.stderr}`);
  assert.equal(first.lines.filter((l) => /verify-worktree\.sh --dir \S+\/_baseline --stem _baseline/.test(l)).length, 1);
  assert.deepEqual({ commit: state(root).baseline.commit, verdict: state(root).baseline.verdict }, { commit: tip, verdict: "pass" });

  // Same tip, a second run (alpha's merge moved it, so pin the cache to the new tip first).
  addIssue(root, "02-beta.md");
  const again = sh("git", ["-C", root, "rev-parse", "feature/demo"]).stdout.trim();
  const sf = join(root, ".scratch/demo/sprint-state.json");
  writeFileSync(sf, JSON.stringify({ ...state(root), baseline: { commit: again, verdict: "pass" } }));
  const second = commandLines(root, [], { baseline: true });
  assert.equal(second.r.code, 0, `${second.r.stdout}\n${second.r.stderr}`);
  assert.equal(second.lines.filter((l) => /--stem _baseline/.test(l)).length, 0);
  assert.match(second.r.stderr, /BASELINE: pass \(cached/);
});

test("--no-baseline skips the baseline", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(lines.filter((l) => /--stem _baseline/.test(l)).length, 0);
});

// ─── a dirty main checkout at merge time ──────────────────────────────────────────────

test("a merge refused by uncommitted changes in the main checkout blocks at once, then resumes at merge", () => {
  const root = fixtureRepo();
  mkdirSync(join(root, "src"), { recursive: true });
  writeFileSync(join(root, "src/alpha.txt"), "// base\n");
  sh("git", ["-C", root, "add", "-A"]);
  sh("git", ["-C", root, "commit", "-q", "-m", "seed"]);
  addIssue(root, "01-alpha.md");
  // The fake coder appends to src/alpha.txt; the same file edited, uncommitted, here.
  writeFileSync(join(root, "src/alpha.txt"), "// someone's local edit\n");

  const first = commandLines(root, ["--allow-dirty"]);
  assert.equal(first.r.code, 2, `${first.r.stdout}\n${first.r.stderr}`);
  const s = state(root);
  assert.match(s.retention.alpha.reason, /^blocked — main-tree-dirty — uncommitted changes in \S+ would be overwritten: src\/alpha\.txt — commit or stash/);
  assert.equal(s.attempts.alpha, 1, "no retry: nothing a dispatch does can clean the checkout");
  assert.equal(first.lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length, 1);
  assert.match(first.r.stdout, /## Main Checkout Not Clean \(need a human\)/);
  assert.match(first.r.stdout, /- crew\/demo\/alpha: uncommitted changes in \S+ would be overwritten: src\/alpha\.txt/);

  // The human stashes the edit and re-runs: straight to merge, nothing re-dispatched.
  sh("git", ["-C", root, "checkout", "--", "src/alpha.txt"]);
  const second = commandLines(root);
  assert.equal(second.r.code, 0, `${second.r.stdout}\n${second.r.stderr}`);
  assert.deepEqual(state(root).completed_slugs, ["alpha"]);
  // Nothing of alpha's is re-dispatched; the merge it resumes at is a first drain's feature review.
  assert.equal(second.lines.filter((l) => /^SPAWN .*--agent crew-/.test(l) && !/ --slug feature(-\d+)?( |$)/.test(l)).length, 0);
  assert.equal(second.lines.filter((l) => /verify-worktree\.sh --dir/.test(l)).length, 0);
  assert.match(traceLog(root), /\[SKIP-TO-MERGE\] slug=alpha reason=blocked — main-tree-dirty/);
});

// ─── the per-dispatch cost ledger ─────────────────────────────────────────────────────

test("every dispatch is filed in this run's ledger with its slug, role and attempt", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.review-once", "2");
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const s = state(root);
  assert.ok(s.current_run, "run-start tagged the run");
  const rows = s.dispatches.map((d) => [d.role, d.attempt, d.run === s.current_run]);
  assert.deepEqual(rows, [
    ["coder", 1, true],
    ["reviewer", 1, true],
    ["reviewer", 1, true],
    ["reviewer", 2, true],
    ["reviewer", 1, true], // the feature review's planner, once, at the drain
    ["reviewer", 1, true], // the feature review's one area reviewer
  ]);
  // The coder's entry keeps the tip it left: the commit verify then checked.
  const verified = JSON.parse(readFileSync(join(root, ".scratch/demo/dispatch/01-alpha/verify.json"), "utf8")).commit;
  assert.equal(s.dispatches[0].head, verified);
});

// ─── the issue-set lint (lint-issues.sh, once, before discovery and any worktree) ──────────────

/** A copy of the test install whose lint-issues.sh is `body` (bash), run with the real argv. */
function lintInstall(body) {
  const dir = mkdtempSync(join(TMPDIR, "crew-install-"));
  FIXTURE_ROOTS.push(dir);
  cpSync(INSTALL_DIR, dir, { recursive: true });
  writeFileSync(join(dir, "to-issues/scripts/lint-issues.sh"), `#!/usr/bin/env bash\n${body}\n`);
  return dir;
}
const recordArgs = (root) => `printf '%s\\n' "$@" > '${join(root, "lint-argv.txt")}'`;
/** A dry run cannot create the sprint it inspects (session-init.sh is itself an effect), so make one. */
const initSprint = (root, env = {}) =>
  sh("bash", [join(SCRIPTS, "session-init.sh"), "--feature-slug", "demo"], {
    cwd: root,
    env: { ...process.env, MAIN_ROOT: root, CREW_SCRIPTS: SCRIPTS, ...env },
  });
const lintArgv = (root) => readFileSync(join(root, "lint-argv.txt"), "utf8").trim().split("\n");

test("a structural error in the issue set stops the run before any worktree or dispatch, quoting each ERROR line", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  writeFileSync(join(root, ".scratch/demo/issues/open/02-beta.md"), "# beta\n\nStatus: ready-for-agent\n\nNo criteria here.\n");
  const r = runSprint(root);
  assert.equal(r.code, 1, `${r.stdout}\n${r.stderr}`);
  const beta = join(root, ".scratch/demo/issues/open/02-beta.md");
  assert.ok(r.stderr.includes(`ERROR ${beta}: no ## Acceptance criteria section`), r.stderr);
  assert.equal(sh("git", ["-C", root, "worktree", "list"]).stdout.trim().split("\n").length, 1, "no worktree was made");
  assert.equal(existsSync(join(root, ".scratch/demo/dispatch")) && coderSpawns(root).length > 0, false, "nothing was dispatched");
  assert.equal(existsSync(join(root, ".coding-crew/dev-commands.json")), false, "not even command discovery ran");
});

test("lint WARN lines are logged and the run goes on", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md"); // one criterion: a WARN (3-8 expected), never an ERROR
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(traceLog(root), /WARN  LINT: WARN .*01-alpha\.md: 1 acceptance criteria \(expected 3-8\)/);
  assert.match(traceLog(root), /LINT: pass \(\d+ warnings?\)/);
});

test("under local the linter gets every open issue, issues-deps.json and the PRD", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-beta.md");
  writeFileSync(join(root, ".scratch/demo/issues/issues-deps.json"), "{}");
  writeFileSync(join(root, ".scratch/demo/PRD.md"), "# PRD\n");
  const dir = lintInstall(recordArgs(root));
  const r = runSprint(root, [], { CREW_INSTALL_DIR: dir });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const open = join(root, ".scratch/demo/issues/open");
  assert.deepEqual(lintArgv(root), [
    "--issue", join(open, "01-alpha.md"), "--issue", join(open, "02-beta.md"),
    "--deps", join(root, ".scratch/demo/issues/issues-deps.json"), "--prd", join(root, ".scratch/demo/PRD.md"),
  ]);
});

test("a resumed sprint: a Blocked by ref to a done issue resolves through --known, so the run goes on", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  mkdirSync(join(root, ".scratch/demo/issues/done"), { recursive: true });
  renameSync(join(root, ".scratch/demo/issues/open/01-alpha.md"), join(root, ".scratch/demo/issues/done/01-alpha.md"));
  addIssue(root, "02-beta.md", { blockedBy: ["01-alpha.md", "Issue #1"] });
  writeFileSync(join(root, ".scratch/demo/issues/issues-deps.json"), '{"01-alpha.md": [], "02-beta.md": ["01-alpha.md"]}');
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.doesNotMatch(traceLog(root), /LINT: ERROR/);
  assert.match(traceLog(root), /LINT: pass/);
});

test("without issues-deps.json or a PRD the linter is passed neither flag", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const r = runSprint(root, [], { CREW_INSTALL_DIR: lintInstall(recordArgs(root)) });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.deepEqual(lintArgv(root), ["--issue", join(root, ".scratch/demo/issues/open/01-alpha.md")]);
});

test("under github the linter gets one written-out body file per open milestone issue, each done one as --known, and the PRD issue", () => {
  const root = githubFixtureRepo();
  const closed = { ...GH_ALPHA, number: 2, title: "beta", state: "CLOSED" };
  const prd = { number: 9, title: "PRD: Demo", body: "# PRD\n\n- **D1** thing\n", labels: [], state: "OPEN" };
  const { stub } = stubGh(root, [GH_ALPHA, closed, prd]);
  const dir = lintInstall(`${recordArgs(root)}\ncat "$2" > '${join(root, "lint-body.txt")}'`);
  initSprint(root, { CREW_INSTALL_DIR: dir, PATH: `${stub}:${process.env.PATH}` });
  const r = sh("node", [MAIN, "run", "--platform", "pi", "--feature-slug", "demo", "--no-baseline", "--no-integration-check", "--dry-run"], {
    cwd: root,
    env: { ...process.env, CREW_SCRIPTS: SCRIPTS, CREW_FAKE_DISPATCH: FAKE, MAIN_ROOT: root, CREW_INSTALL_DIR: dir, PATH: `${stub}:${process.env.PATH}` },
  });
  assert.equal(r.code, 2, `${r.stdout}\n${r.stderr}`); // dry run: stalled past the lint
  const argv = lintArgv(root);
  assert.equal(argv.length, 6, argv.join(" "));
  assert.equal(argv[0], "--issue");
  assert.match(argv[1], /\/1-alpha\.md$/);
  assert.deepEqual(argv.slice(2, 4), ["--known", "2-beta.md"]);
  assert.equal(argv[4], "--prd");
  assert.match(argv[5], /\/PRD\.md$/);
  assert.equal(readFileSync(join(root, "lint-body.txt"), "utf8"), GH_ALPHA.body);
});

test("an install without lint-issues.sh is reported by the missing-assets stop, naming the path", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const dir = lintInstall("exit 0");
  unlinkSync(join(dir, "to-issues/scripts/lint-issues.sh"));
  const r = runSprint(root, [], { CREW_INSTALL_DIR: dir });
  assert.equal(r.code, 1, `${r.stdout}\n${r.stderr}`);
  assert.ok(r.stderr.includes(`toIssues: ${join(dir, "to-issues/scripts/lint-issues.sh")}`), r.stderr);
});

test("a linter that exits 2 is logged and does not stop the run", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const r = runSprint(root, [], { CREW_INSTALL_DIR: lintInstall('echo "lint-issues.sh: broken" >&2; exit 2') });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stderr, /LINT: skipped — lint-issues\.sh exited 2 — lint-issues\.sh: broken/);
});

test("a linter that cannot run at all is logged and does not stop the run", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const r = runSprint(root, [], { CREW_INSTALL_DIR: lintInstall("kill -9 $$") });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stderr, /LINT: skipped — lint-issues\.sh exited/);
});

test("--dry-run runs the linter, reports an ERROR, and does not stop", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const dir = lintInstall('echo "ERROR x.md: dependency cycle"; exit 1');
  initSprint(root, { CREW_INSTALL_DIR: dir });
  const r = runSprint(root, ["--dry-run"], { CREW_INSTALL_DIR: dir });
  // A dry run dispatches nothing, so the issue stays open and the sprint ends stalled (2): past the lint.
  assert.equal(r.code, 2, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stderr, /step=dispatch-coder/);
  assert.match(r.stderr, /LINT: ERROR x\.md: dependency cycle/);
  assert.match(r.stderr, /LINT: fail — a real run would stop here/);
});
