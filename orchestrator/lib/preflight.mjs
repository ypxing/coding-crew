/**
 * preflight.mjs — what must hold before the first dispatch, checked once per run.
 *
 * Both checks catch a problem every issue would otherwise hit only after paying for its
 * coder and review: a dirty main checkout refuses the merge at the very end, and a feature
 * branch whose own checks already fail makes every issue's verify gate fail on code no issue
 * wrote. Neither costs a token.
 */

import { join } from "node:path";

import { depsLine, readVerifyRecord } from "./report.mjs";
import { applyWorktreeInclude, removeWorktree, worktreePath } from "./worktree.mjs";

/** Files crew-afk itself writes in the main checkout; the summary already reminds about them. */
const CREW_OWNED = new Set([".coding-crew/dev-commands.json", ".worktreeinclude"]);

/**
 * Tracked files with uncommitted changes in the main checkout, crew-afk's own excepted.
 * Untracked files are left to the merge gate: most never collide with a branch.
 */
export function dirtyTrackedFiles(effects) {
  const r = effects.gitRead(["status", "--porcelain", "-z", "--untracked-files=no"]);
  if (r.code !== 0) return [];
  const entries = r.stdout.split("\0").filter(Boolean);
  const files = [];
  for (let i = 0; i < entries.length; i++) {
    const e = entries[i];
    files.push(e.slice(3));
    // A rename or copy is followed by its source path, which is not a second change.
    if (/^[RC]/.test(e)) i++;
  }
  return files.filter((f) => !CREW_OWNED.has(f));
}

/** The branch the baseline worktree checks out: a crew branch, so verify-worktree.sh records it. */
export function baselineBranch(featureSlug) {
  return `crew/${featureSlug}/_baseline`;
}

const BASELINE_STEM = "_baseline";

/**
 * Run the project's checks once on the feature branch's tip, in a throwaway worktree set up
 * exactly as an issue's is (include, deps), so a failure here is the one every issue's verify
 * would repeat. A pass is cached by the tip's commit; a failure never is, since an
 * environment the human fixed (a service started) should be re-checked on the next run.
 *
 * Returns `{ status: "pass" | "cached" | "fail", commit, failed: [{check, log}], reason }`.
 */
export function runBaseline(ctx) {
  const { sprint, effects, options } = ctx;
  const commit = effects.gitRead(["rev-parse", `${sprint.featureBranch}^{commit}`]).stdout.trim();
  const cached = sprint.readState().baseline;
  if (commit && cached?.commit === commit && cached.verdict === "pass") {
    ctx.log(`BASELINE: pass (cached — ${sprint.featureBranch} already passed at ${commit.slice(0, 12)})`);
    return { status: "cached", commit, failed: [] };
  }

  const branch = baselineBranch(sprint.featureSlug);
  const path = worktreePath(effects.mainRoot, branch);
  // A crashed earlier run may have left both behind.
  removeWorktree(effects, { mainRoot: effects.mainRoot, path });
  effects.git(["worktree", "prune"]);
  ctx.log(`[STEP] step=baseline branch=${sprint.featureBranch} commit=${commit.slice(0, 12)}`);
  const add = effects.git(["worktree", "add", "-B", branch, path, sprint.featureBranch]);
  if (add.code !== 0) {
    // Not the project's fault: a baseline that could not run says nothing, so it does not stop the run.
    ctx.log(`BASELINE: skipped — could not create its worktree: ${add.stderr.trim()}`);
    return { status: "pass", commit, failed: [], reason: "worktree add failed" };
  }

  try {
    applyWorktreeInclude(effects.mainRoot, path);
    if (options.installDeps !== false) {
      const deps = effects.bash("ensure-deps.sh", ["--dir", path, "--slug", BASELINE_STEM, "--stem", BASELINE_STEM], {
        env: sprint.childEnv(),
      });
      const line = depsLine(deps.stdout);
      if (line) ctx.log(`baseline ${line}`);
      if (/^DEPS: failed\b/.test(line)) {
        sprint.state(["baseline", "--commit", commit, "--verdict", "fail"]);
        return { status: "fail", commit, failed: [], reason: `dependency install failed — ${line.replace(/^DEPS:\s*/, "")}` };
      }
    }
    const verify = effects.bash("verify-worktree.sh", ["--dir", path, "--stem", BASELINE_STEM], { env: sprint.childEnv() });
    ctx.log(`baseline ${verify.stdout.trim()}`);
    const verdict = verify.code === 0 ? "pass" : "fail";
    sprint.state(["baseline", "--commit", commit, "--verdict", verdict]);
    if (verdict === "pass") return { status: "pass", commit, failed: [] };
    const recordFile = join(sprint.dispatchDir, `${BASELINE_STEM}.verify.json`);
    const record = readVerifyRecord(recordFile);
    const failed = Object.entries(record.checks)
      .filter(([, result]) => result === "fail")
      .map(([check]) => ({ check, log: record.logs[check] ?? null }));
    return { status: "fail", commit, failed, reason: `verify-worktree.sh failed — see ${recordFile}` };
  } finally {
    removeWorktree(effects, { mainRoot: effects.mainRoot, path });
    effects.git(["branch", "-D", branch]);
  }
}

/** The stop message for a red baseline: which checks, where their output is, and the two ways on. */
export function baselineFailureMessage(featureBranch, result) {
  const lines = [
    `crew-afk: ${featureBranch} fails its own checks before any issue has touched it (${result.commit.slice(0, 12)}) — every issue's verify gate would fail the same way, after paying for its coder.`,
  ];
  if (result.failed.length) {
    for (const f of result.failed) lines.push(`  ${f.check}: fail${f.log ? ` — ${f.log}` : ""}`);
  } else {
    lines.push(`  ${result.reason}`);
  }
  lines.push("Fix it on the feature branch (or start the service the checks need), then re-run.");
  lines.push("To run anyway, knowing every issue will be judged against a red branch: --no-baseline.");
  return lines.join("\n");
}
