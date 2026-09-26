/**
 * The last gate: merge, then close.
 */

import { finishBlocked, finishRetryOrBlock } from "./finish.mjs";
import { MAIN_TREE_DIRTY_TAG, MERGE_CONFLICT_TAG, dispatchStem, issueRef, notifyMilestone, taggedReason } from "./shared.mjs";

/**
 * Merge, then close only on the merge's success. Also the merge route's entry point: a
 * retry is safe because merge-branches.sh short-circuits an already-merged branch and
 * both scripts re-check the SHA-bound receipts themselves.
 */
export async function mergeAndClose(ctx, worker, outcome) {
  const { sprint, effects, options } = ctx;
  const { issue, branch } = worker;

  effects.git(["checkout", sprint.featureBranch]);
  ctx.log(`[STEP] slug=${dispatchStem(issue)} round=${worker.attempt} step=merge`);
  // Bounded: effects.bash is spawnSync, so a stalled merge would freeze the whole sprint.
  const merge = effects.bash("merge-branches.sh", [sprint.featureBranch, branch], {
    env: sprint.childEnv(),
    timeoutMs: options.timeoutMs.merge,
  });
  ctx.log(`slug=${issue.slug} round=${worker.attempt} ${merge.stdout.trim()}`);
  if (merge.code !== 0) {
    if (merge.code === 124) {
      effects.git(["merge", "--abort"]);
    }
    // A retry would re-run the same merge into the same dirty checkout: block for a human.
    const dirty = /failed \(main-tree-dirty — ([^)]*)\)/.exec(merge.stderr);
    if (dirty) {
      const summary = `${dirty[1]} — commit or stash them in the main checkout, then re-run`;
      return finishBlocked(ctx, worker, outcome, taggedReason(MAIN_TREE_DIRTY_TAG, summary));
    }
    // merge-branches.sh's own conflict line; it has already aborted the merge.
    if (/failed \(conflict/.test(merge.stderr)) {
      const summary = `'${sprint.featureBranch}' gained commits that conflict with '${branch}'`;
      return finishRetryOrBlock(ctx, worker, outcome, taggedReason(MERGE_CONFLICT_TAG, summary));
    }
    return finishRetryOrBlock(ctx, worker, outcome, "merge-failed");
  }

  ctx.log(`[STEP] slug=${dispatchStem(issue)} round=${worker.attempt} step=close`);
  // The branch is for github's AC receipt check; local ignores it.
  const close = effects.bash("close-issue.sh", [issueRef(issue), branch], {
    env: sprint.childEnv(),
    timeoutMs: options.timeoutMs.merge,
  });
  ctx.log(`slug=${issue.slug} round=${worker.attempt} ${close.stdout.trim()}`);
  if (close.code !== 0) {
    return finishRetryOrBlock(ctx, worker, outcome, `close-refused — ${close.stderr.trim() || close.stdout.trim()}`);
  }

  sprint.complete(issue.slug, branch);
  outcome.status = "complete";
  notifyMilestone(ctx, issue, `complete — merged and closed (round ${worker.attempt})`);
  return outcome;
}
