/**
 * Sprint suite — the feature branch lives in the sprint's own `crew/<slug>/_feature` worktree, and
 * the main checkout is never switched. Shared helpers: ./helpers/sprint.mjs.
 */

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { MAIN, SCRIPTS, FAKE, FIXTURE_ROOTS, sprintEnv, sh, fixtureRepo, addIssue, runSprint, state, fake, traceLog, test } from "./helpers/sprint.mjs";

const git = (root, ...args) => sh("git", ["-C", root, ...args]).stdout.trim();
const featureWt = (root, slug = "demo") => join(root, ".scratch/worktrees/crew", slug, "_feature");

/** The fixture, with the user's checkout on `main` — the way a real run finds it. */
function userOnMain() {
  const root = fixtureRepo();
  git(root, "checkout", "-q", "main");
  return root;
}

test("a run leaves the main checkout's branch and HEAD alone, merges onto feature/<slug>, and removes _feature", () => {
  const root = userOnMain();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-beta.md");
  const head = git(root, "rev-parse", "HEAD");
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(git(root, "rev-parse", "--abbrev-ref", "HEAD"), "main");
  assert.equal(git(root, "rev-parse", "HEAD"), head);
  assert.equal(git(root, "status", "--porcelain", "--untracked-files=no"), "", "no tracked file in the user's working tree changed");
  for (const f of ["alpha", "beta"]) assert.equal(sh("git", ["-C", root, "cat-file", "-e", `feature/demo:src/${f}.txt`]).code, 0, `${f} merged on feature/demo`);
  assert.equal(sh("git", ["-C", root, "cat-file", "-e", "main:src/alpha.txt"]).code, 128, "main did not receive it");
  assert.equal(existsSync(featureWt(root)), false, "_feature is removed");
  assert.equal(git(root, "worktree", "list", "--porcelain").includes("_feature"), false, "and unregistered");
  assert.equal(existsSync(join(root, ".scratch/sprint.env")), false, "no repo-wide pointer is written");
  assert.equal(existsSync(join(root, ".scratch/demo/sprint.env")), true);
});

test("the per-issue reviewer runs in _feature, on the feature branch, not in the user's checkout", () => {
  const root = userOnMain();
  git(root, "checkout", "-q", "-b", "mine");
  addIssue(root, "01-alpha.md");
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const dirs = readFileSync(join(root, ".scratch/fake/dispatch-dirs"), "utf8").split("\n").filter((l) => l.startsWith("crew-reviewer "));
  assert.ok(dirs.length > 0, "a reviewer ran");
  for (const line of dirs) assert.equal(line.slice("crew-reviewer ".length), featureWt(root), line);
});

test("a stalled run removes _feature too, and a re-run resumes the same feature branch", () => {
  const root = userOnMain();
  addIssue(root, "01-alpha.md");
  const first = runSprint(root);
  assert.equal(first.code, 0, `${first.stdout}\n${first.stderr}`);
  const tip = git(root, "rev-parse", "feature/demo");
  addIssue(root, "02-beta.md");
  const second = runSprint(root);
  assert.equal(second.code, 0, `${second.stdout}\n${second.stderr}`);
  assert.equal(sh("git", ["-C", root, "merge-base", "--is-ancestor", tip, "feature/demo"]).code, 0, "the first run's commits are still on the branch");
  assert.deepEqual([...state(root).completed_slugs].sort(), ["alpha", "beta"]);
  assert.equal(existsSync(featureWt(root)), false);
  assert.equal(git(root, "rev-parse", "--abbrev-ref", "HEAD"), "main");
});

test("a run that errors still removes _feature and keeps the branch", () => {
  const root = userOnMain();
  addIssue(root, "01-alpha.md");
  writeFileSync(join(root, ".scratch/demo/issues/open/00-broken.md"), "# broken\n\nStatus: ready-for-agent\n\n## Blocked by\n\n- 99-nowhere\n");
  const r = runSprint(root);
  assert.notEqual(r.code, 0, "a lint error ends the run");
  assert.equal(existsSync(featureWt(root)), false);
  assert.equal(sh("git", ["-C", root, "rev-parse", "--verify", "-q", "feature/demo"]).code, 0);
});

test("with the main checkout on feature/<slug> the run exits 1 telling the user to switch it", () => {
  const root = fixtureRepo();
  git(root, "checkout", "-q", "feature/demo");
  addIssue(root, "01-alpha.md");
  const r = runSprint(root);
  assert.equal(r.code, 1, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stderr, /checked out in the main checkout .* switch it to another branch/);
  assert.equal(git(root, "rev-parse", "--abbrev-ref", "HEAD"), "feature/demo", "and it was not switched for the user");
});

test("a _feature worktree with uncommitted changes left by a crashed run is refused, listing the files, and nothing is removed", () => {
  const root = userOnMain();
  addIssue(root, "01-alpha.md");
  git(root, "worktree", "add", "-q", featureWt(root), "feature/demo");
  writeFileSync(join(featureWt(root), "Makefile"), "dirty\n");
  writeFileSync(join(featureWt(root), "stray.txt"), "x\n");
  const r = runSprint(root);
  assert.equal(r.code, 1, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stderr, /uncommitted changes/);
  assert.match(r.stderr, /Makefile/);
  assert.match(r.stderr, /stray\.txt/);
  assert.equal(readFileSync(join(featureWt(root), "stray.txt"), "utf8"), "x\n", "the leftovers are still there for the developer");
  assert.equal(readFileSync(join(featureWt(root), "Makefile"), "utf8"), "dirty\n");
});

test("a clean _feature worktree already on the branch is reused in place and the run continues", () => {
  const root = userOnMain();
  addIssue(root, "01-alpha.md");
  git(root, "worktree", "add", "-q", featureWt(root), "feature/demo");
  const marker = join(featureWt(root), ".git");
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.deepEqual(state(root).completed_slugs, ["alpha"]);
  assert.equal(existsSync(marker), false, "with no pane host, _feature is removed at the end as before");
});

test("uncommitted changes in the main checkout never reach, or are touched by, the sprint", () => {
  const root = userOnMain();
  addIssue(root, "01-alpha.md");
  const edited = "test:\n\t@echo mine\nlint:\n\t@echo ok\ntypecheck:\n\t@echo ok\n";
  writeFileSync(join(root, "Makefile"), edited);
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(readFileSync(join(root, "Makefile"), "utf8"), edited);
  assert.doesNotMatch(git(root, "show", "feature/demo:Makefile"), /mine/);
});

test("two runs on different slugs in one repo both finish, each merging only into its own feature branch", async () => {
  const root = userOnMain();
  addIssue(root, "01-alpha.md");
  mkdirSync(join(root, ".scratch/other/issues/open"), { recursive: true });
  writeFileSync(join(root, ".scratch/other/issues/open/01-gamma.md"), "# gamma\n\nStatus: ready-for-agent\n\n## Acceptance criteria\n\n- [ ] gamma exists\n");
  const run = (slug) =>
    new Promise((res) => {
      let out = "";
      const child = spawn("node", [MAIN, "run", "--platform", "pi", "--feature-slug", slug, "--no-baseline", "--no-integration-check"], {
        cwd: root,
        env: sprintEnv({ ...process.env, CREW_SCRIPTS: SCRIPTS, CREW_FAKE_DISPATCH: FAKE, CREW_FAKE_DIR: join(root, ".scratch/fake"), MAIN_ROOT: root }),
      });
      child.stdout.on("data", (d) => (out += d));
      child.stderr.on("data", (d) => (out += d));
      child.on("exit", (code) => res({ code, out }));
    });
  const [a, b] = await Promise.all([run("demo"), run("other")]);
  assert.equal(a.code, 0, a.out);
  assert.equal(b.code, 0, b.out);
  assert.equal(sh("git", ["-C", root, "cat-file", "-e", "feature/demo:src/alpha.txt"]).code, 0);
  assert.equal(sh("git", ["-C", root, "cat-file", "-e", "feature/other:src/gamma.txt"]).code, 0);
  assert.equal(sh("git", ["-C", root, "cat-file", "-e", "feature/demo:src/gamma.txt"]).code, 128, "demo did not receive other's issue");
  assert.equal(sh("git", ["-C", root, "cat-file", "-e", "feature/other:src/alpha.txt"]).code, 128, "other did not receive demo's issue");
  assert.equal(git(root, "rev-parse", "--abbrev-ref", "HEAD"), "main");
  assert.equal(existsSync(join(root, ".scratch/sprint.env")), false);
});

test("main.mjs status needs --feature-slug and prints that sprint", () => {
  const root = userOnMain();
  addIssue(root, "01-alpha.md");
  assert.equal(runSprint(root).code, 0);
  const env = { ...process.env, MAIN_ROOT: root };
  const none = sh("node", [MAIN, "status"], { cwd: root, env });
  assert.equal(none.code, 2);
  assert.match(none.stderr, /--feature-slug/);
  const some = sh("node", [MAIN, "status", "--feature-slug", "demo"], { cwd: root, env });
  assert.equal(some.code, 0, some.stderr);
  assert.equal(JSON.parse(some.stdout).env.FEATURE_SLUG, "demo");
});

test("a user's own worktree on feature/<slug> is never removed: the run exits 1 and the worktree and its ignored file survive", () => {
  const root = userOnMain();
  addIssue(root, "01-alpha.md");
  const mine = join(root, "..", `${root.split("/").pop()}-mine`);
  git(root, "worktree", "add", "-q", mine, "feature/demo");
  writeFileSync(join(mine, ".gitignore"), "secret.env\n");
  git(mine, "add", ".gitignore");
  git(mine, "commit", "-q", "-m", "ignore");
  writeFileSync(join(mine, "secret.env"), "keep me\n");
  const r = runSprint(root);
  assert.equal(r.code, 1, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stderr, /did not make|switch it to another branch/);
  assert.equal(existsSync(mine), true, "the user's worktree still exists");
  assert.equal(readFileSync(join(mine, "secret.env"), "utf8"), "keep me\n");
});

test("launched from a linked worktree, the run resolves the main checkout: sprint.env's MAIN_ROOT is it", () => {
  const root = userOnMain();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-fix-findings-alpha.md", { status: "deferred-findings" });
  const linked = join(root, "..", `${root.split("/").pop()}-linked`);
  git(root, "worktree", "add", "-q", "-b", "scratchpad", linked, "main");
  const r = sh("node", [MAIN, "run", "--platform", "pi", "--feature-slug", "demo", "--no-baseline", "--no-integration-check"], {
    cwd: linked,
    env: { ...process.env, CREW_SCRIPTS: SCRIPTS, CREW_FAKE_DISPATCH: FAKE, CREW_FAKE_DIR: join(root, ".scratch/fake"), MAIN_ROOT: "" },
  });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(readFileSync(join(root, ".scratch/demo/sprint.env"), "utf8"), new RegExp(`MAIN_ROOT="?${root}"?\\n`));
  // The orchestrator's tracker reads the main checkout: the parked fix issue was found, promoted and closed.
  assert.deepEqual([...state(root).completed_slugs].sort(), ["alpha", "fix-findings-alpha"]);
  assert.equal(existsSync(join(root, ".scratch/demo/issues/done/02-fix-findings-alpha.md")), true);
});

test("launched inside a submodule, the run and its scripts share the submodule's checkout as MAIN_ROOT", () => {
  const upstream = userOnMain();
  const outer = `${upstream}-outer`;
  FIXTURE_ROOTS.push(outer);
  sh("git", ["init", "-q", "-b", "main", outer]);
  for (const [k, v] of [["user.email", "t@test"], ["user.name", "T"]]) git(outer, "config", k, v);
  assert.equal(sh("git", ["-C", outer, "-c", "protocol.file.allow=always", "submodule", "add", "-q", upstream, "sub"]).code, 0);
  const sub = join(outer, "sub");
  for (const [k, v] of [["user.email", "t@test"], ["user.name", "T"]]) git(sub, "config", k, v);
  mkdirSync(join(sub, ".scratch/demo/issues/open"), { recursive: true });
  mkdirSync(join(sub, ".scratch/fake"), { recursive: true });
  addIssue(sub, "01-alpha.md");
  const r = sh("node", [MAIN, "run", "--platform", "pi", "--feature-slug", "demo", "--no-baseline", "--no-integration-check"], {
    cwd: sub,
    env: { ...process.env, CREW_SCRIPTS: SCRIPTS, CREW_FAKE_DISPATCH: FAKE, CREW_FAKE_DIR: join(sub, ".scratch/fake"), MAIN_ROOT: "" },
  });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(readFileSync(join(sub, ".scratch/demo/sprint.env"), "utf8"), new RegExp(`MAIN_ROOT="?${sub}"?\\n`));
  assert.equal(existsSync(join(outer, ".git/modules/.scratch")), false, "nothing written beside the submodule's git dir");
  assert.deepEqual(state(sub).completed_slugs, ["alpha"]);
  assert.equal(sh("git", ["-C", sub, "cat-file", "-e", "feature/demo:src/alpha.txt"]).code, 0);
});

/**
 * The user's checkout on `main` with a bare `origin` holding it, and no `feature/demo` anywhere: the
 * hook that moves `feature/demo` with `main` is gone, so a commit on `main` stays unpushed.
 */
function withOrigin() {
  const root = userOnMain();
  rmSync(join(root, ".git/hooks/post-commit"));
  git(root, "branch", "-D", "feature/demo");
  const origin = `${root}-origin.git`;
  FIXTURE_ROOTS.push(origin);
  sh("git", ["init", "-q", "--bare", "-b", "main", origin]);
  git(root, "remote", "add", "origin", origin);
  git(root, "push", "-q", "origin", "main");
  return { root, origin };
}

/** One commit on `parent`, made without touching any checkout; its sha. */
const commitOn = (root, parent, message) => git(root, "commit-tree", `${parent}^{tree}`, "-p", parent, "-m", message);

/** Another developer's push: `branch` on origin becomes `from` (on origin) plus one commit; its sha. */
function pushFromElsewhere(origin, branch, from = branch) {
  const other = `${origin}-${FIXTURE_ROOTS.length}`;
  FIXTURE_ROOTS.push(other);
  sh("git", ["clone", "-q", origin, other]);
  for (const [k, v] of [["user.email", "t@test"], ["user.name", "T"]]) git(other, "config", k, v);
  const tip = commitOn(other, `origin/${from}`, `elsewhere on ${branch}`);
  git(other, "push", "-q", "origin", `${tip}:refs/heads/${branch}`);
  return tip;
}

const upstreamOf = (root, branch) => sh("git", ["-C", root, "rev-parse", "--abbrev-ref", `${branch}@{upstream}`]);

test("with no feature branch anywhere, it starts untracked at the fetched origin/main, whatever local main holds, and a second run reuses it", () => {
  const { root, origin } = withOrigin();
  const originMain = pushFromElsewhere(origin, "main");
  git(root, "commit", "-q", "--allow-empty", "-m", "unpushed");
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(git(root, "rev-parse", "feature/demo"), originMain);
  assert.notEqual(upstreamOf(root, "feature/demo").code, 0, "no upstream configured");
  assert.doesNotMatch(r.stderr, /behind origin/);
  const again = runSprint(root);
  assert.equal(again.code, 0, `${again.stdout}\n${again.stderr}`);
  assert.equal(git(root, "rev-parse", "feature/demo"), originMain);
  assert.doesNotMatch(again.stderr, /BRANCH-SHIPPED/);
});

for (const originHead of [null, "refs/remotes/origin/master"]) {
  test(`with origin's default branch trunk and the local origin/HEAD ${originHead ? "naming origin/master, which origin lacks" : "unset"}, a new feature branch starts at origin's trunk`, () => {
    const { root, origin } = withOrigin();
    git(origin, "branch", "-m", "main", "trunk");
    const trunk = pushFromElsewhere(origin, "trunk");
    if (originHead) git(root, "symbolic-ref", "refs/remotes/origin/HEAD", originHead);
    const r = runSprint(root);
    assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
    assert.equal(git(root, "rev-parse", "feature/demo"), trunk);
  });
}

test("after origin renames main to trunk, the local origin/HEAD names origin/trunk, so a resumed feature branch syncs with trunk, not the stale origin/main", () => {
  const { root, origin } = withOrigin();
  git(root, "remote", "set-head", "origin", "main");
  git(origin, "branch", "-m", "main", "trunk");
  pushFromElsewhere(origin, "trunk");
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(git(root, "symbolic-ref", "refs/remotes/origin/HEAD"), "refs/remotes/origin/trunk");
  pushFromElsewhere(origin, "trunk");
  const sync = sh("bash", [join(SCRIPTS, "sync-feature-branch.sh"), "--dry-run", "feature/demo"], { cwd: root });
  assert.match(sync.stdout, /would merge origin\/trunk/);
});

test("an origin with branches but no default to start from (its HEAD names none it has, and no main) stops the run at setup, creating no branch", () => {
  const { root, origin } = withOrigin();
  git(origin, "branch", "-m", "main", "trunk");
  git(origin, "symbolic-ref", "HEAD", "refs/heads/gone");
  addIssue(root, "01-alpha.md");
  const r = runSprint(root);
  assert.equal(r.code, 1, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stderr, /origin/);
  assert.notEqual(sh("git", ["-C", root, "rev-parse", "--verify", "-q", "refs/heads/feature/demo"]).code, 0, "no feature branch created");
  assert.equal(existsSync(featureWt(root)), false);
});

test("with feature/<slug> only on origin, the local branch is created at its tip, tracking it", () => {
  const { root, origin } = withOrigin();
  const tip = pushFromElsewhere(origin, "feature/demo", "main");
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(git(root, "rev-parse", "feature/demo"), tip);
  assert.equal(upstreamOf(root, "feature/demo").stdout.trim(), "origin/feature/demo");
});

for (const ahead of [true, false]) {
  test(`a local feature/<slug> ${ahead ? "ahead of" : "equal to"} origin's is used unchanged`, () => {
    const { root } = withOrigin();
    git(root, "push", "-q", "origin", "main:refs/heads/feature/demo");
    const local = ahead ? commitOn(root, "main", "local only") : git(root, "rev-parse", "main");
    git(root, "branch", "feature/demo", local);
    const r = runSprint(root);
    assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
    assert.equal(git(root, "rev-parse", "feature/demo"), local);
  });
}

test("a local feature/<slug> behind origin's is fast-forwarded to origin's tip", () => {
  const { root, origin } = withOrigin();
  git(root, "branch", "feature/demo", "main");
  const tip = pushFromElsewhere(origin, "feature/demo", "main");
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(git(root, "rev-parse", "feature/demo"), tip);
});

test("a local feature/<slug> diverged from origin's stops the run at setup, naming both tips, with no worktree made", () => {
  const { root, origin } = withOrigin();
  const local = commitOn(root, "main", "local only");
  git(root, "branch", "feature/demo", local);
  const remote = pushFromElsewhere(origin, "feature/demo", "main");
  addIssue(root, "01-alpha.md");
  const r = runSprint(root);
  assert.equal(r.code, 1, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stderr, new RegExp(local.slice(0, 12)));
  assert.match(r.stderr, new RegExp(remote.slice(0, 12)));
  assert.equal(existsSync(featureWt(root)), false);
  assert.equal(git(root, "worktree", "list", "--porcelain").includes("_feature"), false);
  assert.equal(git(root, "rev-parse", "feature/demo"), local);
});

for (const upstream of [null, "origin/main"]) {
  test(`a local feature/<slug> with ${upstream ? "an upstream that is not its own origin branch" : "no upstream"} and none on origin is used unchanged`, () => {
    const { root } = withOrigin();
    const local = commitOn(root, "main", "never pushed");
    git(root, "branch", "feature/demo", local);
    if (upstream) git(root, "branch", "-q", `--set-upstream-to=${upstream}`, "feature/demo");
    const r = runSprint(root);
    assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
    assert.equal(git(root, "rev-parse", "feature/demo"), local);
    assert.doesNotMatch(r.stderr, /BRANCH-SHIPPED/);
  });
}

test("a shipped feature/<slug> (its origin branch gone) is renamed aside and the run starts fresh from origin/main in the same _feature", () => {
  const { root, origin } = withOrigin();
  const shipped = commitOn(root, "main", "shipped work");
  git(root, "branch", "feature/demo", shipped);
  git(root, "push", "-q", "-u", "origin", "feature/demo");
  git(root, "push", "-q", "origin", "--delete", "feature/demo");
  const originMain = pushFromElsewhere(origin, "main");
  const d = new Date();
  const day = `${d.getFullYear()}${String(d.getMonth() + 1).padStart(2, "0")}${String(d.getDate()).padStart(2, "0")}`;
  git(root, "branch", `feature/demo-shipped-${day}`, "main");
  git(root, "worktree", "add", "-q", featureWt(root), "feature/demo");
  addIssue(root, "01-alpha.md");
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const renamed = `feature/demo-shipped-${day}-2`;
  assert.ok(r.stderr.split("\n").includes(`[BRANCH-SHIPPED] renamed feature/demo → ${renamed}`), r.stderr);
  assert.equal(git(root, "rev-parse", renamed), shipped);
  assert.equal(git(root, "rev-parse", "feature/demo~1"), originMain, "the issue merged onto a branch fresh from origin/main");
  assert.equal(sh("git", ["-C", root, "cat-file", "-e", "feature/demo:src/alpha.txt"]).code, 0, "merged in _feature, on the new branch");
  assert.equal(sh("git", ["-C", root, "cat-file", "-e", `${renamed}:src/alpha.txt`]).code, 128);
});

for (const holder of ["the main checkout", "a worktree crew-afk did not make"]) {
  test(`a shipped feature/<slug> checked out in ${holder} is not renamed: the run stops at setup naming it`, () => {
    const { root } = withOrigin();
    const shipped = commitOn(root, "main", "shipped work");
    git(root, "branch", "feature/demo", shipped);
    git(root, "push", "-q", "-u", "origin", "feature/demo");
    git(root, "push", "-q", "origin", "--delete", "feature/demo");
    const mine = join(root, "..", `${root.split("/").pop()}-mine`);
    if (holder === "the main checkout") git(root, "checkout", "-q", "feature/demo");
    else git(root, "worktree", "add", "-q", mine, "feature/demo");
    const branches = git(root, "for-each-ref", "--format=%(refname)", "refs/heads");
    addIssue(root, "01-alpha.md");
    const r = runSprint(root);
    assert.equal(r.code, 1, `${r.stdout}\n${r.stderr}`);
    assert.match(r.stderr, new RegExp(`'${(holder === "the main checkout" ? root : mine).replace(/[.*+?^${}()|[\]\\/]/g, "\\$&")}'`));
    assert.doesNotMatch(r.stderr, /BRANCH-SHIPPED/);
    assert.equal(git(root, "for-each-ref", "--format=%(refname)", "refs/heads"), branches, "no branch renamed or created");
    assert.equal(git(root, "rev-parse", "feature/demo"), shipped);
    assert.equal(existsSync(featureWt(root)), false);
  });
}

test("an unreachable origin stops the run at setup with git's error, not a fallback to local refs", () => {
  const root = userOnMain();
  git(root, "remote", "add", "origin", `${root}-nowhere.git`);
  addIssue(root, "01-alpha.md");
  const r = runSprint(root);
  assert.equal(r.code, 1, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stderr, /nowhere\.git/);
  assert.equal(existsSync(featureWt(root)), false);
});
