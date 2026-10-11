/**
 * prd.mjs — the one owner of locating a sprint's PRD: local `.scratch/<slug>/PRD.md`, else under
 * `tracker: github` the fetched PRD issue (its saved copy only when the fetch fails), else the one
 * issue carrying `## Decisions` (`intentIssue`).
 */

import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { readTrackerConfig } from "../../tracker/tracker-config.mjs";
import { listFeatureIssues } from "./tracker.mjs";

const TRACKER_CLI = fileURLToPath(new URL("../../tracker/cli.mjs", import.meta.url));
const cache = new WeakMap();

/** Re-located only when the cached file is gone: a local intent issue moves open/ → done/ on close. */
export function prdPath(ctx) {
  const { sprint } = ctx;
  const cached = cache.get(sprint);
  if (cached === undefined || (cached !== null && !existsSync(cached))) cache.set(sprint, locate(ctx));
  return cache.get(sprint);
}

function locate(ctx) {
  return locatePrd(ctx) ?? intentIssue(ctx);
}

const DECISIONS = /^## Decisions[ \t]*$/m;

function locatePrd({ sprint, effects, log = () => {} }) {
  const dir = join(effects.mainRoot, ".scratch", sprint.featureSlug);
  const local = join(dir, "PRD.md");
  if (existsSync(local)) return local;
  const file = join(dir, "prd-issue.md");
  // Under github a saved prd-issue.md may be an earlier run's copy of an edited issue: fetch first, keep it as the fallback.
  const saved = () => (existsSync(file) ? file : null);
  if (readTrackerConfig(effects.mainRoot).tracker !== "github") return saved();

  const cli = process.env.CREW_TRACKER_CLI || TRACKER_CLI;
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

/**
 * With no PRD: the one issue with a `## Decisions` heading. Two or more → null plus a warning, since
 * a wrong intent would mislead the reviewer. Never throws.
 */
function intentIssue({ sprint, effects, log = () => {} }) {
  const dir = join(effects.mainRoot, ".scratch", sprint.featureSlug);
  const file = join(dir, "intent-issue.md");
  const saved = () => (existsSync(file) ? file : null);
  const github = readTrackerConfig(effects.mainRoot).tracker === "github";
  let found = [];
  let tmp = null;
  try {
    if (github) {
      const cli = process.env.CREW_TRACKER_CLI || TRACKER_CLI;
      tmp = mkdtempSync(join(tmpdir(), "intent-known-"));
      const r = effects.exec("node", [cli, "known", "--feature-slug", sprint.featureSlug, "--out", tmp, "--main-root", effects.mainRoot], { mutating: false });
      if (r.code === 3) return saved(); // the milestone has no issues
      if (r.code !== 0 || r.error) {
        log(`[WARN] PRD: could not list the feature's issues for its decisions (exit ${r.code}) — using the saved intent issue, if any`, "warn");
        return saved();
      }
      found = withDecisions(tmp);
    } else {
      found = listFeatureIssues(effects.mainRoot, { featureSlug: sprint.featureSlug }).filter((i) => DECISIONS.test(i.text)).map((i) => i.path);
    }
    if (found.length > 1) {
      log(`[WARN] PRD: ${found.length} issues carry a \`## Decisions\` section (${found.map((f) => basename(f)).join(", ")}) — no feature intent is used`, "warn");
      return null;
    }
    if (!found.length) return null;
    if (!github) return found[0];
    mkdirSync(dir, { recursive: true });
    writeFileSync(file, readFileSync(found[0], "utf8"));
    return file;
  } catch (err) {
    log(`[WARN] PRD: could not look up the feature's intent issue: ${err.message}`, "warn");
    return saved();
  } finally {
    if (tmp) rmSync(tmp, { recursive: true, force: true });
  }
}

function withDecisions(dir) {
  return readdirSync(dir)
    .filter((n) => n.endsWith(".md"))
    .sort()
    .map((n) => join(dir, n))
    .filter((path) => DECISIONS.test(readFileSync(path, "utf8")));
}
