/**
 * skill-dirs.mjs — where each platform's installer puts a skill, as candidate dirs in lookup order.
 *
 * Project scope and user scope differ per platform (pi nests under .pi/agent/, Copilot reads
 * .github/ in a repo but ~/.copilot/ at user level), so both lists are spelled out rather than
 * derived. A platform's config-dir env var (install.sh's resolve_dest) relocates its user-level
 * dir; codex has none for skills, which it always reads from .agents/skills.
 */
import { homedir } from "node:os";
import { join } from "node:path";

const PROJECT = { pi: ".pi/skills", claude: ".claude/skills", codex: ".agents/skills", copilot: ".github/skills" };
const USER = { pi: ".pi/agent/skills", claude: ".claude/skills", codex: ".agents/skills", copilot: ".copilot/skills" };
const CONFIG_DIR_ENV = { claude: "CLAUDE_CONFIG_DIR", copilot: "COPILOT_HOME", pi: "PI_CODING_AGENT_DIR" };

/** `platform`'s own entry first, then the others. */
const ownFirst = (map, platform) => [map[platform], ...Object.entries(map).filter(([p]) => p !== platform).map(([, v]) => v)].filter(Boolean);

/**
 * `<skill>`'s install dirs, best first: the project install (a pinned copy wins), the relocated
 * user-level install, then the `$HOME` default. $HOME before os.homedir(): on Windows homedir()
 * reads USERPROFILE and would ignore a $HOME override.
 */
export function skillDirCandidates(mainRoot, platform, skill, env = process.env) {
  const home = env.HOME || homedir();
  return [
    ...ownFirst(PROJECT, platform).map((d) => join(mainRoot, d, skill)),
    ...ownFirst(CONFIG_DIR_ENV, platform).map((v) => (env[v] ? join(env[v], "skills", skill) : null)),
    ...ownFirst(USER, platform).map((d) => join(home, d, skill)),
  ].filter(Boolean);
}
