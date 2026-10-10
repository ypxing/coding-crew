/**
 * install-dir.mjs — where this run's installed assets live, resolved once per run.
 *
 * `CREW_INSTALL_DIR` is the `.coding-crew/` the running orchestrator was launched from
 * (`<dir>/crew-afk/main.mjs`): install.sh puts crew-afk there together with its
 * deps, so every asset sits beside it at the matching version, whether that is a project or a
 * user-level (`TARGET_REPO=$HOME`) install. An already-set `CREW_INSTALL_DIR` wins — for tests
 * and for dev in this repo, whose source orchestrator/ has no installed assets beside it.
 *
 * Everything else is a fixed sub-path of it: no search inside a run, and no per-asset variable.
 * A constant rather than a runtime read of registry.json, which is not installed into consuming
 * repos; tests/install-dir-registry.bats keeps each entry equal to its registry `dest`.
 */

import { delimiter, dirname, join, resolve } from "node:path";

export const ASSET_DIRS = {
  reviewer: "crew-afk/roles/reviewer", // skills.crew-afk.assets.dest + roles/reviewer: the reviewer checklists and scripts
  depInstall: "dep-install/scripts", // skills.dep-install.assets.dest
  solveIssue: "solve-issue/scripts", // skills.solve-issue.assets.dest — check-requires.sh
  toIssues: "to-issues/scripts", // skills.to-issues.assets.dest — lint-issues.sh
  writePr: "write-pr", // skills.write-pr.assets.dest — SKILL.md, the PR writer's procedure
};

/** `$CREW_INSTALL_DIR`, else the parent of the dir holding main.mjs. */
export function resolveInstallDir(env, orchestratorDir) {
  return resolve(env.CREW_INSTALL_DIR || dirname(orchestratorDir));
}

export function assetDir(installDir, kind) {
  return join(installDir, ASSET_DIRS[kind]);
}

/**
 * `PATH` with dep-install's `docker`/`docker-compose` shim first, so a bare `docker compose …` any
 * child makes (a coder's own, a recipe's) loads its worktree's crew override. `path` unchanged
 * when there is no install dir: a hand-made sprint.env has no installed dep-install to point at.
 */
export function pathWithShim(installDir, path) {
  if (!installDir) return path;
  const shim = join(assetDir(installDir, "depInstall"), "shim");
  return path ? `${shim}${delimiter}${path}` : shim;
}
