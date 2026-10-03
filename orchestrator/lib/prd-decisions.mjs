/**
 * prd-decisions.mjs — the PRD's `- **D<n>** — …` / `- **B<n>** — …` lines, by ID.
 *
 * An issue names the ones it implements under `## Implements`; the per-branch review judges the
 * branch against each like a criterion. The PRD is located once per sprint: the local
 * `.scratch/<slug>/PRD.md`, else a `prd-issue.md` an earlier fetch left, else — under
 * `tracker: github` — fetched with `trackers/github.mjs prd` (the CLI prd-audit.sh uses).
 */

import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { readTrackerConfig } from "./tracker-config.mjs";
import { sectionBody } from "./trackers/body-format.mjs";

const GITHUB_CLI = fileURLToPath(new URL("./trackers/github.mjs", import.meta.url));
const cache = new WeakMap();

/** Pure: every `- **<ID>** — …` line of a PRD, ID → the line verbatim. */
export function parsePrdDecisions(text) {
  const out = new Map();
  for (const line of String(text ?? "").split("\n")) {
    const m = /^\s*[-*]\s+\*\*([A-Z]\d+)\*\*\s*[—–-]/.exec(line);
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

/** ID → PRD line for this sprint's feature; empty when there is no PRD. Fetched at most once per sprint. */
export function loadPrdDecisions(ctx) {
  const { sprint, effects } = ctx;
  if (cache.has(sprint)) return cache.get(sprint);
  const decisions = locate(ctx, sprint, effects);
  cache.set(sprint, decisions);
  return decisions;
}

function locate({ log = () => {} }, sprint, effects) {
  const dir = join(effects.mainRoot, ".scratch", sprint.featureSlug);
  for (const name of ["PRD.md", "prd-issue.md"]) {
    const file = join(dir, name);
    if (existsSync(file)) return parsePrdDecisions(readFileSync(file, "utf8"));
  }
  if (readTrackerConfig(effects.mainRoot).tracker !== "github") return new Map();

  const file = join(dir, "prd-issue.md");
  const cli = process.env.CREW_GITHUB_TRACKER_CLI || GITHUB_CLI;
  const r = effects.exec("node", [cli, "prd", "--feature-slug", sprint.featureSlug, "--main-root", effects.mainRoot], { mutating: false });
  if (r.code === 3) return new Map(); // the milestone has no PRD issue
  if (r.code !== 0 || r.error) {
    log(`[WARN] PRD decisions: could not fetch the PRD issue (exit ${r.code}) — branch reviews proceed without them`, "warn");
    return new Map();
  }
  try {
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, r.stdout);
  } catch (err) {
    rmSync(file, { force: true });
    log(`[WARN] PRD decisions: could not save the PRD issue: ${err.message}`, "warn");
  }
  return parsePrdDecisions(r.stdout);
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
