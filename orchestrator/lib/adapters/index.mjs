import claude from "./claude.mjs";
import codex from "./codex.mjs";
import copilot from "./copilot.mjs";
import pi from "./pi.mjs";

export const ADAPTERS = { pi, codex, claude, copilot };

/** orchestrator/platforms.json has the same keys; platforms.test.mjs checks. */
export const PLATFORMS = Object.keys(ADAPTERS);

/** Copilot's is conservative: what binds is the account's request rate, which the CLI does not expose. */
export const DEFAULT_PARALLEL = Object.fromEntries(PLATFORMS.map((p) => [p, ADAPTERS[p].defaultParallel]));

/** A claude message with several tool calls normalizes to several; [] for anything unparseable or ignored. */
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

export function normalizeLine(platform, line) {
  return normalizeEvents(platform, line)[0] ?? null;
}
