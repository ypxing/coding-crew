/**
 * tracker.mjs — the orchestrator's view of the issue tracker.
 *
 * The orchestrator's callers (`pipeline.mjs`, `loop.mjs`, `main.mjs`) keep importing the
 * tracker's public surface (`selectDispatchable`, `parseIssue`, `writeIssueSection`,
 * `branchFor`, etc.) from this file rather than from a backend module directly, so
 * switching backends never means touching a call site.
 *
 * Today, every one of those named exports below is `local.mjs`'s implementation,
 * re-exported unchanged — this file's split from `local.mjs` is a pure refactor with zero
 * behavior change. `getTracker()`, the actual factory, and the backends themselves live in the
 * repo-root `tracker/` directory (installed to `.coding-crew/tracker/`, shared with the tracker
 * CLI); this file reaches them relatively, which resolves the same in the source and installed
 * trees. See `tracker/index.mjs` for the backend contract.
 */

import * as local from "../../tracker/local.mjs";

export { appendToSection, sectionBody, spliceSection } from "../../tracker/body-format.mjs";

export const READY_STATUS = local.READY_STATUS;
export const PARKED_STATUS = local.PARKED_STATUS;

export const issueSlug = local.issueSlug;
export const issueNumber = local.issueNumber;
export const branchFor = local.branchFor;
export const listOpenIssueFiles = local.listOpenIssueFiles;
export const listFeatureIssues = local.listFeatureIssues;
export const resolveBlockedBy = local.resolveBlockedBy;
export const issueDepsPath = local.issueDepsPath;
export const readIssueDeps = local.readIssueDeps;
export const parseIssue = local.parseIssue;
export const doneFiles = local.doneFiles;
export const blockers = local.blockers;
export const selectDispatchable = local.selectDispatchable;
export const writeIssueSection = local.writeIssueSection;

export { getTracker } from "../../tracker/index.mjs";
