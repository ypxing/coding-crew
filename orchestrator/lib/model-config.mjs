/**
 * .coding-crew/afk-models.json — an optional per-role model override for a sprint.
 * Roles: coder, reviewer, triage, commandsDiscovery, coverageValidation.
 *
 * Deliberately no numeric capability ranking across arbitrary model strings: --model's
 * vocabulary is opaque past this file (Claude Code's own aliases on the claude platform,
 * whatever string each other platform's own CLI accepts otherwise — see dispatch.mjs). The
 * only guarantee this module gives is by construction, not by comparison: an omitted
 * reviewer/triage/commandsDiscovery/coverageValidation inherits the coder's own resolved
 * value, so a role can never end up weaker than the coder by accident. A role only diverges
 * when the file names it explicitly — coverage-validation.sh's own prompt still warns not to
 * point this one at a cheap tier; naming it here is advisory-checked (see the weaker-tier
 * warning below) but not blocked, same as every other role.
 */
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

// The one place this repo *does* know a real order — Claude Code's own aliases — used only
// for an advisory warning, never to block a sprint. Any other string (an explicit model ID,
// "inherit", or another platform's own vocabulary) is unranked and skipped silently.
const CLAUDE_TIER_RANK = { haiku: 0, sonnet: 1, opus: 2 };

// crew-coder's own baseline on the claude platform when nothing else names a coder model.
// Resolved here rather than left to the agent file's own frontmatter default so that an
// unconfigured sprint's reviewer/triage genuinely match what the coder runs on (the
// "never weaker than coder by accident" guarantee below only sees values this function
// returns — a default living only in claude.agent.md's frontmatter is invisible to it).
const CLAUDE_DEFAULT_CODER_MODEL = "sonnet";

export function loadModelConfig(mainRoot) {
  const path = join(mainRoot, ".coding-crew", "afk-models.json");
  if (!existsSync(path)) return {};
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (err) {
    console.error(`crew-afk: .coding-crew/afk-models.json is not valid JSON (${err.message}) — ignoring it.`);
    return {};
  }
}

export function resolveModelTiers({ fileConfig, cliModel, platform }) {
  const coderDefault = platform === "claude" ? CLAUDE_DEFAULT_CODER_MODEL : null;
  const coder = cliModel ?? fileConfig.coder ?? coderDefault;
  const reviewer = fileConfig.reviewer ?? coder;
  const triage = fileConfig.triage ?? coder;
  const commandsDiscovery = fileConfig.commandsDiscovery ?? coder;
  const coverageValidation = fileConfig.coverageValidation ?? coder;

  const warnings = [];
  if (platform === "claude") {
    for (const [role, value] of [
      ["reviewer", reviewer],
      ["triage", triage],
      ["commandsDiscovery", commandsDiscovery],
      ["coverageValidation", coverageValidation],
    ]) {
      if (
        value !== coder &&
        coder in CLAUDE_TIER_RANK &&
        value in CLAUDE_TIER_RANK &&
        CLAUDE_TIER_RANK[value] < CLAUDE_TIER_RANK[coder]
      ) {
        warnings.push(
          `${role} model "${value}" is a weaker tier than coder model "${coder}" — the ` +
            "standard that role holds the branch to may be lower than intended.",
        );
      }
    }
  }
  return { coder, reviewer, triage, commandsDiscovery, coverageValidation, warnings };
}
