/**
 * pipeline.mjs — the per-branch gate chain, in one place, in one order:
 *
 *     worktree → include → deps → dispatch → prefilter → verify → review → AC receipt
 *     → merge → close
 *
 * The order is a function body, so no model can reorder or skip it, and each gate's
 * refusal is a return value rather than a paragraph asking to be obeyed.
 *
 * Every failure demotes to `partial` and retains the branch. Nothing merges on an
 * absent check.
 *
 * The order lives here (runWorker, runHousekeeping); each stage's body lives in
 * pipeline/: verify.mjs (triage), review.mjs (review), merge.mjs (merge +
 * close), finish.mjs (partial/blocked endings), shared.mjs (reason tags, helpers).
 */

import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { applySchemaPrefilter, depsLine, parseWorkerReport, readVerifyRecord } from "./report.mjs";
import { getTracker } from "./tracker.mjs";
import { issueFingerprint } from "./trackers/body-format.mjs";
import { conflictPrompt, fixPrompt, resumeNote, workerPrompt } from "./prompts.mjs";
import { applyWorktreeInclude, ensureWorktree, mergeFeatureBranch, removeWorktree } from "./worktree.mjs";
import { dispatch } from "./dispatch.mjs";
import { flagFullSuiteRuns } from "./pipeline/deviation.mjs";
import { finishBlocked, finishRetryOrBlock } from "./pipeline/finish.mjs";
import { mergeAndClose } from "./pipeline/merge.mjs";
import { runReview } from "./pipeline/review.mjs";
import {
  AC_RECEIPT_FAILED_TAG,
  CRITERIA_ENVIRONMENT_TAG,
  CRITERIA_UNMET_TAG,
  dispatchIssueDir,
  logVerifyOutput,
  dispatchStem,
  FIXABLE_TAG,
  gatesAtTip,
  MAIN_TREE_DIRTY_TAG,
  MERGE_CONFLICT_TAG,
  issueDescriptor,
  limitExceeded,
  NOT_FIXABLE_TAG,
  REVIEW_NOT_RUN_TAG,
  notifyMilestone,
  readSidecar,
  roleBinding,
  stripReasonTag,
  taggedReason,
  unblockedReason,
  VERIFY_INCONCLUSIVE_TAG,
  VERIFY_INTERRUPTED_TAG,
} from "./pipeline/shared.mjs";
import { handleVerificationFailure, hasVerifyFailure } from "./pipeline/verify.mjs";

/** Whether `branch` has commits the feature branch lacks: a dead dispatch with commits is worth resuming. */
function branchHasCommits(effects, featureBranch, branch) {
  const r = effects.gitRead(["rev-list", "--count", `${featureBranch}..${branch}`]);
  return r.code === 0 && parseInt(r.stdout.trim(), 10) > 0;
}

/**
 * The largest coder context a fix round resumes rather than starting fresh. Past this, every
 * resumed turn re-sends more history than a fresh, narrow fix dispatch would ever build up.
 */
export const RESUME_MAX_CONTEXT_TOKENS = 100_000;

/**
 * The coder session a fix round may continue, or why not (`{ sessionId }` | `{ reason }`).
 * Only the session that left the branch exactly where it is: once the tip has moved (a sync
 * merged the feature branch in, another session committed), its picture of the code is stale.
 */
export function resumableSession(prior, tip) {
  if (!prior?.session_id) return { reason: "no earlier coder session recorded" };
  if (!prior.head || prior.head !== tip) return { reason: "the branch moved since that session" };
  if ((prior.context_tokens ?? 0) > RESUME_MAX_CONTEXT_TOKENS) {
    return { reason: `its context is ${Math.round(prior.context_tokens / 1000)}k tokens, over ${RESUME_MAX_CONTEXT_TOKENS / 1000}k` };
  }
  return { sessionId: prior.session_id };
}

/**
 * Where a retry re-enters the pipeline, by the reason the prior attempt retained its branch
 * (finishRetryOrBlock writes it; state.sh records it). The one table of resume targets:
 *
 *   merge   `merge-failed`, `close-refused …` — verify, review and the AC receipt already
 *           passed; only merge/close runs again. Safe because merge-branches.sh and
 *           close-issue.sh re-check the SHA-bound receipts themselves on every run.
 *           `main-tree-dirty` — blocked at once (no retry could clean the main checkout);
 *           the route once a human has committed or stashed the files and re-run.
 *   verify  `review-not-run …` — the branch is done; only the review dispatch failed.
 *           `criteria-unmet:environment …` — the reviewer blamed the environment, which
 *           blocked at once; the route once a human has fixed it and re-run. Verify and
 *           review re-run on the unchanged branch, with no coder.
 *           `verification-failed:not-fixable` — triage ruled out recoding, so skip the
 *           coder and re-run deps + verify once, in case the failure was transient. Also
 *           the route once a human reruns after the retry cap blocked it: no coder can
 *           fix what triage already ruled environmental.
 *           `ac-receipt-failed …` — review was all-met; only the receipt write failed. The
 *           receipt is rewritten only after a fresh all-met review, never on this note's
 *           word. Also the route once a human reruns after the retry cap blocked it.
 *   fix     `verification-failed:fixable`, `criteria-unmet` — the coder runs on fixPrompt,
 *           told exactly what failed, instead of re-reading the whole issue. Also the
 *           route once a human reruns after the retry cap blocked it.
 *           `merge-conflict` — the feature branch moved on under this one. The sync step
 *           auto-resolves what it can (registry versions, CHANGELOG appends); any other
 *           conflict is left in the worktree for its own conflict-only coder dispatch, whose
 *           success is read from git. Verify and review then re-run on the new commit. If
 *           the sync merges cleanly after all, no coder runs and only verify + review re-run.
 *           Also the route once a human reruns after the retry cap blocked it: a restart
 *           would only hit the same conflict at the sync step.
 *   An edited issue overrides `fix` (`conflict` included) and `verify`: when the issue's
 *   fingerprint (What to build + Acceptance criteria, checkboxes normalised; crew-afk's own
 *   writes are outside it) differs from the one recorded when the branch was retained, a human
 *   changed what the coder works from, so the route is `restart` — workerPrompt on the
 *   retained branch, commits kept — never fixPrompt's "do not re-read the issue". A kept sync
 *   conflict still gets its conflict-only dispatch first; the restart replaces the verify a
 *   conflict retry would otherwise end in. A record with no fingerprint, and the `merge`
 *   route, ignore it.
 *
 *   restart anything else, including no reason — the coder runs on workerPrompt. An issue
 *           blocked as `requires-failed` retains no branch, so it has no reason here and
 *           restarts once check-requires.sh passes it.
 *
 * Whatever the route, a retry's sync with the feature branch has three steps: auto-resolve,
 * then a conflict-only coder dispatch for any other conflict, then the original route with
 * a prompt that has no conflict text (a verify route stays a verify route).
 *
 * The retry cap (MAX_ATTEMPTS_PER_ISSUE, pipeline/finish.mjs) bounds every route alike;
 * a coder that timed out after committing gets a free retry, up to MAX_DISPATCHES_PER_ISSUE.
 */
export function resumeRoute(reason, { edited = false } = {}) {
  const route = baseRoute(reason);
  if (edited && (route.route === "verify" || route.route === "fix")) {
    return { route: "restart", edited: true };
  }
  return route;
}

function baseRoute(reason) {
  if (reason == null) return { route: "restart" };
  const unblocked = unblockedReason(reason);
  if (unblocked.startsWith(AC_RECEIPT_FAILED_TAG)) return { route: "verify", label: "ac-receipt-retry" };
  if (unblocked.startsWith(MAIN_TREE_DIRTY_TAG)) return { route: "merge" };
  if (unblocked.startsWith(MERGE_CONFLICT_TAG)) {
    return { route: "fix", kind: "conflict", context: stripReasonTag(unblocked, MERGE_CONFLICT_TAG) };
  }
  if (reason === "merge-failed" || reason.startsWith("close-refused")) return { route: "merge" };
  if (reason.startsWith(REVIEW_NOT_RUN_TAG)) return { route: "verify", label: "review-not-run" };
  if (unblocked.startsWith(CRITERIA_ENVIRONMENT_TAG)) return { route: "verify", label: "environment-recheck" };
  if (unblocked.startsWith(VERIFY_INTERRUPTED_TAG)) return { route: "verify", label: "verify-interrupted" };
  if (unblocked.startsWith(VERIFY_INCONCLUSIVE_TAG)) return { route: "verify", label: "verify-inconclusive" };
  if (unblocked.startsWith(NOT_FIXABLE_TAG)) return { route: "verify", label: "not-fixable-recheck" };
  if (unblocked.startsWith(FIXABLE_TAG)) return { route: "fix", kind: "verify", context: stripReasonTag(unblocked, FIXABLE_TAG) };
  if (unblocked.startsWith(CRITERIA_UNMET_TAG)) {
    return { route: "fix", kind: "review", context: stripReasonTag(unblocked, CRITERIA_UNMET_TAG) };
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
  "verify-interrupted": {
    what: "re-running verify only, no triage and no coder dispatch: the prior verify was killed before it gave a verdict",
    progress: "verify-interrupted retry — coder dispatch skipped; verify re-run",
    notes: "verify-interrupted retry: the prior round's verify was ended by a signal, so there is no failure to fix",
  },
  "verify-inconclusive": {
    what: "re-running verify only, no triage and no coder dispatch: the prior verify output named no failing check",
    progress: "verify-inconclusive retry — coder dispatch skipped; verify re-run",
    notes: "verify-inconclusive retry: the prior round's verify output named no failing check, so there is no failure to fix",
  },
  "not-fixable-recheck": {
    what: "rechecking deps + verify only, no triage and no coder dispatch, in case the failure was transient",
    progress: "not-fixable recheck — coder and triage both skipped; only deps + verify re-run",
    notes:
      "not-fixable recheck: a prior triage pass judged this verification failure not fixable by recoding; re-checking once, cheaply, in case it was transient",
  },
  "environment-recheck": {
    what: "re-running verify + review on the unchanged branch, no coder dispatch, now the environment may be fixed",
    progress: "environment recheck — coder dispatch skipped; verify + review re-run",
    notes: "environment recheck: the prior review found a criterion's precondition unmet by the environment, not the code",
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

/** The worker a merge-only retry hands runHousekeeping: no dispatch, no verify, no review. */
function mergeOnlyWorker(issue, branch, attempt, notes) {
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
      notes,
      criteria: [],
      raw: "",
    },
    resumeAtMerge: true,
  };
}

/**
 * Phase 1 of an issue: worktree + worker dispatch. Runs concurrently across issues.
 * `attempt` is this issue's own 1-based attempt number (sprint.attemptCount in loop.mjs).
 */
export async function runWorker(ctx, issue, attempt) {
  const { sprint, effects, options } = ctx;
  const tracker = await getTracker(effects.mainRoot);
  // github.mjs has no branchFor: the issue number is already the unique part.
  const branch = tracker.branchFor
    ? tracker.branchFor(sprint.featureSlug, issue.slug)
    : `crew/${sprint.featureSlug}/${issue.number}-${issue.slug}`;
  const dispatchDir = sprint.dispatchDir;
  mkdirSync(dispatchDir, { recursive: true });

  // State says whether a prior attempt retained a branch (and the ref still exists). Not
  // gated on the issue's Progress/Blocked sections: under tracker: github those live in
  // comments the issue body does not carry, so the flags would hide a retained branch.
  const priorBranch = sprint.resumeBranch(issue.slug);
  const retention = priorBranch != null ? sprint.retentionRecord(issue.slug) : { reason: null, fingerprint: null };
  const retentionReason = retention.reason;
  const edited = retention.fingerprint != null && issue.text != null && issueFingerprint(issue.text) !== retention.fingerprint;
  let resume = resumeRoute(retentionReason, { edited });
  if (resume.edited) {
    ctx.log(`[RESUME] slug=${issue.slug} reason=${retentionReason} — issue edited since the last attempt — restarting on the retained branch`);
  }

  if (resume.route === "merge") {
    ctx.log(
      `[SKIP-TO-MERGE] slug=${issue.slug} reason=${retentionReason} branch=${branch} — retrying merge/close only, no coder dispatch, no verify, no review`,
    );
    return mergeOnlyWorker(issue, branch, attempt, "merge/close retry: the prior round's only failure was the merge or close step itself");
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
  // here rather than as a conflict at the merge gate. A sync is three steps, whatever this
  // retry was for (a sibling can merge while any retry waits): mergeFeatureBranch commits
  // what resolve-merge-conflicts.sh resolves (registry versions, CHANGELOG appends); any
  // other conflict is left in the worktree for its own conflict-only coder dispatch, checked
  // mechanically (conflictResolved); only then does the original route run, with a prompt
  // that has no conflict text. The conflict dispatch spends no attempt and no dispatch.
  let synced = false;
  let pendingConflict = null;
  if (wt.reusedBranch) {
    ctx.log(`[STEP] slug=${dispatchStem(issue)} round=${attempt} step=sync-feature-branch`);
    const conflictRetry = resume.kind === "conflict";
    const sync = mergeFeatureBranch(effects, { worktree, branch, featureBranch: sprint.featureBranch, keepConflict: true });
    for (const line of sync.decisions ?? []) ctx.log(`[SYNC-AUTO-RESOLVED] slug=${issue.slug} branch=${branch} — ${line}`);
    if (sync.kept) {
      ctx.log(`[SYNC-CONFLICT-KEPT] slug=${issue.slug} branch=${branch} files=${sync.files.join(",")} — left for a conflict-only coder dispatch`);
      pendingConflict = {
        files: sync.files,
        context: resume.kind === "conflict" && resume.context ? resume.context : `'${sprint.featureBranch}' moved on under this branch`,
      };
      // A conflict retry's only job was the merge: once resolved, verify and review re-run.
      if (conflictRetry) resume = { route: "verify", label: "conflict-merged-clean" };
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
    synced = Boolean(sync.merged || sync.kept);
  }

  // A coder-free retry re-runs only the gates this commit has not already passed: their
  // receipts are bound to the commit, so a gate re-run on it could only repeat its answer.
  let skipVerify = false;
  if (resume.route === "verify" && !pendingConflict) {
    const gates = gatesAtTip(ctx, branch);
    if (gates.reviewed) {
      ctx.log(
        `[SKIP-TO-MERGE] slug=${issue.slug} reason=${resume.label} branch=${branch} — verify and review already passed at this commit; retrying merge/close only`,
      );
      removeWorktree(effects, { mainRoot: effects.mainRoot, path: worktree });
      return mergeOnlyWorker(issue, branch, attempt, `${resume.label}: verify and review receipts already match this commit`);
    }
    skipVerify = gates.verifiedThisRun;
  }

  applyWorktreeInclude(effects.mainRoot, worktree);

  // Deps sit after the include (an inherited node_modules costs nothing) and before both
  // consumers: the worker, and verify-worktree.sh, a gate that cannot invoke dep-install.
  // The skipped-worker path needs them too — its worktree is recreated bare. A failed
  // install stops the issue here: nothing after it — the coder, the verify gate — can do
  // useful work in an unprovisioned worktree, so letting them run only rediscovers it later.
  // Review alone needs no deps: skipped with the verify it would have fed.
  // Its outcome goes into the coder's prompt, so the coder does not re-run the same install.
  let depsOutcome = null;
  if (options.installDeps !== false && !skipVerify) {
    ctx.log(`[STEP] slug=${dispatchStem(issue)} round=${attempt} step=deps`);
    const deps = await effects.bashAsync("ensure-deps.sh", ["--dir", worktree, "--slug", issue.slug, "--stem", dispatchStem(issue)], {
      env: sprint.childEnv(),
    });
    const line = depsLine(deps.stdout);
    ctx.log(`slug=${issue.slug} round=${attempt} ${line}`, "debug"); // ensure-deps.sh traced [DEPS]
    depsOutcome = line.replace(/^DEPS:\s*/, "") || null;
    if (/^DEPS: failed\b/.test(line)) {
      ctx.log(`[DEPS-FAILED] slug=${issue.slug} branch=${branch} — ${line}`);
      return {
        issue,
        branch,
        attempt,
        worktree,
        dispatch: { code: 0, timedOut: false, dryRun: false, text: "", stderr: "" },
        report: {
          parsedFrom: "deps-failed",
          status: "blocked",
          checks: { test: "not_run", lint: "not_run", typecheck: "not_run" },
          branch,
          workingDirectory: worktree,
          progress: null,
          notes: `dependency install failed — ${line.replace(/^DEPS:\s*/, "")}`,
          criteria: [],
          raw: "",
        },
      };
    }
  }

  const issueDir = dispatchIssueDir(dispatchDir, issue);
  mkdirSync(issueDir, { recursive: true });
  // A red baseline (loop.mjs) stopped this attempt before any coder (the conflict one included) started — during deps, whose
  // kill leaves no DEPS line to stop on. runHousekeeping keeps the branch for the next run; a coder-free retry
  // (skippedWorker) keeps the reason that routed it, so the next run is not handed to a coder.
  const baselineRedWorker = () => ({
    issue,
    branch,
    attempt,
    worktree,
    skippedWorker: resume.route === "verify",
    dispatch: { code: 0, timedOut: false, dryRun: false, text: "", stderr: "" },
    report: { parsedFrom: "baseline-red", status: "blocked", checks: {}, branch, workingDirectory: worktree, progress: null, notes: "baseline failed", criteria: [], raw: "" },
  });
  if (ctx.baselineRed) return baselineRedWorker();

  if (pendingConflict) {
    const resolved = await dispatchConflict(ctx, {
      issue,
      worktree,
      branch,
      attempt,
      issueDir,
      deps: depsOutcome,
      files: pendingConflict.files,
      context: pendingConflict.context,
    });
    // The baseline can go red while the conflict coder runs (its kill is why it left the merge open).
    if (ctx.baselineRed) return baselineRedWorker();
    if (!resolved.ok) {
      ctx.log(`[CONFLICT-UNRESOLVED] slug=${issue.slug} round=${attempt} branch=${branch} — ${resolved.why}; the original route did not run`, "warn");
      return {
        issue,
        branch,
        attempt,
        worktree,
        dispatch: resolved.dispatch,
        report: {
          parsedFrom: "conflict-unresolved",
          status: "partial",
          checks: { test: "not_run", lint: "not_run", typecheck: "not_run" },
          branch,
          workingDirectory: worktree,
          progress: null,
          notes: resolved.why,
          criteria: [],
          raw: "",
        },
        conflictUnresolved: resolved.why,
        // The edited issue was never worked from this attempt: keep the record's fingerprint so the
        // next retry still sees the edit and restarts once the conflict is resolved.
        keepFingerprint: retention.fingerprint,
      };
    }
    synced = true;
  }

  if (resume.route === "verify") {
    const skip = SKIPPED_WORKER[resume.label];
    const verifyNote = skipVerify ? " (verify already passed at this commit — review only)" : "";
    ctx.log(`[SKIP-WORKER] slug=${issue.slug} reason=${resume.label} branch=${branch} — ${skip.what}${verifyNote}`);
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
      skipVerify,
    };
  }

  const promptFile = join(issueDir, "prompt.md");
  const outFile = join(issueDir, "report.md");
  const sidecarFile = join(issueDir, "report.json");

  // A stale sidecar at this fixed path must not be read back as this round's verdict.
  rmSync(sidecarFile, { force: true });

  writeFileSync(
    promptFile,
    resume.route === "fix"
      ? fixPrompt({
          mainRoot: effects.mainRoot,
          deps: depsOutcome,
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
          deps: depsOutcome,
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

  // A review fix starts from the very commit this run's previous attempt judged unmet —
  // unless the sync just moved it. runHousekeeping compares the coder's tip with it: no new
  // commit, same verdict. Not across runs: the environment that review saw may have changed.
  const reviewedTip =
    attempt > 1 && resume.route === "fix" && resume.kind === "review" && !synced
      ? effects.gitRead(["rev-parse", `${branch}^{commit}`]).stdout.trim() || null
      : null;

  // The same for a verify fix: the tip the last verify failed at. A fix round that commits
  // nothing leaves that commit, so re-running verify (and triage) could only repeat the failure.
  const verifyFailedTip =
    attempt > 1 && resume.route === "fix" && resume.kind === "verify" && !synced
      ? effects.gitRead(["rev-parse", `${branch}^{commit}`]).stdout.trim() || null
      : null;

  const coder = roleBinding(ctx, "coder");
  // Opt-in (afk.resumeCoderSession): a fix round continues the session that wrote the branch
  // instead of re-exploring it, when that session is small and the branch has not moved.
  // Not after a conflict dispatch: it is recorded under CONFLICT_ROLE, so its session is never
  // picked, and the merge it committed moved the branch on under the coder's last session.
  let resumeSessionId = null;
  if (mayResumeCoderSession({ enabled: options.resumeCoderSession, route: resume.route, runtime: coder.runtime, conflictDispatched: Boolean(pendingConflict) })) {
    const tip = effects.gitRead(["rev-parse", `${branch}^{commit}`]).stdout.trim();
    const pick = resumableSession(sprint.lastDispatch(issue.slug, "coder"), tip);
    if (pick.sessionId) {
      resumeSessionId = pick.sessionId;
      ctx.log(`[RESUME-SESSION] slug=${issue.slug} round=${attempt} session=${pick.sessionId}`);
    } else {
      ctx.log(`[FRESH-SESSION] slug=${issue.slug} round=${attempt} — ${pick.reason}`);
    }
  }
  // The tip this dispatch starts from: a timed-out coder that moved it gets a free retry.
  const startTip = effects.gitRead(["rev-parse", `${branch}^{commit}`]).stdout.trim() || null;
  ctx.log(
    `[STEP] slug=${dispatchStem(issue)} round=${attempt} step=dispatch-coder model=${coder.model ?? "inherit"} runtime=${coder.runtime}`,
  );
  const result = await dispatch(
    effects,
    coder.runtime,
    {
      agent: "crew-coder",
      cwd: worktree,
      promptFile,
      outFile,
      model: coder.model,
      mainRoot: effects.mainRoot,
      baseRef: sprint.featureBranch,
      logFile: sprint.traceLog,
      featureSlug: sprint.featureSlug,
      slug: dispatchStem(issue),
      issueNumber: issue.number,
      round: attempt,
      reportPath: sidecarFile,
      resumeSessionId,
      maxBudgetUsd: coder.maxBudgetUsd,
    },
    {
      timeoutMs: options.timeoutMs.coder,
      onTrace: (line) => ctx.heartbeat(`slug=${dispatchStem(issue)} round=${attempt} ${line}`),
    },
  );

  const head = effects.gitRead(["rev-parse", `${branch}^{commit}`]).stdout.trim();
  sprint.recordDispatchCost(result, { slug: issue.slug, role: "coder", attempt, head });

  flagFullSuiteRuns(ctx, { slug: dispatchStem(issue), attempt, outFile });

  const sidecar = readSidecar(sidecarFile);
  // A worker that ran to completion (no timeout, non-empty output) but left no sidecar is
  // otherwise silent until the pipeline reports "blocked" several steps later — by then
  // result.stderr, the only clue why the Write never happened, is gone. Surface it now.
  if (!sidecar && !result.timedOut && result.text.trim()) {
    const stderrSnippet = (result.stderr ?? "").trim().slice(0, 500).replace(/\s+/g, " ");
    ctx.log(
      `[SIDECAR-MISSING] slug=${dispatchStem(issue)} round=${attempt} reportPath=${sidecarFile} outBytes=${result.text.length} code=${result.code} stderr=${JSON.stringify(stderrSnippet || "(none)")}`,
    );
  }

  const report = parseWorkerReport(result.text, sidecar);
  return { issue, branch, attempt, worktree, dispatch: result, report, head, startTip, reviewedTip, verifyFailedTip, priorVerdict: reviewedTip || verifyFailedTip ? resume.context : null };
}

/** The ledger role of a conflict-only dispatch, apart from "coder" so a fix round never resumes its session. */
export const CONFLICT_ROLE = "conflict";

/**
 * Whether a fix round may continue the coder's recorded session. Never after a conflict
 * dispatch ran this attempt: that dispatch is recorded under CONFLICT_ROLE (its session saw
 * only the conflict), and the merge it committed moved the branch on under the coder's.
 */
export function mayResumeCoderSession({ enabled, route, runtime, conflictDispatched }) {
  return Boolean(enabled) && route === "fix" && runtime === "claude" && !conflictDispatched;
}

/**
 * The conflict-only coder dispatch for a sync merge left conflicted in the worktree: one per
 * attempt, outside the retry cap and MAX_DISPATCHES_PER_ISSUE (it is not a worker round). Its
 * success is read from git, never from its report.
 */
async function dispatchConflict(ctx, { issue, worktree, branch, attempt, issueDir, deps, files, context }) {
  const { sprint, effects, options } = ctx;
  const promptFile = join(issueDir, "conflict-prompt.md");
  const outFile = join(issueDir, "conflict-report.md");
  const sidecarFile = join(issueDir, "conflict-report.json");
  rmSync(sidecarFile, { force: true });
  writeFileSync(
    promptFile,
    conflictPrompt({
      mainRoot: effects.mainRoot,
      deps,
      worktree,
      issuePath: issueDescriptor(issue),
      slug: issue.slug,
      branch,
      context,
      reportPath: sidecarFile,
      featureBranch: sprint.featureBranch,
      conflictFiles: files,
    }),
  );
  const coder = roleBinding(ctx, "coder");
  ctx.log(`[STEP] slug=${dispatchStem(issue)} round=${attempt} step=dispatch-conflict model=${coder.model ?? "inherit"} runtime=${coder.runtime}`);
  const result = await dispatch(
    effects,
    coder.runtime,
    {
      agent: "crew-coder",
      cwd: worktree,
      promptFile,
      outFile,
      model: coder.model,
      mainRoot: effects.mainRoot,
      baseRef: sprint.featureBranch,
      logFile: sprint.traceLog,
      featureSlug: sprint.featureSlug,
      slug: dispatchStem(issue),
      issueNumber: issue.number,
      round: attempt,
      reportPath: sidecarFile,
      maxBudgetUsd: coder.maxBudgetUsd,
    },
    {
      timeoutMs: options.timeoutMs.coder,
      onTrace: (line) => ctx.heartbeat(`slug=${dispatchStem(issue)} round=${attempt} conflict ${line}`),
    },
  );
  const head = effects.gitRead(["rev-parse", `${branch}^{commit}`]).stdout.trim();
  // Its own role: its session saw only the conflict, so lastDispatch(slug, "coder") must never return it.
  sprint.recordDispatchCost(result, { slug: issue.slug, role: CONFLICT_ROLE, attempt, head });
  return { ...conflictResolved(effects, worktree, sprint.featureBranch), dispatch: result };
}

/** Is the merge really concluded: no MERGE_HEAD, nothing unmerged, the feature branch inside HEAD. */
function conflictResolved(effects, worktree, featureBranch) {
  const git = (args) => effects.gitRead(args, { cwd: worktree });
  if (git(["rev-parse", "-q", "--verify", "MERGE_HEAD"]).code === 0) return { ok: false, why: "the merge is still in progress (MERGE_HEAD)" };
  if (git(["diff", "--name-only", "--diff-filter=U"]).stdout.trim()) return { ok: false, why: "unmerged paths remain" };
  if (git(["merge-base", "--is-ancestor", featureBranch, "HEAD"]).code !== 0) return { ok: false, why: `HEAD does not contain '${featureBranch}'` };
  return { ok: true };
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

  // A red baseline stopped this attempt (loop.mjs): the branch is kept as it stands and the
  // attempt is free. A coder-free retry keeps the reason that routed it; an attempt whose coder
  // was stopped (or never started) is a coder's job again next run, never a verify-only one.
  if (ctx.baselineRed) {
    ctx.log(`[BASELINE-RED] slug=${issue.slug} round=${worker.attempt} — the baseline failed; branch kept, not verified`, "warn");
    const reason = worker.skippedWorker
      ? (sprint.retentionReason(issue.slug) ?? taggedReason(VERIFY_INTERRUPTED_TAG, "baseline failed"))
      : "baseline failed — the coder was stopped before its branch was verified";
    return finishRetryOrBlock(ctx, worker, outcome, reason, { free: true });
  }

  // The merge route (see resumeRoute): straight to merge/close, which re-checks both receipts.
  if (worker.resumeAtMerge) return mergeAndClose(ctx, worker, outcome);

  // The conflict dispatch left the merge unresolved: retained as a conflict, whatever it reported.
  if (worker.conflictUnresolved) {
    return finishRetryOrBlock(ctx, worker, outcome, taggedReason(MERGE_CONFLICT_TAG, `the conflict dispatch left the sync merge unresolved: ${worker.conflictUnresolved}`));
  }

  // --- dispatch health -------------------------------------------------------
  // The coder's dollar cap ends the attempt for a human, whatever it committed: a retry would
  // spend the same cap again.
  const capped = limitExceeded(worker.dispatch, "coder", roleBinding(ctx, "coder"));
  if (capped) return finishBlocked(ctx, worker, outcome, capped);
  // A dead dispatch (timeout, crash) with commits on the branch is resumed, not discarded;
  // with none, there is nothing to resume and it blocks. A timeout that committed this
  // attempt was still making progress, so its retry is free.
  if (worker.dispatch.timedOut) {
    const reason = `worker timed out after ${Math.round(options.timeoutMs.coder / 60000)}m`;
    const free = !!worker.head && worker.head !== worker.startTip;
    if (branchHasCommits(effects, sprint.featureBranch, branch)) return finishRetryOrBlock(ctx, worker, outcome, reason, { free });
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
  // The coder's own `not_run` is a claim, not a fact: coverage gaps are what verify reports.

  // A coder that stopped short but committed has made a claim about its branch, not a verdict:
  // `partial`, or `blocked` on the environment. The gates decide — verify, then on a failure
  // triage, which is handed the coder's own evidence to check against the diff (a code bug
  // misread as the environment is caught there). Restarting the coder instead re-derived the
  // same blocker from scratch. A plain `blocked`, or one with nothing committed, stays a stop.
  const claim =
    (pre.status === "partial" || (pre.status === "blocked" && worker.report.cause === "environment")) &&
    branchHasCommits(effects, sprint.featureBranch, branch);
  if (pre.status === "blocked" && !claim) {
    return finishBlocked(ctx, worker, outcome, pre.reason ?? worker.report.notes ?? "blocked");
  }
  // A review fix that committed nothing leaves the commit, and so the evidence, the last
  // review judged unmet: another review could only repeat that verdict.
  if (worker.reviewedTip && worker.head === worker.reviewedTip) {
    return finishBlocked(
      ctx,
      worker,
      outcome,
      taggedReason(
        CRITERIA_UNMET_TAG,
        `the fix round made no commit, so ${branch} is still at ${worker.head.slice(0, 12)}, already judged unmet: ${worker.priorVerdict || "see review"}`,
      ),
    );
  }
  if (worker.verifyFailedTip && worker.head === worker.verifyFailedTip) {
    return finishBlocked(
      ctx,
      worker,
      outcome,
      taggedReason(
        FIXABLE_TAG,
        `the fix round made no commit, so ${branch} is still at ${worker.head.slice(0, 12)}, where verify last failed; triage's unaddressed detail: ${worker.priorVerdict || "see verify output"}`,
      ),
    );
  }
  // A coder that called itself done but reported a failing or un-run check is overruled by
  // the gate the same way: verify runs every check itself, and its verdict, not the coder's,
  // decides whether another coder round is needed — a narrow fix one, if so. With nothing
  // committed there is nothing to verify, and the retry restarts.
  if (claim && pre.demoted) {
    ctx.log(`[PREFILTER-OVERRULED] slug=${issue.slug} round=${worker.attempt} — the coder reported ${pre.reason}; the branch has commits, so verify decides`);
  } else if (claim) {
    const cause = worker.report.cause ? ` (cause: ${worker.report.cause})` : "";
    ctx.log(`[CODER-CLAIM] slug=${issue.slug} round=${worker.attempt} — the coder reported ${worker.report.status}${cause}; the branch has commits, so verify decides`);
  } else if (pre.status !== "complete") {
    return finishRetryOrBlock(ctx, worker, outcome, pre.reason ?? "partial");
  }

  // Not a verdict yet, but the coder is the longest step: a mid-pipeline heartbeat.
  notifyMilestone(ctx, issue, `coder finished (round ${worker.attempt}) — verifying`);

  // --- gate 1: independent verification in the worktree ----------------------
  // Skipped when this exact commit already has a passing record — a retry whose coder made
  // no commit, or a coder-free one runWorker already checked.
  if (worker.skipVerify || gatesAtTip(ctx, branch).verifiedThisRun) {
    ctx.log(`[SKIP-VERIFY] slug=${issue.slug} round=${worker.attempt} branch=${branch} — verification already passed at this commit, in this run`);
  } else {
    // No verify starts before the baseline's verdict (it runs alongside the coders). A red one
    // keeps this branch as it stands, to be verified by the next run.
    const baseline = await ctx.baseline;
    if (baseline?.status === "fail") {
      ctx.log(`[BASELINE-RED] slug=${issue.slug} round=${worker.attempt} — the baseline failed; branch kept, not verified`, "warn");
      return finishRetryOrBlock(ctx, worker, outcome, taggedReason(VERIFY_INTERRUPTED_TAG, "baseline failed"), { free: true });
    }
    ctx.log(`[STEP] slug=${dispatchStem(issue)} round=${worker.attempt} step=verify`);
    // Awaited, not spawnSync: a verify runs the project's whole test suite for minutes, and the
    // other worker loops (their verifies, their coder dispatches) must keep running meanwhile.
    const runVerify = async () => {
      const v = await effects.bashAsync("verify-worktree.sh", ["--dir", worker.worktree, "--stem", dispatchStem(issue)], {
        env: sprint.childEnv(),
      });
      logVerifyOutput(ctx, dispatchIssueDir(sprint.dispatchDir, issue), `slug=${issue.slug}`, worker.attempt, v);
      return v;
    };
    // What verify ran on beyond the committed tree: an untracked or modified file the branch does
    // not carry. A pass on such a worktree says nothing about the tree that merges.
    const dirtyBefore = effects.gitRead(["status", "--porcelain"], { cwd: worker.worktree });
    let verify = await runVerify();
    // Output that names no failing check is no evidence against the branch: run the gate
    // once more before triage can call it fixable and a coder is paid to chase it.
    if (verify.code !== 0 && !verify.interrupted && !verify.dryRun && !hasVerifyFailure(verify.stdout)) {
      ctx.log(`[VERIFY-INCONCLUSIVE] slug=${issue.slug} round=${worker.attempt} — exit ${verify.code} with no failing check in the output; verifying once more`, "warn");
      verify = await runVerify();
    }
    if (verify.code !== 0) {
      return await handleVerificationFailure(ctx, worker, outcome, verify);
    }
    sprint.markVerifiedThisRun(branch, effects.gitRead(["rev-parse", `${branch}^{commit}`]).stdout.trim());
    // Lets a feature branch of this exact tree skip its baseline / integration check — only when
    // the worktree verify ran on was that tree and nothing else.
    const passedTree = effects.gitRead(["rev-parse", `${branch}^{tree}`]).stdout.trim();
    if (dirtyBefore.code !== 0 || dirtyBefore.stdout.trim()) {
      ctx.log(`[TREE-NOT-CACHED] slug=${issue.slug} round=${worker.attempt} — verify ran with uncommitted files in the worktree; its pass does not stand for the committed tree`, "warn");
    } else if (passedTree) {
      sprint.state(["verified-tree", "--tree", passedTree]);
    }
    // This verify's answer replaces any earlier round's; a skipped verify (above) keeps its own.
    const cats = /coverage gap/i.test(verify.stdout)
      ? [...verify.stdout.matchAll(/not_run:\s*([\w, ]+)/gi)].flatMap((m) => m[1].split(",").map((c) => c.trim())).filter(Boolean)
      : [];
    if (cats.length) {
      sprint.coverageGap(issue.slug, cats);
      outcome.coverageGaps = [...new Set(cats)];
    } else {
      sprint.coverageClear(issue.slug);
    }
  }

  // --- gate 2: independent review (acceptance-criteria verdict; no findings) ---
  // The worktree stays alive across review (which needs none of it): an `AC: unmet`
  // verdict sends the coder back to fix this branch.
  // The gate's own record, not its stdout: the reviewer is pointed at the same file.
  const verifyFile = join(dispatchIssueDir(sprint.dispatchDir, issue), "verify.json");
  const verifyRecord = { ...readVerifyRecord(verifyFile), file: verifyFile };
  let review = await runReview(ctx, worker, verifyRecord);
  if (review.limitExceeded) return finishBlocked(ctx, worker, outcome, review.limitExceeded);
  // A reviewer that ended without a verdict gets one more dispatch in this round: cheaper
  // than a retry round, which would rebuild the worktree and re-verify an unchanged branch.
  // Not after a timeout — a second would double an already-long wait.
  if (!review.completed && !review.timedOut && !review.violation) {
    ctx.log(`[REVIEW-RETRY] slug=${issue.slug} round=${worker.attempt} — ${review.reason}`);
    review = await runReview(ctx, worker, verifyRecord);
    if (review.limitExceeded) return finishBlocked(ctx, worker, outcome, review.limitExceeded);
  }
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
    return finishRetryOrBlock(ctx, worker, outcome, taggedReason(REVIEW_NOT_RUN_TAG, review.reason));
  }

  // Not the code's fault: no coder round can start a service or supply a credential.
  if (review.parsed.verdict !== "all-met" && review.parsed.cause === "environment") {
    return finishBlocked(ctx, worker, outcome, taggedReason(CRITERIA_ENVIRONMENT_TAG, review.parsed.detail || "see review"));
  }
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
  const acReceipt = effects.bash("receipts.sh", ["write", "ac", "--branch", branch, ...(review.reviewedSha ? ["--sha", review.reviewedSha] : [])], {
    env: sprint.childEnv(),
  });
  if (acReceipt.code !== 0) {
    const detail = (acReceipt.stderr || acReceipt.stdout || "").trim() || `exit ${acReceipt.code}`;
    return finishRetryOrBlock(ctx, worker, outcome, taggedReason(AC_RECEIPT_FAILED_TAG, detail));
  }

  return mergeAndClose(ctx, worker, outcome);
}

