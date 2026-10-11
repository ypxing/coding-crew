/**
 * shipped.mjs — close the feature's issues whose PR has merged, under `tracker: github`. GitHub's
 * own close-on-merge can miss, so close-shipped.sh closes what merged PR bodies name (then the PRD).
 */

/** Right after the lease is acquired: no run is alive, so every awaiting-merge issue is settled. */
export function closeShipped({ effects, sprint, log }) {
  if (effects.dryRun) return;
  const r = effects.bash("close-shipped.sh", [sprint.featureSlug, sprint.featureBranch], { env: sprint.childEnv() });
  if (r.code !== 0) log(`[CLOSE-SHIPPED-FAILED] ${(r.stderr || r.stdout).trim()}`, "warn");
  else for (const line of r.stdout.split("\n").filter((l) => l.startsWith("CLOSED:"))) log(`[SHIPPED] ${line}`, "info");
}
