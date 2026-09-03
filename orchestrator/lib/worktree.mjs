/**
 * worktree.mjs — one isolated checkout per issue, for every platform.
 *
 * This is what makes the four platforms behave identically: the orchestrator creates
 * the worktree itself, so isolation no longer depends on Claude's runtime managing it
 * or on a Copilot worker obeying a "Working directory:" line in its prompt.
 */

import { existsSync, lstatSync, mkdirSync, readFileSync, symlinkSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

export function worktreePath(mainRoot, branch) {
  return join(mainRoot, ".scratch", "worktrees", branch);
}

const DOCKER_OVERRIDE_ENTRY = "docker-compose.override.yml";

/**
 * Make sure `.worktreeinclude` at mainRoot lists docker-compose.override.yml, before any
 * worktree exists. Without this, a docker-mode project's override only reaches a worktree
 * via gen-override.sh's own docker-present fast path inside ensure-deps.sh — which requires
 * DOCKER_MARKER to already be on disk, a race the first round's concurrently-created
 * worktrees can lose. Listing the entry here means every worktree's own applyWorktreeInclude()
 * symlinks it in deterministically at creation time instead.
 *
 * Safe to call unconditionally, even when the project has no docker-compose.override.yml at
 * all: applyWorktreeInclude() already skips any entry whose source is missing from mainRoot.
 */
export function ensureWorktreeInclude(mainRoot) {
  const manifest = join(mainRoot, ".worktreeinclude");
  const existing = existsSync(manifest) ? readFileSync(manifest, "utf8") : "";
  const hasEntry = existing.split("\n").some((raw) => raw.trim() === DOCKER_OVERRIDE_ENTRY);
  if (hasEntry) return false;
  const sep = existing && !existing.endsWith("\n") ? "\n" : "";
  writeFileSync(manifest, `${existing}${sep}${DOCKER_OVERRIDE_ENTRY}\n`);
  return true;
}

/**
 * Create (or reuse) the worktree for a branch.
 * Reuse matters for resume: a retained branch already holds committed WIP.
 *
 * `expectReuse` names whether the *caller* already has a reason to believe this
 * branch should exist (the issue has recorded progress from an earlier round).
 * Reuse is otherwise silent and un-rebased: a branch left behind by an earlier,
 * abandoned attempt (branches are never deleted except by cleanup-worktrees.sh's
 * own ancestry-checked sweep) can sit in the repo with a base that predates work
 * this sprint has since merged. Reusing it as-is on what the caller thinks is a
 * *fresh* dispatch would silently carry that stale base all the way to the merge
 * step, where it surfaces 45 minutes later as an unexplained conflict. Detected
 * here instead: `base` not being an ancestor of the existing branch, on a dispatch
 * nobody expected to resume, is reported back as `stale` rather than reused.
 */
export function ensureWorktree(effects, { mainRoot, branch, base = "HEAD", expectReuse = true }) {
  const path = worktreePath(mainRoot, branch);
  const listed = effects.gitRead(["worktree", "list", "--porcelain"]).stdout;
  if (listed.includes(`worktree ${path}\n`) && existsSync(path)) return { path, created: false };

  const exists = effects.gitRead(["rev-parse", "--verify", "--quiet", `${branch}^{commit}`]).code === 0;

  if (exists && !expectReuse) {
    const isAncestor = effects.gitRead(["merge-base", "--is-ancestor", base, branch]).code === 0;
    if (!isAncestor) {
      return {
        path: null,
        created: false,
        stale: true,
        reason:
          `branch '${branch}' already exists but this issue has no recorded progress, and ` +
          `'${base}' is not an ancestor of it — likely stale from an earlier run; delete ` +
          `the branch or reconcile it by hand before retrying`,
      };
    }
  }

  mkdirSync(dirname(path), { recursive: true });
  const args = exists
    ? ["worktree", "add", path, branch]
    : ["worktree", "add", "-b", branch, path, base];
  const r = effects.git(args);
  if (r.code !== 0) throw new Error(`git worktree add failed for ${branch}: ${r.stderr.trim()}`);
  return { path, created: true, reusedBranch: exists };
}

/**
 * Symlink each `.worktreeinclude` entry into the worktree (node_modules, .venv, …).
 * Blank lines and `#` comments are skipped. A missing source is skipped, not fatal.
 *
 * `existsSync` follows symlinks, so it reports `false` for a *dangling* one — the same
 * value it reports for "nothing here yet". A dangling link that already points at the
 * current `mainRoot/<entry>` self-heals for free once that path becomes real (same target,
 * no relink needed). But a `dest` left as a broken symlink pointing anywhere else — a
 * worktree reused after `.worktreeinclude` changed, or a link this function did not create —
 * used to hit `EEXIST` from `symlinkSync` and get swallowed as "a pre-existing entry is not
 * a failure", so it never healed: the worker's own `cp .env.template .env` kept failing with
 * "not writing through dangling symlink". `lstatSync` (no follow) tells the three states
 * apart: nothing at `dest` (link it), a live entry (leave it — reuse matters for resume), or
 * a broken symlink (clear it and relink to the current source).
 */
export function applyWorktreeInclude(mainRoot, worktree) {
  const manifest = join(mainRoot, ".worktreeinclude");
  if (!existsSync(manifest)) return [];
  const linked = [];
  for (const raw of readFileSync(manifest, "utf8").split("\n")) {
    const entry = raw.trim();
    if (!entry || entry.startsWith("#")) continue;
    const src = join(mainRoot, entry);
    const dest = join(worktree, entry);
    if (!existsSync(src)) continue;

    let destStat = null;
    try {
      destStat = lstatSync(dest);
    } catch {
      /* nothing at dest — the common case, fall through to link it */
    }
    if (destStat) {
      if (!destStat.isSymbolicLink() || existsSync(dest)) continue; // live entry — leave it
      try {
        rmSync(dest);
      } catch {
        continue; // could not clear the stale link — try again next round
      }
    }

    mkdirSync(dirname(dest), { recursive: true });
    try {
      symlinkSync(src, dest);
      linked.push(entry);
    } catch {
      /* another process linked it between our check and this call — not a failure */
    }
  }
  return linked;
}

/** Remove only the worktree. Never `git branch -D` — retention decides refs. */
export function removeWorktree(effects, { mainRoot, path }) {
  if (!path) return { code: 0 };
  const r = effects.git(["worktree", "remove", "--force", path]);
  if (r.code !== 0 && existsSync(path) && !effects.dryRun) {
    // A worktree git will not release is left in place; cleanup-worktrees.sh sweeps it.
    try {
      rmSync(path, { recursive: true, force: true });
    } catch {
      /* reported by cleanup */
    }
  }
  return r;
}
