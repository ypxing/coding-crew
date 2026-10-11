/** A failed verify: triage decides fixable vs. environmental, tagged into the retention reason. */

import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { dispatch } from "../dispatch.mjs";
import { triagePrompt } from "../prompts.mjs";
import { parseTriageReport, readVerifyRecord } from "../report.mjs";
import { finishBlocked, finishRetryOrBlock } from "./finish.mjs";
import { dispatchIssueDir, dispatchStem, FIXABLE_TAG, issueDescriptor, limitExceeded, NOT_FIXABLE_TAG, readOnlyDispatch, readSidecar, roleBinding, taggedReason, unblockedReason, VERIFY_INCONCLUSIVE_TAG, VERIFY_INTERRUPTED_TAG } from "./shared.mjs";

/** Output that stops at `TEST: running: …` (a gate killed mid-check) names no failing check. */
export function hasVerifyFailure(stdout) {
  return /^[A-Z_]+: (fail|not_run is fatal)/m.test(stdout ?? "");
}

/** A not-fixable-recheck round (worker.skippedWorker) reuses the retaining round's verdict verbatim. */
export async function handleVerificationFailure(ctx, worker, outcome, verify) {
  const { sprint } = ctx;

  // No verdict from the gate is not the branch's fault: no triage, no coder. An interruption spends
  // no attempt; an inconclusive pair does, which bounds a gate that never reaches a verdict.
  if (verify.interrupted) {
    ctx.log(`[VERIFY-INTERRUPTED] slug=${worker.issue.slug} round=${worker.attempt} — verify-worktree.sh was killed by ${verify.signal}; no verdict, so no triage and no coder`, "warn");
    return finishRetryOrBlock(ctx, worker, outcome, taggedReason(VERIFY_INTERRUPTED_TAG, `killed by ${verify.signal}`), { free: true });
  }
  if (!verify.dryRun && !hasVerifyFailure(verify.stdout)) {
    ctx.log(`[VERIFY-INCONCLUSIVE] slug=${worker.issue.slug} round=${worker.attempt} — two verifies, neither named a failing check; no triage and no coder`, "warn");
    return finishRetryOrBlock(ctx, worker, outcome, taggedReason(VERIFY_INCONCLUSIVE_TAG, `exit ${verify.code} with no failing check in the output`));
  }

  if (worker.skippedWorker) {
    // Unwrapped: a nested block prefix hides the tag from resumeRoute and restarts the coder.
    const priorReason = unblockedReason(sprint.retentionReason(worker.issue.slug) ?? "verification-failed");
    return finishRetryOrBlock(ctx, worker, outcome, priorReason);
  }

  // A check whose command is not installed (exit 127) failed before judging the code.
  const missing = Object.entries(readVerifyRecord(join(dispatchIssueDir(sprint.dispatchDir, worker.issue), "verify.json")).missing);
  if (missing.length) {
    const detail = missing.map(([check, cmd]) => `${cmd} is not installed (${check})`).join("; ");
    ctx.log(`[MISSING-COMMAND] slug=${worker.issue.slug} — ${detail}; triage skipped`);
    return finishRetryOrBlock(ctx, worker, outcome, taggedReason(NOT_FIXABLE_TAG, `missing command: ${detail}`));
  }

  const triage = await runTriage(ctx, worker, verify.stdout);
  if (triage.limitExceeded) return finishBlocked(ctx, worker, outcome, triage.limitExceeded);
  if (!triage.completed) {
    // Triage itself failed: a full coder retry rather than let a helper's failure stall the branch.
    return finishRetryOrBlock(ctx, worker, outcome, "verification-failed");
  }

  const summary = `${triage.parsed.category || "unspecified"}: ${triage.parsed.detail || "no detail given"}`;
  const fixable = triage.parsed.fixable;
  const tag = fixable ? FIXABLE_TAG : NOT_FIXABLE_TAG;

  // A coder that deferred its test run never saw this failure, so its first fixable retry is free.
  const free = !!fixable && worker.report?.checks?.test === "deferred" && sprint.claimDeferredRefund(worker.issue.slug);
  return finishRetryOrBlock(ctx, worker, outcome, taggedReason(tag, summary), { free });
}

/** Never the coder: it has every incentive to call its own failure "environmental". */
export async function runTriage(ctx, worker, verifyStdout) {
  const { sprint, effects, options } = ctx;
  const { issue, branch } = worker;
  const issueDir = dispatchIssueDir(sprint.dispatchDir, issue);
  mkdirSync(issueDir, { recursive: true });
  const promptFile = join(issueDir, "triage-prompt.md");
  const outFile = join(issueDir, "triage.md");
  const sidecarFile = join(issueDir, "triage.report.json");

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
      coderEvidence: worker.report.evidence || worker.report.cause ? { ...worker.report.evidence, cause: worker.report.cause } : null,
    }),
  );

  const triage = roleBinding(ctx, "triage");
  ctx.log(
    `[STEP] slug=${dispatchStem(issue)} round=${worker.attempt} step=dispatch-triage model=${triage.model ?? "inherit"} runtime=${triage.runtime}`,
  );
  const guarded = await readOnlyDispatch(ctx, { label: `triage ${issue.slug}`, branches: [branch] }, () => dispatch(
    effects,
    triage.runtime,
    {
      agent: "crew-triage",
      cwd: effects.featureRoot,
      promptFile,
      outFile,
      model: triage.model,
      mainRoot: effects.mainRoot,
      logFile: sprint.traceLog,
      featureSlug: sprint.featureSlug,
      slug: dispatchStem(issue),
      issueNumber: issue.number,
      round: worker.attempt,
      reportPath: sidecarFile,
      maxBudgetUsd: triage.maxBudgetUsd,
      effort: triage.effort,
    },
    {
      timeoutMs: options.timeoutMs.triage,
      onTrace: (line) => ctx.heartbeat(`slug=${dispatchStem(issue)} round=${worker.attempt} ${line}`),
    },
  ));
  const result = guarded.result;
  if (result) sprint.recordDispatchCost(result, { slug: issue.slug, role: "triage", attempt: worker.attempt });
  if (guarded.violation) return { completed: false, parsed: { ok: false, detail: guarded.violation }, limitExceeded: null };

  const sidecar = readSidecar(sidecarFile);

  const parsed = parseTriageReport(result.text, sidecar);
  const completed = !result.timedOut && parsed.ok;
  return { completed, parsed, limitExceeded: limitExceeded(result, "triage", triage) };
}
