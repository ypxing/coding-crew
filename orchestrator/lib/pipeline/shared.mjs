/**
 * Helpers shared by the pipeline stages: retention-reason tags, issue naming, the
 * milestone push and tracker writes.
 */

import { existsSync, readFileSync } from "node:fs";

import { getTracker } from "../tracker.mjs";
import { notifyTriggeringPane } from "../pane-host/index.mjs";

// Retention-reason tags for a verify-worktree.sh failure, once triage (see runTriage
// below) has classified it. Read back by runWorker to route the *next* attempt — a
// fixable verdict to a narrower fix prompt, a not-fixable one to a coder-free recheck.
// Centralised here, not restated at each comparison, so the tag and its separator cannot
// drift between the writer and the reader.
export const FIXABLE_TAG = "verification-failed:fixable";
export const NOT_FIXABLE_TAG = "verification-failed:not-fixable";
// Written by runHousekeeping on an `AC: unmet` verdict, read back by runWorker the same
// way FIXABLE_TAG is: routes the retry to fixPrompt instead of a full workerPrompt restart.
// No triage step here — the reviewer's own detail is already the concrete, actionable
// thing a fix needs, unlike a verify failure's raw check output.
export const CRITERIA_UNMET_TAG = "criteria-unmet";
const REASON_SEP = " — ";

export function taggedReason(tag, summary) {
  return `${tag}${REASON_SEP}${summary}`;
}

/** Dispatch filename stem — the issue's own `NN-<slug>` (see tracker.mjs's issueNumber), so
 * prompt/report files sort and scan the same way the issue tracker's own files do. Falls
 * back to the bare slug when the issue file carries no leading number. */
export function dispatchStem(issue) {
  return issue.number ? `${issue.number}-${issue.slug}` : issue.slug;
}

/** The one push per issue per round a caller polling for milestones actually needs —
 * a terminal outcome, not every gate in between. Always written to ctx.log (stderr +
 * orchestrator.log) first: that is the only signal a caller with no pane host ever gets —
 * the push below it is a no-op without one (see notifyTriggeringPane's own doc comment),
 * so without this line a whole sprint's worth of milestones was previously invisible to
 * anyone not running under herdr/orca, discoverable only after the fact from a finished
 * sprint's final summary. */
export async function notifyMilestone(ctx, issue, message) {
  ctx.log(`[MILESTONE] ${dispatchStem(issue)}: ${message}`);
  const result = await notifyTriggeringPane(ctx.effects, `[${ctx.sprint.featureSlug}] ${dispatchStem(issue)}: ${message}`);
  if (!result.sent) ctx.log(`[MILESTONE-PUSH-SKIPPED] ${dispatchStem(issue)}: ${result.reason}`);
  return result;
}

/** close-issue.sh / promote-findings.sh's own `--issue`/positional argument: an issue
 * file path for local, a bare GitHub issue number for github (both scripts branch on
 * tracker-config.sh the same way; see close-issue.sh's own "tracker backend" comment). */
export function issueRef(issue) {
  return issue.path ?? String(issue.number);
}

/** The `issuePath:` value handed to prompts.mjs's builders — a real path to `cat` for
 * local; for github (no file, just an already-fetched body this dispatch doesn't
 * forward), a pointer the dispatched agent can act on directly instead of the literal
 * string "undefined". */
export function issueDescriptor(issue) {
  return issue.path ?? `GitHub issue #${issue.number} — fetch its current body with: gh issue view ${issue.number} --json body -q .body`;
}

/** The free text after a tag this module itself wrote — never applied to a reason whose tag is unknown. */
export function stripReasonTag(reason, tag) {
  return reason.startsWith(tag + REASON_SEP) ? reason.slice(tag.length + REASON_SEP.length) : reason;
}

/**
 * Write a `## <heading>` note against `issue`, through whichever backend `getTracker`
 * resolves — local's in-place file splice (`writeIssueSection`) or github's new-comment-
 * per-call (`writeProgress`; see its own docstring for why a github write is never an
 * in-place edit). The two take different argument shapes (a path vs. the issue itself),
 * so this is the one place that branches on which the resolved tracker exposes, instead
 * of every call site guessing the backend from `issue.path`'s presence.
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
