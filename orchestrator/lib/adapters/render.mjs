/**
 * renderRolePrompt — a role's protocol, ready to hand to a CLI.
 *
 * Reads `orchestrator/roles/<role>.md` (shipped with the orchestrator, so the installed copy sits
 * at the same relative path) and expands each whole-line `{{FRAGMENT:<key>}}` by
 * `scripts/render-skill.sh`'s rule (`skills/_shared/fragments/<key>.md`, under the repo root or the
 * installed `.coding-crew/`). A missing protocol
 * or fragment, or any `{{…}}` left over, throws before anything is spawned. Each skill the
 * protocol names gets the absolute path of its installed SKILL.md, so a worker in a worktree
 * (where gitignored skill dirs are absent) can still read it.
 */
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { skillDirCandidates } from "../skill-dirs.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROLES_DIR = resolve(HERE, "../../roles");
// The repo checkout, or the installed `.coding-crew/` (crew-afk installs to `.coding-crew/crew-afk/`).
const FRAGMENT_ROOT = resolve(HERE, "../../..");

/** role → the dispatch's agent label; the plain roles have no protocol. */
export const ROLE_AGENTS = { coder: "crew-coder", reviewer: "crew-reviewer", triage: "crew-triage", followup: "crew-followup" };

/**
 * role → what it may do, declared once; each adapter's `policyArgs` turns it into its CLI's flags.
 * The reviewer and triage are read-only and may spawn sub-agents (whether to is their call); the coder
 * may not, since sub-agents would edit one worktree at once; the follow-up (feature) agent may edit, with none. Effort: `high` for the three dispatched roles; afk.effort overrides it per role. A plain role (no protocol: command finder, PR writer) has none, so it runs at its CLI's default.
 */
export const ROLE_POLICY = {
  coder: { readOnly: false, subagents: false, effort: "high" },
  reviewer: { readOnly: true, subagents: true, effort: "high" },
  triage: { readOnly: true, subagents: true, effort: "high" },
  // The feature agent is interactive, not dispatched: it edits in `_feature` once the sprint ends, with the CLI's own permission
  // prompts on (the developer is at its terminal). No default effort: its CLI's applies unless afk.effort.followup sets one.
  followup: { readOnly: false },
};

const NAMED_SKILLS = ["solve-issue", "dep-install", "tdd"];

export function roleOfAgent(agent) {
  return Object.keys(ROLE_AGENTS).find((r) => ROLE_AGENTS[r] === agent) ?? null;
}

/** The SKILL.md `platform`'s installer wrote for `skill`, best scope first; null when none is installed. */
export function installedSkillFile(mainRoot, platform, skill) {
  return skillDirCandidates(mainRoot, platform, skill).map((d) => join(d, "SKILL.md")).find((f) => existsSync(f)) ?? null;
}

/**
 * The rendered protocol of `role` (or of its agent label, e.g. "crew-coder"); null for a role with none.
 * `rolesDir` is a test seam: a protocol other than the shipped one.
 */
export function renderRolePrompt(role, platform, { mainRoot = null, rolesDir = ROLES_DIR } = {}) {
  const name = ROLE_AGENTS[role] ? role : roleOfAgent(role);
  if (!name) return null;
  const src = join(rolesDir, `${name}.md`);
  if (!existsSync(src)) throw new Error(`protocol for ${ROLE_AGENTS[name]} not found (${src})`);

  const out = [];
  for (const line of readFileSync(src, "utf8").split("\n")) {
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
