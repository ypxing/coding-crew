/**
 * prd.mjs — where this sprint's PRD is, the one owner of that lookup.
 *
 * The local `.scratch/<slug>/PRD.md`, else — under `tracker: github` — fetched with
 * `tracker/cli.mjs prd` and saved as `prd-issue.md`, whose earlier copy is used only when the
 * fetch fails (or under another tracker). With no PRD, the feature's intent is the one issue
 * carrying a `## Decisions` heading (see `intentIssue`). Located once per sprint.
 */

import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { readTrackerConfig } from "../../tracker/tracker-config.mjs";
import { listFeatureIssues } from "./tracker.mjs";

const TRACKER_CLI = fileURLToPath(new URL("../../tracker/cli.mjs", import.meta.url));
const cache = new WeakMap();

/**
 * The feature's intent for this sprint: its PRD, or the one issue carrying its decisions; null when there is none.
 * Located once per sprint; re-located only when the cached file is gone (a local intent issue moves open/ → done/ when closed).
 */
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
 * With no PRD: the feature's one issue whose body has a `## Decisions` heading (a one-slice
 * feature carries its own decisions). Zero matches → null; two or more → null plus a warning, since
 * a wrong intent would mislead the reviewer. Local: every open and done issue, through the tracker. Github:
 * `tracker/cli.mjs known` (open and closed), the match saved as `intent-issue.md`, whose earlier
 * copy is used only when `known` fails. Never throws.
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

/** The `.md` files in `dir` whose body has a `## Decisions` heading, sorted by name. */
function withDecisions(dir) {
  return readdirSync(dir)
    .filter((n) => n.endsWith(".md"))
    .sort()
    .map((n) => join(dir, n))
    .filter((path) => DECISIONS.test(readFileSync(path, "utf8")));
}
