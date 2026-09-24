/**
 * What a failed verify-worktree.sh means: triage decides fixable vs. environmental, and the
 * verdict is tagged into the retention reason for resumeRoute to read next attempt.
 */

import { rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { dispatch } from "../dispatch.mjs";
import { triagePrompt } from "../prompts.mjs";
import { parseTriageReport } from "../report.mjs";
import { finishRetryOrBlock } from "./finish.mjs";
import { dispatchStem, FIXABLE_TAG, issueDescriptor, NOT_FIXABLE_TAG, readSidecar, taggedReason } from "./shared.mjs";

/**
 * Verify-worktree.sh already failed — decide what that failure means before demoting.
 *
 * Dispatches `runTriage`, an agent independent of the coder that wrote the branch (the same
 * reason review is independent of the coder, not a self-grade), and tags the retention
 * reason with its verdict so the next attempt's runWorker can route on it without
 * re-deriving anything. A not-fixable verdict that recurs stops on its own, via this issue's
 * retry cap (see finishRetryOrBlock) — no reason-specific repeat-check needed here.
 *
 * Exception: a not-fixable-recheck round (runWorker's verify route, worker.skippedWorker)
 * already carries a triage verdict from the round that first retained this branch — that is
 * the whole point of "recheck deps + verify only" ([SKIP-WORKER]'s own "no triage" promise).
 * Re-triaging here on the exact same failure would just re-ask the same question at the cost
 * of another dispatch, so this reuses that prior verdict verbatim instead.
 */
export async function handleVerificationFailure(ctx, worker, outcome, verify) {
  const { sprint } = ctx;

  if (worker.skippedWorker) {
    const priorReason = sprint.retentionReason(worker.issue.slug) ?? "verification-failed";
    return finishRetryOrBlock(ctx, worker, outcome, priorReason);
  }

  const triage = await runTriage(ctx, worker, verify.stdout);
  if (!triage.completed) {
    // Triage itself is unusable (dispatch failure, timeout, unparseable answer) — fall back
    // to the plain reason rather than let a helper's own failure stall the branch. The next
    // attempt still gets a full coder redispatch, same as before this existed.
    return finishRetryOrBlock(ctx, worker, outcome, "verification-failed");
  }

  const summary = `${triage.parsed.category || "unspecified"}: ${triage.parsed.detail || "no detail given"}`;
  const fixable = triage.parsed.fixable;
  const tag = fixable ? FIXABLE_TAG : NOT_FIXABLE_TAG;

  return finishRetryOrBlock(ctx, worker, outcome, taggedReason(tag, summary));
}

/**
 * Dispatched to `crew-triage`, never to `crew-coder` — the coder that wrote the branch has
 * every incentive to call its own failure "environmental" rather than do more work, the same
 * self-grading risk that keeps review off the coder too. cwd is mainRoot, not the worktree:
 * the branch ref and the captured check output are all triage needs, matching runReview.
 */
export async function runTriage(ctx, worker, verifyStdout) {
  const { sprint, effects, platform, options } = ctx;
  const { issue, branch } = worker;
  const promptFile = join(sprint.dispatchDir, `${dispatchStem(issue)}.triage-prompt.md`);
  const outFile = join(sprint.dispatchDir, `${dispatchStem(issue)}.triage.md`);
  const sidecarFile = join(sprint.dispatchDir, `${dispatchStem(issue)}.triage.report.json`);

  // See runWorker's matching rmSync: this path is fixed per issue, so a stale sidecar from
  // a prior triage dispatch must not be read back as this round's verdict.
  rmSync(sidecarFile, { force: true });

  writeFileSync(
    promptFile,
    triagePrompt({
      branch,
      slug: issue.slug,
      issuePath: issueDescriptor(issue),
      featureBranch: sprint.featureBranch,
      checkOutput: verifyStdout,
      reportPath: sidecarFile,
    }),
  );

  ctx.log(
    `[STEP] slug=${dispatchStem(issue)} round=${worker.attempt} step=dispatch-triage model=${options.triageModel ?? "inherit"}`,
  );
  const result = await dispatch(
    effects,
    platform,
    {
      agent: "crew-triage",
      cwd: effects.mainRoot,
      promptFile,
      outFile,
      // Same convention as the reviewer: triage judges the coder's work, so it defaults to
      // the coder's own model — never a cheaper one the sprint did not choose — unless
      // .coding-crew/afk-models.json explicitly names a different (typically stronger) one.
      model: options.triageModel,
      mainRoot: effects.mainRoot,
      logFile: sprint.traceLog,
      featureSlug: sprint.featureSlug,
      scriptsDir: effects.scriptsDir,
      slug: dispatchStem(issue),
      issueNumber: issue.number,
      round: worker.attempt,
      reportPath: sidecarFile,
    },
    {
      timeoutMs: options.reviewTimeoutMs,
      onTrace: (line) => ctx.log(`slug=${dispatchStem(issue)} round=${worker.attempt} ${line}`),
    },
  );

  const sidecar = readSidecar(sidecarFile);

  const parsed = parseTriageReport(result.text, sidecar);
  const completed = !result.timedOut && parsed.ok;
  return { completed, parsed };
}
