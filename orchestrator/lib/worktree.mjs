/**
 * worktree.mjs — one isolated checkout per issue, created by the orchestrator itself so isolation
 * never depends on a platform's runtime or a worker obeying its prompt.
 */

import { copyFileSync, existsSync, lstatSync, mkdirSync, readFileSync, realpathSync, symlinkSync, rmSync } from "node:fs";
import { dirname, isAbsolute, join, relative, sep } from "node:path";

import { adoptWorktree } from "./pane-host/index.mjs";

// main.mjs also sets CREW_WORKTREE_ROOT from afk.worktreeRoot.
export function worktreeRoot(mainRoot) {
  const override = process.env.CREW_WORKTREE_ROOT;
  if (!override) return join(mainRoot, ".scratch", "worktrees");
  return isAbsolute(override) ? override : join(mainRoot, override);
}

export function worktreePath(mainRoot, branch) {
  return join(worktreeRoot(mainRoot), branch);
}

/** The sprint's feature-branch checkout: `<worktreeRoot>/crew/<slug>/_feature`, on `feature/<slug>`. */
export function featureWorktreePath(mainRoot, featureSlug) {
  return worktreePath(mainRoot, `crew/${featureSlug}/_feature`);
}

/** Provisioned as if `.worktreeinclude` listed them; `.env` can appear only after the first worktrees exist. */
const BUILTIN_ENTRIES = [".env"];

/** Copied, not symlinked: a container that bind-mounts only the worktree cannot resolve a link to mainRoot. */
const COPY_ENTRIES = new Set([".env"]);

/**
 * Create (or reuse) the worktree for a branch. With `expectReuse` false, an existing branch `base`
 * is not an ancestor of is `stale` — its old base would surface later as a merge conflict — unless
 * it holds no unique work (no commits past `base`, or `base`'s tree), when it is recreated.
 */
export function ensureWorktree(effects, { mainRoot, branch, base = "HEAD", expectReuse = true, mode = "issue", path: at, adopt = null }) {
  const path = at ?? worktreePath(mainRoot, branch);
  if (mode === "checkout") return checkoutWorktree(effects, { mainRoot, branch, base, path, adopt });
  const listed = effects.gitRead(["worktree", "list", "--porcelain"]).stdout;
  if (listed.includes(`worktree ${path}\n`) && existsSync(path)) return { path, created: false, reusedBranch: true };

  const blocker = releaseBranch(effects, listed, branch);
  if (blocker) return { path: null, created: false, stale: true, reason: blocker };

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
  if (adopt) adoptWorktree(effects, path, adopt);
  return { path, created: true, reusedBranch: exists };
}

/** git lists worktrees by real path, which differs through a symlinked mainRoot (macOS's `/var` → `/private/var`). */
const realPath = (path) => {
  try {
    return realpathSync(path);
  } catch {
    return path;
  }
};

/** Whether `git worktree list --porcelain` output `listed` registers `path`, compared by real path. */
export function listsWorktree(listed, path) {
  const want = realPath(path);
  return listed.split("\n").some((line) => line.startsWith("worktree ") && realPath(line.slice("worktree ".length)) === want);
}

/** The slug of a directory inside `<worktreeRoot>/crew/<slug>/_feature`, else null; compared by real path. */
export function featureSlugOfPath(root, dir) {
  const rel = relative(realPath(root), realPath(dir));
  if (!rel || rel === ".." || rel.startsWith(`..${sep}`) || isAbsolute(rel)) return null;
  const m = /^crew[\\/]([^\\/]+)[\\/]_feature(?:[\\/]|$)/.exec(rel);
  return m ? m[1] : null;
}

function branchAt(listed, path) {
  const want = realPath(path);
  const block = listed.split("\n\n").find((b) => {
    const line = b.split("\n").find((l) => l.startsWith("worktree "));
    return line && realPath(line.slice("worktree ".length)) === want;
  });
  return block?.split("\n").find((l) => l.startsWith("branch "))?.slice("branch ".length) ?? null;
}

/**
 * The feature branch's `_feature` worktree: its commits are never discarded or judged stale. A
 * dirty worktree at `path` is refused and a clean one switched in place (a live agent's cwd may be
 * in it); only crew-made holders of the branch are released.
 */
function checkoutWorktree(effects, { mainRoot, branch, base, path, adopt }) {
  let listed = effects.gitRead(["worktree", "list", "--porcelain"]).stdout;
  if (existsSync(path) && listsWorktree(listed, path)) {
    // Whatever it has checked out: a developer's work in progress is never removed to make room.
    const status = effects.gitRead(["status", "--porcelain"], { cwd: path });
    const dirty = status.stdout.trim();
    if (status.code !== 0 || dirty) {
      const files = dirty ? `:\n${dirty}` : ` (git status exit ${status.code}: ${(status.stderr ?? "").trim()})`;
      return {
        path: null,
        created: false,
        stale: true,
        reason:
          `the feature worktree '${path}' has uncommitted changes${files}\n` +
          `commit or discard them (or 'git worktree remove ${path}'), then re-run`,
      };
    }
    if (branchAt(listed, path) === `refs/heads/${branch}`) {
      if (adopt) adoptWorktree(effects, path, adopt);
      return { path, created: false, reusedBranch: true };
    }
    // Clean, on another branch or detached: switched in place, never removed — a live feature
    // agent (or the process that launched this run) may have its cwd in it.
    const blocker = releaseBranch(effects, listed, branch, { onlyCrewMade: (holder) => crewMade(mainRoot, holder) });
    if (blocker) return { path: null, created: false, stale: true, reason: blocker };
    const exists = effects.gitRead(["rev-parse", "--verify", "--quiet", `${branch}^{commit}`]).code === 0;
    const r = effects.git(exists ? ["checkout", "-q", branch] : ["checkout", "-q", "-b", branch, base], { cwd: path });
    if (r.code !== 0) throw new Error(`git checkout ${branch} failed in ${path}: ${r.stderr.trim()}`);
    if (adopt) adoptWorktree(effects, path, adopt);
    return { path, created: false, reusedBranch: exists };
  }
  if (listsWorktree(listed, path) || existsSync(path)) {
    removeWorktree(effects, { path });
    effects.git(["worktree", "prune"]);
    listed = effects.gitRead(["worktree", "list", "--porcelain"]).stdout;
  }
  const blocker = releaseBranch(effects, listed, branch, { onlyCrewMade: (holder) => crewMade(mainRoot, holder) });
  if (blocker) return { path: null, created: false, stale: true, reason: blocker };

  const exists = effects.gitRead(["rev-parse", "--verify", "--quiet", `${branch}^{commit}`]).code === 0;
  mkdirSync(dirname(path), { recursive: true });
  const r = effects.git(exists ? ["worktree", "add", path, branch] : ["worktree", "add", "-b", branch, path, base]);
  if (r.code !== 0) throw new Error(`git worktree add failed for ${branch}: ${r.stderr.trim()}`);
  if (adopt) adoptWorktree(effects, path, adopt);
  return { path, created: true, reusedBranch: exists };
}

/** The worktree `git worktree list --porcelain` output `listed` has `branch` checked out in, else null; `main` for the main checkout. */
export function branchHolder(listed, branch) {
  const entries = listed.split("\n\n").map((block) => {
    const lines = block.split("\n");
    return {
      path: lines.find((l) => l.startsWith("worktree "))?.slice("worktree ".length),
      branch: lines.find((l) => l.startsWith("branch "))?.slice("branch ".length),
    };
  });
  const index = entries.findIndex((e) => e.branch === `refs/heads/${branch}`);
  return index === -1 ? null : { path: entries[index].path, main: index === 0 };
}

/** Whether `holder` lies under `<worktreeRoot>`, where crew-afk makes its worktrees; compared by real path. */
export function crewMade(mainRoot, holder) {
  return join(realPath(holder), "/").startsWith(join(realPath(worktreeRoot(mainRoot)), "/"));
}

/**
 * Free `branch` from any other worktree holding it: a gone one is pruned, a clean one removed (its
 * commits live on the branch). A reason string when the holder must be kept — the main checkout,
 * uncommitted changes, or one `onlyCrewMade` rejects — else null.
 */
function releaseBranch(effects, listed, branch, { onlyCrewMade } = {}) {
  const held = branchHolder(listed, branch);
  if (!held) return null;
  const holder = held.path;

  if (held.main) return `branch '${branch}' is checked out in the main checkout at '${holder}'; switch it to another branch before retrying`;
  if (!existsSync(holder)) {
    effects.git(["worktree", "prune"]);
    return null;
  }
  if (onlyCrewMade && !onlyCrewMade(holder)) {
    return `branch '${branch}' is checked out in the worktree '${holder}', which crew-afk did not make; switch it to another branch before retrying`;
  }
  const status = effects.gitRead(["status", "--porcelain"], { cwd: holder });
  if (status.code !== 0 || status.stdout.trim()) {
    return (
      `branch '${branch}' is checked out by another worktree at '${holder}' with uncommitted ` +
      `changes; commit or discard them, then 'git worktree remove ${holder}' before retrying`
    );
  }
  const removed = effects.git(["worktree", "remove", holder]);
  if (removed.code !== 0) return `branch '${branch}' is held by worktree '${holder}', which git would not remove: ${removed.stderr.trim()}`;
  return null;
}

/**
 * Provision each `.worktreeinclude` entry, plus `BUILTIN_ENTRIES`: a symlink, or a copy for
 * `COPY_ENTRIES`; a missing source is skipped. `lstatSync` because `existsSync` follows links: a
 * dangling symlink at `dest` is cleared and reprovisioned, not left to fail the worker's writes.
 */
export function applyWorktreeInclude(mainRoot, worktree) {
  const manifest = join(mainRoot, ".worktreeinclude");
  const listed = existsSync(manifest) ? readFileSync(manifest, "utf8").split("\n").map((raw) => raw.trim()) : [];
  const entries = new Set([...listed.filter((entry) => entry && !entry.startsWith("#")), ...BUILTIN_ENTRIES]);
  const linked = [];
  for (const entry of entries) {
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
 * Merge the feature branch into a reused issue branch before the coder starts, so it works from the
 * current base. A conflict goes to resolve-merge-conflicts.sh first (registry versions / CHANGELOG
 * appends); anything else aborts, or with `keepConflict` stays in the worktree for the caller.
 */
export function mergeFeatureBranch(effects, { worktree, branch, featureBranch, keepConflict = false }) {
  if (!featureBranch || featureBranch === branch) return { merged: false };
  const pending = effects.gitRead(["log", `${branch}..${featureBranch}`, "--oneline"], { cwd: worktree }).stdout.trim();
  if (!pending) return { merged: false };

  const r = effects.git(
    ["merge", "--no-ff", featureBranch, "-m", `Merge '${featureBranch}' into '${branch}'`],
    { cwd: worktree },
  );
  if (r.code !== 0) {
    // HEAD is the issue branch here, the reverse of merge-branches.sh's merge.
    const resolved = effects.bash("resolve-merge-conflicts.sh", ["--head-is-branch"], { cwd: worktree });
    if (resolved.code === 0) {
      const c = effects.git(["commit", "--no-verify", "-q", "-m", `Merge '${featureBranch}' into '${branch}'`], { cwd: worktree });
      if (c.code === 0) return { merged: true, autoResolved: true, decisions: resolved.stdout.split("\n").filter(Boolean) };
    }
  }
  if (r.code !== 0 && keepConflict) {
    // Left for the coder to resolve. With nothing conflicted (an untracked file in the way) it is
    // aborted below. featureSha is MERGE_HEAD: the feature branch can move on while the coder works.
    const files = effects.gitRead(["diff", "--name-only", "--diff-filter=U"], { cwd: worktree }).stdout.trim().split("\n").filter(Boolean);
    if (files.length) {
      const featureSha = effects.gitRead(["rev-parse", "-q", "--verify", "MERGE_HEAD"], { cwd: worktree }).stdout.trim();
      return { merged: false, conflict: true, kept: true, files, featureSha };
    }
  }
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
