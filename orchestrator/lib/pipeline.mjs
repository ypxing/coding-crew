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
 */

import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import {
  applySchemaPrefilter,
  depsLine,
  findingsAtOrAbove,
  parseReviewReport,
  parseTriageReport,
  parseVerifyChecks,
  parseWorkerReport,
} from "./report.mjs";
import { getTracker } from "./tracker.mjs";
import { criteriaFile, fixPrompt, resumeNote, reviewPrompt, triagePrompt, workerPrompt } from "./prompts.mjs";
import { applyWorktreeInclude, ensureWorktree, mergeFeatureBranch, removeWorktree } from "./worktree.mjs";
import { dispatch, notifyTriggeringPane } from "./dispatch.mjs";

// Retention-reason tags for a verify-worktree.sh failure, once triage (see runTriage
// below) has classified it. Read back by runWorker to route the *next* attempt — a
// fixable verdict to a narrower fix prompt, a not-fixable one to a coder-free recheck.
// Centralised here, not restated at each comparison, so the tag and its separator cannot
// drift between the writer and the reader.
const FIXABLE_TAG = "verification-failed:fixable";
const NOT_FIXABLE_TAG = "verification-failed:not-fixable";
// Written by runHousekeeping on an `AC: unmet` verdict, read back by runWorker the same
// way FIXABLE_TAG is: routes the retry to fixPrompt instead of a full workerPrompt restart.
// No triage step here — the reviewer's own detail is already the concrete, actionable
// thing a fix needs, unlike a verify failure's raw check output.
const CRITERIA_UNMET_TAG = "criteria-unmet";
const REASON_SEP = " — ";

// Every non-`complete` outcome — verify failure, unmet AC, a failed merge, a review that
// never landed a report, anything — spends one of this issue's attempts (see
// finishRetryOrBlock below). Two spent attempts and the third demotion becomes `blocked`
// instead of another retry: one retry is "might have been transient", a second failure in
// the same shape is the answer, not a reason to ask a fourth time. Replaces what used to
// be two separate, reason-specific repeat-checks (a second not-fixable verdict, a second
// review-not-run) with one rule that covers every retry path the same way.
const MAX_ATTEMPTS_PER_ISSUE = 2;

function taggedReason(tag, summary) {
  return `${tag}${REASON_SEP}${summary}`;
}

/** Dispatch filename stem — the issue's own `NN-<slug>` (see tracker.mjs's issueNumber), so
 * prompt/report files sort and scan the same way the issue tracker's own files do. Falls
 * back to the bare slug when the issue file carries no leading number. */
function dispatchStem(issue) {
  return issue.number ? `${issue.number}-${issue.slug}` : issue.slug;
}

/** The one push per issue per round a caller polling for milestones actually needs —
 * a terminal outcome, not every gate in between. Always written to ctx.log (stderr +
 * orchestrator.log) first: that is the only signal a non-herdr caller ever gets — the
 * herdr push below it is a no-op off-herdr (see notifyTriggeringPane's own doc comment),
 * so without this line a whole sprint's worth of milestones was previously invisible to
 * anyone not running under herdr, discoverable only after the fact from a finished
 * sprint's final summary. */
function notifyMilestone(ctx, issue, message) {
  ctx.log(`[MILESTONE] ${dispatchStem(issue)}: ${message}`);
  return notifyTriggeringPane(ctx.effects, `[${ctx.sprint.featureSlug}] ${dispatchStem(issue)}: ${message}`);
}

/** close-issue.sh / promote-findings.sh's own `--issue`/positional argument: an issue
 * file path for local, a bare GitHub issue number for github (both scripts branch on
 * tracker-config.sh the same way; see close-issue.sh's own "tracker backend" comment). */
function issueRef(issue) {
  return issue.path ?? String(issue.number);
}

/** The `issuePath:` value handed to prompts.mjs's builders — a real path to `cat` for
 * local; for github (no file, just an already-fetched body this dispatch doesn't
 * forward), a pointer the dispatched agent can act on directly instead of the literal
 * string "undefined". */
function issueDescriptor(issue) {
  return issue.path ?? `GitHub issue #${issue.number} — fetch its current body with: gh issue view ${issue.number} --json body -q .body`;
}

/** The free text after a tag this module itself wrote — never applied to a reason whose tag is unknown. */
function stripReasonTag(reason, tag) {
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
async function writeTrackerSection(effects, issue, heading, body, { append = false } = {}) {
  if (effects.dryRun) return;
  const tracker = await getTracker(effects.mainRoot);
  if (tracker.writeIssueSection) {
    if (issue.path && existsSync(issue.path)) tracker.writeIssueSection(issue.path, heading, body, { append });
    return;
  }
  if (tracker.writeProgress) tracker.writeProgress(issue, body, { heading, mainRoot: effects.mainRoot });
}

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

  // merge-failed and close-refused are a stronger guarantee than review-not-run: verify
  // already passed, review already returned `AC: all-met`, and the AC receipt is already
  // on disk — only the merge (or, for close-refused, the already-merged no-op plus the
  // close) step itself needs another attempt. This resume target skips not just the
  // coder dispatch but the worktree it would run in, verify-worktree.sh, and the reviewer
  // dispatch too, re-entering runHousekeeping directly at the merge step with the branch
  // already on disk. That is safe only because merge-branches.sh and close-issue.sh
  // themselves re-check the SHA-bound verify receipt and the AC receipt every time they
  // run, rather than trusting a prior round's pass — this resume target relies on that
  // re-check, it does not replace it.
  if (
    priorBranch != null &&
    (retentionReason === "merge-failed" || retentionReason?.startsWith("close-refused"))
  ) {
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

  // A branch retained purely because its *review* dispatch failed to produce a usable
  // report (timeout, crash, transient dispatch failure — see `[DISPATCH-FAIL]` tracing in
  // dispatch.mjs) already has a worker that completed and a verify that passed in the
  // prior round: nothing about the branch's content needs to change, only the review needs
  // another attempt. Every other retention reason (verification-failed, criteria-unmet,
  // merge-failed, close-refused) means the branch itself needs more work, so only this one
  // reason skips the coder — re-entering the pipeline at the verify gate below with the
  // already-retained branch, instead of paying for a brand new ~45m worker dispatch to
  // reach a functionally identical outcome.
  //
  // A not-fixable triage verdict (see runTriage in runHousekeeping) earns the same skip,
  // for a different reason: triage already said no code on this branch can fix it, so
  // dispatching the coder again would only relearn that. What this attempt *does* try is
  // the one thing a not-fixable verdict cannot rule out by itself — a transient failure
  // (a registry blip, a flaky network) that a plain, coder-free deps + verify re-run might
  // simply not hit a second time. If it fails again, this issue's retry cap (see
  // finishRetryOrBlock) is what stops a third attempt, not a reason-specific repeat-check.
  const notFixableRetry = priorBranch != null && retentionReason?.startsWith(NOT_FIXABLE_TAG);
  const skipWorker = (priorBranch != null && retentionReason === "review-not-run") || notFixableRetry;

  // A fixable triage verdict, or a reviewer's `AC: unmet` verdict, routes to a narrower
  // prompt (fixPrompt, below) instead of the generic workerPrompt + resumeNote — the coder
  // still runs, just told exactly what failed and why, instead of re-reading the whole
  // issue as if starting over.
  const fixableRetry = priorBranch != null && retentionReason?.startsWith(FIXABLE_TAG);
  const criteriaUnmetRetry = priorBranch != null && retentionReason?.startsWith(CRITERIA_UNMET_TAG);

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

  if (skipWorker) {
    const label = notFixableRetry ? "not-fixable-recheck" : "review-not-run";
    const what = notFixableRetry
      ? "rechecking deps + verify only, no triage and no coder dispatch, in case the failure was transient"
      : "retrying review only, no coder dispatch";
    ctx.log(`[SKIP-WORKER] slug=${issue.slug} reason=${label} branch=${branch} — ${what}`);
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
    fixableRetry || criteriaUnmetRetry
      ? fixPrompt({
          mainRoot: effects.mainRoot,
          worktree,
          issuePath: issueDescriptor(issue),
          slug: issue.slug,
          branch,
          context: criteriaUnmetRetry
            ? stripReasonTag(retentionReason, CRITERIA_UNMET_TAG)
            : stripReasonTag(retentionReason, FIXABLE_TAG),
          kind: criteriaUnmetRetry ? "review" : "verify",
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

  let sidecar = null;
  if (existsSync(sidecarFile)) {
    try {
      sidecar = JSON.parse(readFileSync(sidecarFile, "utf8"));
    } catch {
      sidecar = null;
    }
  }

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

/**
 * Merge, then close only on the merge's success. Shared by the normal end-of-pipeline
 * path and the merge-failed/close-refused resume, which re-enters here directly — both
 * rely on merge-branches.sh's already-merged short-circuit and receipts.sh's own SHA-
 * bound checks to make a retry safe, not on anything re-derived above this function.
 */
async function mergeAndClose(ctx, worker, outcome) {
  const { sprint, effects, options } = ctx;
  const { issue, branch } = worker;

  effects.git(["checkout", sprint.featureBranch]);
  ctx.log(`[STEP] slug=${dispatchStem(issue)} round=${worker.attempt} step=merge`);
  // effects.bash runs spawnSync, which blocks the same single event loop every issue's
  // dispatch shares (see dispatch.mjs's herdrExec comment for the same hazard elsewhere) —
  // without a bound here, a stalled merge (e.g. a docker-mode merge whose container hangs
  // on a network fetch) freezes the whole sprint, not just this issue.
  const merge = effects.bash("merge-branches.sh", [sprint.featureBranch, branch], {
    env: sprint.childEnv(),
    timeoutMs: options.mergeTimeoutMs,
  });
  ctx.log(`slug=${issue.slug} round=${worker.attempt} ${merge.stdout.trim()}`);
  if (merge.code !== 0) {
    if (merge.code === 124) {
      effects.git(["merge", "--abort"]);
    }
    return finishRetryOrBlock(ctx, worker, outcome, "merge-failed");
  }

  ctx.log(`[STEP] slug=${dispatchStem(issue)} round=${worker.attempt} step=close`);
  // The branch is only needed by the github path (receipts.sh check ac --branch — see
  // close-issue.sh's own comment); harmless as a trailing arg for local, which ignores it.
  const close = effects.bash("close-issue.sh", [issueRef(issue), branch], {
    env: sprint.childEnv(),
    timeoutMs: options.mergeTimeoutMs,
  });
  ctx.log(`slug=${issue.slug} round=${worker.attempt} ${close.stdout.trim()}`);
  if (close.code !== 0) {
    return finishRetryOrBlock(ctx, worker, outcome, `close-refused — ${close.stderr.trim() || close.stdout.trim()}`);
  }

  sprint.complete(issue.slug, branch);
  outcome.status = "complete";
  await notifyMilestone(ctx, issue, `complete — merged and closed (round ${worker.attempt})`);
  return outcome;
}

/**
 * Verify-worktree.sh already failed — decide what that failure means before demoting.
 *
 * Dispatches `runTriage`, an agent independent of the coder that wrote the branch (the same
 * reason review is independent of the coder, not a self-grade), and tags the retention
 * reason with its verdict so the next attempt's runWorker can route on it without
 * re-deriving anything. A not-fixable verdict that recurs stops on its own, via this issue's
 * retry cap (see finishRetryOrBlock) — no reason-specific repeat-check needed here.
 *
 * Exception: a not-fixable-recheck round (runWorker's skipWorker path, worker.skippedWorker)
 * already carries a triage verdict from the round that first retained this branch — that is
 * the whole point of "recheck deps + verify only" ([SKIP-WORKER]'s own "no triage" promise).
 * Re-triaging here on the exact same failure would just re-ask the same question at the cost
 * of another dispatch, so this reuses that prior verdict verbatim instead.
 */
async function handleVerificationFailure(ctx, worker, outcome, verify) {
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
async function runTriage(ctx, worker, verifyStdout) {
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

  let sidecar = null;
  if (existsSync(sidecarFile)) {
    try {
      sidecar = JSON.parse(readFileSync(sidecarFile, "utf8"));
    } catch {
      sidecar = null;
    }
  }

  const parsed = parseTriageReport(result.text, sidecar);
  const completed = !result.timedOut && parsed.ok;
  return { completed, parsed };
}

async function runReview(ctx, worker, checks) {
  const { sprint, effects, platform, options } = ctx;
  const { issue, branch } = worker;
  const promptFile = join(sprint.dispatchDir, `${dispatchStem(issue)}.review-prompt.md`);
  const outFile = join(sprint.dispatchDir, `${dispatchStem(issue)}.review.md`);
  const sidecarFile = join(sprint.dispatchDir, `${dispatchStem(issue)}.review.report.json`);
  const reportFile = ctx.roundReviewFile();

  // See runWorker's matching rmSync: this path is fixed per issue, so a stale sidecar from
  // a prior review dispatch must not be read back as this round's verdict.
  rmSync(sidecarFile, { force: true });

  writeFileSync(
    promptFile,
    reviewPrompt({
      branch,
      slug: issue.slug,
      issuePath: issueDescriptor(issue),
      criteria: issue.criteria,
      featureBranch: sprint.featureBranch,
      checks,
      reportPath: sidecarFile,
    }),
  );

  ctx.log(
    `[STEP] slug=${dispatchStem(issue)} round=${worker.attempt} step=dispatch-review model=${options.reviewerModel ?? "inherit"}`,
  );
  const result = await dispatch(
    effects,
    platform,
    {
      agent: "crew-code-reviewer",
      cwd: effects.mainRoot,
      promptFile,
      outFile,
      // The reviewer defaults to the coder's model: reviewing on a weaker one silently
      // changes the standard the branch is held to. .coding-crew/afk-models.json can name
      // a different (typically stronger) one explicitly.
      model: options.reviewerModel,
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

  let sidecar = null;
  if (existsSync(sidecarFile)) {
    try {
      sidecar = JSON.parse(readFileSync(sidecarFile, "utf8"));
    } catch {
      sidecar = null;
    }
  }

  const parsed = parseReviewReport(result.text, sidecar);
  // sidecar-only, fail-closed: parsed.ok is false whenever the sidecar is missing or has no
  // valid verdict, whatever the dispatch's captured text happened to contain — there is no
  // separate "real prose findings without a verdict block" case to disambiguate any more,
  // since findings are only ever read from the sidecar too.
  if (result.timedOut || !parsed.ok) {
    // result.stderr is where a dispatch-level failure reason actually lives (a `die()`
    // guard in dispatch-agent.sh, a spawn-level error, ...) — surfaced here so a human
    // reading the review report's `not_run` stub does not have to reproduce the dispatch
    // by hand to find out why.
    const stderrHint = (result.stderr ?? "").trim().slice(0, 300).replace(/\s+/g, " ");
    return {
      completed: false,
      reportFile,
      reason: result.timedOut ? "review dispatch timed out" : `${parsed.detail}${stderrHint ? ` — ${stderrHint}` : ""}`,
      parsed,
    };
  }

  // The aggregate file is fed straight from the sidecar's own bytes, not the dispatch's
  // captured text — the two used to usually agree (the reviewer's protocol asked for the
  // same block twice, once to disk and once in its final message) but only ever *usually*:
  // this makes them identical by construction. The `## Branch:` heading is cosmetic —
  // parseReviewAggregate only ever scans for the fenced json block — but keeps the
  // aggregate readable for a human, sourced from the sidecar's own branch/slug rather than
  // trusting the model's chat reply to have written one correctly.
  mkdirSync(sprint.reviewDir, { recursive: true });
  const heading = `## Branch: ${sidecar.branch ?? branch} (${sidecar.slug ?? issue.slug})`;
  const block = `${heading}\n\n\`\`\`json\n${JSON.stringify(sidecar)}\n\`\`\``;
  const prefix = existsSync(reportFile) ? "\n\n" : "";
  writeFileSync(reportFile, `${existsSync(reportFile) ? readFileSync(reportFile, "utf8") : ""}${prefix}${block}\n`);
  return { completed: true, reportFile, parsed };
}

async function promote(ctx, worker, review, outcome) {
  const { sprint, effects } = ctx;
  const { issue, branch } = worker;
  const guard = effects.bash("promote-findings.sh", ["guard", "--issue", issueRef(issue)], {
    env: sprint.childEnv(),
  });
  const guardText = guard.stdout.trim();
  ctx.log(`slug=${issue.slug} round=${worker.attempt} ${guardText}`);
  if (!/promotable/.test(guardText)) return; // source-guarded: the depth bound

  const threshold = /critical-high/i.test(guardText) ? "critical-high" : sprint.promoteThreshold;
  const promotable = findingsAtOrAbove(review.parsed.findings, threshold);
  if (!promotable.length) return;

  mkdirSync(sprint.reviewDir, { recursive: true });
  const criteriaPath = join(sprint.reviewDir, `${issue.slug}.criteria.md`);
  writeFileSync(criteriaPath, criteriaFile({ branch, findings: promotable }));

  const defer = effects.bash("promote-findings.sh", [
    "defer",
    "--feature-slug", sprint.featureSlug,
    "--branch", branch,
    "--slug", issue.slug,
    "--title", `Fix review findings: ${issue.slug}`,
    "--report", review.reportFile,
    "--criteria-file", criteriaPath,
  ], { env: sprint.childEnv() });
  ctx.log(`slug=${issue.slug} round=${worker.attempt} ${defer.stdout.trim()}`);
  outcome.promoted = promotable.length;
}

/**
 * Every retryable demotion goes through here instead of calling finishPartial directly —
 * this is the one place that decides, from this dispatch's own attempt number (spent at
 * claim time, see sprint.bumpAttempt in loop.mjs), whether there's still a retry left or
 * whether it's time to give up and let a human look. `reason` is passed through unchanged
 * on a retry; finishBlocked gets a reason that says *why* the cap tripped, since by then
 * the original reason has already repeated once.
 */
function finishRetryOrBlock(ctx, worker, outcome, reason) {
  if (worker.attempt >= MAX_ATTEMPTS_PER_ISSUE) {
    return finishBlocked(ctx, worker, outcome, `retry limit reached (${worker.attempt} attempts) — ${reason}`);
  }
  return finishPartial(ctx, worker, outcome, reason);
}

async function finishPartial(ctx, worker, outcome, reason) {
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

async function finishBlocked(ctx, worker, outcome, reason) {
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
