/**
 * worktree.mjs — one isolated checkout per issue, for every platform.
 *
 * This is what makes the four platforms behave identically: the orchestrator creates
 * the worktree itself, so isolation no longer depends on Claude's runtime managing it
 * or on a Copilot worker obeying a "Working directory:" line in its prompt.
 */

import { existsSync, mkdirSync, readFileSync, symlinkSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";

export function worktreePath(mainRoot, branch) {
  return join(mainRoot, ".scratch", "worktrees", branch);
}

/**
 * Create (or reuse) the worktree for a branch.
 * Reuse matters for resume: a retained branch already holds committed WIP.
 */
export function ensureWorktree(effects, { mainRoot, branch, base = "HEAD" }) {
  const path = worktreePath(mainRoot, branch);
  const listed = effects.gitRead(["worktree", "list", "--porcelain"]).stdout;
  if (listed.includes(`worktree ${path}\n`) && existsSync(path)) return { path, created: false };

  mkdirSync(dirname(path), { recursive: true });
  const exists = effects.gitRead(["rev-parse", "--verify", "--quiet", `${branch}^{commit}`]).code === 0;
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
    if (!existsSync(src) || existsSync(dest)) continue;
    mkdirSync(dirname(dest), { recursive: true });
    try {
      symlinkSync(src, dest);
      linked.push(entry);
    } catch {
      /* a pre-existing entry is not a failure */
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
