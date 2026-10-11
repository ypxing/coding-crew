
import { removeWorktree } from "../worktree.mjs";
import { issueFingerprint } from "../../../tracker/body-format.mjs";
import { notifyMilestone, writeTrackerSection } from "./shared.mjs";

// One retry covers "might have been transient"; a second failure is the answer.
export const MAX_ATTEMPTS_PER_ISSUE = 2;
// A coder out of time after committing was working, not failing, so its retry is free; free
// retries still count here, so a coder that keeps outgrowing the timeout blocks.
export const MAX_DISPATCHES_PER_ISSUE = 3;

/** The one place that decides whether a retry is left; `reason` passes through for resumeRoute. */
export function finishRetryOrBlock(ctx, worker, outcome, reason, { free = false } = {}) {
  const { sprint } = ctx;
  const slug = worker.issue.slug;
  if (free && worker.attempt < MAX_DISPATCHES_PER_ISSUE) {
    sprint.grantFreeAttempt(slug);
    return finishPartial(ctx, worker, outcome, reason);
  }
  const spent = worker.attempt - sprint.freeAttempts(slug);
  if (spent >= MAX_ATTEMPTS_PER_ISSUE || worker.attempt >= MAX_DISPATCHES_PER_ISSUE) {
    return finishBlocked(ctx, worker, outcome, `retry limit reached (${worker.attempt} attempts) — ${reason}`);
  }
  return finishPartial(ctx, worker, outcome, reason);
}

// The issue's current fingerprint, except after an attempt that never worked from it.
function recordFingerprint(worker) {
  if (worker.keepFingerprint) return worker.keepFingerprint;
  return worker.issue.text ? issueFingerprint(worker.issue.text) : null;
}

export async function finishPartial(ctx, worker, outcome, reason) {
  const { sprint, effects } = ctx;
  const { issue, branch } = worker;
  const progress = worker.report.progress || worker.report.notes || `Round ${worker.attempt}: ${reason}`;
  // Verbatim: the prose summary may not name every gap.
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
  sprint.retain(issue.slug, branch, reason, recordFingerprint(worker));
  outcome.status = "partial";
  outcome.reason = reason;
  notifyMilestone(ctx, issue, `partial — retrying (round ${worker.attempt}) — ${reason}`);
  return outcome;
}

/** `tracker: github`: later runs skip a `blocked` issue until a human removes the label. */
function labelBlocked(ctx, issue) {
  const { effects } = ctx;
  if (effects.dryRun || issue.number == null) return false;
  const r = effects.bash("issue-labels.sh", ["block", String(issue.number)], { env: ctx.sprint.childEnv() });
  if (r.code !== 0) {
    ctx.log(`[BLOCKED-LABEL-FAILED] slug=${issue.slug} — ${(r.stderr || r.stdout).trim()}`, "warn");
    return false;
  }
  return /^LABELLED: blocked /m.test(r.stdout);
}

export async function finishBlocked(ctx, worker, outcome, reason) {
  const { sprint, effects } = ctx;
  const { issue, branch } = worker;
  await writeTrackerSection(effects, issue, "Blocked", `Round ${worker.attempt}: ${reason}`, { append: true });
  removeWorktree(effects, { mainRoot: effects.mainRoot, path: worker.worktree });
  const labelled = labelBlocked(ctx, issue);
  // A branch refused as stale is someone else's leftover: retained, the next run would resume on it.
  sprint.blocked(issue.slug, worker.report.parsedFrom === "stale-branch" ? null : branch, reason, labelled ? issue.number : null,
    recordFingerprint(worker));
  // In-memory only: the persisted list must not stop a future run retrying once a human fixed it.
  sprint.markBlockedThisRun(issue.slug);
  outcome.status = "blocked";
  outcome.inProgressCleared = labelled;
  outcome.reason = reason;
  notifyMilestone(ctx, issue, `blocked — ${reason}`);
  return outcome;
}
