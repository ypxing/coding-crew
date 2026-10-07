/**
 * tracker-config.mjs — reads which issue-tracker backend a repo uses.
 *
 * The single source of truth is the optional YAML front matter atop
 * .coding-crew/docs/issue-tracker.md:
 *
 *   ---
 *   tracker: github        # or "local"
 *   # repo: owner/name     # optional override — omit to let `gh` infer it from the git remote
 *   ---
 *
 * Absent doc, absent front matter, or an absent field are all zero-config: existing
 * local-tracker installs need no front matter at all. Pure read — no network calls,
 * no file writes.
 */

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

const CONFIG_REL_PATH = ".coding-crew/docs/issue-tracker.md";

/** `{tracker, repo}`, defaulting to `{tracker: "local", repo: null}`. */
export function readTrackerConfig(mainRoot) {
  const fallback = { tracker: "local", repo: null };
  const path = join(mainRoot, CONFIG_REL_PATH);
  if (!existsSync(path)) return fallback;

  const text = readFileSync(path, "utf8");
  const match = /^---\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)/.exec(text);
  if (!match) return fallback;

  const fields = {};
  for (const line of match[1].split(/\r?\n/)) {
    const m = /^([A-Za-z_][\w-]*)\s*:\s*(.*)$/.exec(line);
    if (!m) continue;
    const value = m[2]
      .replace(/\s+#.*$/, "")
      .trim()
      .replace(/^["']|["']$/g, "");
    fields[m[1]] = value;
  }

  return {
    tracker: fields.tracker === "github" ? "github" : "local",
    repo: fields.repo || null,
  };
}
