/**
 * The two non-complete endings of an issue's attempt: partial (retain the branch, retry)
 * and blocked (retain it for a human). finishRetryOrBlock picks between them.
 */

import { removeWorktree } from "../worktree.mjs";
import { notifyMilestone, writeTrackerSection } from "./shared.mjs";

// Every non-complete outcome spends an attempt. One retry covers "might have been
// transient"; a second failure is the answer, so the next demotion blocks instead.
export const MAX_ATTEMPTS_PER_ISSUE = 2;

/**
 * Every retryable demotion goes through here: the one place that decides, from the attempt
 * spent at claim time (sprint.bumpAttempt in loop.mjs), whether a retry is left. `reason`
 * passes through unchanged on a retry — resumeRoute reads it back.
 */
export function finishRetryOrBlock(ctx, worker, outcome, reason) {
  if (worker.attempt >= MAX_ATTEMPTS_PER_ISSUE) {
    return finishBlocked(ctx, worker, outcome, `retry limit reached (${worker.attempt} attempts) — ${reason}`);
  }
  return finishPartial(ctx, worker, outcome, reason);
}

export async function finishPartial(ctx, worker, outcome, reason) {
  const { sprint, effects } = ctx;
  const { issue, branch } = worker;
  const progress = worker.report.progress || worker.report.notes || `Round ${worker.attempt}: ${reason}`;
  // The worker's own unmet criteria, verbatim: the prose summary may not name every gap.
  // (Empty on the review's criteria-unmet path, whose detail rides in `reason`.)
  const unmet = (worker.report.criteria || []).filter((c) => c && c.met === false && c.text);
  const unmetBlock = unmet.length
    ? `\n\nUnmet criteria (from the worker's own report):\n${unmet.map((c) => `- ${c.text}`).join("\n")}`
    : "";
  await writeTrackerSection(
    effects,
    issue,
    "Progress",
    `Round ${worker.attempt}: ${progress}${unmetBlock}\n\nDemotion reason: ${reason}`,
  );
  removeWorktree(effects, { mainRoot: effects.mainRoot, path: worker.worktree });
  sprint.retain(issue.slug, branch, reason);
  outcome.status = "partial";
  outcome.reason = reason;
  await notifyMilestone(ctx, issue, `partial — retrying (round ${worker.attempt}) — ${reason}`);
  return outcome;
}

export async function finishBlocked(ctx, worker, outcome, reason) {
  const { sprint, effects } = ctx;
  const { issue, branch } = worker;
  await writeTrackerSection(effects, issue, "Blocked", `Round ${worker.attempt}: ${reason}`, { append: true });
  removeWorktree(effects, { mainRoot: effects.mainRoot, path: worker.worktree });
  sprint.blocked(issue.slug, branch, reason);
  // In-memory only: persisted `blocked_slugs` feeds the summary, and must not stop a
  // future run retrying once a human has fixed the blocker.
  sprint.markBlockedThisRun(issue.slug);
  outcome.status = "blocked";
  outcome.reason = reason;
  await notifyMilestone(ctx, issue, `blocked — ${reason}`);
  return outcome;
}
