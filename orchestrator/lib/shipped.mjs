/**
 * shipped.mjs — close the feature's issues whose PR has merged, under `tracker: github`.
 *
 * GitHub closes an issue on merge only if it linked the PR's `Closes #n` line, and it can fail
 * to. close-shipped.sh reads the merged PRs' bodies itself and closes what they name (then the
 * PRD, once no work issue is left). A no-op under `tracker: local`; a failure only warns.
 */

/** Right after the lease is acquired: no run is alive, so every awaiting-merge issue is settled. */
export function closeShipped({ effects, sprint, log }) {
  if (effects.dryRun) return;
  const r = effects.bash("close-shipped.sh", [sprint.featureSlug, sprint.featureBranch], { env: sprint.childEnv() });
  if (r.code !== 0) log(`[CLOSE-SHIPPED-FAILED] ${(r.stderr || r.stdout).trim()}`, "warn");
  else for (const line of r.stdout.split("\n").filter((l) => l.startsWith("CLOSED:"))) log(`[SHIPPED] ${line}`, "info");
}
