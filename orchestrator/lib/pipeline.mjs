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

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
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
import { branchFor, writeIssueSection } from "./tracker.mjs";
import { criteriaFile, fixPrompt, resumeNote, reviewPrompt, triagePrompt, workerPrompt } from "./prompts.mjs";
import { applyWorktreeInclude, ensureWorktree, mergeFeatureBranch, removeWorktree } from "./worktree.mjs";
import { dispatch } from "./dispatch.mjs";

// Retention-reason tags for a verify-worktree.sh failure, once triage (see runTriage
// below) has classified it. Read back by runWorker (to route the *next* round) and by
// runHousekeeping (to recognise a second consecutive not-fixable verdict without asking
// triage again). Centralised here, not restated at each comparison, so the tag and its
// separator cannot drift between the writer and the two readers.
const FIXABLE_TAG = "verification-failed:fixable";
const NOT_FIXABLE_TAG = "verification-failed:not-fixable";
// Written by runHousekeeping on an `AC: unmet` verdict, read back by runWorker the same
// way FIXABLE_TAG is: routes the retry to fixPrompt instead of a full workerPrompt restart.
// No triage step here — the reviewer's own detail is already the concrete, actionable
// thing a fix needs, unlike a verify failure's raw check output.
const CRITERIA_UNMET_TAG = "criteria-unmet";
const REASON_SEP = " — ";

function taggedReason(tag, summary) {
  return `${tag}${REASON_SEP}${summary}`;
}

/** The free text after a tag this module itself wrote — never applied to a reason whose tag is unknown. */
function stripReasonTag(reason, tag) {
  return reason.startsWith(tag + REASON_SEP) ? reason.slice(tag.length + REASON_SEP.length) : reason;
}

/** Phase 1 of an issue: worktree + worker dispatch. Runs concurrently across issues. */
export async function runWorker(ctx, issue) {
  const { sprint, effects, platform, options } = ctx;
  const branch = branchFor(sprint.featureSlug, issue.slug);
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
      worktree: null,
      dispatch: { code: 0, timedOut: false, dryRun: false, text: "", stderr: "" },
      report: {
        parsedFrom: "skipped-worker",
        status: "complete",
        checks: { test: "pass", lint: "pass", typecheck: "pass" },
        branch,
        workingDirectory: null,
        progress: `Round ${ctx.round}: merge/close retry — coder dispatch, verify, and review all skipped`,
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
  // dispatching the coder again would only relearn that. What this round *does* attempt is
  // the one thing a not-fixable verdict cannot rule out by itself — a transient failure
  // (a registry blip, a flaky network) that a plain, coder-free deps + verify re-run might
  // simply not hit a second time. If it fails again the same way, runHousekeeping below
  // recognises the repeat (via this worker's own `priorReason`) and escalates to blocked
  // without asking triage again.
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
  ctx.log(`[STEP] slug=${issue.slug} round=${ctx.round} step=worktree`);
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
    ctx.log(`[STEP] slug=${issue.slug} round=${ctx.round} step=sync-feature-branch`);
    const sync = mergeFeatureBranch(effects, { worktree, branch, featureBranch: sprint.featureBranch });
    if (sync.conflict) {
      ctx.log(`[SYNC-CONFLICT] slug=${issue.slug} branch=${branch} — ${sync.reason}`);
      // worktree (not null): the checkout was actually created above and merge --abort
      // already left it clean — finishBlocked's own removeWorktree() call needs the real
      // path to clean it up. Only the branch ref (and whatever WIP it holds) is retained.
      return {
        issue,
        branch,
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
    if (sync.merged) ctx.log(`slug=${issue.slug} round=${ctx.round} SYNC: merged ${sprint.featureBranch} into ${branch}`);
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
    ctx.log(`[STEP] slug=${issue.slug} round=${ctx.round} step=deps`);
    const deps = effects.bash("ensure-deps.sh", ["--dir", worktree, "--slug", issue.slug], {
      env: sprint.childEnv(),
    });
    ctx.log(`slug=${issue.slug} round=${ctx.round} ${depsLine(deps.stdout)}`);
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
      worktree,
      dispatch: { code: 0, timedOut: false, dryRun: false, text: "", stderr: "" },
      report: {
        parsedFrom: "skipped-worker",
        status: "complete",
        checks: { test: "pass", lint: "pass", typecheck: "pass" },
        branch,
        workingDirectory: worktree,
        progress: notFixableRetry
          ? `Round ${ctx.round}: not-fixable recheck — coder and triage both skipped; only deps + verify re-run`
          : `Round ${ctx.round}: review-only retry — coder dispatch skipped, branch content unchanged`,
        notes: notFixableRetry
          ? "not-fixable recheck: a prior triage pass judged this verification failure not fixable by recoding; re-checking once, cheaply, in case it was transient"
          : "review-only retry: the prior round's only failure was the review dispatch itself",
        criteria: [],
        raw: "",
      },
      skippedWorker: true,
      priorReason: retentionReason,
    };
  }

  const promptFile = join(dispatchDir, `${issue.slug}.prompt.md`);
  const outFile = join(dispatchDir, `${issue.slug}.report.md`);
  const sidecarFile = join(dispatchDir, `${issue.slug}.report.json`);

  writeFileSync(
    promptFile,
    fixableRetry || criteriaUnmetRetry
      ? fixPrompt({
          mainRoot: effects.mainRoot,
          worktree,
          issuePath: issue.path,
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
          issuePath: issue.path,
          slug: issue.slug,
          criteria: issue.criteria,
          resume: resumeNote({ priorBranch, hasProgress: issue.hasProgress, hasBlocked: issue.hasBlocked }),
          reportPath: sidecarFile,
        }),
  );

  ctx.log(`[STEP] slug=${issue.slug} round=${ctx.round} step=dispatch-coder`);
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
      scriptsDir: effects.scriptsDir,
      slug: issue.slug,
    },
    {
      timeoutMs: options.workerTimeoutMs,
      onTrace: (line) => ctx.log(`slug=${issue.slug} round=${ctx.round} ${line}`),
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
  return { issue, branch, worktree, dispatch: result, report, priorReason: retentionReason };
}

/**
 * Phase 2 of an issue: everything after the worker. Sequential by design — merges and
 * closes touch the main checkout, and two of them at once is a race.
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

  // --- dispatch health -------------------------------------------------------
  if (worker.dispatch.timedOut) {
    return finishBlocked(ctx, worker, outcome, `worker timed out after ${Math.round(options.workerTimeoutMs / 60000)}m`);
  }
  if (worker.dispatch.code !== 0 && worker.report.unparseable) {
    // A non-zero exit *and* nothing usable back: the worker died before reporting.
    // Its own report is preferred whenever there is one — a worker that exited badly
    // but reported `blocked` with a reason knows more than the exit code does.
    return finishBlocked(ctx, worker, outcome, "worker process failed — see traces/");
  }

  // --- schema pre-filter -----------------------------------------------------
  const pre = applySchemaPrefilter(worker.report);
  outcome.coverageGaps = pre.coverageGaps;
  if (pre.coverageGaps.length) sprint.coverageGap(issue.slug, pre.coverageGaps);

  if (pre.status === "blocked") {
    return finishBlocked(ctx, worker, outcome, pre.reason ?? worker.report.notes ?? "blocked");
  }
  if (pre.status !== "complete") {
    return finishPartial(ctx, worker, outcome, pre.reason ?? "partial");
  }

  // --- gate 1: independent verification in the worktree ----------------------
  ctx.log(`[STEP] slug=${issue.slug} round=${ctx.round} step=verify`);
  const verify = effects.bash("verify-worktree.sh", ["--dir", worker.worktree], {
    env: sprint.childEnv(),
  });
  ctx.log(`slug=${issue.slug} round=${ctx.round} ${verify.stdout.trim()}`);
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

  // Every gate after this reads the branch from the main checkout.
  removeWorktree(effects, { mainRoot: effects.mainRoot, path: worker.worktree });

  // --- gate 2: independent review (findings + acceptance-criteria verdict) ---
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
    return finishPartial(ctx, worker, outcome, "review-not-run");
  }
  outcome.findings = review.parsed.findings;

  if (review.parsed.verdict !== "all-met") {
    return finishPartial(ctx, worker, outcome, taggedReason(CRITERIA_UNMET_TAG, review.parsed.detail || "see review"));
  }

  // The receipt close-issue.sh demands, written only on an all-met verdict, and only
  // ever for this issue's own slug.
  const acReceipt = effects.bash("receipts.sh", ["write", "ac", "--branch", branch], {
    env: sprint.childEnv(),
  });
  if (acReceipt.code !== 0) {
    return finishPartial(ctx, worker, outcome, "ac-receipt-failed");
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
function mergeAndClose(ctx, worker, outcome) {
  const { sprint, effects } = ctx;
  const { issue, branch } = worker;

  effects.git(["checkout", sprint.featureBranch]);
  ctx.log(`[STEP] slug=${issue.slug} round=${ctx.round} step=merge`);
  const merge = effects.bash("merge-branches.sh", [sprint.featureBranch, branch], {
    env: sprint.childEnv(),
  });
  ctx.log(`slug=${issue.slug} round=${ctx.round} ${merge.stdout.trim()}`);
  if (merge.code !== 0) {
    return finishPartial(ctx, worker, outcome, "merge-failed");
  }

  ctx.log(`[STEP] slug=${issue.slug} round=${ctx.round} step=close`);
  const close = effects.bash("close-issue.sh", [issue.path], { env: sprint.childEnv() });
  ctx.log(`slug=${issue.slug} round=${ctx.round} ${close.stdout.trim()}`);
  if (close.code !== 0) {
    return finishPartial(ctx, worker, outcome, `close-refused — ${close.stderr.trim() || close.stdout.trim()}`);
  }

  sprint.complete(issue.slug, branch);
  outcome.status = "complete";
  return outcome;
}

/**
 * Verify-worktree.sh already failed — decide what that failure means before demoting.
 *
 * Two consecutive not-fixable verdicts for the same slug (recognised via `worker.priorReason`,
 * set by runWorker) skip straight to blocked: the round in between already re-ran deps +
 * verify with no coder and no triage involved, purely to rule out a transient failure, so a
 * second identical result is not "ask the model again" territory — it is the answer. Every
 * other case dispatches `runTriage`, an agent independent of the coder that wrote the branch
 * (the same reason review is independent of the coder, not a self-grade), and tags the
 * retention reason with its verdict so the *next* round's runWorker can route on it without
 * re-deriving anything.
 */
async function handleVerificationFailure(ctx, worker, outcome, verify) {
  const priorReason = worker.priorReason ?? null;
  if (priorReason && priorReason.startsWith(NOT_FIXABLE_TAG)) {
    const carried = stripReasonTag(priorReason, NOT_FIXABLE_TAG);
    return finishBlocked(
      ctx,
      worker,
      outcome,
      `environment — verification still fails the same way after a clean, coder-free retry: ${carried}`,
    );
  }

  const triage = await runTriage(ctx, worker, verify.stdout);
  if (!triage.completed) {
    // Triage itself is unusable (dispatch failure, timeout, unparseable answer) — fall back
    // to the plain reason rather than let a helper's own failure stall the branch. The next
    // round still gets a full coder redispatch, same as before this existed.
    return finishPartial(ctx, worker, outcome, "verification-failed");
  }

  const summary = `${triage.parsed.category || "unspecified"}: ${triage.parsed.detail || "no detail given"}`;
  const tag = triage.parsed.fixable ? FIXABLE_TAG : NOT_FIXABLE_TAG;
  return finishPartial(ctx, worker, outcome, taggedReason(tag, summary));
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
  const promptFile = join(sprint.dispatchDir, `${issue.slug}.triage-prompt.md`);
  const outFile = join(sprint.dispatchDir, `${issue.slug}.triage.md`);

  writeFileSync(
    promptFile,
    triagePrompt({
      branch,
      slug: issue.slug,
      issuePath: issue.path,
      featureBranch: sprint.featureBranch,
      checkOutput: verifyStdout,
    }),
  );

  ctx.log(`[STEP] slug=${issue.slug} round=${ctx.round} step=dispatch-triage`);
  const result = await dispatch(
    effects,
    platform,
    {
      agent: "crew-triage",
      cwd: effects.mainRoot,
      promptFile,
      outFile,
      // Same convention as the reviewer: triage judges the coder's work, so it is held to
      // the same model, never a cheaper one the sprint did not choose.
      model: options.model,
      mainRoot: effects.mainRoot,
      logFile: sprint.traceLog,
      scriptsDir: effects.scriptsDir,
      slug: issue.slug,
    },
    {
      timeoutMs: options.reviewTimeoutMs,
      onTrace: (line) => ctx.log(`slug=${issue.slug} round=${ctx.round} ${line}`),
    },
  );

  const parsed = parseTriageReport(result.text);
  const completed = !(result.timedOut || (result.code !== 0 && !parsed.ok) || !parsed.ok);
  return { completed, parsed };
}

async function runReview(ctx, worker, checks) {
  const { sprint, effects, platform, options } = ctx;
  const { issue, branch } = worker;
  const promptFile = join(sprint.dispatchDir, `${issue.slug}.review-prompt.md`);
  const outFile = join(sprint.dispatchDir, `${issue.slug}.review.md`);
  const reportFile = ctx.roundReviewFile();

  writeFileSync(
    promptFile,
    reviewPrompt({
      branch,
      slug: issue.slug,
      issuePath: issue.path,
      criteria: issue.criteria,
      featureBranch: sprint.featureBranch,
      checks,
    }),
  );

  ctx.log(`[STEP] slug=${issue.slug} round=${ctx.round} step=dispatch-review`);
  const result = await dispatch(
    effects,
    platform,
    {
      agent: "crew-code-reviewer",
      cwd: effects.mainRoot,
      promptFile,
      outFile,
      // The reviewer takes the coder's model: reviewing on a different one silently
      // changes the standard the branch is held to.
      model: options.model,
      mainRoot: effects.mainRoot,
      logFile: sprint.traceLog,
      scriptsDir: effects.scriptsDir,
      slug: issue.slug,
    },
    {
      timeoutMs: options.reviewTimeoutMs,
      onTrace: (line) => ctx.log(`slug=${issue.slug} round=${ctx.round} ${line}`),
    },
  );

  const parsed = parseReviewReport(result.text);
  if (result.timedOut || (result.code !== 0 && !parsed.ok) || !parsed.ok) {
    // parsed.detail is a generic string for an empty report ("empty review report") and
    // says nothing about *why* the dispatch produced nothing. result.stderr is the one
    // place that reason actually lives (a `die()` guard in dispatch-agent.sh, a spawn-level
    // error, ...) — surface a snippet of it here so a human reading the review report's
    // `not_run` stub does not have to reproduce the dispatch by hand to find out why.
    const stderrHint = (result.stderr ?? "").trim().slice(0, 300).replace(/\s+/g, " ");
    const noDetail = !parsed.detail || parsed.detail === "empty review report";
    return {
      completed: false,
      reportFile,
      reason: result.timedOut
        ? "review dispatch timed out"
        : noDetail
          ? `review dispatch exited ${result.code} with no usable report${stderrHint ? ` — ${stderrHint}` : ""}`
          : parsed.detail,
      parsed,
    };
  }

  mkdirSync(sprint.reviewDir, { recursive: true });
  const block = result.text.trim();
  const prefix = existsSync(reportFile) ? "\n\n" : "";
  writeFileSync(reportFile, `${existsSync(reportFile) ? readFileSync(reportFile, "utf8") : ""}${prefix}${block}\n`);
  return { completed: true, reportFile, parsed };
}

async function promote(ctx, worker, review, outcome) {
  const { sprint, effects } = ctx;
  const { issue, branch } = worker;
  const guard = effects.bash("promote-findings.sh", ["guard", "--issue", issue.path], {
    env: sprint.childEnv(),
  });
  const guardText = guard.stdout.trim();
  ctx.log(`slug=${issue.slug} round=${ctx.round} ${guardText}`);
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
  ctx.log(`slug=${issue.slug} round=${ctx.round} ${defer.stdout.trim()}`);
  outcome.promoted = promotable.length;
}

function finishPartial(ctx, worker, outcome, reason) {
  const { sprint, effects } = ctx;
  const { issue, branch } = worker;
  const progress = worker.report.progress || worker.report.notes || `Round ${ctx.round}: ${reason}`;
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
  if (!effects.dryRun && existsSync(issue.path)) {
    writeIssueSection(
      issue.path,
      "Progress",
      `Round ${ctx.round}: ${progress}${unmetBlock}\n\nDemotion reason: ${reason}`,
    );
  }
  removeWorktree(effects, { mainRoot: effects.mainRoot, path: worker.worktree });
  sprint.retain(issue.slug, branch, reason);
  outcome.status = "partial";
  outcome.reason = reason;
  return outcome;
}

function finishBlocked(ctx, worker, outcome, reason) {
  const { sprint, effects } = ctx;
  const { issue, branch } = worker;
  if (!effects.dryRun && existsSync(issue.path)) {
    writeIssueSection(issue.path, "Blocked", `Round ${ctx.round}: ${reason}`, { append: true });
  }
  removeWorktree(effects, { mainRoot: effects.mainRoot, path: worker.worktree });
  sprint.blocked(issue.slug, branch, reason);
  outcome.status = "blocked";
  outcome.reason = reason;
  return outcome;
}
