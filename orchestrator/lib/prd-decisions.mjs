/**
 * prd-decisions.mjs — the PRD's `- **D<n>** …` / `- **B<n>** …` lines, by ID.
 *
 * An issue names the ones it implements under `## Implements`; the per-branch review judges the
 * branch against each like a criterion. The PRD is located once per sprint: the local
 * `.scratch/<slug>/PRD.md`, else — under `tracker: github` — fetched with `trackers/github.mjs prd` (the CLI prd-audit.sh uses)
 * and saved as `prd-issue.md`, which is read back only when the fetch fails (or under another tracker).
 */

import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { readTrackerConfig } from "./tracker-config.mjs";
import { sectionBody } from "./trackers/body-format.mjs";

const GITHUB_CLI = fileURLToPath(new URL("./trackers/github.mjs", import.meta.url));
const cache = new WeakMap();

/**
 * Pure: every `- **<ID>**` / `* **<ID>**` line of a PRD, ID → the line verbatim, whatever follows the
 * ID (`—`, `:`, `(auto):`) — the lines `lint-issues.sh`'s PRD coverage counts.
 */
export function parsePrdDecisions(text) {
  const out = new Map();
  for (const line of String(text ?? "").split("\n")) {
    const m = /^\s*[-*]\s+\*\*([A-Z]\d+)\*\*/.exec(line);
    if (m && !out.has(m[1])) out.set(m[1], line.replace(/\s+$/, ""));
  }
  return out;
}

/** Pure: the IDs an issue's `## Implements` names. A parenthetical ("(part of D11)") is a note, not a claim. */
export function implementedIds(issueText) {
  const body = sectionBody(String(issueText ?? ""), "Implements");
  if (!body) return [];
  return [...new Set(body.replace(/\([^)]*\)/g, " ").match(/\b[A-Z]\d+\b/g) ?? [])];
}

/** The PRD's text for this sprint's feature, '' when there is none. Located at most once per sprint. */
function prdText(ctx) {
  const { sprint, effects } = ctx;
  if (!cache.has(sprint)) cache.set(sprint, locate(ctx, sprint, effects));
  return cache.get(sprint);
}

/** ID → PRD line for this sprint's feature; empty when there is no PRD. Fetched at most once per sprint. */
export function loadPrdDecisions(ctx) {
  return parsePrdDecisions(prdText(ctx));
}

/** One `## <heading>` section of the PRD, body verbatim; null when there is no PRD or it has no such section. */
export function loadPrdSection(ctx, heading) {
  return sectionBody(prdText(ctx), heading) || null;
}

function locate({ log = () => {} }, sprint, effects) {
  const dir = join(effects.mainRoot, ".scratch", sprint.featureSlug);
  const local = join(dir, "PRD.md");
  if (existsSync(local)) return readFileSync(local, "utf8");
  const file = join(dir, "prd-issue.md");
  const github = readTrackerConfig(effects.mainRoot).tracker === "github";
  // Under github a saved prd-issue.md may be an earlier run's copy of an edited issue: fetch first, keep it as the fallback.
  const saved = () => (existsSync(file) ? readFileSync(file, "utf8") : "");
  if (!github) return saved();

  const cli = process.env.CREW_GITHUB_TRACKER_CLI || GITHUB_CLI;
  const r = effects.exec("node", [cli, "prd", "--feature-slug", sprint.featureSlug, "--main-root", effects.mainRoot], { mutating: false });
  if (r.code === 3) return ""; // the milestone has no PRD issue
  if (r.code !== 0 || r.error) {
    log(`[WARN] PRD decisions: could not fetch the PRD issue (exit ${r.code}) — branch reviews use the saved copy, if any`, "warn");
    return saved();
  }
  try {
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, r.stdout);
  } catch (err) {
    rmSync(file, { force: true });
    log(`[WARN] PRD decisions: could not save the PRD issue: ${err.message}`, "warn");
  }
  return r.stdout;
}

/** The lines `issueText`'s `## Implements` selects; an ID with no PRD line is warned about, never fatal. */
export function decisionsFor(ctx, issueText, label = "issue") {
  const ids = implementedIds(issueText);
  if (!ids.length) return [];
  const all = loadPrdDecisions(ctx);
  if (!all.size) return [];
  const lines = [];
  for (const id of ids) {
    if (all.has(id)) lines.push(all.get(id));
    else ctx.log?.(`[WARN] PRD decisions: ${label} implements ${id}, which has no line in the PRD`, "warn");
  }
  return lines;
}
