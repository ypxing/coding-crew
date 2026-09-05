import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, symlinkSync, existsSync, lstatSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";

import { applyWorktreeInclude, ensureWorktree, ensureWorktreeInclude } from "../../orchestrator/lib/worktree.mjs";
import { Effects } from "../../orchestrator/lib/effects.mjs";

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
  writeFileSync(join(mainRoot, ".worktreeinclude"), ".env\n");
  writeFileSync(join(mainRoot, ".env"), "SECRET=1\n");

  const linked = applyWorktreeInclude(mainRoot, worktree);

  assert.deepEqual(linked, [".env"]);
  assert.ok(lstatSync(join(worktree, ".env")).isSymbolicLink());
  assert.equal(readFileSync(join(worktree, ".env"), "utf8"), "SECRET=1\n");
});

test("leaves an already-linked, still-valid entry alone", () => {
  const mainRoot = tmpRoot();
  const worktree = tmpRoot();
  writeFileSync(join(mainRoot, ".worktreeinclude"), ".env\n");
  writeFileSync(join(mainRoot, ".env"), "SECRET=1\n");
  symlinkSync(join(mainRoot, ".env"), join(worktree, ".env"));

  const linked = applyWorktreeInclude(mainRoot, worktree);

  assert.deepEqual(linked, []); // nothing to do — it was already correct
  assert.equal(readFileSync(join(worktree, ".env"), "utf8"), "SECRET=1\n");
});

test("a real (non-symlink) file already at the destination is never touched", () => {
  const mainRoot = tmpRoot();
  const worktree = tmpRoot();
  writeFileSync(join(mainRoot, ".worktreeinclude"), ".env\n");
  writeFileSync(join(mainRoot, ".env"), "SECRET=1\n");
  writeFileSync(join(worktree, ".env"), "worker-local-override\n");

  applyWorktreeInclude(mainRoot, worktree);

  assert.ok(!lstatSync(join(worktree, ".env")).isSymbolicLink());
  assert.equal(readFileSync(join(worktree, ".env"), "utf8"), "worker-local-override\n");
});

test("a source missing from mainRoot is skipped, not fatal", () => {
  const mainRoot = tmpRoot();
  const worktree = tmpRoot();
  writeFileSync(join(mainRoot, ".worktreeinclude"), ".env\n");

  const linked = applyWorktreeInclude(mainRoot, worktree);

  assert.deepEqual(linked, []);
  assert.ok(!existsSync(join(worktree, ".env")));
});

test("a .env symlink pointing at mainRoot self-heals once mainRoot gets a real .env", () => {
  // The common case: the worktree's `.env` link was created (or would be created)
  // pointing at `mainRoot/.env` before that file existed there, so it read as dangling.
  // Because our own links always target the same absolute `mainRoot/<entry>` path, no
  // relink is needed once that path becomes real — resolution just starts working.
  const mainRoot = tmpRoot();
  const worktree = tmpRoot();
  writeFileSync(join(mainRoot, ".worktreeinclude"), ".env\n");
  symlinkSync(join(mainRoot, ".env"), join(worktree, ".env"));
  assert.ok(!existsSync(join(worktree, ".env")), "precondition: the link starts dangling");

  writeFileSync(join(mainRoot, ".env"), "SECRET=1\n");

  const linked = applyWorktreeInclude(mainRoot, worktree);

  assert.deepEqual(linked, []); // nothing to relink — the existing link already resolves
  assert.ok(lstatSync(join(worktree, ".env")).isSymbolicLink());
  assert.equal(readFileSync(join(worktree, ".env"), "utf8"), "SECRET=1\n");
});

test("replaces an orphaned .env symlink that points somewhere other than the current source", () => {
  // Reproduces the reported failure for the case the plain existsSync check cannot self
  // heal: `dest` is a broken symlink left pointing at a target that is not (and will
  // never become, via this function) `mainRoot/.env` — e.g. a worktree reused after
  // `.worktreeinclude` itself changed, or a link placed by something other than this
  // function. The old code swallowed `symlinkSync`'s EEXIST here and left the broken
  // link in place forever, so a worker's `cp .env.template .env` kept failing with
  // "not writing through dangling symlink".
  const mainRoot = tmpRoot();
  const worktree = tmpRoot();
  writeFileSync(join(mainRoot, ".worktreeinclude"), ".env\n");
  writeFileSync(join(mainRoot, ".env"), "SECRET=1\n");
  symlinkSync(join(mainRoot, "no-such-file"), join(worktree, ".env"));
  assert.ok(!existsSync(join(worktree, ".env")), "precondition: the link starts dangling");

  const linked = applyWorktreeInclude(mainRoot, worktree);

  assert.deepEqual(linked, [".env"]);
  assert.ok(lstatSync(join(worktree, ".env")).isSymbolicLink());
  assert.equal(readFileSync(join(worktree, ".env"), "utf8"), "SECRET=1\n");
});

test("a dangling symlink with no source to heal it yet is left in place", () => {
  const mainRoot = tmpRoot();
  const worktree = tmpRoot();
  writeFileSync(join(mainRoot, ".worktreeinclude"), ".env\n");
  symlinkSync(join(mainRoot, ".env"), join(worktree, ".env"));

  const linked = applyWorktreeInclude(mainRoot, worktree);

  assert.deepEqual(linked, []);
  assert.ok(lstatSync(join(worktree, ".env")).isSymbolicLink());
  assert.ok(!existsSync(join(worktree, ".env")));
});

// --- ensureWorktreeInclude: docker-compose.override.yml and .env before any worktree exists ----

test("ensureWorktreeInclude creates .worktreeinclude with both entries when it does not exist yet", () => {
  const mainRoot = tmpRoot();

  const changed = ensureWorktreeInclude(mainRoot);

  assert.equal(changed, true);
  assert.equal(
    readFileSync(join(mainRoot, ".worktreeinclude"), "utf8"),
    "docker-compose.override.yml\n.env\n",
  );
});

test("ensureWorktreeInclude appends both missing entries to an existing manifest that lacks them", () => {
  const mainRoot = tmpRoot();
  writeFileSync(join(mainRoot, ".worktreeinclude"), "node_modules\n");

  const changed = ensureWorktreeInclude(mainRoot);

  assert.equal(changed, true);
  assert.equal(
    readFileSync(join(mainRoot, ".worktreeinclude"), "utf8"),
    "node_modules\ndocker-compose.override.yml\n.env\n",
  );
});

test("ensureWorktreeInclude appends only the entry still missing when the other is already listed", () => {
  const mainRoot = tmpRoot();
  writeFileSync(join(mainRoot, ".worktreeinclude"), ".env\nnode_modules\n");

  const changed = ensureWorktreeInclude(mainRoot);

  assert.equal(changed, true);
  assert.equal(
    readFileSync(join(mainRoot, ".worktreeinclude"), "utf8"),
    ".env\nnode_modules\ndocker-compose.override.yml\n",
  );
});

test("ensureWorktreeInclude appends onto a manifest missing its trailing newline", () => {
  const mainRoot = tmpRoot();
  writeFileSync(join(mainRoot, ".worktreeinclude"), "node_modules");

  ensureWorktreeInclude(mainRoot);

  assert.equal(
    readFileSync(join(mainRoot, ".worktreeinclude"), "utf8"),
    "node_modules\ndocker-compose.override.yml\n.env\n",
  );
});

test("ensureWorktreeInclude is a no-op when both entries are already present", () => {
  const mainRoot = tmpRoot();
  writeFileSync(join(mainRoot, ".worktreeinclude"), "docker-compose.override.yml\n.env\n");

  const changed = ensureWorktreeInclude(mainRoot);

  assert.equal(changed, false);
  assert.equal(readFileSync(join(mainRoot, ".worktreeinclude"), "utf8"), "docker-compose.override.yml\n.env\n");
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
  // The branch exists from an earlier, abandoned attempt, based on an old commit —
  // then main advances (e.g. a dependency's branch merges) without the leftover
  // branch ever being rebased or deleted.
  git("branch", branch);
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
