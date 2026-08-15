import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, symlinkSync, existsSync, lstatSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { applyWorktreeInclude } from "../../orchestrator/lib/worktree.mjs";

function tmpRoot() {
  return mkdtempSync(join(tmpdir(), "worktreeinclude-"));
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
