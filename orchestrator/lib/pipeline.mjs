/**
 * pipeline.mjs — the per-branch gate chain, in one place, in one order:
 *
 *     worktree → include → deps → dispatch → prefilter → verify → review → AC receipt
 *     → promote → merge → close
 *
 * This is the part that was prose, and the part that failed in real sprints: a branch
 * merged with a failing VERIFY, an issue closed off a sibling's branch, a review
 * skipped and read as clean. Here the order is a function body, so it cannot be
 * reordered by a model that is running low on context, and each gate's refusal is a
 * return value rather than a paragraph asking to be obeyed.
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
  CRITERIA_UNMET_TAG,
  dispatchStem,
  FIXABLE_TAG,
  issueDescriptor,
  NOT_FIXABLE_TAG,
  notifyMilestone,
  readSidecar,
  stripReasonTag,
  taggedReason,
} from "./pipeline/shared.mjs";
import { handleVerificationFailure } from "./pipeline/verify.mjs";

/**
 * Whether `branch` carries any commit the feature branch doesn't already have — the same
 * question ensureWorktree's own staleness check answers from the other side. Used to tell a
 * dispatch that died before writing any report (worker process crash, timeout) apart from
 * one that also never got the coder to commit anything: only the former has real work
 * worth resuming next round instead of just a reason to give up.
 */
function branchHasCommits(effects, featureBranch, branch) {
  const r = effects.gitRead(["rev-list", "--count", `${featureBranch}..${branch}`]);
  return r.code === 0 && parseInt(r.stdout.trim(), 10) > 0;
}

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
 *   fix     `verification-failed:fixable`, `criteria-unmet` — the coder runs on fixPrompt,
 *           told exactly what failed, instead of re-reading the whole issue.
 *   restart anything else, including no reason — the coder runs on workerPrompt.
 *
 * The retry cap (MAX_ATTEMPTS_PER_ISSUE, pipeline/finish.mjs) bounds every route alike.
 */
export function resumeRoute(reason) {
  if (reason == null) return { route: "restart" };
  if (reason === "merge-failed" || reason.startsWith("close-refused")) return { route: "merge" };
  if (reason === "review-not-run") return { route: "verify", label: "review-not-run" };
  if (reason.startsWith(NOT_FIXABLE_TAG)) return { route: "verify", label: "not-fixable-recheck" };
  if (reason.startsWith(FIXABLE_TAG)) return { route: "fix", kind: "verify", context: stripReasonTag(reason, FIXABLE_TAG) };
  if (reason.startsWith(CRITERIA_UNMET_TAG)) {
    return { route: "fix", kind: "review", context: stripReasonTag(reason, CRITERIA_UNMET_TAG) };
  }
  return { route: "restart" };
}

/**
 * Phase 1 of an issue: worktree + worker dispatch. Runs concurrently across issues.
 * `attempt` is this issue's own 1-based attempt number (see sprint.attemptCount in
 * loop.mjs) — independent of any other issue's, since the scheduler no longer batches
 * issues into synchronized rounds.
 */
export async function runWorker(ctx, issue, attempt) {
  const { sprint, effects, platform, options } = ctx;
  const tracker = await getTracker(effects.mainRoot);
  // github.mjs has no branchFor of its own — an issue number is already the unique part a
  // filename-derived slug exists to provide for local, so the branch name is computed
  // inline here per the PRD's Slug/branch mapping decision instead of a factory method.
  const branch = tracker.branchFor
    ? tracker.branchFor(sprint.featureSlug, issue.slug)
    : `crew/${sprint.featureSlug}/${issue.number}-${issue.slug}`;
  const dispatchDir = sprint.dispatchDir;
  mkdirSync(dispatchDir, { recursive: true });

  const priorBranch = issue.hasProgress ? sprint.resumeBranch(issue.slug) : null;
  const retentionReason = priorBranch != null ? sprint.retentionReason(issue.slug) : null;
  const resume = resumeRoute(retentionReason);

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

  // expectReuse: true only when the issue itself has a recorded reason to already have
  // a branch (progress from an earlier round). A branch ref that exists despite this
  // being a fresh dispatch is not a resume — it's leftover from an abandoned attempt
  // (branches are never deleted except by cleanup-worktrees.sh's own ancestry-checked
  // sweep), and silently reusing it can carry a base that predates work this sprint has
  // since merged, surfacing only much later as an unexplained merge conflict.
  ctx.log(`[STEP] slug=${dispatchStem(issue)} round=${attempt} step=worktree`);
  const wt = ensureWorktree(effects, {
    mainRoot: effects.mainRoot,
    branch,
    base: "HEAD",
    expectReuse: issue.hasProgress,
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

  // A reused branch (this round's resume, or a worktree left over from an earlier
  // `crew-afk` invocation) may have been forked from the feature branch before other
  // issues merged into it — sync that history in now, before the coder ever sees the
  // branch, instead of letting the gap surface as a conflict at the merge gate later.
  if (wt.reusedBranch) {
    ctx.log(`[STEP] slug=${dispatchStem(issue)} round=${attempt} step=sync-feature-branch`);
    const sync = mergeFeatureBranch(effects, { worktree, branch, featureBranch: sprint.featureBranch });
    if (sync.conflict) {
      ctx.log(`[SYNC-CONFLICT] slug=${issue.slug} branch=${branch} — ${sync.reason}`);
      // worktree (not null): the checkout was actually created above and merge --abort
      // already left it clean — finishBlocked's own removeWorktree() call needs the real
      // path to clean it up. Only the branch ref (and whatever WIP it holds) is retained.
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

  // Deps, here, because this position is the whole point: after the include (so an
  // inherited node_modules is seen by the presence guard and costs nothing) and before
  // *both* consumers of them. The worker is the obvious one; verify-worktree.sh is the one
  // no worker skill can cover — it runs the project's own tests in this worktree, has no
  // dep recovery path, and being a gate it cannot invoke dep-install. That second consumer
  // still needs this even on the skipped-worker path: the worktree removed at the end of
  // the prior (partial) round is recreated bare here, with no node_modules of its own yet.
  //
  // The DEPS: line is logged and nothing more. A failed install is not a demotion: the
  // verify gate already fails closed on the consequence, and stalling a whole round on
  // whatever host-install.sh mishandled would be worse than letting the gate say so.
  if (options.deps !== false) {
    ctx.log(`[STEP] slug=${dispatchStem(issue)} round=${attempt} step=deps`);
    const deps = effects.bash("ensure-deps.sh", ["--dir", worktree, "--slug", issue.slug], {
      env: sprint.childEnv(),
    });
    ctx.log(`slug=${issue.slug} round=${attempt} ${depsLine(deps.stdout)}`);
  }

  if (resume.route === "verify") {
    const notFixableRetry = resume.label === "not-fixable-recheck";
    const what = notFixableRetry
      ? "rechecking deps + verify only, no triage and no coder dispatch, in case the failure was transient"
      : "retrying review only, no coder dispatch";
    ctx.log(`[SKIP-WORKER] slug=${issue.slug} reason=${resume.label} branch=${branch} — ${what}`);
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
        progress: notFixableRetry
          ? `Round ${attempt}: not-fixable recheck — coder and triage both skipped; only deps + verify re-run`
          : `Round ${attempt}: review-only retry — coder dispatch skipped, branch content unchanged`,
        notes: notFixableRetry
          ? "not-fixable recheck: a prior triage pass judged this verification failure not fixable by recoding; re-checking once, cheaply, in case it was transient"
          : "review-only retry: the prior round's only failure was the review dispatch itself",
        criteria: [],
        raw: "",
      },
      skippedWorker: true,
    };
  }

  const promptFile = join(dispatchDir, `${dispatchStem(issue)}.prompt.md`);
  const outFile = join(dispatchDir, `${dispatchStem(issue)}.report.md`);
  const sidecarFile = join(dispatchDir, `${dispatchStem(issue)}.report.json`);

  // A prior round's (or a prior resumed sprint's) sidecar at this same fixed path must not
  // be mistaken for this round's verdict if the coder's turn dies before writing one.
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
          reportPath: sidecarFile,
        })
      : workerPrompt({
          mainRoot: effects.mainRoot,
          worktree,
          issuePath: issueDescriptor(issue),
          slug: issue.slug,
          criteria: issue.criteria,
          resume: resumeNote({ priorBranch, hasProgress: issue.hasProgress, hasBlocked: issue.hasBlocked }),
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
 * Phase 2 of an issue: everything after the worker. Runs concurrently across issues, in
 * the same pool as the worker dispatch (see runSprint in loop.mjs) — merges and closes
 * touch the main checkout, but every such step shells out via effects.bash/git's
 * spawnSync, which blocks this single-threaded process until it returns, so two issues'
 * merge-and-close can never actually interleave. Only which issue's merge lands first
 * becomes completion-order rather than issue-list-order; merge-branches.sh already
 * tolerates any order (it merges by branch, independent of the others).
 */
export async function runHousekeeping(ctx, worker) {
  const { sprint, effects, options } = ctx;
  const { issue, branch } = worker;
  const outcome = { slug: issue.slug, branch, status: null, reason: null, coverageGaps: [], findings: [], reviewReport: null };

  // merge-failed / close-refused resume: verify, review, and the AC receipt already
  // happened in the round that produced this retention reason. Nothing here re-derives
  // any of that — it goes straight to the merge/close step, which re-checks both
  // receipts itself.
  if (worker.resumeAtMerge) {
    return mergeAndClose(ctx, worker, outcome);
  }

  // Every dispatch's cost/duration/turns count toward the sprint's running totals
  // (crew-summary.sh's cost line) regardless of what it did — a timed-out or blocked
  // dispatch still spent tokens. Claude-only fields for now (dispatch.mjs's
  // extractResultMeta); no-ops to 0 for every other platform.
  sprint.recordDispatchCost({
    costUsd: worker.dispatch.costUsd,
    durationMs: worker.dispatch.durationMs,
    numTurns: worker.dispatch.numTurns,
  });

  // --- dispatch health -------------------------------------------------------
  // A dead dispatch (timeout, crash — see [DISPATCH-FAIL] tracing in dispatch.mjs) with
  // real commits on the branch already is worth resuming, not discarding: finishPartial
  // writes the same ## Progress section a genuine partial-work report would, so the next
  // round's resumeNote correctly says "resume on that branch, the code is preserved"
  // instead of just warning about a repeat failure. A dead dispatch that never got the
  // coder to commit anything has nothing to resume — that one still blocks.
  if (worker.dispatch.timedOut) {
    const reason = `worker timed out after ${Math.round(options.workerTimeoutMs / 60000)}m`;
    if (branchHasCommits(effects, sprint.featureBranch, branch)) return finishRetryOrBlock(ctx, worker, outcome, reason);
    return finishBlocked(ctx, worker, outcome, reason);
  }
  // A non-zero exit, or claude's own `is_error: true` on the terminal result, *and*
  // nothing usable back: the worker died (or ended in an error state) before reporting.
  // Its own report is preferred whenever there is one — a worker that exited badly but
  // reported `blocked` with a reason knows more than the process signal does.
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

  // The coder's own report is not yet the sprint's verdict — verify/review/merge still
  // gate it — but it is the longest single step in the pipeline, and the triggering pane
  // otherwise hears nothing about this issue until one of those later gates reaches a
  // terminal outcome. A milestone here gives it a mid-pipeline heartbeat instead of silence.
  await notifyMilestone(ctx, issue, `coder finished (round ${worker.attempt}) — verifying`);

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
  // The worktree stays alive across this gate (deliberately not removed right after
  // verify, despite review reading the branch from the main checkout and needing none of
  // it) — an `AC: unmet` verdict below sends the coder back to fix its own branch, and
  // removing it eagerly would throw away exactly what that retry needs.
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
    // This issue's retry cap (see finishRetryOrBlock) is what stops a third attempt if the
    // review dispatch itself keeps failing to land a report — no reason-specific repeat-check
    // needed here. Neither outcome here redispatches the coder (only the reviewer) —
    // finishBlocked/finishPartial's own default cleanup (no keepWorktree) is exactly right,
    // nothing left that a coder retry could reuse.
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

  // Every gate after this reads the branch from the main checkout, same as review just did —
  // but review confirming all-met means there is no more fix retry coming, so the worktree
  // is finally done being useful.
  removeWorktree(effects, { mainRoot: effects.mainRoot, path: worker.worktree });

  // The receipt close-issue.sh demands, written only on an all-met verdict, and only
  // ever for this issue's own slug.
  const acReceipt = effects.bash("receipts.sh", ["write", "ac", "--branch", branch], {
    env: sprint.childEnv(),
  });
  if (acReceipt.code !== 0) {
    return finishRetryOrBlock(ctx, worker, outcome, "ac-receipt-failed");
  }

  // --- findings promotion (advisory findings routed back into the sprint) ----
  await promote(ctx, worker, review, outcome);

  return mergeAndClose(ctx, worker, outcome);
}

