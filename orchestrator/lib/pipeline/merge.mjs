/**
 * The last gate: merge, then close.
 */

import { finishRetryOrBlock } from "./finish.mjs";
import { dispatchStem, issueRef, notifyMilestone } from "./shared.mjs";

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
    timeoutMs: options.mergeTimeoutMs,
  });
  ctx.log(`slug=${issue.slug} round=${worker.attempt} ${merge.stdout.trim()}`);
  if (merge.code !== 0) {
    if (merge.code === 124) {
      effects.git(["merge", "--abort"]);
    }
    return finishRetryOrBlock(ctx, worker, outcome, "merge-failed");
  }

  ctx.log(`[STEP] slug=${dispatchStem(issue)} round=${worker.attempt} step=close`);
  // The branch is for github's AC receipt check; local ignores it.
  const close = effects.bash("close-issue.sh", [issueRef(issue), branch], {
    env: sprint.childEnv(),
    timeoutMs: options.mergeTimeoutMs,
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
