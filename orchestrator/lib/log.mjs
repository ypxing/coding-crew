/**
 * log.mjs — the one line format of a sprint's orchestrator.log.
 *
 *   2026-09-22T04:28:54Z INFO  [MARKER] field=value ... — text
 *
 * The level is the second column, so `grep -E ' (WARN|ERROR|FATAL) '` answers "what went
 * wrong" with no tooling. trace.sh writes the same shape; this
 * module is the node side of it.
 *
 * Every line reaches the file. stderr gets those at or above stderrThreshold(): info by
 * default, since a launcher agent pays tokens for each stderr line it reads.
 *
 * A caller rarely names a level: it comes from the line's first [MARKER] (MARKER_LEVELS),
 * so a new ctx.log() call site is levelled by its marker, not by remembering an argument.
 * Bash callers pass trace.sh --level at the call site instead, where the outcome is known.
 */

import { appendLine } from "./effects.mjs";

export const LEVELS = ["debug", "info", "warn", "error", "fatal"];

/** A header line of the log, as every writer emits it. */
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

/**
 * One header line; a multi-line message's other lines follow indented, blank ones dropped,
 * so every line that starts at column 0 is a header a level grep can find.
 */
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

/** a is at least as severe as b. */
export function atLeast(a, b) {
  return LEVELS.indexOf(a) >= LEVELS.indexOf(b);
}

/**
 * The lowest level stderr shows. CREW_LOG_LEVEL names it; CREW_VERBOSE=1, the older switch,
 * means debug when CREW_LOG_LEVEL is unset. A bad value runs at info rather than failing a run.
 */
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
