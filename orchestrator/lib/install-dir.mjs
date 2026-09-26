/**
 * install-dir.mjs — where this run's installed assets live, resolved once per run.
 *
 * `CREW_INSTALL_DIR` is the `.coding-crew/` the running orchestrator was launched from
 * (`<dir>/crew-afk/main.mjs`): install.sh puts crew-afk there together with its agent-deps and
 * deps, so every asset sits beside it at the matching version, whether that is a project or a
 * user-level (`TARGET_REPO=$HOME`) install. An already-set `CREW_INSTALL_DIR` wins — for tests
 * and for dev in this repo, whose source orchestrator/ has no installed assets beside it.
 *
 * Everything else is a fixed sub-path of it: no search inside a run, and no per-asset variable.
 * A constant rather than a runtime read of registry.json, which is not installed into consuming
 * repos; tests/install-dir-registry.bats keeps each entry equal to its registry `dest`.
 */

import { dirname, join, resolve } from "node:path";

export const ASSET_DIRS = {
  reviewer: "code-review", // agents.crew-reviewer.install.assets.dest
  depInstall: "dep-install/scripts", // skills.dep-install.assets.dest
};

/** `$CREW_INSTALL_DIR`, else the parent of the dir holding main.mjs. */
export function resolveInstallDir(env, orchestratorDir) {
  return resolve(env.CREW_INSTALL_DIR || dirname(orchestratorDir));
}

export function assetDir(installDir, kind) {
  return join(installDir, ASSET_DIRS[kind]);
}
