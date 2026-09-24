/**
 * pipeline.mjs — the per-branch gate chain, in one place, in one order:
 *
 *     worktree → include → deps → dispatch → prefilter → verify → review → AC receipt
 *     → promote → merge → close
 *
 * The order is a function body, so no model can reorder or skip it, and each gate's
 * refusal is a return value rather than a paragraph asking to be obeyed.
 *
 * Every failure demotes to `partial` and retains the branch. Nothing merges on an
 * absent check.
 *
 * The order lives here (runWorker, runHousekeeping); each stage's body lives in
 * pipeline/: verify.mjs (triage), review.mjs (review + promotion), merge.mjs (merge +
 * close), finish.mjs (partial/blocked endings), shared.mjs (reason tags, helpers).
 */

import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { applySchemaPrefilter, depsLine, parseVerifyChecks, parseWorkerReport } from "./report.mjs";
import { getTracker } from "./tracker.mjs";
import { fixPrompt, resumeNote, workerPrompt } from "./prompts.mjs";
import { applyWorktreeInclude, ensureWorktree, mergeFeatureBranch, removeWorktree } from "./worktree.mjs";
import { dispatch } from "./dispatch.mjs";
import { finishBlocked, finishRetryOrBlock } from "./pipeline/finish.mjs";
import { mergeAndClose } from "./pipeline/merge.mjs";
import { promote, runReview } from "./pipeline/review.mjs";
import {
  AC_RECEIPT_FAILED_TAG,
  CRITERIA_UNMET_TAG,
  dispatchStem,
  FIXABLE_TAG,
  MERGE_CONFLICT_TAG,
  issueDescriptor,
  NOT_FIXABLE_TAG,
  notifyMilestone,
  readSidecar,
  stripReasonTag,
  taggedReason,
} from "./pipeline/shared.mjs";
import { handleVerificationFailure } from "./pipeline/verify.mjs";

/** Whether `branch` has commits the feature branch lacks: a dead dispatch with commits is worth resuming. */
function branchHasCommits(effects, featureBranch, branch) {
  const r = effects.gitRead(["rev-list", "--count", `${featureBranch}..${branch}`]);
  return r.code === 0 && parseInt(r.stdout.trim(), 10) > 0;
}

/** How state.sh records a block (`blocked — <reason>`), and finishRetryOrBlock a capped retry. */
const BLOCKED_PREFIX = /^blocked — (retry limit reached \(\d+ attempts\) — )?/;

/**
 * Where a retry re-enters the pipeline, by the reason the prior attempt retained its branch
 * (finishRetryOrBlock writes it; state.sh records it). The one table of resume targets:
 *
 *   merge   `merge-failed`, `close-refused …` — verify, review and the AC receipt already
 *           passed; only merge/close runs again. Safe because merge-branches.sh and
 *           close-issue.sh re-check the SHA-bound receipts themselves on every run.
 *   verify  `review-not-run` — the branch is done; only the review dispatch failed.
 *           `verification-failed:not-fixable` — triage ruled out recoding, so skip the
 *           coder and re-run deps + verify once, in case the failure was transient.
 *           `ac-receipt-failed …` — review was all-met; only the receipt write failed. The
 *           receipt is rewritten only after a fresh all-met review, never on this note's
 *           word. Also the route once a human reruns after the retry cap blocked it.
 *   fix     `verification-failed:fixable`, `criteria-unmet` — the coder runs on fixPrompt,
 *           told exactly what failed, instead of re-reading the whole issue.
 *           `merge-conflict` — the feature branch moved on under this one. The sync step
 *           leaves the conflicted merge in the worktree and the coder resolves it; verify
 *           and review then re-run on the new commit. If the sync merges cleanly after
 *           all, the coder is skipped and only verify + review re-run.
 *   restart anything else, including no reason — the coder runs on workerPrompt.
 *
 * The retry cap (MAX_ATTEMPTS_PER_ISSUE, pipeline/finish.mjs) bounds every route alike.
 */
export function resumeRoute(reason) {
  if (reason == null) return { route: "restart" };
  if (reason.replace(BLOCKED_PREFIX, "").startsWith(AC_RECEIPT_FAILED_TAG)) return { route: "verify", label: "ac-receipt-retry" };
  if (reason.startsWith(MERGE_CONFLICT_TAG)) {
    return { route: "fix", kind: "conflict", context: stripReasonTag(reason, MERGE_CONFLICT_TAG) };
  }
  if (reason === "merge-failed" || reason.startsWith("close-refused")) return { route: "merge" };
  if (reason === "review-not-run") return { route: "verify", label: "review-not-run" };
  if (reason.startsWith(NOT_FIXABLE_TAG)) return { route: "verify", label: "not-fixable-recheck" };
  if (reason.startsWith(FIXABLE_TAG)) return { route: "fix", kind: "verify", context: stripReasonTag(reason, FIXABLE_TAG) };
  if (reason.startsWith(CRITERIA_UNMET_TAG)) {
    return { route: "fix", kind: "review", context: stripReasonTag(reason, CRITERIA_UNMET_TAG) };
  }
  return { route: "restart" };
}

/** The verify route's labels: what each skipped-worker attempt logs and records. */
const SKIPPED_WORKER = {
  "review-not-run": {
    what: "retrying review only, no coder dispatch",
    progress: "review-only retry — coder dispatch skipped, branch content unchanged",
    notes: "review-only retry: the prior round's only failure was the review dispatch itself",
  },
  "not-fixable-recheck": {
    what: "rechecking deps + verify only, no triage and no coder dispatch, in case the failure was transient",
    progress: "not-fixable recheck — coder and triage both skipped; only deps + verify re-run",
    notes:
      "not-fixable recheck: a prior triage pass judged this verification failure not fixable by recoding; re-checking once, cheaply, in case it was transient",
  },
  "conflict-merged-clean": {
    what: "the feature branch now merges cleanly, so re-running verify + review only, no coder dispatch",
    progress: "merge-conflict retry — the sync merged cleanly, so the coder was skipped; verify + review re-run",
    notes: "merge-conflict retry: the conflict the prior round hit did not recur when the feature branch was merged in",
  },
  "ac-receipt-retry": {
    what: "re-running verify + review to rewrite the AC receipt, no coder dispatch",
    progress: "AC receipt retry — coder dispatch skipped; verify + review re-run before the receipt is rewritten",
    notes: "AC receipt retry: the prior round's review was all-met but writing its receipt failed",
  },
};

/**
 * Phase 1 of an issue: worktree + worker dispatch. Runs concurrently across issues.
 * `attempt` is this issue's own 1-based attempt number (sprint.attemptCount in loop.mjs).
 */
export async function runWorker(ctx, issue, attempt) {
  const { sprint, effects, platform, options } = ctx;
  const tracker = await getTracker(effects.mainRoot);
  // github.mjs has no branchFor: the issue number is already the unique part.
  const branch = tracker.branchFor
    ? tracker.branchFor(sprint.featureSlug, issue.slug)
    : `crew/${sprint.featureSlug}/${issue.number}-${issue.slug}`;
  const dispatchDir = sprint.dispatchDir;
  mkdirSync(dispatchDir, { recursive: true });

  // A recorded Progress or Blocked section means a prior attempt left a branch on purpose;
  // resumeBranch then says whether state still retains it and the ref still exists.
  const priorBranch = issue.hasProgress || issue.hasBlocked ? sprint.resumeBranch(issue.slug) : null;
  const retentionReason = priorBranch != null ? sprint.retentionReason(issue.slug) : null;
  let resume = resumeRoute(retentionReason);

  if (resume.route === "merge") {
    ctx.log(
      `[SKIP-TO-MERGE] slug=${issue.slug} reason=${retentionReason} branch=${branch} — retrying merge/close only, no coder dispatch, no verify, no review`,
    );
    return {
      issue,
      branch,
      attempt,
      worktree: null,
      dispatch: { code: 0, timedOut: false, dryRun: false, text: "", stderr: "" },
      report: {
        parsedFrom: "skipped-worker",
        status: "complete",
        checks: { test: "pass", lint: "pass", typecheck: "pass" },
        branch,
        workingDirectory: null,
        progress: `Round ${attempt}: merge/close retry — coder dispatch, verify, and review all skipped`,
        notes: "merge/close retry: the prior round's only failure was the merge or close step itself",
        criteria: [],
        raw: "",
      },
      resumeAtMerge: true,
    };
  }

  // expectReuse only for a branch this issue's own earlier attempt retained: any other
  // existing branch is leftover from an abandoned attempt and may carry a base predating
  // work this sprint has since merged. A reused branch is synced with the feature branch
  // below, where a real conflict still blocks.
  ctx.log(`[STEP] slug=${dispatchStem(issue)} round=${attempt} step=worktree`);
  const wt = ensureWorktree(effects, {
    mainRoot: effects.mainRoot,
    branch,
    base: "HEAD",
    expectReuse: issue.hasProgress || priorBranch != null,
  });

  if (wt.stale) {
    ctx.log(`[STALE-BRANCH] slug=${issue.slug} branch=${branch} — ${wt.reason}`);
    return {
      issue,
      branch,
      attempt,
      worktree: null,
      dispatch: { code: 0, timedOut: false, dryRun: false, text: "", stderr: "" },
      report: {
        parsedFrom: "stale-branch",
        status: "blocked",
        checks: { test: "not_run", lint: "not_run", typecheck: "not_run" },
        branch,
        workingDirectory: null,
        progress: null,
        notes: wt.reason,
        criteria: [],
        raw: "",
      },
    };
  }

  const { path: worktree } = wt;
  // A conflict retry needs its retained branch; without it there is nothing to reconcile.
  if (resume.kind === "conflict" && !wt.reusedBranch) resume = { route: "restart" };

  // A reused branch may predate other issues' merges: sync it now, so the gap surfaces
  // here rather than as a conflict at the merge gate.
  if (wt.reusedBranch) {
    ctx.log(`[STEP] slug=${dispatchStem(issue)} round=${attempt} step=sync-feature-branch`);
    const conflictRetry = resume.kind === "conflict";
    const sync = mergeFeatureBranch(effects, { worktree, branch, featureBranch: sprint.featureBranch, keepConflict: conflictRetry });
    if (sync.kept) {
      ctx.log(`[SYNC-CONFLICT-KEPT] slug=${issue.slug} branch=${branch} files=${sync.files.join(",")} — left for the coder to resolve`);
      resume = { ...resume, conflictFiles: sync.files };
    } else if (conflictRetry) {
      resume = { route: "verify", label: "conflict-merged-clean" };
    }
    if (sync.conflict && !sync.kept) {
      ctx.log(`[SYNC-CONFLICT] slug=${issue.slug} branch=${branch} — ${sync.reason}`);
      // worktree, not null: finishBlocked's removeWorktree needs the real path. Only the
      // branch ref is retained.
      return {
        issue,
        branch,
        attempt,
        worktree,
        dispatch: { code: 0, timedOut: false, dryRun: false, text: "", stderr: "" },
        report: {
          parsedFrom: "sync-conflict",
          status: "blocked",
          checks: { test: "not_run", lint: "not_run", typecheck: "not_run" },
          branch,
          workingDirectory: worktree,
          progress: null,
          notes: sync.reason,
          criteria: [],
          raw: "",
        },
      };
    }
    if (sync.merged) ctx.log(`slug=${issue.slug} round=${attempt} SYNC: merged ${sprint.featureBranch} into ${branch}`);
  }

  applyWorktreeInclude(effects.mainRoot, worktree);

  // Deps sit after the include (an inherited node_modules costs nothing) and before both
  // consumers: the worker, and verify-worktree.sh, a gate that cannot invoke dep-install.
  // The skipped-worker path needs them too — its worktree is recreated bare. A failed
  // install is only logged, not a demotion: the verify gate fails closed on it anyway.
  if (options.deps !== false) {
    ctx.log(`[STEP] slug=${dispatchStem(issue)} round=${attempt} step=deps`);
    const deps = effects.bash("ensure-deps.sh", ["--dir", worktree, "--slug", issue.slug], {
      env: sprint.childEnv(),
    });
    ctx.log(`slug=${issue.slug} round=${attempt} ${depsLine(deps.stdout)}`);
  }

  if (resume.route === "verify") {
    const skip = SKIPPED_WORKER[resume.label];
    ctx.log(`[SKIP-WORKER] slug=${issue.slug} reason=${resume.label} branch=${branch} — ${skip.what}`);
    return {
      issue,
      branch,
      attempt,
      worktree,
      dispatch: { code: 0, timedOut: false, dryRun: false, text: "", stderr: "" },
      report: {
        parsedFrom: "skipped-worker",
        status: "complete",
        checks: { test: "pass", lint: "pass", typecheck: "pass" },
        branch,
        workingDirectory: worktree,
        progress: `Round ${attempt}: ${skip.progress}`,
        notes: skip.notes,
        criteria: [],
        raw: "",
      },
      skippedWorker: true,
    };
  }

  const promptFile = join(dispatchDir, `${dispatchStem(issue)}.prompt.md`);
  const outFile = join(dispatchDir, `${dispatchStem(issue)}.report.md`);
  const sidecarFile = join(dispatchDir, `${dispatchStem(issue)}.report.json`);

  // A stale sidecar at this fixed path must not be read back as this round's verdict.
  rmSync(sidecarFile, { force: true });

  writeFileSync(
    promptFile,
    resume.route === "fix"
      ? fixPrompt({
          mainRoot: effects.mainRoot,
          worktree,
          issuePath: issueDescriptor(issue),
          slug: issue.slug,
          branch,
          context: resume.context,
          kind: resume.kind,
          featureBranch: sprint.featureBranch,
          conflictFiles: resume.conflictFiles,
          reportPath: sidecarFile,
        })
      : workerPrompt({
          mainRoot: effects.mainRoot,
          worktree,
          issuePath: issueDescriptor(issue),
          slug: issue.slug,
          criteria: issue.criteria,
          // A block before any commit still retains the branch: name it only if it holds work.
          resume: resumeNote({
            priorBranch: priorBranch && branchHasCommits(effects, sprint.featureBranch, priorBranch) ? priorBranch : null,
            hasProgress: issue.hasProgress,
            hasBlocked: issue.hasBlocked,
          }),
          reportPath: sidecarFile,
        }),
  );

  ctx.log(
    `[STEP] slug=${dispatchStem(issue)} round=${attempt} step=dispatch-coder model=${options.model ?? "inherit"}`,
  );
  const result = await dispatch(
    effects,
    platform,
    {
      agent: "crew-coder",
      cwd: worktree,
      promptFile,
      outFile,
      model: options.model,
      mainRoot: effects.mainRoot,
      logFile: sprint.traceLog,
      featureSlug: sprint.featureSlug,
      scriptsDir: effects.scriptsDir,
      slug: dispatchStem(issue),
      issueNumber: issue.number,
      round: attempt,
      reportPath: sidecarFile,
    },
    {
      timeoutMs: options.workerTimeoutMs,
      onTrace: (line) => ctx.log(`slug=${dispatchStem(issue)} round=${attempt} ${line}`),
    },
  );

  const sidecar = readSidecar(sidecarFile);

  const report = parseWorkerReport(result.text, sidecar);
  return { issue, branch, attempt, worktree, dispatch: result, report };
}

/**
 * Phase 2 of an issue: everything after the worker. Runs concurrently across issues, but
 * merge and close shell out via spawnSync, which blocks this process, so two issues'
 * merge-and-close never interleave. Merge order is completion order; merge-branches.sh
 * tolerates any.
 */
export async function runHousekeeping(ctx, worker) {
  const { sprint, effects, options } = ctx;
  const { issue, branch } = worker;
  const outcome = { slug: issue.slug, branch, status: null, reason: null, coverageGaps: [], findings: [], reviewReport: null };

  // The merge route (see resumeRoute): straight to merge/close, which re-checks both receipts.
  if (worker.resumeAtMerge) {
    return mergeAndClose(ctx, worker, outcome);
  }

  // Counted whatever the outcome: a timed-out dispatch still spent tokens. Claude-only
  // fields for now; 0 elsewhere.
  sprint.recordDispatchCost({
    costUsd: worker.dispatch.costUsd,
    durationMs: worker.dispatch.durationMs,
    numTurns: worker.dispatch.numTurns,
  });

  // --- dispatch health -------------------------------------------------------
  // A dead dispatch (timeout, crash) with commits on the branch is resumed, not discarded;
  // with none, there is nothing to resume and it blocks.
  if (worker.dispatch.timedOut) {
    const reason = `worker timed out after ${Math.round(options.workerTimeoutMs / 60000)}m`;
    if (branchHasCommits(effects, sprint.featureBranch, branch)) return finishRetryOrBlock(ctx, worker, outcome, reason);
    return finishBlocked(ctx, worker, outcome, reason);
  }
  // A bad exit (or claude's `is_error`) counts only with no usable report: a worker that
  // exited badly but reported a reason knows more than the process signal does.
  if ((worker.dispatch.code !== 0 || worker.dispatch.isError) && worker.report.unparseable) {
    const reason = "worker process failed — see traces/";
    if (branchHasCommits(effects, sprint.featureBranch, branch)) return finishRetryOrBlock(ctx, worker, outcome, reason);
    return finishBlocked(ctx, worker, outcome, reason);
  }

  // --- schema pre-filter -----------------------------------------------------
  const pre = applySchemaPrefilter(worker.report);
  outcome.coverageGaps = pre.coverageGaps;
  if (pre.coverageGaps.length) sprint.coverageGap(issue.slug, pre.coverageGaps);

  if (pre.status === "blocked") {
    return finishBlocked(ctx, worker, outcome, pre.reason ?? worker.report.notes ?? "blocked");
  }
  if (pre.status !== "complete") {
    return finishRetryOrBlock(ctx, worker, outcome, pre.reason ?? "partial");
  }

  // Not a verdict yet, but the coder is the longest step: a mid-pipeline heartbeat.
  notifyMilestone(ctx, issue, `coder finished (round ${worker.attempt}) — verifying`);

  // --- gate 1: independent verification in the worktree ----------------------
  ctx.log(`[STEP] slug=${dispatchStem(issue)} round=${worker.attempt} step=verify`);
  const verify = effects.bash("verify-worktree.sh", ["--dir", worker.worktree], {
    env: sprint.childEnv(),
  });
  ctx.log(`slug=${issue.slug} round=${worker.attempt} ${verify.stdout.trim()}`);
  if (verify.code !== 0) {
    return await handleVerificationFailure(ctx, worker, outcome, verify);
  }
  if (/coverage gap/i.test(verify.stdout)) {
    const cats = [...verify.stdout.matchAll(/not_run:\s*([\w, ]+)/gi)]
      .flatMap((m) => m[1].split(",").map((s) => s.trim()))
      .filter(Boolean);
    if (cats.length) {
      sprint.coverageGap(issue.slug, cats);
      outcome.coverageGaps = [...new Set([...outcome.coverageGaps, ...cats])];
    }
  }

  // --- gate 2: independent review (findings + acceptance-criteria verdict) ---
  // The worktree stays alive across review (which needs none of it): an `AC: unmet`
  // verdict sends the coder back to fix this branch.
  const review = await runReview(ctx, worker, parseVerifyChecks(verify.stdout));
  outcome.reviewReport = review.reportFile;
  if (!review.completed) {
    effects.bash("promote-findings.sh", [
      "mark-not-run",
      "--feature-slug", sprint.featureSlug,
      "--branch", branch,
      "--slug", issue.slug,
      "--report", review.reportFile,
      "--reason", review.reason,
    ], { env: sprint.childEnv() });
    return finishRetryOrBlock(ctx, worker, outcome, "review-not-run");
  }
  outcome.findings = review.parsed.findings;

  if (review.parsed.verdict !== "all-met") {
    return finishRetryOrBlock(
      ctx,
      worker,
      outcome,
      taggedReason(CRITERIA_UNMET_TAG, review.parsed.detail || "see review"),
    );
  }

  // All-met: no fix retry is coming, and every later gate reads from the main checkout.
  removeWorktree(effects, { mainRoot: effects.mainRoot, path: worker.worktree });

  // The receipt close-issue.sh demands: only on all-met, only for this issue's branch.
  const acReceipt = effects.bash("receipts.sh", ["write", "ac", "--branch", branch], {
    env: sprint.childEnv(),
  });
  if (acReceipt.code !== 0) {
    const detail = (acReceipt.stderr || acReceipt.stdout || "").trim() || `exit ${acReceipt.code}`;
    return finishRetryOrBlock(ctx, worker, outcome, taggedReason(AC_RECEIPT_FAILED_TAG, detail));
  }

  // --- findings promotion (advisory findings routed back into the sprint) ----
  await promote(ctx, worker, review, outcome);

  return mergeAndClose(ctx, worker, outcome);
}

