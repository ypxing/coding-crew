import claude from "./claude.mjs";
import codex from "./codex.mjs";
import copilot from "./copilot.mjs";
import pi from "./pi.mjs";

/** Every platform is dispatched through an adapter; none has a bash dispatcher or an agent file. */
export const ADAPTERS = { pi, codex, claude, copilot };

/** One raw JSONL event line, normalized by `platform`'s adapter; null for an unknown platform, an unparseable line or an event it ignores. */
export function normalizeLine(platform, line) {
  const adapter = ADAPTERS[platform];
  if (!adapter) return null;
  let evt;
  try {
    evt = JSON.parse(line);
  } catch {
    return null;
  }
  if (!evt || typeof evt !== "object") return null;
  return adapter.normalize(evt) ?? null;
}
