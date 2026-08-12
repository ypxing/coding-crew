/**
 * pipeline.mjs — the per-branch gate chain, in one place, in one order:
 *
 *     dispatch → prefilter → verify → review → AC receipt → promote → merge → close
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
  findingsAtOrAbove,
  parseReviewReport,
  parseVerifyChecks,
  parseWorkerReport,
} from "./report.mjs";
import { branchFor, writeIssueSection } from "./tracker.mjs";
import { criteriaFile, resumeNote, reviewPrompt, workerPrompt } from "./prompts.mjs";
import { applyWorktreeInclude, ensureWorktree, removeWorktree } from "./worktree.mjs";
import { dispatch } from "./dispatch.mjs";

/** Phase 1 of an issue: worktree + worker dispatch. Runs concurrently across issues. */
export async function runWorker(ctx, issue) {
  const { sprint, effects, platform, options } = ctx;
  const branch = branchFor(sprint.featureSlug, issue.slug);
  const dispatchDir = sprint.dispatchDir;
  mkdirSync(dispatchDir, { recursive: true });

  const { path: worktree } = ensureWorktree(effects, {
    mainRoot: effects.mainRoot,
    branch,
    base: "HEAD",
  });
  applyWorktreeInclude(effects.mainRoot, worktree);

  const promptFile = join(dispatchDir, `${issue.slug}.prompt.md`);
  const outFile = join(dispatchDir, `${issue.slug}.report.md`);
  const sidecarFile = join(dispatchDir, `${issue.slug}.report.json`);
  const priorBranch = issue.hasProgress ? sprint.resumeBranch(issue.slug) : null;

  writeFileSync(
    promptFile,
    workerPrompt({
      mainRoot: effects.mainRoot,
      worktree,
      issuePath: issue.path,
      slug: issue.slug,
      criteria: issue.criteria,
      resume: resumeNote({ priorBranch, hasProgress: issue.hasProgress, hasBlocked: issue.hasBlocked }),
      reportPath: sidecarFile,
    }),
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
      scriptsDir: effects.scriptsDir,
    },
    { timeoutMs: options.workerTimeoutMs },
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
  return { issue, branch, worktree, dispatch: result, report };
}

/**
 * Phase 2 of an issue: everything after the worker. Sequential by design — merges and
 * closes touch the main checkout, and two of them at once is a race.
 */
export async function runHousekeeping(ctx, worker) {
  const { sprint, effects, options } = ctx;
  const { issue, branch } = worker;
  const outcome = { slug: issue.slug, branch, status: null, reason: null, coverageGaps: [], findings: [], reviewReport: null };

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
  const verify = effects.bash("verify-worktree.sh", ["--dir", worker.worktree], {
    env: sprint.childEnv(),
  });
  ctx.log(verify.stdout.trim());
  if (verify.code !== 0) {
    return finishPartial(ctx, worker, outcome, "verification-failed");
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
    return finishPartial(ctx, worker, outcome, `criteria-unmet — ${review.parsed.detail || "see review"}`);
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

  // --- merge, then close only on the merge's success ------------------------
  effects.git(["checkout", sprint.featureBranch]);
  const merge = effects.bash("merge-branches.sh", [sprint.featureBranch, branch], {
    env: sprint.childEnv(),
  });
  ctx.log(merge.stdout.trim());
  if (merge.code !== 0) {
    outcome.status = "partial";
    outcome.reason = "merge-failed";
    sprint.retain(issue.slug, branch, "merge-failed");
    return outcome;
  }

  const close = effects.bash("close-issue.sh", [issue.path], { env: sprint.childEnv() });
  ctx.log(close.stdout.trim());
  if (close.code !== 0) {
    outcome.status = "partial";
    outcome.reason = `close-refused — ${close.stderr.trim() || close.stdout.trim()}`;
    sprint.retain(issue.slug, branch, "close-refused");
    return outcome;
  }

  sprint.complete(issue.slug, branch);
  outcome.status = "complete";
  return outcome;
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
    },
    { timeoutMs: options.reviewTimeoutMs },
  );

  const parsed = parseReviewReport(result.text);
  if (result.timedOut || (result.code !== 0 && !parsed.ok) || !parsed.ok) {
    return {
      completed: false,
      reportFile,
      reason: result.timedOut
        ? "review dispatch timed out"
        : parsed.detail || `review dispatch exited ${result.code} with no usable report`,
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
  ctx.log(guardText);
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
  ctx.log(defer.stdout.trim());
  outcome.promoted = promotable.length;
}

function finishPartial(ctx, worker, outcome, reason) {
  const { sprint, effects } = ctx;
  const { issue, branch } = worker;
  const progress = worker.report.progress || worker.report.notes || `Round ${ctx.round}: ${reason}`;
  if (!effects.dryRun && existsSync(issue.path)) {
    writeIssueSection(issue.path, "Progress", `Round ${ctx.round}: ${progress}\n\nDemotion reason: ${reason}`);
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
