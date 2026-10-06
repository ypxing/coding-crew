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
