/**
 * skill-dirs.mjs — where each platform's installer puts a skill, as candidate dirs in lookup order.
 *
 * Every platform's dirs come from orchestrator/platforms.json (shipped with the orchestrator, so
 * the installed copy sits at the same relative path): `projectSkills` in a repo, `userSkills`
 * under $HOME. At user scope a dir under `configDir` moves to `$<configDirEnv>` when that is set
 * (install.sh's rule); any other dir stays under $HOME — codex's `.agents/skills` is not under
 * `.codex`, so CODEX_HOME relocates no skill dir.
 */
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const PLATFORM_DATA = JSON.parse(readFileSync(new URL("../platforms.json", import.meta.url), "utf8"));

/** `platform`'s own entry first, then the others, in platforms.json's order. */
const ownFirst = (platform) => [platform, ...Object.keys(PLATFORM_DATA).filter((p) => p !== platform)].filter((p) => PLATFORM_DATA[p]);

/** `p`'s user-scope skills dir relocated under its config-dir env var, or null when unset or not under its config dir. */
function relocatedUserSkills(p, env) {
  const { userSkills, configDir, configDirEnv } = PLATFORM_DATA[p];
  if (!env[configDirEnv] || !userSkills.startsWith(`${configDir}/`)) return null;
  return join(env[configDirEnv], userSkills.slice(configDir.length + 1));
}

/**
 * `<skill>`'s install dirs, best first: the project install (a pinned copy wins), the relocated
 * user-level install, then the `$HOME` default. $HOME before os.homedir(): on Windows homedir()
 * reads USERPROFILE and would ignore a $HOME override.
 */
export function skillDirCandidates(mainRoot, platform, skill, env = process.env) {
  const home = env.HOME || homedir();
  const order = ownFirst(platform);
  return [
    ...order.map((p) => join(mainRoot, PLATFORM_DATA[p].projectSkills, skill)),
    ...order.map((p) => relocatedUserSkills(p, env)).filter(Boolean).map((d) => join(d, skill)),
    ...order.map((p) => join(home, PLATFORM_DATA[p].userSkills, skill)),
  ];
}
