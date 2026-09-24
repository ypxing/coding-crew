/**
 * The two non-complete endings of an issue's attempt: partial (retain the branch, retry)
 * and blocked (retain it for a human). finishRetryOrBlock picks between them.
 */

import { removeWorktree } from "../worktree.mjs";
import { notifyMilestone, writeTrackerSection } from "./shared.mjs";

// Every non-`complete` outcome — verify failure, unmet AC, a failed merge, a review that
// never landed a report, anything — spends one of this issue's attempts (see
// finishRetryOrBlock below). Two spent attempts and the third demotion becomes `blocked`
// instead of another retry: one retry is "might have been transient", a second failure in
// the same shape is the answer, not a reason to ask a fourth time. Replaces what used to
// be two separate, reason-specific repeat-checks (a second not-fixable verdict, a second
// review-not-run) with one rule that covers every retry path the same way.
export const MAX_ATTEMPTS_PER_ISSUE = 2;

/**
 * Every retryable demotion goes through here instead of calling finishPartial directly —
 * this is the one place that decides, from this dispatch's own attempt number (spent at
 * claim time, see sprint.bumpAttempt in loop.mjs), whether there's still a retry left or
 * whether it's time to give up and let a human look. `reason` is passed through unchanged
 * on a retry; finishBlocked gets a reason that says *why* the cap tripped, since by then
 * the original reason has already repeated once.
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
  // The worker's own criteria array, when it reports any as unmet, is a structured signal
  // the prose progress/notes text does not reliably restate — carry it forward verbatim so
  // the next round's resume doesn't depend on the coder's summary having named every gap.
  // Only meaningful straight from the worker's own report: by the criteria-unmet-from-review
  // path (see runHousekeeping), the worker already believed everything was met, so this array
  // is empty there and adds nothing — the review's own detail already rides in `reason` below.
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
  // In-memory, this invocation only — see sprint.mjs's isBlockedThisRun. Persisted
  // `blocked_slugs` (just above) is for crew-summary.sh's report; it must not be what
  // keeps a future `crew-afk` run from retrying this issue after a human fixes whatever
  // blocked it.
  sprint.markBlockedThisRun(issue.slug);
  outcome.status = "blocked";
  outcome.reason = reason;
  await notifyMilestone(ctx, issue, `blocked — ${reason}`);
  return outcome;
}
