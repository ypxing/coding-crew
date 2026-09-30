/**
 * labels.mjs — crew-afk's `in-progress` display label, under `tracker: github`.
 *
 * Display only: it tells a human on GitHub which issues a run is working, and never decides
 * what is dispatched — the feature lease does. Every write goes through issue-labels.sh (a
 * no-op under `tracker: local`), and a failed write warns and never stops the sprint.
 */

/**
 * Run one label effect for `issue`. True when the write succeeded; false when skipped or failed.
 * A local issue (it has a file) has no label to write, so it never spawns the script.
 */
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

/**
 * Right after the lease is acquired: drop `in-progress` from every issue in the milestone. The
 * lease says no other run is alive, so what still carries it was left by one that died.
 */
export function sweepInProgress({ effects, sprint, log }) {
  if (effects.dryRun) return;
  const r = effects.bash("issue-labels.sh", ["sweep", sprint.featureSlug], { env: sprint.childEnv() });
  if (r.code !== 0) log(`[IN-PROGRESS-SWEEP-FAILED] ${(r.stderr || r.stdout).trim()}`, "warn");
}
