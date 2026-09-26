/**
 * Helpers shared by the pipeline stages: retention-reason tags, issue naming, the
 * milestone push and tracker writes.
 */

import { existsSync, readFileSync } from "node:fs";

import { getTracker } from "../tracker.mjs";
import { queuePaneNotice } from "../pane-host/index.mjs";

// Retention-reason tags, written by the gates and read back by resumeRoute. Defined once
// so writer and reader cannot drift. The two verification tags carry triage's verdict.
export const FIXABLE_TAG = "verification-failed:fixable";
export const NOT_FIXABLE_TAG = "verification-failed:not-fixable";
// An `AC: unmet` review verdict. No triage: the reviewer's detail is already actionable.
export const CRITERIA_UNMET_TAG = "criteria-unmet";
// `receipts.sh write ac` failed after an all-met review. Never the branch's fault: the
// branch is fine, so no route for it re-runs the coder.
export const AC_RECEIPT_FAILED_TAG = "ac-receipt-failed";
// merge-branches.sh hit a conflict: the feature branch moved on under this branch. Only a
// coder can reconcile that; retrying the merge alone would conflict again.
export const MERGE_CONFLICT_TAG = "merge-conflict";
// merge-branches.sh refused because uncommitted changes in the main checkout would be
// overwritten. Not the branch's fault and not fixable by any dispatch, so it blocks at once;
// a re-run resumes at merge, since verify, review and the AC receipt already passed.
export const MAIN_TREE_DIRTY_TAG = "main-tree-dirty";
// The reviewer left no valid verdict, even after its in-round retry. Carries why (a timeout,
// no report.json, no verdict field) — the branch itself is done, so no route recodes it.
export const REVIEW_NOT_RUN_TAG = "review-not-run";
const REASON_SEP = " — ";

export function taggedReason(tag, summary) {
  return `${tag}${REASON_SEP}${summary}`;
}

/**
 * The runtime and model `role` dispatches on (crew-config.mjs's resolveCrew), and the scripts
 * dir holding that runtime's own dispatcher — pi's and codex's ship only in their own install.
 */
export function roleBinding(ctx, role) {
  const { runtime, model } = ctx.options.crew[role];
  return { runtime, model, scriptsDir: ctx.options.dispatcherDirs?.[runtime] ?? ctx.effects.scriptsDir };
}

/** Dispatch filename stem: `NN-<slug>`, sorting like the tracker's files; bare slug if unnumbered. */
export function dispatchStem(issue) {
  return issue.number ? `${issue.number}-${issue.slug}` : issue.slug;
}

/**
 * A milestone: always logged (the only signal without a pane host), then queued for the
 * pane. Not awaited: the push is advisory and must not hold the issue's pipeline.
 */
export function notifyMilestone(ctx, issue, message) {
  ctx.log(`[MILESTONE] ${dispatchStem(issue)}: ${message}`);
  if (!ctx.effects.paneHost) {
    ctx.log(`[MILESTONE-PUSH-SKIPPED] ${dispatchStem(issue)}: no pane host`);
    return;
  }
  queuePaneNotice(ctx.effects, `[${ctx.sprint.featureSlug}] ${dispatchStem(issue)}: ${message}`, (result) => {
    if (!result.sent) ctx.log(`[MILESTONE-PUSH-SKIPPED] ${dispatchStem(issue)}: ${result.reason}`);
  });
}

/**
 * Which gates `branch`'s current tip already passed, read from the receipts (receipts.sh
 * owns both): `verified` — a `pass` verify record for this exact commit; `reviewed` — also an
 * all-met AC receipt for it. A retry skips what these say is done: re-running a gate on an
 * unchanged commit can only repeat its answer. Matched on the positive line, so
 * CREW_RECEIPTS=off (whose `check` passes everything) never skips a gate.
 */
export function gatesAtTip(ctx, branch) {
  const { sprint, effects } = ctx;
  const check = (args) =>
    effects.exec("bash", [effects.script("receipts.sh"), "check", ...args], { env: sprint.childEnv(), mutating: false });
  const v = check(["verify", "--branch", branch]);
  const verified = v.code === 0 && /verified at [0-9a-f]+/.test(v.stdout);
  if (!verified) return { verified: false, reviewed: false };
  const a = check(["ac", "--branch", branch, "--at-tip"]);
  return { verified, reviewed: a.code === 0 && /criteria-verified at [0-9a-f]+/.test(a.stdout) };
}

/** close-issue.sh / promote-findings.sh's issue argument: a file path (local) or number (github). */
export function issueRef(issue) {
  return issue.path ?? String(issue.number);
}

/** The prompts' `issuePath:` — a file for local; for github, how to fetch the body. */
export function issueDescriptor(issue) {
  return issue.path ?? `GitHub issue #${issue.number} — fetch its current body with: gh issue view ${issue.number} --json body -q .body`;
}

/** The free text after a tag this module itself wrote — never applied to a reason whose tag is unknown. */
export function stripReasonTag(reason, tag) {
  return reason.startsWith(tag + REASON_SEP) ? reason.slice(tag.length + REASON_SEP.length) : reason;
}

/**
 * Write a `## <heading>` note against `issue`: local splices the file in place, github
 * posts a new comment. The one place that branches on which the tracker exposes.
 */
export async function writeTrackerSection(effects, issue, heading, body, { append = false } = {}) {
  if (effects.dryRun) return;
  const tracker = await getTracker(effects.mainRoot);
  if (tracker.writeIssueSection) {
    if (issue.path && existsSync(issue.path)) tracker.writeIssueSection(issue.path, heading, body, { append });
    return;
  }
  if (tracker.writeProgress) tracker.writeProgress(issue, body, { heading, mainRoot: effects.mainRoot });
}

/**
 * A dispatch's JSON sidecar, or null when absent or unparseable. Callers rmSync it before
 * dispatching, so a stale file from a prior round is never read back as this one's.
 */
export function readSidecar(file) {
  if (!existsSync(file)) return null;
  try {
    return JSON.parse(readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}
