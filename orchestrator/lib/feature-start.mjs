/**
 * feature-start.mjs — where a sprint's feature branch starts, from origin's view of it: a new branch
 * from the branch origin's HEAD names, an origin-only one from origin's tip, a local one only when
 * that is safe, and a shipped one (its own origin branch gone) renamed aside. Each git effect is one call.
 */

import { existsSync } from "node:fs";

import { branchHolder, crewMade } from "./worktree.mjs";

const sha = (effects, ref) => {
  const r = effects.gitRead(["rev-parse", "--verify", "-q", `${ref}^{commit}`]);
  return r.code === 0 ? r.stdout.trim() : null;
};

const configValue = (effects, key) => effects.gitRead(["config", "--get", key]).stdout.trim();

const isAncestor = (effects, a, b) => effects.gitRead(["merge-base", "--is-ancestor", a, b]).code === 0;

const yyyymmdd = (d) => `${d.getFullYear()}${String(d.getMonth() + 1).padStart(2, "0")}${String(d.getDate()).padStart(2, "0")}`;

/**
 * Settle `branch` before its `_feature` worktree is made. Returns `{ base, fastForward, messages }` —
 * `base` for ensureWorktree when the branch does not exist yet, `fastForward` a sha the checked-out
 * branch must fast-forward to, `messages` setup lines for stderr — or `{ error, messages }` to stop.
 */
export function settleFeatureBranch(effects, { branch, defaultBranch, now = new Date() }) {
  const messages = [];
  const local = sha(effects, `refs/heads/${branch}`);
  if (effects.gitRead(["remote", "get-url", "origin"]).code !== 0) {
    return { base: sha(effects, `refs/heads/${defaultBranch}`) ? defaultBranch : "HEAD", messages };
  }

  // Never the remote-tracking refs: they are as old as the last fetch, and refs/remotes/origin/HEAD can
  // name a branch origin no longer has. No prompt: nobody is there to answer it.
  const env = { GIT_TERMINAL_PROMPT: "0" };
  const listed = effects.gitRead(["ls-remote", "--symref", "origin", "HEAD", `refs/heads/${defaultBranch}`, `refs/heads/${branch}`], { env });
  if (listed.code !== 0) return { error: `crew-afk: cannot read origin (git ls-remote origin): ${listed.stderr.trim()}`, messages };
  const tips = new Map();
  let headBranch = null;
  for (const line of listed.stdout.split("\n").filter(Boolean)) {
    const [left, ref] = line.split("\t");
    if (!left.startsWith("ref: ")) tips.set(ref, left);
    else if (ref === "HEAD") headBranch = left.slice("ref: refs/heads/".length);
  }
  // origin's own default branch; the local guess only when origin's HEAD names none.
  const fromHead = Boolean(headBranch && tips.has("HEAD"));
  const startBranch = fromHead ? headBranch : tips.has(`refs/heads/${defaultBranch}`) ? defaultBranch : null;
  const remoteDefault = fromHead ? tips.get("HEAD") : (tips.get(`refs/heads/${defaultBranch}`) ?? null);
  const remote = tips.get(`refs/heads/${branch}`) ?? null;

  const refspecs = [...new Set([startBranch, remote ? branch : null].filter(Boolean))].map((b) => `+refs/heads/${b}:refs/remotes/origin/${b}`);
  if (refspecs.length) {
    const fetched = effects.git(["fetch", "-q", "origin", ...refspecs], { env });
    if (fetched.code !== 0) return { error: `crew-afk: cannot fetch from origin (git fetch origin): ${fetched.stderr.trim()}`, messages };
  }

  // Only an empty origin has no default branch to start from; a non-empty one without one stops the run.
  const noStart = () => {
    if (remoteDefault) return null;
    const heads = effects.gitRead(["ls-remote", "--heads", "origin"], { env });
    if (heads.code !== 0) return { error: `crew-afk: cannot read origin (git ls-remote --heads origin): ${heads.stderr.trim()}`, messages };
    if (!heads.stdout.trim()) return null;
    return {
      error:
        `crew-afk: origin has branches but none to start ${branch} from: its HEAD names no branch it has, and it has no ${defaultBranch}.\n` +
        `Point origin's HEAD at its default branch, then re-run.`,
      messages,
    };
  };

  const fresh = () => {
    const stop = noStart();
    if (stop) return stop;
    // An empty origin: the local default branch, as without origin.
    if (!remoteDefault) return { base: sha(effects, `refs/heads/${defaultBranch}`) ? defaultBranch : "HEAD", messages };
    // --no-track: autoSetupMerge would make origin/<default> its upstream, and a later run would read that as shipped.
    const r = effects.git(["branch", "--no-track", branch, remoteDefault]);
    if (r.code !== 0) return { error: `crew-afk: could not create ${branch} at origin/${startBranch}: ${r.stderr.trim()}`, messages };
    return { base: branch, messages };
  };

  if (!local && !remote) return fresh();
  if (!local) {
    for (const args of [["branch", "--no-track", branch, remote], ["config", `branch.${branch}.remote`, "origin"], ["config", `branch.${branch}.merge`, `refs/heads/${branch}`]]) {
      const r = effects.git(args);
      if (r.code !== 0) return { error: `crew-afk: could not create ${branch} from origin/${branch}: ${r.stderr.trim()}`, messages };
    }
    return { base: branch, messages };
  }
  if (remote) {
    if (isAncestor(effects, remote, local)) return { base: branch, messages };
    if (isAncestor(effects, local, remote)) return { base: branch, fastForward: remote, messages };
    return {
      error:
        `crew-afk: ${branch} (${local}) and origin/${branch} (${remote}) have diverged.\n` +
        `Reconcile them by hand (merge or rebase, then push), then re-run.`,
      messages,
    };
  }

  const shipped = configValue(effects, `branch.${branch}.remote`) === "origin" && configValue(effects, `branch.${branch}.merge`) === `refs/heads/${branch}`;
  if (!shipped) return { base: branch, messages };

  // A rename moves whatever checkout holds the branch along with it: only crew-afk's own may be moved.
  const held = branchHolder(effects.gitRead(["worktree", "list", "--porcelain"]).stdout, branch);
  if (held && existsSync(held.path) && (held.main || !crewMade(effects.mainRoot, held.path))) {
    const where = held.main ? `the main checkout at '${held.path}'` : `the worktree '${held.path}', which crew-afk did not make`;
    return {
      error: `crew-afk: ${branch} has shipped (origin/${branch} is gone) and would be renamed aside, but it is checked out in ${where}; switch it to another branch, then re-run.`,
      messages,
    };
  }

  const stop = noStart();
  if (stop) return stop;

  // Renamed, never deleted: commits that never reached the PR stay reachable.
  const stem = `${branch}-shipped-${yyyymmdd(now)}`;
  let aside = stem;
  for (let n = 2; sha(effects, `refs/heads/${aside}`); n++) aside = `${stem}-${n}`;
  const moved = effects.git(["branch", "-m", branch, aside]);
  if (moved.code !== 0) return { error: `crew-afk: could not rename shipped ${branch} to ${aside}: ${moved.stderr.trim()}`, messages };
  messages.push(`[BRANCH-SHIPPED] renamed ${branch} → ${aside}`);
  return fresh();
}
