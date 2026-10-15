/**
 * tracker-config.mjs — reads which tracker backend a repo uses: config.json's `tracker.kind`, else
 * the legacy front matter of .coding-crew/docs/issue-tracker.md, else `local`. A broken config
 * throws rather than falling back to a silent `local`.
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
