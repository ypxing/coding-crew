/**
 * The one trace formatter: a normalized event (common.mjs `normalized`) becomes a `[TOOL]`,
 * `[TOOL-ERROR]` or `[AGENT-ERROR]` line, with no platform-specific code. Only the prefix is
 * parsed downstream (log.mjs `levelFor`); the text after it is for people.
 */
import { safePreview } from "./common.mjs";
import { normalizeLine } from "./index.mjs";

const MARKERS = { tool: "TOOL", "tool-error": "TOOL-ERROR", "agent-error": "AGENT-ERROR" };

/** `$ <command>` for a shell call, a bare path for a file tool, else a capped JSON preview of its args. */
function subject(evt) {
  if (typeof evt.command === "string") return `$ ${evt.command}`;
  if (typeof evt.path === "string") return evt.path;
  return `args=${safePreview(evt.args)}`;
}

/** The trace line for a normalized event; null for "text", null, or an unknown kind. No timestamp or slug. */
export function formatTrace(agent, evt) {
  const marker = MARKERS[evt?.kind];
  if (!marker) return null;
  const parts = [`[${marker}] agent=${agent}`];
  if (evt.tool != null) parts.push(`tool=${evt.tool}`);
  if (evt.kind === "tool") parts.push(subject(evt));
  if (evt.detail) parts.push(evt.detail);
  return parts.join(" ");
}

/**
 * One trace line per recognised raw event line, null for anything else including an unparseable
 * line — observability never fails the dispatch. dispatch() adds the timestamp and slug.
 */
export function formatJsonTraceLine(platform, agent, line) {
  return formatTrace(agent, normalizeLine(platform, line));
}
