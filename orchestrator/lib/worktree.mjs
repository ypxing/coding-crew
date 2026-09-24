/**
 * worktree.mjs — one isolated checkout per issue, for every platform.
 *
 * This is what makes the four platforms behave identically: the orchestrator creates
 * the worktree itself, so isolation no longer depends on Claude's runtime managing it
 * or on a Copilot worker obeying a "Working directory:" line in its prompt.
 */

import { copyFileSync, existsSync, lstatSync, mkdirSync, readFileSync, symlinkSync, rmSync, writeFileSync } from "node:fs";
import { dirname, isAbsolute, join } from "node:path";

/**
 * Base directory worktrees are created under, overridable via `CREW_WORKTREE_ROOT`
 * (absolute, or relative to `mainRoot`) for repos that need worktrees off the main
 * checkout's disk/volume. Defaults to today's `.scratch/worktrees`.
 */
export function worktreeRoot(mainRoot) {
  const override = process.env.CREW_WORKTREE_ROOT;
  if (!override) return join(mainRoot, ".scratch", "worktrees");
  return isAbsolute(override) ? override : join(mainRoot, override);
}

export function worktreePath(mainRoot, branch) {
  return join(worktreeRoot(mainRoot), branch);
}

const AUTO_INCLUDE_ENTRIES = ["docker-compose.override.yml", ".env"];

/**
 * Entries provisioned as a real copy instead of a symlink. `.env` is the one case where
 * a symlink to mainRoot's absolute path is actively wrong, not just unnecessary: a worker
 * running inside a container that bind-mounts only the worktree (not mainRoot) resolves
 * the link to a path that does not exist in its filesystem, so a from-worktree read/write
 * of `.env` fails with ENOENT even though the file is "there" from the host's point of
 * view. A copy has no such target to lose.
 */
const COPY_ENTRIES = new Set([".env"]);

/**
 * Make sure `.worktreeinclude` at mainRoot lists docker-compose.override.yml and .env, before
 * any worktree exists. Without this, each only reaches a worktree via its own script's fast
 * path — docker-compose.override.yml via gen-override.sh's docker-present check inside
 * ensure-deps.sh (which requires DOCKER_MARKER to already be on disk, a race the first round's
 * concurrently-created worktrees can lose), .env via dep-install's ensure-env.sh (which
 * requires a worker to have actually reached that step first). Listing both entries here means
 * every worktree's own applyWorktreeInclude() provisions them in deterministically at creation
 * time instead, before any of that has had a chance to run.
 *
 * Safe to call unconditionally, even when the project has neither file yet:
 * applyWorktreeInclude() already skips any entry whose source is missing from mainRoot.
 */
export function ensureWorktreeInclude(mainRoot) {
  const manifest = join(mainRoot, ".worktreeinclude");
  let existing = existsSync(manifest) ? readFileSync(manifest, "utf8") : "";
  const lines = existing.split("\n").map((raw) => raw.trim());
  const missing = AUTO_INCLUDE_ENTRIES.filter((entry) => !lines.includes(entry));
  if (!missing.length) return false;
  const sep = existing && !existing.endsWith("\n") ? "\n" : "";
  writeFileSync(manifest, `${existing}${sep}${missing.join("\n")}\n`);
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
 *
 * Two cases auto-resolve rather than staying `stale`, both because the branch holds no
 * unique work: it has no commits `base` lacks (a worker that died before committing), or
 * its tree is byte-identical to `base`'s (debris whose commits were squashed into the
 * feature branch elsewhere — ancestry can't see that, tree equality can). The branch is
 * deleted and recreated fresh from `base`. A branch with real unique content still stalls
 * for a human.
 */
export function ensureWorktree(effects, { mainRoot, branch, base = "HEAD", expectReuse = true }) {
  const path = worktreePath(mainRoot, branch);
  const listed = effects.gitRead(["worktree", "list", "--porcelain"]).stdout;
  if (listed.includes(`worktree ${path}\n`) && existsSync(path)) return { path, created: false, reusedBranch: true };

  let exists = effects.gitRead(["rev-parse", "--verify", "--quiet", `${branch}^{commit}`]).code === 0;

  if (exists && !expectReuse) {
    const isAncestor = effects.gitRead(["merge-base", "--is-ancestor", base, branch]).code === 0;
    if (!isAncestor) {
      const baseTree = effects.gitRead(["rev-parse", `${base}^{tree}`]).stdout.trim();
      const branchTree = effects.gitRead(["rev-parse", `${branch}^{tree}`]).stdout.trim();
      const sameTree = !!baseTree && baseTree === branchTree;
      const noUniqueCommits = effects.gitRead(["rev-list", "--count", `${base}..${branch}`]).stdout.trim() === "0";
      const discarded = (sameTree || noUniqueCommits) && effects.git(["branch", "-D", branch]).code === 0;
      if (!discarded) {
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
      exists = false;
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
 * Provision each `.worktreeinclude` entry into the worktree: a symlink for most entries
 * (node_modules, .venv, …), a real copy for `COPY_ENTRIES` (see `.env` above). Blank lines
 * and `#` comments are skipped. A missing source is skipped, not fatal.
 *
 * `existsSync` follows symlinks, so it reports `false` for a *dangling* one — the same
 * value it reports for "nothing here yet". For a symlinked entry, a dangling link that
 * already points at the current `mainRoot/<entry>` self-heals for free once that path
 * becomes real (same target, no relink needed). But a `dest` left as a broken symlink
 * pointing anywhere else — a worktree reused after `.worktreeinclude` changed, or a link
 * this function did not create — used to hit `EEXIST` from `symlinkSync` and get swallowed
 * as "a pre-existing entry is not a failure", so it never healed: the worker's own
 * `cp .env.template .env` kept failing with "not writing through dangling symlink".
 * `lstatSync` (no follow) tells the three states apart: nothing at `dest` (provision it), a
 * live entry (leave it — reuse matters for resume), or a broken symlink (clear it and
 * reprovision from the current source). A copy entry can never be left dangling, so for it
 * this only ever clears a stale *symlink* sitting at `dest` (e.g. one made before `.env`
 * moved into `COPY_ENTRIES`) before copying fresh.
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
    const copy = COPY_ENTRIES.has(entry);

    let destStat = null;
    try {
      destStat = lstatSync(dest);
    } catch {
      /* nothing at dest — the common case, fall through to provision it */
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
      if (copy) copyFileSync(src, dest);
      else symlinkSync(src, dest);
      linked.push(entry);
    } catch {
      /* another process provisioned it between our check and this call — not a failure */
    }
  }
  return linked;
}

/**
 * Forward-merge the feature branch into a reused issue branch, inside its own worktree,
 * before the coder starts. A reused branch (`ensureWorktree`'s `reusedBranch: true`) was
 * forked from the feature branch as it stood at some earlier round or an earlier
 * `crew-afk` invocation — every sibling issue merged into the feature branch since, or
 * any commit landed on it by hand, is invisible to this branch until it merges that
 * history back in. Left undone, the coder works from a stale base and the gap only
 * surfaces ~45 minutes later as an unexplained conflict at the merge gate.
 *
 * Never attempted for a brand-new branch (`reusedBranch: false` — nothing to merge yet,
 * it forked from the current tip). On conflict: aborts cleanly and reports it, exactly
 * like merge-branches.sh's own "never attempts resolution" rule — reconciling by hand
 * is the caller's job, not this function's.
 */
export function mergeFeatureBranch(effects, { worktree, branch, featureBranch }) {
  if (!featureBranch || featureBranch === branch) return { merged: false };
  const pending = effects.gitRead(["log", `${branch}..${featureBranch}`, "--oneline"], { cwd: worktree }).stdout.trim();
  if (!pending) return { merged: false };

  const r = effects.git(
    ["merge", "--no-ff", featureBranch, "-m", `Merge '${featureBranch}' into '${branch}'`],
    { cwd: worktree },
  );
  if (r.code !== 0) {
    effects.git(["merge", "--abort"], { cwd: worktree });
    return {
      merged: false,
      conflict: true,
      reason:
        `feature branch '${featureBranch}' has commits since '${branch}' was created, and merging them in ` +
        `conflicted — aborted cleanly; reconcile '${branch}' with '${featureBranch}' by hand before retrying`,
    };
  }
  return { merged: true };
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
