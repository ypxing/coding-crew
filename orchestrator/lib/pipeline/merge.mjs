/**
 * The last gate: merge, then close.
 */

import { finishRetryOrBlock } from "./finish.mjs";
import { dispatchStem, issueRef, notifyMilestone } from "./shared.mjs";

/**
 * Merge, then close only on the merge's success. Shared by the normal end-of-pipeline
 * path and the merge-failed/close-refused resume, which re-enters here directly — both
 * rely on merge-branches.sh's already-merged short-circuit and receipts.sh's own SHA-
 * bound checks to make a retry safe, not on anything re-derived above this function.
 */
export async function mergeAndClose(ctx, worker, outcome) {
  const { sprint, effects, options } = ctx;
  const { issue, branch } = worker;

  effects.git(["checkout", sprint.featureBranch]);
  ctx.log(`[STEP] slug=${dispatchStem(issue)} round=${worker.attempt} step=merge`);
  // effects.bash runs spawnSync, which blocks the same single event loop every issue's
  // dispatch shares (see pane-host/shared.mjs's paneHostExec comment for the same hazard elsewhere) —
  // without a bound here, a stalled merge (e.g. a docker-mode merge whose container hangs
  // on a network fetch) freezes the whole sprint, not just this issue.
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
  // The branch is only needed by the github path (receipts.sh check ac --branch — see
  // close-issue.sh's own comment); harmless as a trailing arg for local, which ignores it.
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
  await notifyMilestone(ctx, issue, `complete — merged and closed (round ${worker.attempt})`);
  return outcome;
}
