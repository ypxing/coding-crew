/**
 * prd.mjs — where this sprint's PRD is, the one owner of that lookup.
 *
 * The local `.scratch/<slug>/PRD.md`, else — under `tracker: github` — fetched with
 * `tracker/cli.mjs prd` and saved as `prd-issue.md`, whose earlier copy is used only when the
 * fetch fails (or under another tracker). Located once per sprint.
 */

import { existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { readTrackerConfig } from "../../tracker/tracker-config.mjs";

const TRACKER_CLI = fileURLToPath(new URL("../../tracker/cli.mjs", import.meta.url));
const cache = new WeakMap();

/** The PRD file for this sprint's feature, null when there is none. Located at most once per sprint. */
export function prdPath(ctx) {
  const { sprint } = ctx;
  if (!cache.has(sprint)) cache.set(sprint, locate(ctx));
  return cache.get(sprint);
}

function locate({ sprint, effects, log = () => {} }) {
  const dir = join(effects.mainRoot, ".scratch", sprint.featureSlug);
  const local = join(dir, "PRD.md");
  if (existsSync(local)) return local;
  const file = join(dir, "prd-issue.md");
  // Under github a saved prd-issue.md may be an earlier run's copy of an edited issue: fetch first, keep it as the fallback.
  const saved = () => (existsSync(file) ? file : null);
  if (readTrackerConfig(effects.mainRoot).tracker !== "github") return saved();

  const cli = process.env.CREW_GITHUB_TRACKER_CLI || TRACKER_CLI;
  const r = effects.exec("node", [cli, "prd", "--feature-slug", sprint.featureSlug, "--main-root", effects.mainRoot], { mutating: false });
  if (r.code === 3) return null; // the milestone has no PRD issue
  if (r.code !== 0 || r.error) {
    log(`[WARN] PRD: could not fetch the PRD issue (exit ${r.code}) — using the saved copy, if any`, "warn");
    return saved();
  }
  try {
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, r.stdout);
    return file;
  } catch (err) {
    rmSync(file, { force: true });
    log(`[WARN] PRD: could not save the PRD issue: ${err.message}`, "warn");
    return null;
  }
}
