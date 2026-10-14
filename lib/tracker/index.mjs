/**
 * index.mjs — the tracker backend factory. Every backend means the same by an issue's `status`:
 * `ready-for-agent` is dispatchable once no `## Blocked by` issue is short of `done`; `done` is
 * merged into the feature branch, *not* shipped, set only by `cli.mjs mark-done`. Optional
 * `closingRefs` returns the `Closes #n` lines that ship them on PR merge (local omits it).
 */

import { readTrackerConfig } from "./tracker-config.mjs";
import * as local from "./local.mjs";

/** Resolve the backend for `mainRoot`; github is a dynamic import so a local repo never loads it. */
export async function getTracker(mainRoot) {
  const { tracker } = readTrackerConfig(mainRoot);
  if (tracker === "github") {
    return import("./github.mjs");
  }
  return local;
}
