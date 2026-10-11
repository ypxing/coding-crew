/**
 * Sprint suite — the issue-set lint (lint-issues.sh), run once before discovery and any worktree.
 * Shared helpers: ./helpers/sprint.mjs.
 */

import assert from "node:assert/strict";
import { chmodSync, cpSync, mkdirSync, mkdtempSync, readFileSync, renameSync, writeFileSync, existsSync, unlinkSync } from "node:fs";
import { join } from "node:path";
import { MAIN, TMPDIR, SCRIPTS, INSTALL_DIR, FAKE, FIXTURE_ROOTS, sh, fixtureRepo, githubFixtureRepo, stubGh, GH_ALPHA, addIssue, runSprint, traceLog, state, fake, workerReport, coderSpawns, commandLines, privateScripts, test } from "./helpers/sprint.mjs";

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
  // eleven criteria: a context-budget WARN (over 10), never an ERROR
  addIssue(root, "01-alpha.md", { body: Array.from({ length: 10 }, (_, i) => `- [ ] alpha part ${i + 1}`).join("\n") });
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(traceLog(root), /WARN  LINT: WARN .*01-alpha\.md: 11 acceptance criteria \(over 10: a context-budget check/);
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

test("a re-run under local: a PRD ID only a done issue implements gets no coverage WARN", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md", { body: "## Implements\n\nD1" });
  mkdirSync(join(root, ".scratch/demo/issues/done"), { recursive: true });
  renameSync(join(root, ".scratch/demo/issues/open/01-alpha.md"), join(root, ".scratch/demo/issues/done/01-alpha.md"));
  addIssue(root, "02-beta.md", { body: "## Implements\n\nD2" });
  writeFileSync(join(root, ".scratch/demo/PRD.md"), "# PRD\n\n## Decisions\n\n- **D1** — alpha.\n- **D2** — beta.\n- **D3** — orphan.\n");
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.doesNotMatch(traceLog(root), /LINT: WARN .*D1 is not named/);
  assert.match(traceLog(root), /LINT: WARN .*D3 is not named by any issue's ## Implements/);
});

test("a re-run under github: a PRD ID only a closed issue implements gets no coverage WARN", () => {
  const root = githubFixtureRepo();
  const alpha = { ...GH_ALPHA, body: `${GH_ALPHA.body}\n## Implements\n\nD2\n` };
  const closed = { ...GH_ALPHA, number: 2, title: "beta", state: "CLOSED", body: "# beta\n\n## Implements\n\nD1\n\n## Acceptance criteria\n\n- [x] beta exists\n" };
  const prd = { number: 9, title: "PRD: Demo", body: "# PRD\n\n- **D1** — beta.\n- **D2** — alpha.\n- **D3** — orphan.\n", labels: [], state: "OPEN" };
  const { stub } = stubGh(root, [alpha, closed, prd]);
  initSprint(root, { PATH: `${stub}:${process.env.PATH}` });
  const r = sh("node", [MAIN, "run", "--platform", "pi", "--feature-slug", "demo", "--no-baseline", "--no-integration-check", "--dry-run"], {
    cwd: root,
    env: { ...process.env, CREW_SCRIPTS: SCRIPTS, CREW_FAKE_DISPATCH: FAKE, MAIN_ROOT: root, CREW_INSTALL_DIR: INSTALL_DIR, PATH: `${stub}:${process.env.PATH}` },
  });
  assert.equal(r.code, 2, `${r.stdout}\n${r.stderr}`);
  const out = `${r.stdout}\n${r.stderr}\n${traceLog(root)}`;
  assert.match(out, /LINT: WARN .*D3 is not named by any issue's ## Implements/);
  assert.doesNotMatch(out, /D1 is not named/);
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
  assert.equal(argv[2], "--known");
  assert.match(argv[3], /\/2-beta\.md$/); // written out, so its ## Implements counts toward coverage
  assert.equal(readFileSync(argv[3], "utf8"), closed.body);
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
