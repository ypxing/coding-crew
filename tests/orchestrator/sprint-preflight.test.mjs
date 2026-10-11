/**
 * Sprint suite — preflight: a dirty main checkout, the feature branch's baseline check, and the per-dispatch cost ledger.
 * Shared helpers: ./helpers/sprint.mjs.
 */

import assert from "node:assert/strict";
import { chmodSync, cpSync, mkdirSync, mkdtempSync, readFileSync, renameSync, writeFileSync, existsSync, unlinkSync } from "node:fs";
import { join } from "node:path";
import { MAIN, TMPDIR, SCRIPTS, INSTALL_DIR, FAKE, FIXTURE_ROOTS, sh, fixtureRepo, githubFixtureRepo, stubGh, GH_ALPHA, addIssue, runSprint, traceLog, state, fake, workerReport, coderSpawns, commandLines, privateScripts, test } from "./helpers/sprint.mjs";

// ─── preflight: a clean main checkout, and a green feature branch ─────────────────────

test("uncommitted changes to a tracked file in the main checkout do not stop a run", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  writeFileSync(join(root, "Makefile"), "test:\n\t@echo edited\nlint:\n\t@echo ok\ntypecheck:\n\t@echo ok\n");
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.doesNotMatch(r.stderr, /allow-dirty/);
  assert.equal(readFileSync(join(root, "Makefile"), "utf8").includes("edited"), true, "the user's edit is untouched");
});

test("--allow-dirty is accepted, prints one notice line, and crew-afk's own files never count as dirty", () => {
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
  assert.equal(r.stderr.split("\n").filter((l) => /--allow-dirty no longer does anything/.test(l)).length, 1);
});

test("a run leaves no .worktreeinclude behind in a repo that had none", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  assert.equal(runSprint(root).code, 0);
  assert.equal(existsSync(join(root, ".worktreeinclude")), false);
});

test("plan no longer reports the main checkout's cleanliness", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  writeFileSync(join(root, "Makefile"), "test:\n\t@echo edited\n");
  const r = sh("node", [MAIN, "plan", "--platform", "pi", "--feature-slug", "demo"], { cwd: root, env: { ...process.env, MAIN_ROOT: root } });
  assert.doesNotMatch(r.stdout, /main tree:/);
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
  assert.deepEqual([state(root).last_exit.reason, state(root).last_exit.code], ["baseline red", 1]);
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
    ["commandFinder", 1, true], // command discovery, before any worktree
    ["coder", 1, true],
    ["reviewer", 1, true],
    ["reviewer", 1, true],
    ["reviewer", 2, true],
    ["reviewer", 1, true], // the feature review's one reviewer, at the drain
  ]);
  // The coder's entry keeps the tip it left: the commit verify then checked.
  const verified = JSON.parse(readFileSync(join(root, ".scratch/demo/dispatch/01-alpha/verify.json"), "utf8")).commit;
  assert.equal(s.dispatches[1].head, verified);
});
