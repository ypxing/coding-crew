import claude from "./claude.mjs";
import codex from "./codex.mjs";
import copilot from "./copilot.mjs";
import pi from "./pi.mjs";

/** Every platform is dispatched through an adapter; none has a bash dispatcher or an agent file. */
export const ADAPTERS = { pi, codex, claude, copilot };

/** The platform list: one adapter each (orchestrator/platforms.json has the same keys; platforms.test.mjs checks). */
export const PLATFORMS = Object.keys(ADAPTERS);

/**
 * Default parallelism per platform. Copilot's is conservative because what binds is the
 * account's request rate, which the CLI does not expose; raise with `--max-parallel`.
 */
export const DEFAULT_PARALLEL = Object.fromEntries(PLATFORMS.map((p) => [p, ADAPTERS[p].defaultParallel]));

/**
 * Every normalized event in one raw JSONL event line, by `platform`'s adapter (whose `normalize`
 * returns one, an array — a claude message with several tool calls — or null); [] for an unknown
 * platform, an unparseable line or an event it ignores.
 */
export function normalizeEvents(platform, line) {
  const adapter = ADAPTERS[platform];
  if (!adapter) return [];
  let evt;
  try {
    evt = JSON.parse(line);
  } catch {
    return [];
  }
  if (!evt || typeof evt !== "object") return [];
  const out = adapter.normalize(evt);
  return (Array.isArray(out) ? out : [out]).filter(Boolean);
}

/** A line's first normalized event, or null: the one the trace line and pane show. */
export function normalizeLine(platform, line) {
  return normalizeEvents(platform, line)[0] ?? null;
}
