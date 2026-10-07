/**
 * tracker-config.mjs — reads which issue-tracker backend a repo uses.
 *
 * The tracker choice is the `tracker` section of the repo's .coding-crew/config.json:
 *
 *   { "tracker": { "kind": "github" } }     // or "local"
 *
 * Precedence: that section, else the legacy YAML front matter atop
 * .coding-crew/docs/issue-tracker.md (`tracker: github|local`; a repo relying on a user-level
 * install is never migrated off it), else `local`. `configured` says whether a choice was made:
 * the section exists, or the legacy file does (with or without front matter).
 *
 * Never a silent `local` for a broken config: a config.json that is not JSON, an unknown
 * `tracker.kind`, or a legacy front matter naming `repo:` (removed: `gh` targets the git remote)
 * throws. Pure read — no network calls, no file writes. `cli.mjs config` prints the result, and
 * scripts/tracker/tracker-config.sh reads it from there.
 */

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

const CONFIG_REL_PATH = ".coding-crew/config.json";
const LEGACY_REL_PATH = ".coding-crew/docs/issue-tracker.md";
export const TRACKER_KINDS = ["local", "github"];

const isObject = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

/** config.json's `tracker.kind`, or null when the file or its section is absent. */
function readConfigJson(path) {
  if (!existsSync(path)) return null;
  let config;
  try {
    config = JSON.parse(readFileSync(path, "utf8"));
  } catch (e) {
    throw new Error(`${path} is not valid JSON (${e.message})`);
  }
  if (!isObject(config)) throw new Error(`${path} must be a JSON object`);
  if (config.tracker === undefined) return null;
  const kind = config.tracker?.kind;
  if (!isObject(config.tracker) || !TRACKER_KINDS.includes(kind)) {
    throw new Error(`${path}: "tracker.kind" is ${JSON.stringify(kind)} (expected ${TRACKER_KINDS.join(", ")}), as in {"tracker": {"kind": "github"}}`);
  }
  return kind;
}

/** The legacy doc's front-matter fields (`{}` when it has none). */
function frontMatter(text) {
  const match = /^---\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)/.exec(text);
  const fields = {};
  if (!match) return fields;
  for (const line of match[1].split(/\r?\n/)) {
    const m = /^([A-Za-z_][\w-]*)\s*:\s*(.*)$/.exec(line);
    if (!m) continue;
    fields[m[1]] = m[2]
      .replace(/\s+#.*$/, "")
      .trim()
      .replace(/^["']|["']$/g, "");
  }
  return fields;
}

/** `{tracker: "local"|"github", configured: boolean}`; throws on an invalid config. */
export function readTrackerConfig(mainRoot) {
  const kind = readConfigJson(join(mainRoot, CONFIG_REL_PATH));
  if (kind) return { tracker: kind, configured: true };

  const legacy = join(mainRoot, LEGACY_REL_PATH);
  if (!existsSync(legacy)) return { tracker: "local", configured: false };
  const fields = frontMatter(readFileSync(legacy, "utf8"));
  if (Object.hasOwn(fields, "repo")) {
    throw new Error(`${legacy}: \`repo\` is no longer supported — gh targets the git remote. Remove the repo: line.`);
  }
  return { tracker: fields.tracker === "github" ? "github" : "local", configured: true };
}
