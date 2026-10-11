/** The one trace formatter. Only the `[TOOL]`-style prefix is parsed downstream; the rest is for people. */
import { safePreview } from "./common.mjs";
import { normalizeLine } from "./index.mjs";

const MARKERS = { tool: "TOOL", "tool-error": "TOOL-ERROR", "agent-error": "AGENT-ERROR" };

function subject(evt) {
  if (typeof evt.command === "string") return `$ ${evt.command}`;
  if (typeof evt.path === "string") return evt.path;
  return `args=${safePreview(evt.args)}`;
}

/** No timestamp or slug: dispatch() adds them. */
export function formatTrace(agent, evt) {
  const marker = MARKERS[evt?.kind];
  if (!marker) return null;
  const parts = [`[${marker}] agent=${agent}`];
  if (evt.tool != null) parts.push(`tool=${evt.tool}`);
  if (evt.kind === "tool") parts.push(subject(evt));
  if (evt.detail) parts.push(evt.detail);
  return parts.join(" ");
}

/** Observability never fails the dispatch: anything unrecognised is null. */
export function formatJsonTraceLine(platform, agent, line) {
  return formatTrace(agent, normalizeLine(platform, line));
}
