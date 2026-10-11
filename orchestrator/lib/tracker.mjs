/**
 * tracker.mjs — the orchestrator's one import point for the tracker, so switching backends never
 * touches a call site. The relative `../../tracker/` paths resolve the same in the source and
 * installed (`.coding-crew/tracker/`) trees.
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
