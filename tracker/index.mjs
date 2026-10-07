/**
 * index.mjs — the issue-tracker backend factory, shared by crew-afk and the tracker CLI.
 *
 * `getTracker()` reads `tracker-config.mjs` and resolves to a backend module, `import()`ing
 * `./github.mjs` *dynamically* — never a static top-level import — so a `local`-configured repo
 * never loads the github backend. Installed to `.coding-crew/tracker/` on every install, so any
 * skill reaches it through `cli.mjs` without crew-afk installed.
 *
 * Backend contract — what every tracker means by an issue's `status`, whatever it stores:
 *   - `ready-for-agent`: dispatchable. `selectDispatchable` returns these, minus any whose
 *     `## Blocked by` names an issue not yet `done`.
 *   - `done`: implemented and merged into the feature branch — *not* shipped. It resolves
 *     blockers and takes the issue out of the queue. `cli.mjs mark-done` sets it, behind its two
 *     guards (mark-issue-done.sh and close-issue.sh call it); local moves the file to done/,
 *     github labels the issue `awaiting-merge`.
 *   - Shipped is a separate, optional capability: `closingRefs(mainRoot, {featureSlug})`
 *     returns the lines (`Closes #n`) that close the `done` issues when the feature PR merges.
 *     Provide it only for a tracker other people read whose host closes issues on merge;
 *     local omits it, since nobody else reads .scratch/.
 *
 * The CLI's write ops call, on every backend: `beginPublish(mainRoot, {featureSlug, drafts,
 * replace, exec})` → `{create(draft) → {ref, blockerRef}, finish?({deps})}` (the CLI orders the
 * drafts and rewrites each `## Blocked by` to the `blockerRef`s already made), the optional
 * `publishGuard` (a re-run refusal, `{code, message}`), `publishPrd`, `rewriteIssue`, and for
 * `mark-done` — whose guards are the CLI's, not a backend's — `doneTarget`, `readIssueBody` and
 * `markDone`.
 */

import { readTrackerConfig } from "./tracker-config.mjs";
import * as local from "./local.mjs";

/**
 * Resolve the tracker backend for `mainRoot`: `local.mjs`'s module for `local` (also the
 * default when nothing is configured) or, for `github`, a dynamic `import()` of `./github.mjs`.
 * Throws what `readTrackerConfig` throws for an invalid config.
 */
export async function getTracker(mainRoot) {
  const { tracker } = readTrackerConfig(mainRoot);
  if (tracker === "github") {
    return import("./github.mjs");
  }
  return local;
}
