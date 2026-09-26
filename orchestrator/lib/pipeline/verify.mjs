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
import { dispatchStem, FIXABLE_TAG, issueDescriptor, NOT_FIXABLE_TAG, readSidecar, roleBinding, taggedReason } from "./shared.mjs";

/**
 * verify-worktree.sh already failed: triage it, and tag the retention reason with the
 * verdict. A not-fixable-recheck round (worker.skippedWorker) already has a verdict from
 * the round that retained the branch, and reuses it verbatim instead of re-triaging.
 */
export async function handleVerificationFailure(ctx, worker, outcome, verify) {
  const { sprint } = ctx;

  if (worker.skippedWorker) {
    const priorReason = sprint.retentionReason(worker.issue.slug) ?? "verification-failed";
    return finishRetryOrBlock(ctx, worker, outcome, priorReason);
  }

  const triage = await runTriage(ctx, worker, verify.stdout);
  if (!triage.completed) {
    // Triage itself failed: fall back to the plain reason (a full coder retry) rather than
    // let a helper's failure stall the branch.
    return finishRetryOrBlock(ctx, worker, outcome, "verification-failed");
  }

  const summary = `${triage.parsed.category || "unspecified"}: ${triage.parsed.detail || "no detail given"}`;
  const fixable = triage.parsed.fixable;
  const tag = fixable ? FIXABLE_TAG : NOT_FIXABLE_TAG;

  return finishRetryOrBlock(ctx, worker, outcome, taggedReason(tag, summary));
}

/**
 * Dispatched to `crew-triage`, never the coder: the coder has every incentive to call its
 * own failure "environmental". cwd is mainRoot — the branch ref and check output suffice.
 */
export async function runTriage(ctx, worker, verifyStdout) {
  const { sprint, effects, options } = ctx;
  const { issue, branch } = worker;
  const promptFile = join(sprint.dispatchDir, `${dispatchStem(issue)}.triage-prompt.md`);
  const outFile = join(sprint.dispatchDir, `${dispatchStem(issue)}.triage.md`);
  const sidecarFile = join(sprint.dispatchDir, `${dispatchStem(issue)}.triage.report.json`);

  // A stale sidecar at this fixed path must not be read back as this round's verdict.
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

  const triage = roleBinding(ctx, "triage");
  ctx.log(
    `[STEP] slug=${dispatchStem(issue)} round=${worker.attempt} step=dispatch-triage model=${triage.model ?? "inherit"} runtime=${triage.runtime}`,
  );
  const result = await dispatch(
    effects,
    triage.runtime,
    {
      agent: "crew-triage",
      cwd: effects.mainRoot,
      promptFile,
      outFile,
      // Defaults to the coder's model, never a cheaper one; config.json's afk.models can override.
      model: triage.model,
      mainRoot: effects.mainRoot,
      logFile: sprint.traceLog,
      featureSlug: sprint.featureSlug,
      scriptsDir: triage.scriptsDir,
      slug: dispatchStem(issue),
      issueNumber: issue.number,
      round: worker.attempt,
      reportPath: sidecarFile,
    },
    {
      timeoutMs: options.timeoutMs.triage,
      onTrace: (line) => ctx.heartbeat(`slug=${dispatchStem(issue)} round=${worker.attempt} ${line}`),
    },
  );
  sprint.recordDispatchCost(result, { slug: issue.slug, role: "triage", attempt: worker.attempt });

  const sidecar = readSidecar(sidecarFile);

  const parsed = parseTriageReport(result.text, sidecar);
  const completed = !result.timedOut && parsed.ok;
  return { completed, parsed };
}
