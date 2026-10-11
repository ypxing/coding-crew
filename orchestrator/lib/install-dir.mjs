/**
 * install-dir.mjs — where this run's installed assets live: the `.coding-crew/` main.mjs was launched
 * from, unless CREW_INSTALL_DIR is preset (tests, dev). ASSET_DIRS is a constant because
 * registry.json is not installed into consuming repos.
 */

import { delimiter, dirname, join, resolve } from "node:path";

export const ASSET_DIRS = {
  reviewer: "crew-afk/roles/reviewer", // skills.crew-afk.assets.dest + roles/reviewer: the reviewer checklists and scripts
  depInstall: "dep-install/scripts", // skills.dep-install.assets.dest
  solveIssue: "solve-issue/scripts", // skills.solve-issue.assets.dest — check-requires.sh
  toIssues: "to-issues/scripts", // skills.to-issues.assets.dest — lint-issues.sh
  writePr: "write-pr", // skills.write-pr.assets.dest — SKILL.md, the PR writer's procedure
};

export function resolveInstallDir(env, orchestratorDir) {
  return resolve(env.CREW_INSTALL_DIR || dirname(orchestratorDir));
}

export function assetDir(installDir, kind) {
  return join(installDir, ASSET_DIRS[kind]);
}

/** dep-install's docker shim first on `PATH`, so any child's bare `docker compose` loads its worktree's override. */
export function pathWithShim(installDir, path) {
  if (!installDir) return path;
  const shim = join(assetDir(installDir, "depInstall"), "shim");
  return path ? `${shim}${delimiter}${path}` : shim;
}
