/**
 * tracker.mjs — the issue-tracker backend factory.
 *
 * The orchestrator's callers (`pipeline.mjs`, `loop.mjs`, `main.mjs`) keep importing the
 * tracker's public surface (`selectDispatchable`, `parseIssue`, `writeIssueSection`,
 * `branchFor`, etc.) from this file rather than from a backend module directly, so
 * switching backends never means touching a call site.
 *
 * Today, every one of those named exports below is `local.mjs`'s implementation,
 * re-exported unchanged — this file's split from `local.mjs` is a pure refactor with zero
 * behavior change (see `.scratch/github-issue-tracker/issues/open/
 * 03-split-tracker-into-factory-and-backends.md`). `getTracker()` is the actual factory:
 * it reads `tracker-config.mjs` and resolves to a backend module, `import()`ing
 * `./trackers/github.mjs` *dynamically* — never a static top-level import — specifically so
 * this module keeps loading, and the local backend keeps running, even before
 * `github.mjs` exists on disk. Later issues wire callers through `getTracker()` itself as
 * the github backend gains real implementations.
 */

import { readTrackerConfig } from "./tracker-config.mjs";
import * as local from "./trackers/local.mjs";

export { appendToSection, sectionBody, spliceSection } from "./trackers/body-format.mjs";

export const READY_STATUS = local.READY_STATUS;
export const PARKED_STATUS = local.PARKED_STATUS;

export const issueSlug = local.issueSlug;
export const issueNumber = local.issueNumber;
export const branchFor = local.branchFor;
export const listOpenIssueFiles = local.listOpenIssueFiles;
export const resolveBlockedBy = local.resolveBlockedBy;
export const issueDepsPath = local.issueDepsPath;
export const readIssueDeps = local.readIssueDeps;
export const parseIssue = local.parseIssue;
export const doneFiles = local.doneFiles;
export const blockers = local.blockers;
export const selectDispatchable = local.selectDispatchable;
export const writeIssueSection = local.writeIssueSection;

/**
 * Resolve the tracker backend for `mainRoot`: `local.mjs`'s module for `tracker: local`
 * (the default, used whenever the config doc or its front matter is absent) or, for
 * `tracker: github`, a dynamic `import()` of `./trackers/github.mjs` — deferred to this
 * call, inside this function, so a `local`-configured repo never attempts to load a
 * `github.mjs` that may not exist yet.
 */
export async function getTracker(mainRoot) {
  const { tracker } = readTrackerConfig(mainRoot);
  if (tracker === "github") {
    return import("./trackers/github.mjs");
  }
  return local;
}
