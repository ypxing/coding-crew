/**
 * tracker-config.mjs — reads which tracker backend a repo uses: the project's config.json `tracker.kind`,
 * else the legacy front matter of .coding-crew/docs/issue-tracker.md, else the user-level
 * ~/.coding-crew/config.json's, else `local`. A broken config throws rather than falling back to a silent `local`.
 */

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join } from "node:path";

export const CONFIG_REL_PATH = ".coding-crew/config.json";
const LEGACY_REL_PATH = ".coding-crew/docs/issue-tracker.md";
export const TRACKER_KINDS = ["local", "github"];

export const isObject = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

/**
 * The main checkout of the repo `cwd` is in (through a linked worktree too), else `cwd`; null when `cwd` is in no
 * repo. A linked worktree reads the main checkout's config.json, committed or not.
 */
export function mainCheckout(cwd) {
  const r = spawnSync("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], { cwd, encoding: "utf8" });
  if (r.status !== 0) return null;
  const commonDir = r.stdout.trim();
  return basename(commonDir) === ".git" ? dirname(commonDir) : cwd;
}

/** A config.json's parsed object, or null when the file is absent; throws on invalid JSON or a non-object. */
export function readConfigFile(path) {
  if (!existsSync(path)) return null;
  let config;
  try {
    config = JSON.parse(readFileSync(path, "utf8"));
  } catch (e) {
    throw new Error(`${path} is not valid JSON (${e.message})`);
  }
  if (!isObject(config)) throw new Error(`${path} must be a JSON object`);
  return config;
}

/** config.json's `tracker.kind`, or null when the file or its section is absent. */
function readConfigJson(path) {
  const config = readConfigFile(path);
  if (config === null || config.tracker === undefined) return null;
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
  // Read before the project's, as `git config` rejects a broken user config whatever overrides it.
  const userKind = readConfigJson(join(homedir(), CONFIG_REL_PATH));
  const kind = readConfigJson(join(mainRoot, CONFIG_REL_PATH));
  if (kind) return { tracker: kind, configured: true };

  const legacy = join(mainRoot, LEGACY_REL_PATH);
  if (!existsSync(legacy)) return userKind ? { tracker: userKind, configured: true } : { tracker: "local", configured: false };
  const fields = frontMatter(readFileSync(legacy, "utf8"));
  if (Object.hasOwn(fields, "repo")) {
    throw new Error(`${legacy}: \`repo\` is no longer supported — gh targets the git remote. Remove the repo: line.`);
  }
  return { tracker: fields.tracker === "github" ? "github" : "local", configured: true };
}
