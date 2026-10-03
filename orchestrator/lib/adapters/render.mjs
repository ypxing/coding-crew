/**
 * renderRolePrompt — a role's protocol, ready to hand to a CLI, with no agent file involved.
 *
 * Reads `agents/<agent>/protocol.md` and expands each whole-line `{{FRAGMENT:<key>}}` by
 * `scripts/render-skill.sh`'s rules (`skills/_shared/fragments/<platform>/<key>.md`, then
 * `.../common/<key>.md`). A missing protocol or fragment, or any `{{…}}` left over, throws
 * before anything is spawned. Skills the protocol names get their installed absolute paths.
 *
 * Source roots, first hit wins: `$CREW_INSTALL_DIR` (installed), then this repo's checkout.
 */
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { ASSET_DIRS } from "../install-dir.mjs";

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");

/** role → the directory under agents/ that holds its protocol; the plain roles have none. */
export const ROLE_AGENT_DIRS = { coder: "crew-coder", reviewer: "crew-reviewer", triage: "crew-triage" };

const SKILL_ASSETS = { "solve-issue": "solveIssue", "dep-install": "depInstall" };

export function roleOfAgent(agent) {
  return Object.keys(ROLE_AGENT_DIRS).find((r) => ROLE_AGENT_DIRS[r] === agent) ?? null;
}

/** The rendered protocol of `role` (or of an agent dir name such as "crew-coder"); null for a role with none. */
export function renderRolePrompt(role, platform, { installDir = null } = {}) {
  const agent = ROLE_AGENT_DIRS[role] ?? (roleOfAgent(role) ? role : null);
  if (!agent) return null;
  const roots = [installDir, REPO_ROOT].filter(Boolean);
  const find = (rel) => roots.map((r) => join(r, rel)).find((p) => existsSync(p)) ?? null;

  const src = find(join("agents", agent, "protocol.md"));
  if (!src) throw new Error(`protocol for ${agent} not found (agents/${agent}/protocol.md under ${roots.join(" or ")})`);

  const out = [];
  for (const line of readFileSync(src, "utf8").split("\n")) {
    const m = line.match(/^\s*\{\{FRAGMENT:([A-Za-z0-9_-]+)\}\}\s*$/);
    if (!m) {
      out.push(line.replaceAll("{{PLATFORM}}", platform));
      continue;
    }
    const key = m[1];
    const frag = find(join("skills/_shared/fragments", platform, `${key}.md`)) ?? find(join("skills/_shared/fragments/common", `${key}.md`));
    if (!frag) throw new Error(`fragment '${key}' needed by ${agent}'s protocol not found (skills/_shared/fragments/${platform}/${key}.md or common/${key}.md)`);
    out.push(readFileSync(frag, "utf8").replace(/\n$/, ""));
  }
  let text = out.join("\n");

  const left = text.match(/\{\{[A-Z][^}]*\}\}/);
  if (left) throw new Error(`unexpanded placeholder ${left[0]} in ${agent}'s rendered protocol`);

  if (installDir) {
    const named = Object.keys(SKILL_ASSETS).filter((s) => text.includes(`\`${s}\``));
    if (named.length) {
      text += `\n\n## Installed skill locations\n\n${named.map((s) => `- \`${s}\` scripts: ${join(installDir, ASSET_DIRS[SKILL_ASSETS[s]])}`).join("\n")}\n`;
    }
  }
  return text;
}
