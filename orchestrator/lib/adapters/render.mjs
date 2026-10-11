/**
 * renderRolePrompt — a role's protocol from `orchestrator/roles/<role>.md`, ready to hand to a CLI.
 * Whole-line `{{FRAGMENT:<key>}}`s expand by render-skill.sh's rule; a missing piece or a leftover
 * `{{…}}` throws before anything spawns. Each named skill gets its installed SKILL.md's absolute
 * path, since a worktree lacks the gitignored skill dirs.
 */
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { skillDirCandidates } from "../skill-dirs.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROLES_DIR = resolve(HERE, "../../roles");
// The repo checkout, or the installed `.coding-crew/`.
const FRAGMENT_ROOT = resolve(HERE, "../../..");

/** The plain roles have no protocol. */
export const ROLE_AGENTS = { coder: "crew-coder", reviewer: "crew-reviewer", triage: "crew-triage", followup: "crew-followup" };

/**
 * Each adapter's `policyArgs` turns this into its CLI's flags. The coder may not spawn sub-agents:
 * they would edit one worktree at once. A plain role has no policy and runs at its CLI's defaults.
 */
export const ROLE_POLICY = {
  coder: { readOnly: false, subagents: false, effort: "high" },
  reviewer: { readOnly: true, subagents: true, effort: "high" },
  triage: { readOnly: true, subagents: true, effort: "high" },
  // Interactive: the CLI's own permission prompts stay on, and its effort applies unless afk.effort.followup sets one.
  followup: { readOnly: false },
};

const NAMED_SKILLS = ["solve-issue", "dep-install", "tdd"];

export function roleOfAgent(agent) {
  return Object.keys(ROLE_AGENTS).find((r) => ROLE_AGENTS[r] === agent) ?? null;
}

export function installedSkillFile(mainRoot, platform, skill) {
  return skillDirCandidates(mainRoot, platform, skill).map((d) => join(d, "SKILL.md")).find((f) => existsSync(f)) ?? null;
}

/** `part` appends `<role>/<part>.md`, which only that dispatch reads; `rolesDir` is a test seam. */
export function renderRolePrompt(role, platform, { mainRoot = null, rolesDir = ROLES_DIR, part = null } = {}) {
  const name = ROLE_AGENTS[role] ? role : roleOfAgent(role);
  if (!name) return null;
  const src = join(rolesDir, `${name}.md`);
  if (!existsSync(src)) throw new Error(`protocol for ${ROLE_AGENTS[name]} not found (${src})`);
  let source = readFileSync(src, "utf8");
  if (part) {
    const partSrc = join(rolesDir, name, `${part}.md`);
    if (!existsSync(partSrc)) throw new Error(`protocol part '${part}' for ${ROLE_AGENTS[name]} not found (${partSrc})`);
    source = `${source.replace(/\n*$/, "")}\n\n${readFileSync(partSrc, "utf8")}`;
  }

  const out = [];
  for (const line of source.split("\n")) {
    const m = line.match(/^\s*\{\{FRAGMENT:([A-Za-z0-9_-]+)\}\}\s*$/);
    if (!m) {
      out.push(line.replaceAll("{{PLATFORM}}", platform));
      continue;
    }
    const key = m[1];
    const frag = join(FRAGMENT_ROOT, "skills/_shared/fragments", `${key}.md`);
    if (!existsSync(frag)) throw new Error(`fragment '${key}' needed by ${ROLE_AGENTS[name]}'s protocol not found (skills/_shared/fragments/${key}.md)`);
    out.push(readFileSync(frag, "utf8").replace(/\n$/, ""));
  }
  let text = out.join("\n");

  const left = text.match(/\{\{[A-Z][^}]*\}\}/);
  if (left) throw new Error(`unexpanded placeholder ${left[0]} in ${ROLE_AGENTS[name]}'s rendered protocol`);

  const named = NAMED_SKILLS.filter((s) => text.includes(`\`${s}\``));
  if (mainRoot && named.length) {
    const lines = named.map((s) => `- \`${s}\`: ${installedSkillFile(mainRoot, platform, s) ?? "not installed"}`);
    text += `\n\n## Installed skills\n\nRead each skill's SKILL.md at this absolute path; its \`<skill-dir>\` is that file's directory.\n\n${lines.join("\n")}\n`;
  }
  return text;
}
