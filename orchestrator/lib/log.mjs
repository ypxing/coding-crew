/**
 * log.mjs — orchestrator.log's line format, the shape trace.sh writes too:
 *   YYYY-MM-DDTHH:MM:SSZ INFO  [MARKER] field=value ... — text
 * Level is the second column, so `grep -E ' (WARN|ERROR|FATAL) '` needs no tooling; it comes from
 * the line's first [MARKER] (MARKER_LEVELS) rather than from each call site.
 */

import { appendLine } from "./effects.mjs";

export const LEVELS = ["debug", "info", "warn", "error", "fatal"];

export const LINE_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z (DEBUG|INFO |WARN |ERROR|FATAL) /;

// debug: mechanics. warn: degraded, the run carries on by itself. error: a step failed for
// this issue. Anything unnamed is info; any *-FAIL / *-FAILED marker is an error.
// [STEP] stays info: a launcher answers "how far along is it?" from those lines on stderr.
const MARKER_LEVELS = {
  TOOL: "debug",
  "TOOL-ERROR": "warn",
  "DISPATCH-WARN": "warn",
  "STALE-BRANCH": "warn",
  "SYNC-CONFLICT-KEPT": "warn",
  "REVIEW-RETRY": "warn",
  "CODER-CLAIM": "warn",
  "PREFILTER-OVERRULED": "warn",
  "MILESTONE-PUSH-SKIPPED": "warn",
  "SYNC-CONFLICT": "error",
  "SIDECAR-MISSING": "error",
  "AGENT-ERROR": "error",
};

export function levelFor(text) {
  const m = /\[([A-Z][A-Z0-9-]*)\]/.exec(String(text));
  if (!m) return "info";
  const marker = m[1];
  if (MARKER_LEVELS[marker]) return MARKER_LEVELS[marker];
  return /-FAIL(ED)?$/.test(marker) ? "error" : "info";
}

function timestamp(now) {
  return `${now.toISOString().slice(0, 19)}Z`;
}

/** Continuation lines are indented, so every column-0 line is a header a level grep finds. */
export function formatLine(level, text, now = new Date()) {
  if (!LEVELS.includes(level)) throw new Error(`unknown log level: ${level}`);
  const [head, ...rest] = String(text).trimEnd().split("\n");
  const header = `${timestamp(now)} ${level.toUpperCase().padEnd(5)} ${head}`;
  const body = rest.filter((l) => l.trim()).map((l) => `  ${l}`);
  return [header, ...body].join("\n");
}

export function writeLog(file, text, level = levelFor(text)) {
  appendLine(file, formatLine(level, text));
}

export function atLeast(a, b) {
  return LEVELS.indexOf(a) >= LEVELS.indexOf(b);
}

/** stderr's lowest level: info by default, since a launcher agent pays tokens per stderr line. */
export function stderrThreshold(env = process.env) {
  const named = (env.CREW_LOG_LEVEL ?? "").trim().toLowerCase();
  if (named) {
    if (LEVELS.includes(named)) return { level: named, warning: null };
    return {
      level: "info",
      warning: `unknown CREW_LOG_LEVEL=${env.CREW_LOG_LEVEL} (expected ${LEVELS.join("|")}) — using info.`,
    };
  }
  return { level: env.CREW_VERBOSE ? "debug" : "info", warning: null };
}
