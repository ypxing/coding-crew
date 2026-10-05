import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, symlinkSync, existsSync, lstatSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";

import {
  applyWorktreeInclude,
  ensureWorktree,
  mergeFeatureBranch,
  worktreePath,
} from "../../orchestrator/lib/worktree.mjs";
import { Effects } from "../../orchestrator/lib/effects.mjs";
import { conflictResolved } from "../../orchestrator/lib/pipeline.mjs";

function tmpRoot() {
  return mkdtempSync(join(tmpdir(), "worktreeinclude-"));
}

/** A real git repo with one commit on its default branch, plus a real (non-dry-run) Effects. */
function gitRoot() {
  const mainRoot = tmpRoot();
  const git = (...args) => execFileSync("git", ["-C", mainRoot, ...args], { encoding: "utf8" });
  git("init", "-q", "-b", "main");
  git("config", "user.email", "test@example.com");
  git("config", "user.name", "Test");
  writeFileSync(join(mainRoot, "README.md"), "seed\n");
  git("add", "-A");
  git("commit", "-q", "-m", "seed");
  const effects = new Effects({ scriptsDir: mainRoot, mainRoot, dryRun: false });
  return { mainRoot, git, effects };
}

test("links a .worktreeinclude entry that has no counterpart in the worktree yet", () => {
  const mainRoot = tmpRoot();
  const worktree = tmpRoot();
  writeFileSync(join(mainRoot, ".worktreeinclude"), "node_modules\n");
  writeFileSync(join(mainRoot, "node_modules"), "SECRET=1\n");

  const linked = applyWorktreeInclude(mainRoot, worktree);

  assert.deepEqual(linked, ["node_modules"]);
  assert.ok(lstatSync(join(worktree, "node_modules")).isSymbolicLink());
  assert.equal(readFileSync(join(worktree, "node_modules"), "utf8"), "SECRET=1\n");
});

test("leaves an already-linked, still-valid entry alone", () => {
  const mainRoot = tmpRoot();
  const worktree = tmpRoot();
  writeFileSync(join(mainRoot, ".worktreeinclude"), "node_modules\n");
  writeFileSync(join(mainRoot, "node_modules"), "SECRET=1\n");
  symlinkSync(join(mainRoot, "node_modules"), join(worktree, "node_modules"));

  const linked = applyWorktreeInclude(mainRoot, worktree);

  assert.deepEqual(linked, []); // nothing to do — it was already correct
  assert.equal(readFileSync(join(worktree, "node_modules"), "utf8"), "SECRET=1\n");
});

test("a real (non-symlink) file already at the destination is never touched", () => {
  const mainRoot = tmpRoot();
  const worktree = tmpRoot();
  writeFileSync(join(mainRoot, ".worktreeinclude"), "node_modules\n");
  writeFileSync(join(mainRoot, "node_modules"), "SECRET=1\n");
  writeFileSync(join(worktree, "node_modules"), "worker-local-override\n");

  applyWorktreeInclude(mainRoot, worktree);

  assert.ok(!lstatSync(join(worktree, "node_modules")).isSymbolicLink());
  assert.equal(readFileSync(join(worktree, "node_modules"), "utf8"), "worker-local-override\n");
});

test("a source missing from mainRoot is skipped, not fatal", () => {
  const mainRoot = tmpRoot();
  const worktree = tmpRoot();
  writeFileSync(join(mainRoot, ".worktreeinclude"), "node_modules\n");

  const linked = applyWorktreeInclude(mainRoot, worktree);

  assert.deepEqual(linked, []);
  assert.ok(!existsSync(join(worktree, "node_modules")));
});

test("a symlinked entry pointing at mainRoot self-heals once mainRoot gets a real source", () => {
  // The common case: the worktree's link was created (or would be created) pointing at
  // `mainRoot/<entry>` before that file existed there, so it read as dangling. Because
  // our own links always target the same absolute `mainRoot/<entry>` path, no relink is
  // needed once that path becomes real — resolution just starts working.
  const mainRoot = tmpRoot();
  const worktree = tmpRoot();
  writeFileSync(join(mainRoot, ".worktreeinclude"), "node_modules\n");
  symlinkSync(join(mainRoot, "node_modules"), join(worktree, "node_modules"));
  assert.ok(!existsSync(join(worktree, "node_modules")), "precondition: the link starts dangling");

  writeFileSync(join(mainRoot, "node_modules"), "SECRET=1\n");

  const linked = applyWorktreeInclude(mainRoot, worktree);

  assert.deepEqual(linked, []); // nothing to relink — the existing link already resolves
  assert.ok(lstatSync(join(worktree, "node_modules")).isSymbolicLink());
  assert.equal(readFileSync(join(worktree, "node_modules"), "utf8"), "SECRET=1\n");
});

test("replaces an orphaned symlink that points somewhere other than the current source", () => {
  // Reproduces the reported failure for the case the plain existsSync check cannot self
  // heal: `dest` is a broken symlink left pointing at a target that is not (and will
  // never become, via this function) `mainRoot/<entry>` — e.g. a worktree reused after
  // `.worktreeinclude` itself changed, or a link placed by something other than this
  // function. The old code swallowed `symlinkSync`'s EEXIST here and left the broken
  // link in place forever, so a worker's own provisioning step kept failing with
  // "not writing through dangling symlink".
  const mainRoot = tmpRoot();
  const worktree = tmpRoot();
  writeFileSync(join(mainRoot, ".worktreeinclude"), "node_modules\n");
  writeFileSync(join(mainRoot, "node_modules"), "SECRET=1\n");
  symlinkSync(join(mainRoot, "no-such-file"), join(worktree, "node_modules"));
  assert.ok(!existsSync(join(worktree, "node_modules")), "precondition: the link starts dangling");

  const linked = applyWorktreeInclude(mainRoot, worktree);

  assert.deepEqual(linked, ["node_modules"]);
  assert.ok(lstatSync(join(worktree, "node_modules")).isSymbolicLink());
  assert.equal(readFileSync(join(worktree, "node_modules"), "utf8"), "SECRET=1\n");
});

test("a dangling symlink with no source to heal it yet is left in place", () => {
  const mainRoot = tmpRoot();
  const worktree = tmpRoot();
  writeFileSync(join(mainRoot, ".worktreeinclude"), "node_modules\n");
  symlinkSync(join(mainRoot, "node_modules"), join(worktree, "node_modules"));

  const linked = applyWorktreeInclude(mainRoot, worktree);

  assert.deepEqual(linked, []);
  assert.ok(lstatSync(join(worktree, "node_modules")).isSymbolicLink());
  assert.ok(!existsSync(join(worktree, "node_modules")));
});

// --- applyWorktreeInclude: .env is copied, never symlinked (COPY_ENTRIES) ------------------

test(".env is provisioned as a real copy, not a symlink", () => {
  const mainRoot = tmpRoot();
  const worktree = tmpRoot();
  writeFileSync(join(mainRoot, ".worktreeinclude"), ".env\n");
  writeFileSync(join(mainRoot, ".env"), "SECRET=1\n");

  const linked = applyWorktreeInclude(mainRoot, worktree);

  assert.deepEqual(linked, [".env"]);
  assert.ok(!lstatSync(join(worktree, ".env")).isSymbolicLink());
  assert.equal(readFileSync(join(worktree, ".env"), "utf8"), "SECRET=1\n");
});

test("a real .env already at the destination is never touched (resume)", () => {
  const mainRoot = tmpRoot();
  const worktree = tmpRoot();
  writeFileSync(join(mainRoot, ".worktreeinclude"), ".env\n");
  writeFileSync(join(mainRoot, ".env"), "SECRET=1\n");
  writeFileSync(join(worktree, ".env"), "worker-local-override\n");

  const linked = applyWorktreeInclude(mainRoot, worktree);

  assert.deepEqual(linked, []);
  assert.equal(readFileSync(join(worktree, ".env"), "utf8"), "worker-local-override\n");
});

test("a stale .env symlink (from before .env moved to COPY_ENTRIES) is replaced with a copy", () => {
  const mainRoot = tmpRoot();
  const worktree = tmpRoot();
  writeFileSync(join(mainRoot, ".worktreeinclude"), ".env\n");
  writeFileSync(join(mainRoot, ".env"), "SECRET=1\n");
  symlinkSync(join(mainRoot, "no-such-file"), join(worktree, ".env"));
  assert.ok(!existsSync(join(worktree, ".env")), "precondition: the link starts dangling");

  const linked = applyWorktreeInclude(mainRoot, worktree);

  assert.deepEqual(linked, [".env"]);
  assert.ok(!lstatSync(join(worktree, ".env")).isSymbolicLink());
  assert.equal(readFileSync(join(worktree, ".env"), "utf8"), "SECRET=1\n");
});

test(".env is skipped, not fatal, when mainRoot has no .env yet", () => {
  const mainRoot = tmpRoot();
  const worktree = tmpRoot();
  writeFileSync(join(mainRoot, ".worktreeinclude"), ".env\n");

  const linked = applyWorktreeInclude(mainRoot, worktree);

  assert.deepEqual(linked, []);
  assert.ok(!existsSync(join(worktree, ".env")));
});

// --- worktreePath: base directory override via CREW_WORKTREE_ROOT -----------

function withEnv(name, value, fn) {
  const prior = process.env[name];
  if (value === undefined) delete process.env[name];
  else process.env[name] = value;
  try {
    return fn();
  } finally {
    if (prior === undefined) delete process.env[name];
    else process.env[name] = prior;
  }
}

test("worktreePath defaults to .scratch/worktrees/<branch> under mainRoot", () => {
  withEnv("CREW_WORKTREE_ROOT", undefined, () => {
    assert.equal(worktreePath("/repo", "crew/feat/a"), join("/repo", ".scratch", "worktrees", "crew/feat/a"));
  });
});

test("worktreePath honors an absolute CREW_WORKTREE_ROOT override", () => {
  withEnv("CREW_WORKTREE_ROOT", "/var/crew-worktrees", () => {
    assert.equal(worktreePath("/repo", "crew/feat/a"), join("/var/crew-worktrees", "crew/feat/a"));
  });
});

test("worktreePath resolves a relative CREW_WORKTREE_ROOT override against mainRoot", () => {
  withEnv("CREW_WORKTREE_ROOT", "../scratch-wt", () => {
    assert.equal(worktreePath("/repo", "crew/feat/a"), join("/repo", "../scratch-wt", "crew/feat/a"));
  });
});

// --- applyWorktreeInclude: built-in entries, without writing a manifest ------
//
// docker-compose.override.yml and .env can be generated in mainRoot after round 1's worktrees
// exist, so they are provisioned whether or not the repo lists them — but crew-afk never writes
// a `.worktreeinclude` into the user's repo to get there.

test("provisions .env and docker-compose.override.yml with no .worktreeinclude at all", () => {
  const mainRoot = tmpRoot();
  const worktree = tmpRoot();
  writeFileSync(join(mainRoot, ".env"), "SECRET=1\n");
  writeFileSync(join(mainRoot, "docker-compose.override.yml"), "services: {}\n");

  const linked = applyWorktreeInclude(mainRoot, worktree);

  assert.deepEqual(linked.sort(), [".env", "docker-compose.override.yml"]);
  assert.ok(!lstatSync(join(worktree, ".env")).isSymbolicLink());
  assert.ok(lstatSync(join(worktree, "docker-compose.override.yml")).isSymbolicLink());
});

test("provisions the built-in entries alongside a repo's own .worktreeinclude entries", () => {
  const mainRoot = tmpRoot();
  const worktree = tmpRoot();
  writeFileSync(join(mainRoot, ".worktreeinclude"), "node_modules\n");
  writeFileSync(join(mainRoot, "node_modules"), "x\n");
  writeFileSync(join(mainRoot, ".env"), "SECRET=1\n");

  const linked = applyWorktreeInclude(mainRoot, worktree);

  assert.deepEqual(linked.sort(), [".env", "node_modules"]);
});

test("a built-in entry the repo also lists is provisioned once", () => {
  const mainRoot = tmpRoot();
  const worktree = tmpRoot();
  writeFileSync(join(mainRoot, ".worktreeinclude"), ".env\n");
  writeFileSync(join(mainRoot, ".env"), "SECRET=1\n");

  assert.deepEqual(applyWorktreeInclude(mainRoot, worktree), [".env"]);
});

test("never creates or changes the repo's .worktreeinclude", () => {
  const bare = tmpRoot();
  applyWorktreeInclude(bare, tmpRoot());
  assert.ok(!existsSync(join(bare, ".worktreeinclude")));

  const listed = tmpRoot();
  writeFileSync(join(listed, ".worktreeinclude"), "node_modules");
  applyWorktreeInclude(listed, tmpRoot());
  assert.equal(readFileSync(join(listed, ".worktreeinclude"), "utf8"), "node_modules");
});

// --- ensureWorktree: stale-branch detection ---------------------------------
//
// Reuse (an existing branch ref, `git worktree add path branch` with no base) is
// correct for a genuine resume — a retained branch already holds committed WIP.
// It is not correct for a fresh dispatch (no recorded progress for this issue) that
// happens to collide with a leftover branch from an earlier, abandoned run: that
// branch's base can predate work the current sprint has since merged, and reusing
// it silently produces a merge conflict at the very end of the pipeline instead of
// a clear signal at the start of it.

test("ensureWorktree creates a fresh worktree when no branch exists yet", () => {
  const { mainRoot, effects } = gitRoot();

  const result = ensureWorktree(effects, { mainRoot, branch: "crew/feat/a", base: "HEAD" });

  assert.equal(result.created, true);
  assert.equal(result.reusedBranch, false);
  assert.equal(result.stale, undefined);
  assert.ok(existsSync(result.path));
});

// A worktree for the branch left somewhere other than worktreePath() — by a crashed run or
// another tool (e.g. a Claude session's scratchpad) — makes `git worktree add` fatal.

test("ensureWorktree prunes a registration for the branch whose directory is gone", () => {
  const { mainRoot, git, effects } = gitRoot();
  const branch = "crew/feat/a";
  const elsewhere = join(tmpRoot(), "a");
  git("worktree", "add", "-q", "-b", branch, elsewhere);
  rmSync(elsewhere, { recursive: true, force: true });

  const result = ensureWorktree(effects, { mainRoot, branch, base: "HEAD", expectReuse: false });

  assert.equal(result.stale, undefined);
  assert.equal(result.path, worktreePath(mainRoot, branch));
  assert.ok(existsSync(result.path));
});

test("ensureWorktree removes a clean worktree for the branch at another path and takes the branch over", () => {
  const { mainRoot, git, effects } = gitRoot();
  const branch = "crew/feat/a";
  const elsewhere = join(tmpRoot(), "a");
  git("worktree", "add", "-q", "-b", branch, elsewhere);

  const result = ensureWorktree(effects, { mainRoot, branch, base: "HEAD", expectReuse: false });

  assert.equal(result.stale, undefined);
  assert.ok(existsSync(result.path));
  assert.ok(!existsSync(elsewhere));
  assert.ok(!git("worktree", "list", "--porcelain").includes(`worktree ${elsewhere}\n`));
});

test("ensureWorktree leaves a dirty worktree for the branch at another path alone and reports stale", () => {
  const { mainRoot, git, effects } = gitRoot();
  const branch = "crew/feat/a";
  const elsewhere = join(tmpRoot(), "a");
  git("worktree", "add", "-q", "-b", branch, elsewhere);
  writeFileSync(join(elsewhere, "uncommitted.txt"), "wip\n");

  const result = ensureWorktree(effects, { mainRoot, branch, base: "HEAD", expectReuse: true });

  assert.equal(result.stale, true);
  assert.equal(result.path, null);
  assert.match(result.reason, /uncommitted/);
  assert.ok(result.reason.includes(elsewhere));
  assert.equal(readFileSync(join(elsewhere, "uncommitted.txt"), "utf8"), "wip\n");
});

test("ensureWorktree never removes the main checkout when it has the branch checked out", () => {
  const { mainRoot, git, effects } = gitRoot();
  const branch = "crew/feat/a";
  git("checkout", "-q", "-b", branch);

  const result = ensureWorktree(effects, { mainRoot, branch, base: "main", expectReuse: true });

  assert.equal(result.stale, true);
  assert.ok(existsSync(join(mainRoot, "README.md")));
});

test("ensureWorktree reuses an existing branch without a staleness check when expectReuse is true", () => {
  const { mainRoot, git, effects } = gitRoot();
  const branch = "crew/feat/a";
  // Create the branch off an old commit, then advance main past it — a real resume
  // (hasProgress: true) must still reuse this branch even though HEAD has moved on.
  git("branch", branch);
  writeFileSync(join(mainRoot, "other.txt"), "advance\n");
  git("add", "-A");
  git("commit", "-q", "-m", "advance main past the branch");

  const result = ensureWorktree(effects, { mainRoot, branch, base: "HEAD", expectReuse: true });

  assert.equal(result.stale, undefined);
  assert.equal(result.reusedBranch, true);
  assert.ok(existsSync(result.path));
});

test("ensureWorktree reuses an existing branch without a staleness check when it already contains base", () => {
  const { mainRoot, git, effects } = gitRoot();
  const branch = "crew/feat/a";
  git("checkout", "-q", "-b", branch);
  writeFileSync(join(mainRoot, "work.txt"), "wip\n");
  git("add", "-A");
  git("commit", "-q", "-m", "wip on the branch");
  git("checkout", "-q", "main");

  const result = ensureWorktree(effects, { mainRoot, branch, base: "HEAD", expectReuse: false });

  assert.equal(result.stale, undefined);
  assert.equal(result.reusedBranch, true);
  assert.ok(existsSync(result.path));
});

test("ensureWorktree flags a stale branch instead of silently reusing it on a fresh dispatch", () => {
  const { mainRoot, git, effects } = gitRoot();
  const branch = "crew/feat/live-api-integration";
  // The branch exists from an earlier, abandoned attempt, with a commit of its own, based
  // on an old commit — then main advances (e.g. a dependency's branch merges) without the
  // leftover branch ever being rebased or deleted.
  git("checkout", "-q", "-b", branch);
  writeFileSync(join(mainRoot, "abandoned.txt"), "abandoned attempt's own work\n");
  git("add", "-A");
  git("commit", "-q", "-m", "abandoned attempt");
  git("checkout", "-q", "main");
  writeFileSync(join(mainRoot, "component.txt"), "merged dependency work\n");
  git("add", "-A");
  git("commit", "-q", "-m", "component-with-mock merges into the feature branch");

  const result = ensureWorktree(effects, { mainRoot, branch, base: "HEAD", expectReuse: false });

  assert.equal(result.stale, true);
  assert.equal(result.path, null);
  assert.match(result.reason, /already exists/);
  assert.match(result.reason, /no recorded progress/);
  // No worktree was ever created for the stale branch.
  const listed = execFileSync("git", ["-C", mainRoot, "worktree", "list", "--porcelain"], { encoding: "utf8" });
  assert.ok(!listed.includes(branch));
});

test("ensureWorktree discards and recreates a stale branch whose tree is identical to base — debris squashed elsewhere, not real unique work", () => {
  const { mainRoot, git, effects } = gitRoot();
  const branch = "crew/feat/team-scoring-lane";
  // The branch forked from the seed commit and committed some work — then that same
  // work landed on main via a squash on a different path entirely (a sibling issue's
  // squash-commits.sh run), so main's tree now matches the branch's tip tree exactly,
  // even though the branch's own commit is not part of main's history at all.
  git("checkout", "-q", "-b", branch);
  writeFileSync(join(mainRoot, "component.txt"), "issue-03's own work\n");
  git("add", "-A");
  git("commit", "-q", "-m", "issue-03 branch's own commit");
  git("checkout", "-q", "main");
  writeFileSync(join(mainRoot, "component.txt"), "issue-03's own work\n");
  git("add", "-A");
  git("commit", "-q", "-m", "squash of other issues lands the identical tree");

  const result = ensureWorktree(effects, { mainRoot, branch, base: "HEAD", expectReuse: false });

  assert.equal(result.stale, undefined);
  assert.equal(result.created, true);
  assert.ok(existsSync(result.path));
  const branchTip = execFileSync("git", ["-C", mainRoot, "rev-parse", branch], { encoding: "utf8" }).trim();
  const headTip = execFileSync("git", ["-C", mainRoot, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
  assert.equal(branchTip, headTip, "the debris branch was deleted and recreated fresh at base, not reused as-is");
});

test("ensureWorktree discards and recreates a branch with no commits of its own — nothing on it to lose", () => {
  const { mainRoot, git, effects } = gitRoot();
  const branch = "crew/feat/dead-dispatch";
  // A worker that died before committing leaves a branch pointing at an old commit of
  // main, which main has since moved past: every commit on it is already on main.
  git("branch", branch);
  writeFileSync(join(mainRoot, "sibling.txt"), "a sibling issue merged\n");
  git("add", "-A");
  git("commit", "-q", "-m", "a sibling issue merges into the feature branch");

  const result = ensureWorktree(effects, { mainRoot, branch, base: "HEAD", expectReuse: false });

  assert.equal(result.stale, undefined);
  assert.equal(result.created, true);
  assert.equal(result.reusedBranch, false);
  const branchTip = execFileSync("git", ["-C", mainRoot, "rev-parse", branch], { encoding: "utf8" }).trim();
  const headTip = execFileSync("git", ["-C", mainRoot, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
  assert.equal(branchTip, headTip, "recreated fresh at base");
});

test("ensureWorktree defaults expectReuse to true — existing callers keep silent-reuse behavior", () => {
  const { mainRoot, git, effects } = gitRoot();
  const branch = "crew/feat/a";
  git("branch", branch);
  writeFileSync(join(mainRoot, "other.txt"), "advance\n");
  git("add", "-A");
  git("commit", "-q", "-m", "advance main past the branch");

  const result = ensureWorktree(effects, { mainRoot, branch, base: "HEAD" });

  assert.equal(result.stale, undefined);
  assert.ok(existsSync(result.path));
});

// --- mergeFeatureBranch: forward-sync a reused issue branch --------------------------
//
// A reused branch forked from the feature branch at some earlier point. Every commit
// landed on the feature branch since (a sibling issue's merge, a manual commit) is
// invisible to it until this runs — otherwise the coder works from a stale base and the
// gap only surfaces as a conflict at the merge gate, ~45 minutes later.

test("mergeFeatureBranch merges new feature-branch commits into the reused issue branch", () => {
  const { mainRoot, git, effects } = gitRoot();
  const featureBranch = "feature/x";
  git("checkout", "-q", "-b", featureBranch);
  const branch = "crew/x/a";
  git("checkout", "-q", "-b", branch);
  writeFileSync(join(mainRoot, "issue-work.txt"), "wip\n");
  git("add", "-A");
  git("commit", "-q", "-m", "issue wip");

  // A sibling issue merges into the feature branch after this one's branch forked.
  git("checkout", "-q", featureBranch);
  writeFileSync(join(mainRoot, "sibling.txt"), "sibling work\n");
  git("add", "-A");
  git("commit", "-q", "-m", "sibling issue merges into feature branch");

  const worktree = join(mainRoot, "wt-a");
  git("worktree", "add", worktree, branch);

  const result = mergeFeatureBranch(effects, { worktree, branch, featureBranch });

  assert.equal(result.merged, true);
  assert.equal(result.conflict, undefined);
  assert.ok(existsSync(join(worktree, "sibling.txt")), "the feature branch's new file is now visible on the issue branch");
  assert.ok(existsSync(join(worktree, "issue-work.txt")), "the issue branch's own prior work survives the merge");
});

test("mergeFeatureBranch is a no-op when the feature branch has nothing new", () => {
  const { mainRoot, git, effects } = gitRoot();
  const featureBranch = "feature/x";
  git("checkout", "-q", "-b", featureBranch);
  const branch = "crew/x/a";
  git("checkout", "-q", "-b", branch);
  writeFileSync(join(mainRoot, "issue-work.txt"), "wip\n");
  git("add", "-A");
  git("commit", "-q", "-m", "issue wip");
  git("checkout", "-q", featureBranch);

  const worktree = join(mainRoot, "wt-a");
  git("worktree", "add", worktree, branch);
  const before = execFileSync("git", ["-C", worktree, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();

  const result = mergeFeatureBranch(effects, { worktree, branch, featureBranch });

  assert.equal(result.merged, false);
  assert.equal(result.conflict, undefined);
  const after = execFileSync("git", ["-C", worktree, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
  assert.equal(after, before, "no merge commit was created");
});

test("mergeFeatureBranch aborts cleanly and reports a conflict instead of resolving it", () => {
  const { mainRoot, git, effects } = gitRoot();
  const featureBranch = "feature/x";
  git("checkout", "-q", "-b", featureBranch);
  writeFileSync(join(mainRoot, "shared.txt"), "base\n");
  git("add", "-A");
  git("commit", "-q", "-m", "shared file on the feature branch");

  const branch = "crew/x/a";
  git("checkout", "-q", "-b", branch);
  writeFileSync(join(mainRoot, "shared.txt"), "issue-side edit\n");
  git("add", "-A");
  git("commit", "-q", "-m", "issue edits the shared file");

  git("checkout", "-q", featureBranch);
  writeFileSync(join(mainRoot, "shared.txt"), "feature-side edit\n");
  git("add", "-A");
  git("commit", "-q", "-m", "feature branch edits the same line");

  const worktree = join(mainRoot, "wt-a");
  git("worktree", "add", worktree, branch);

  const result = mergeFeatureBranch(effects, { worktree, branch, featureBranch });

  assert.equal(result.merged, false);
  assert.equal(result.conflict, true);
  assert.match(result.reason, /conflicted/);
  const status = execFileSync("git", ["-C", worktree, "status", "--porcelain=v1"], { encoding: "utf8" });
  assert.equal(status.trim(), "", "the merge was aborted — the worktree is left clean");
});

test("mergeFeatureBranch with keepConflict leaves the merge in progress and records the feature sha it merged", () => {
  const { mainRoot, git, effects } = gitRoot();
  const featureBranch = "feature/x";
  git("checkout", "-q", "-b", featureBranch);
  writeFileSync(join(mainRoot, "shared.txt"), "base\n");
  git("add", "-A");
  git("commit", "-q", "-m", "shared");
  const branch = "crew/x/a";
  git("checkout", "-q", "-b", branch);
  writeFileSync(join(mainRoot, "shared.txt"), "issue\n");
  git("commit", "-q", "-am", "issue edit");
  git("checkout", "-q", featureBranch);
  writeFileSync(join(mainRoot, "shared.txt"), "feature\n");
  git("commit", "-q", "-am", "feature edit");
  const tip = execFileSync("git", ["-C", mainRoot, "rev-parse", featureBranch], { encoding: "utf8" }).trim();
  const worktree = join(mainRoot, "wt-a");
  git("worktree", "add", worktree, branch);

  const result = mergeFeatureBranch(effects, { worktree, branch, featureBranch, keepConflict: true });

  assert.equal(result.kept, true);
  assert.deepEqual(result.files, ["shared.txt"]);
  assert.equal(result.featureSha, tip, "the sha the merge was started from, not a ref to re-read later");
  assert.equal(execFileSync("git", ["-C", worktree, "rev-parse", "MERGE_HEAD"], { encoding: "utf8" }).trim(), tip);
});

// conflictResolved (pipeline.mjs) judges a conflict-only dispatch from git, against the sha
// mergeFeatureBranch recorded, never the live feature-branch ref.
function keptConflict() {
  const { mainRoot, git, effects } = gitRoot();
  const featureBranch = "feature/x";
  git("checkout", "-q", "-b", featureBranch);
  writeFileSync(join(mainRoot, "shared.txt"), "base\n");
  git("add", "-A");
  git("commit", "-q", "-m", "shared");
  const branch = "crew/x/a";
  git("checkout", "-q", "-b", branch);
  writeFileSync(join(mainRoot, "shared.txt"), "issue\n");
  git("commit", "-q", "-am", "issue edit");
  git("checkout", "-q", featureBranch);
  writeFileSync(join(mainRoot, "shared.txt"), "feature\n");
  git("commit", "-q", "-am", "feature edit");
  const worktree = join(mainRoot, "wt-a");
  git("worktree", "add", worktree, branch);
  const sync = mergeFeatureBranch(effects, { worktree, branch, featureBranch, keepConflict: true });
  assert.equal(sync.kept, true);
  const wt = (...args) => execFileSync("git", ["-C", worktree, ...args], { encoding: "utf8" });
  return { mainRoot, git, wt, effects, worktree, featureBranch, featureSha: sync.featureSha };
}

function concludeMerge(wt, worktree) {
  writeFileSync(join(worktree, "shared.txt"), "issue\nfeature\n");
  wt("add", "shared.txt");
  wt("-c", "user.email=t@t", "-c", "user.name=T", "commit", "-q", "--no-edit");
}

test("conflictResolved: a concluded merge of the recorded sha is resolved though the feature branch moved on", () => {
  const { mainRoot, git, wt, effects, worktree, featureBranch, featureSha } = keptConflict();
  concludeMerge(wt, worktree);
  // A sibling merges into the feature branch while the dispatch ran.
  writeFileSync(join(mainRoot, "late.txt"), "late\n");
  git("add", "late.txt");
  git("commit", "-q", "-m", "sibling");

  assert.deepEqual(conflictResolved(effects, worktree, featureBranch, featureSha), { ok: true });
  assert.equal(conflictResolved(effects, worktree, featureBranch).ok, false, "the live ref would have failed it");
});

test("conflictResolved: a merge still in progress is unresolved", () => {
  const { effects, worktree, featureBranch, featureSha } = keptConflict();
  assert.deepEqual(conflictResolved(effects, worktree, featureBranch, featureSha), { ok: false, why: "the merge is still in progress (MERGE_HEAD)" });
});

test("conflictResolved: unmerged paths left without MERGE_HEAD are unresolved", () => {
  const { wt, effects, worktree, featureBranch, featureSha } = keptConflict();
  rmSync(wt("rev-parse", "--path-format=absolute", "--git-path", "MERGE_HEAD").trim());
  assert.deepEqual(conflictResolved(effects, worktree, featureBranch, featureSha), { ok: false, why: "unmerged paths remain" });
});

test("conflictResolved: a HEAD missing the recorded sha is unresolved", () => {
  const { wt, effects, worktree, featureBranch, featureSha } = keptConflict();
  wt("merge", "--abort");
  const r = conflictResolved(effects, worktree, featureBranch, featureSha);
  assert.equal(r.ok, false);
  assert.match(r.why, new RegExp(`HEAD does not contain ${featureSha.slice(0, 12)}`));
});

test("mergeFeatureBranch is a no-op when the branch is itself the feature branch", () => {
  const { mainRoot, git, effects } = gitRoot();
  const featureBranch = "feature/x";
  git("checkout", "-q", "-b", featureBranch);

  const result = mergeFeatureBranch(effects, { worktree: mainRoot, branch: featureBranch, featureBranch });

  assert.deepEqual(result, { merged: false });
});

test("mergeFeatureBranch runs resolve-merge-conflicts.sh on a conflict and commits what it resolved", () => {
  const { mainRoot, git, effects } = gitRoot();
  writeFileSync(join(mainRoot, "resolve-merge-conflicts.sh"), "#!/usr/bin/env bash\ngit checkout --theirs shared.txt && git add shared.txt && echo resolved\n");
  const featureBranch = "feature/x";
  git("checkout", "-q", "-b", featureBranch);
  writeFileSync(join(mainRoot, "shared.txt"), "base\n");
  git("add", "-A");
  git("commit", "-q", "-m", "shared");
  const branch = "crew/x/a";
  git("checkout", "-q", "-b", branch);
  writeFileSync(join(mainRoot, "shared.txt"), "issue\n");
  git("commit", "-q", "-am", "issue edit");
  git("checkout", "-q", featureBranch);
  writeFileSync(join(mainRoot, "shared.txt"), "feature\n");
  git("commit", "-q", "-am", "feature edit");
  const worktree = join(mainRoot, "wt-a");
  git("worktree", "add", worktree, branch);

  const result = mergeFeatureBranch(effects, { worktree, branch, featureBranch, keepConflict: true });

  assert.equal(result.merged, true);
  assert.equal(result.kept, undefined);
  assert.equal(execFileSync("git", ["-C", worktree, "status", "--porcelain=v1", "--untracked-files=no"], { encoding: "utf8" }).trim(), "");
  assert.equal(execFileSync("git", ["-C", worktree, "merge-base", "--is-ancestor", featureBranch, "HEAD"]).length, 0);
});

test("an auto-resolved sync keeps the feature branch's CHANGELOG entries first, with the sides labelled by merge direction", () => {
  const { mainRoot, git } = gitRoot();
  const effects = new Effects({ scriptsDir: join(import.meta.dirname, "../../skills/crew-afk/scripts"), mainRoot, dryRun: false });
  const featureBranch = "feature/x";
  git("checkout", "-q", "-b", featureBranch);
  writeFileSync(join(mainRoot, "CHANGELOG.md"), "# Changelog\n\n- old\n");
  git("add", "-A");
  git("commit", "-q", "-m", "changelog");
  const branch = "crew/x/a";
  git("checkout", "-q", "-b", branch);
  writeFileSync(join(mainRoot, "CHANGELOG.md"), "# Changelog\n\n- old\n- issue entry\n");
  git("commit", "-q", "-am", "issue appends");
  git("checkout", "-q", featureBranch);
  writeFileSync(join(mainRoot, "CHANGELOG.md"), "# Changelog\n\n- old\n- feature entry\n");
  git("commit", "-q", "-am", "feature appends");

  const worktree = join(mainRoot, "wt-a");
  git("worktree", "add", worktree, branch);
  const result = mergeFeatureBranch(effects, { worktree, branch, featureBranch });

  assert.equal(result.merged, true);
  assert.equal(result.autoResolved, true);
  assert.equal(readFileSync(join(worktree, "CHANGELOG.md"), "utf8"), "# Changelog\n\n- old\n- feature entry\n- issue entry\n");
  assert.deepEqual(result.decisions, ["CHANGELOG.md: kept 1 entry from the feature side and 1 from the branch side"]);
});
