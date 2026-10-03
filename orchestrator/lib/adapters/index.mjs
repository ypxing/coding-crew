import claude from "./claude.mjs";
import copilot from "./copilot.mjs";

/** Platforms dispatched through an adapter; pi and codex still go through their bash dispatchers. */
export const ADAPTERS = { claude, copilot };
