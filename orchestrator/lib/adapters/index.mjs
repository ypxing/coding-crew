import claude from "./claude.mjs";
import codex from "./codex.mjs";
import copilot from "./copilot.mjs";
import pi from "./pi.mjs";

/** Every platform is dispatched through an adapter; none has a bash dispatcher or an agent file. */
export const ADAPTERS = { pi, codex, claude, copilot };
