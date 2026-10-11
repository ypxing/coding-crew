/**
 * labels.mjs — crew-afk's `in-progress` display label under `tracker: github`. Display only: the
 * feature lease decides what is dispatched, and a failed write only warns.
 */

/** True when the write succeeded. A local issue (it has a file) has no label to write. */
export function labelIssue(ctx, action, issue) {
  const { effects, sprint } = ctx;
  if (effects.dryRun || issue.number == null || issue.path) return false;
  const r = effects.bash("issue-labels.sh", [action, String(issue.number)], { env: sprint.childEnv() });
  if (r.code !== 0) {
    ctx.log(`[IN-PROGRESS-LABEL-FAILED] action=${action} slug=${issue.slug} — ${(r.stderr || r.stdout).trim()}`, "warn");
    return false;
  }
  return true;
}

/** Right after the lease: no other run is alive, so any `in-progress` label left was left by a dead one. */
export function sweepInProgress({ effects, sprint, log }) {
  if (effects.dryRun) return;
  const r = effects.bash("issue-labels.sh", ["sweep", sprint.featureSlug], { env: sprint.childEnv() });
  if (r.code !== 0) log(`[IN-PROGRESS-SWEEP-FAILED] ${(r.stderr || r.stdout).trim()}`, "warn");
}
