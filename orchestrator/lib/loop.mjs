/**
 * loop.mjs — the sprint loop and wrap-up: `options.parallel` workers pull from one live queue, so
 * the per-issue attempt cap (sprint.bumpAttempt) is the only retry throttle. Each drain runs the
 * integration check, the feature review (once per drain loop), then the flush into Phase 2.
 */

import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { resumeRoute, runHousekeeping, runWorker } from "./pipeline.mjs";
import { getTracker } from "./tracker.mjs";
import { ADAPTERS } from "./adapters/index.mjs";
import { writeLog } from "./log.mjs";
import { labelIssue } from "./labels.mjs";
import { checkRequires, integrationSection, lintMidRunIssues, runIntegrationCheck } from "./preflight.mjs";
import { fixIntegration } from "./integration-fix.mjs";
import { writePrBody } from "./pipeline/pr-body.mjs";
import { promoteSeverities } from "./report.mjs";
import { reportOnlyFeatureFindings, runFeatureReview } from "./pipeline/feature-review.mjs";

export async function runSprint(ctx) {
  const { sprint, effects, options } = ctx;
  // Resolved once per sprint: the backend tracker-config.mjs names, not tracker.mjs's local re-exports.
  const tracker = ctx.tracker ?? (await getTracker(effects.mainRoot));
  const stages = ctx.stages ?? { runWorker, runHousekeeping, checkRequires, lintMidRunIssues };
  const parallel = Math.max(1, options.parallel ?? 1);
  const inFlight = new Set();
  // One merge-conflict retry at a time: two against one tip would conflict with each other's resolution.
  let conflictRetryInFlight = null;
  const conflictWaitsLogged = new Set();
  const history = [];
  let waiters = [];
  // Issues labelled `in-progress` this run that a merge or block did not unlabel; released at run end.
  const held = new Map();
  // github fix issues created ready-for-agent this run, not yet in the milestone listing (awaitListed).
  const unseen = new Set();
  const unlisted = [];

  const notifyAll = () => {
    const pending = waiters;
    waiters = [];
    for (const resolve of pending) resolve();
  };
  const waitForChange = () => new Promise((resolve) => waiters.push(resolve));

  // --poll-interval: while work is in flight, one poller lists the tracker for idle workers. 0 = off.
  const pollMs = Math.max(0, options.pollInterval ?? 0) * 1000;
  const sleep = ctx.sleep ?? ((ms) => new Promise((resolve) => setTimeout(resolve, ms).unref?.()));
  let pollerId = 0;
  let pollerRunning = false;
  let handoff = [];
  // Slugs already seen (and linted, or exempt) — the baseline a mid-run newcomer is measured against.
  const seen = new Set();
  // Fix issues this run created (github numbers): never re-linted.
  const ownRefs = new Set();
  const seenNow = () => {
    for (const i of tracker.selectDispatchable(effects.mainRoot, { featureSlug: sprint.featureSlug })) seen.add(i.slug);
  };

  async function pollOnce() {
    const issues = tracker.selectDispatchable(effects.mainRoot, { featureSlug: sprint.featureSlug });
    const fresh = issues.filter((i) => !seen.has(i.slug));
    for (const i of issues) seen.add(i.slug);
    const linted = fresh.filter((i) => !ownRefs.has(i.number));
    if (linted.length) await stages.lintMidRunIssues(ctx, linted);
    const claimable = issues.filter((i) => isClaimable(i));
    handoff = claimable;
    const n = Math.min(claimable.length, waiters.length);
    const pending = waiters.splice(0, n);
    for (const resolve of pending) resolve();
  }

  function startPoller() {
    if (!pollMs || pollerRunning) return;
    pollerRunning = true;
    const id = ++pollerId;
    (async () => {
      try {
        while (id === pollerId && inFlight.size > 0 && !claimsStopped()) {
          await sleep(pollMs);
          if (id !== pollerId || inFlight.size === 0 || claimsStopped()) break;
          if (waiters.length === 0) continue;
          await pollOnce();
        }
      } finally {
        if (id === pollerId) pollerRunning = false;
      }
    })();
  }

  // isBlockedThisRun, not the persisted `blocked_slugs`, so a fresh run can retry a capped slug.
  function isClaimable(i) {
    return (
      !inFlight.has(i.slug) &&
      !sprint.isBlockedThisRun(i.slug) &&
      (!options.maxRounds || sprint.attemptCount(i.slug) < options.maxRounds) &&
      !waitsForConflictRetry(i.slug)
    );
  }

  // A red baseline ends claims and stops running dispatches; ctx.baselineRed keeps their branches.
  let baselineFailed = null;
  ctx.baseline?.then((r) => {
    if (r?.status === "fail") {
      baselineFailed = r;
      ctx.baselineRed = true;
      const stopped = effects.interruptDispatches?.() ?? 0;
      ctx.log(`[BASELINE-RED] the baseline failed — stopping ${stopped} running dispatch(es); their branches are kept`, "warn");
      notifyAll();
    }
  }).catch(() => {}); // a crashed baseline surfaces where it is awaited

  // Soft wall-clock cap (afk.maxWallMinutes): once elapsed nothing new is claimed; running workers finish.
  const now = ctx.now ?? (() => Date.now());
  const startedAt = now();
  const wallMs = Math.max(0, Number(options.maxWallMinutes) || 0) * 60_000;
  const wallElapsed = () => wallMs > 0 && now() - startedAt >= wallMs;
  const unclaimedByCap = () =>
    wallElapsed() ? tracker.selectDispatchable(effects.mainRoot, { featureSlug: sprint.featureSlug }).filter((i) => isClaimable(i)) : [];
  let wallLogged = false;
  // The drain loop broke on the cap before Phase 2: parked fix issues wait for the next run.
  let flushSkipped = false;

  /** Nothing new is claimed (nor polled for) past a red baseline or the wall-clock cap. */
  function claimsStopped() {
    if (baselineFailed) return true;
    if (!wallElapsed()) return false;
    if (!wallLogged) {
      wallLogged = true;
      ctx.log(`[WALL-CAP] ${options.maxWallMinutes} minute cap elapsed — no new issue is claimed; running workers finish.`);
    }
    return true;
  }

  function claimNext() {
    if (claimsStopped()) return null;
    // What a poll just listed goes first, so N woken workers cost one listing, not N.
    while (handoff.length) {
      const i = handoff.shift();
      if (isClaimable(i)) return i;
    }
    const issues = tracker.selectDispatchable(effects.mainRoot, { featureSlug: sprint.featureSlug });
    return issues.find(isClaimable) ?? null;
  }

  function isConflictRetry(slug) {
    return resumeRoute(sprint.retentionReason(slug)).kind === "conflict";
  }

  function waitsForConflictRetry(slug) {
    if (conflictRetryInFlight == null || !isConflictRetry(slug)) return false;
    const key = `${slug} ${conflictRetryInFlight}`;
    if (conflictWaitsLogged.has(key)) return true;
    conflictWaitsLogged.add(key);
    ctx.log(`[CONFLICT-RETRY-WAIT] slug=${slug} — waiting for ${conflictRetryInFlight}'s merge-conflict retry to finish`);
    return true;
  }

  /** Some open issue is at its attempt cap (CREW_MAX_ROUNDS), not done or blocked. */
  function cappedByMaxRounds() {
    if (!options.maxRounds) return false;
    return tracker.selectDispatchable(effects.mainRoot, { featureSlug: sprint.featureSlug }).some(
      (i) => !sprint.isBlockedThisRun(i.slug) && sprint.attemptCount(i.slug) >= options.maxRounds,
    );
  }

  async function runOne(issue) {
    inFlight.add(issue.slug);
    // An issue preflight did not probe (it waited on a blocker then): its ## Requires runs now.
    if ((await stages.checkRequires(ctx, [issue])).length) {
      inFlight.delete(issue.slug);
      notifyAll();
      return;
    }
    // After the requires probe: a requires-failed issue is never labelled. Display only.
    if (!held.has(issue.slug) && labelIssue(ctx, "claim", issue)) held.set(issue.slug, issue);
    const conflictRetry = isConflictRetry(issue.slug);
    if (conflictRetry) conflictRetryInFlight = issue.slug;
    const attempt = sprint.bumpAttempt(issue.slug);
    const worker = await stages.runWorker(ctx, issue, attempt);
    const outcome = await stages.runHousekeeping(ctx, worker);
    history.push(outcome);
    if (outcome.status === "complete" || outcome.inProgressCleared) held.delete(issue.slug);
    ctx.log(
      `[ATTEMPT-END] slug=${issue.slug} attempt=${attempt} status=${outcome.status}${outcome.reason ? ` reason=${outcome.reason}` : ""}`,
    );
    inFlight.delete(issue.slug);
    if (conflictRetry) conflictRetryInFlight = null;
    notifyAll();
  }

  // Claims until nothing is claimable and no sibling is still running work that could free more.
  async function workerLoop() {
    while (true) {
      const issue = claimNext();
      if (issue) {
        await runOne(issue);
        continue;
      }
      if (inFlight.size === 0) return;
      startPoller();
      await waitForChange();
    }
  }

  let capped = false;
  let featureReviewed = false;
  let redSkipped = false;
  let integration = null;
  // One entry per drain whose review was attempted (featureReviewEntry), for the summary and the PR.
  const featureReviews = [];
  // Every red drain's outcome (integration-fix.mjs), for the cap, the repeat check and the summary.
  const integrationFixes = [];
  const integrationRefs = new Set();
  if (pollMs) seenNow();
  while (true) {
    await Promise.all(Array.from({ length: parallel }, () => workerLoop()));
    handoff = [];

    // The baseline may still be running when the queue drains: its verdict decides what follows.
    if (ctx.baseline) await ctx.baseline;
    if (baselineFailed) {
      for (const issue of held.values()) labelIssue(ctx, "release", issue);
      held.clear();
      return { stalled: false, history, baselineFailed };
    }

    capped = cappedByMaxRounds();
    if (capped) {
      flush(ctx);
      ctx.log(`Round cap reached (${options.maxRounds} attempts per issue).`);
      break;
    }
    // First at every drain, with whatever has merged so far (nothing merged, nothing new to check).
    if (options.integrationCheck && !options.dryRun && sprint.get("merged")) {
      integration = runIntegrationCheck(ctx);
      integration.fix = null;
      if (integration.status === "fail") {
        const fix = await fixIntegration(ctx, tracker, integration, integrationFixes);
        integration.fix = fix;
        if (!fix.repeat) integrationFixes.push(fix);
        if (fix.number) ownRefs.add(fix.number);
        if (fix.verdict === "queued" && !fix.repeat && fix.queuedReady && fix.number) {
          unseen.add(fix.number);
          integrationRefs.add(fix.number);
        }
      }
    }
    // Once per drain loop, at the first drain with something merged. A red integration check skips it
    // without spending it, so the next drain retries.
    if (!featureReviewed && !options.dryRun && sprint.get("merged")) {
      const red = integration?.status === "fail";
      featureReviewed = !red;
      // A red drain's skip entry gives way to a later drain's review.
      if (redSkipped) featureReviews.pop();
      redSkipped = red;
      const unclaimed = unclaimedByCap();
      const promote = (Number(sprint.get("feature-review-promotions")) || 0) < FEATURE_REVIEW_PROMOTIONS;
      const review = await runFeatureReview(ctx, {
        integration,
        wallCap: unclaimed.length ? { minutes: options.maxWallMinutes, unclaimed: unclaimed.length } : null,
        promote,
        drain: featureReviews.length + 1,
      });
      // A review that created no fix issue leaves the feature its one.
      if (review.promoted && promote) sprint.state(["feature-review-promoted"]);
      featureReviews.push(review);
      if (review.promotedRef) ownRefs.add(review.promotedRef);
      if (review.promotedRef && tracker.fixIssuesCreatedReady) unseen.add(review.promotedRef);
    }
    // Past the cap Phase 2 stays parked: the fix issues wait for the next run.
    if (wallElapsed()) {
      flushSkipped = parkedCount(ctx) > 0 || unseen.size > 0;
      break;
    }
    if (flush(ctx) > 0) {
      // Promoted fix issues are this run's own: not newcomers to lint.
      if (pollMs) seenNow();
      continue;
    }
    if (unseen.size) {
      const refs = [...unseen];
      unseen.clear();
      const missing = await awaitListed(ctx, tracker, refs);
      for (const ref of missing) {
        const what = integrationRefs.has(ref) ? "integration fix" : "review findings";
        const line = `#${ref} (${what}) was created but never appeared in the milestone listing — re-run to implement it.`;
        unlisted.push(line);
        ctx.log(`[FIX-ISSUE-UNLISTED] ${line}`, "warn");
      }
      if (missing.length < refs.length) continue;
    }
    break;
  }

  // The closing review, report-only: what merged after the first feature review reaches the PR reviewed.
  const reviewedThisRun = featureReviews.some((r) => r.report && !r.failed);
  if (reviewedThisRun && !options.dryRun && !wallElapsed()) {
    const review = await runFeatureReview(ctx, { integration, wallCap: null, promote: false, drain: featureReviews.length + 1 });
    if (!review.skipped) featureReviews.push(review);
  }

  // Unclaimed because of the cap: claimable issues, listed before anything releases them.
  const wallUnclaimed = unclaimedByCap().map((i) => i.slug);
  const wallCap = wallUnclaimed.length || flushSkipped ? { minutes: options.maxWallMinutes, unclaimed: wallUnclaimed } : null;
  // A cap hit stalls the run even when the attempt cap (CREW_MAX_ROUNDS) also ended it.
  let unfinished = null;
  const unfinishedIssues = () => (unfinished ??= openIssues(tracker, effects.mainRoot, sprint.featureSlug));
  const stalled =
    Boolean(wallCap) ||
    (!capped &&
      // The last drain's check: a drain red at the fix-issue limit stalls only if none later turned green.
      (integration?.fix?.verdict === "limit" || unfinishedIssues().length > 0));
  // A person's work, not an agent's: the summary names it, so a stall says whom it waits on.
  const waiting = stalled ? unfinishedIssues().filter((i) => i.status === "ready-for-human") : [];

  // Before the summary: drained, capped or stalled, no issue keeps a label saying it is being worked.
  for (const issue of held.values()) labelIssue(ctx, "release", issue);
  held.clear();

  await wrapUp(ctx, { tracker, stalled, capped, wallCap, unlisted, waiting, integration, integrationFixes, featureReviews });
  return { stalled, capped, wallCapped: Boolean(wallCap), history };
}

/** The feature's work issues not yet `done`, parked fix issues included; the PRD issue is not work. */
function openIssues(tracker, mainRoot, featureSlug) {
  return tracker.listFeatureIssues(mainRoot, { featureSlug }).filter((i) => i.status !== "done" && !tracker.isPrdIssue(i));
}

const LISTED_POLL = { tries: 15, delayMs: 2000 };

/** github's listing lags a create by seconds: waits, bounded, for every ref; returns those never listed. */
async function awaitListed(ctx, tracker, refs) {
  const { effects, sprint } = ctx;
  let missing = refs;
  for (let n = 0; ; n++) {
    const listed = new Set(tracker.listFeatureIssues(effects.mainRoot, { featureSlug: sprint.featureSlug }).map((i) => i.number));
    missing = missing.filter((ref) => !listed.has(ref));
    if (n && missing.length < refs.length) ctx.log(`fix issue(s) listed after ${n} poll(s)`);
    if (!missing.length || n >= LISTED_POLL.tries) return missing;
    await new Promise((resolve) => setTimeout(resolve, LISTED_POLL.delayMs));
  }
}

/** Parked fix issues (Phase 2's input) not yet flushed. */
function parkedCount(ctx) {
  const { sprint, effects } = ctx;
  const r = effects.bash("promote-findings.sh", ["list", "--feature-slug", sprint.featureSlug], { env: sprint.childEnv(), mutating: false });
  const m = /DEFERRED:\s*count=(\d+)/.exec(r.stdout ?? "");
  return m ? Number(m[1]) : 0;
}

function flush(ctx) {
  const { sprint, effects } = ctx;
  const r = effects.bash("promote-findings.sh", ["flush", "--feature-slug", sprint.featureSlug], {
    env: sprint.childEnv(),
  });
  const text = r.stdout.trim();
  ctx.log(text, "debug"); // promote-findings.sh traced [FLUSH]
  const m = /FLUSH:\s*promoted=(\d+)/.exec(text);
  const promoted = m ? Number(m[1]) : 0;
  if (promoted > 0) ctx.log(`Phase 2: ${promoted} fix issue(s) re-entered the loop.`);
  return promoted;
}

async function wrapUp(ctx, { tracker, stalled, capped = false, wallCap = null, unlisted = [], waiting = [], integration = null, integrationFixes = [], featureReviews = [] }) {
  const { sprint, effects, options } = ctx;

  // The coder's runtime wrote the commits, so its adapter's trailer credits it.
  const coAuthor = ADAPTERS[options.crew.coder.runtime]?.coAuthor;
  const squashArgs = coAuthor ? ["--co-author", coAuthor] : [];
  if (!options.squashCommits) squashArgs.push("--no-squash");
  const squash = effects.bash("squash-commits.sh", squashArgs, { env: sprint.childEnv() });
  ctx.log(squash.stdout.trim());
  const squashFailed = squash.code !== 0 ? (squash.stderr.trim() || `exit ${squash.code}`) : null;
  if (squashFailed) ctx.log(`Squash failed: ${squashFailed}`);

  const cleanupArgs = [
    "--main-root", effects.mainRoot,
    "--feature-slug", sprint.featureSlug,
  ];
  const merged = sprint.get("merged");
  const retained = sprint.get("retained");
  if (merged) cleanupArgs.push("--merged", merged);
  if (retained) cleanupArgs.push("--retain", retained);
  const cleanup = effects.bash("cleanup-worktrees.sh", cleanupArgs, { env: sprint.childEnv() });
  const lastLine = cleanup.stdout.trim().split("\n").filter(Boolean).pop() ?? "";
  ctx.log(lastLine, "debug"); // cleanup-worktrees.sh traced [CLEANUP]

  // The PR first, so the summary can point at it; the last review dispatched decides featureReviewFailed.
  const featureReviewFailed = featureReviews.findLast((r) => !r.skipped)?.failed ?? null;
  const pr = await pullRequest(ctx, tracker, integration, { stalled, capped, wallCap, unfixedFindings: unfixedFeatureFindings(sprint), featureReviewFailed });
  const summaryArgs = ["--promoted", promoteSeverities(sprint.fixFindings)];
  if (stalled) summaryArgs.push("--stalled");
  if (wallCap) summaryArgs.push("--capped");
  if (pr?.posted != null) summaryArgs.push("--posted-to", pr.url);
  const summary = effects.bash("crew-summary.sh", summaryArgs, { env: sprint.childEnv() });
  ctx.out(summary.stdout);
  // Also kept in the trace: a launcher that retells stdout can drop a line nobody can then recover.
  if (sprint.traceLog && summary.stdout.trim()) writeLog(sprint.traceLog, `[SUMMARY]\n${summary.stdout.trimEnd()}`);
  if (wallCap) {
    ctx.out(`\n## Wall-clock cap\n\nThe ${wallCap.minutes}-minute cap elapsed: running workers finished, Phase 2 fix issues stayed parked.${wallCap.unclaimed.length ? ` Unclaimed (${wallCap.unclaimed.length}):\n${wallCap.unclaimed.map((s) => `- ${s}`).join("\n")}` : ""}\n`);
  }
  if (integration) ctx.out(`\n## Integration check\n\n${integrationSection(effects.mainRoot, sprint.featureBranch, integration, integration.fix, integrationFixes)}\n`);
  if (featureReviews.length) ctx.out(`\n## Feature Review\n\n${featureReviews.map((r, i) => featureReviewLine(sprint, r, i + 1, featureReviews.length)).join("\n\n")}\n`);
  if (sprint.triageFallbacks.length) {
    const lines = sprint.triageFallbacks.map((f) => `- ${f.scope}: ${f.reason}`);
    ctx.out(
      `\n## Findings Triage\n\n**Triage left no usable verdict, so the \`high\` rule applied** (CRITICAL and HIGH findings were promoted, the rest left open) for:\n${lines.join("\n")}\n`,
    );
  }
  if (unlisted.length) ctx.out(`\n**Fix issues not implemented:**\n${unlisted.map((l) => `- ${l}`).join("\n")}\n`);
  if (waiting.length) {
    // An issue's file name under local, its number under github.
    const lines = waiting.map((i) => `- ${i.file ?? `#${i.number}`} ${i.title}`);
    ctx.out(`\n## Waiting on a person\n\n${lines.join("\n")}\n\nWhen they are done (cli.mjs mark-done), re-run: /crew-afk ${sprint.featureSlug}\n`);
  }
  if (squashFailed) ctx.out(`\n## Squash\n\n**Failed:** ${squashFailed}\n`);
  if (pr) ctx.out(`\n## ${pr.heading ?? "Pull Request"}\n\n${pr.text}\n`);
  ctx.out("NO MORE TASKS");
}

/** One findings fix issue per feature, not per run: the count lives in sprint-state.json, so a later run only reports. */
const FEATURE_REVIEW_PROMOTIONS = 1;

/** The findings a report-only feature review left that the fixFindings rule would have promoted, read from the review report on disk (an earlier run's count too). */
function unfixedFeatureFindings(sprint) {
  return sprint.fixFindings === "none" ? [] : reportOnlyFeatureFindings(sprint.reviewDir);
}

function featureReviewLine(sprint, r, n, total) {
  const label = total > 1 ? `Drain ${n}: ` : "";
  if (r.skipped) return `${label}**Not run:** ${r.skipped}`;
  if (r.failed) return `${label}**Not run:** ${r.failed}`;
  const count = r.findings?.length ?? 0;
  const rule = sprint.fixFindings === "actionable" ? "Actionable" : "at or above the fix threshold";
  const fate = r.promoted
    ? `; ${r.promoted} ${rule} went to Phase 2${r.overflow ? `, ${r.overflow} more report-only (past the fix issue's limit)` : ""}`
    : r.reportOnly?.length
      ? `; report-only (past the promotion cap): ${r.reportOnly.length} ${rule} not sent to Phase 2`
      : "";
  const what = r.mode === "increment" ? "The commits since the last review were" : "The feature was";
  return `${label}${what} reviewed: ${count} finding(s)${fate} (see ${r.report}, branch \`feature\`).`;
}

/**
 * Why a run is not green, one per cause. A check that could not run is not green; one switched off
 * is not held against it; a feature review with no valid report is, or the PR would look reviewed.
 */
function notGreenCauses({ exitCode = 0, blocked = [], integration = null, capped = false, integrationEnabled = true, wallCap = null, unfixedFindings = [], featureReviewFailed = null }) {
  const causes = [];
  const add = (kind, text) => causes.push({ kind, text });
  if (wallCap) add("wall-cap", `the ${wallCap.minutes}-minute wall-clock cap was hit (${wallCap.unclaimed.length ? `${wallCap.unclaimed.length} issue(s) unclaimed` : "Phase 2 fix issues stayed parked"})`);
  else if (exitCode !== 0) add("stalled", "the run stalled with issues unfinished");
  if (blocked.length) add("blocked", `${blocked.length} issue(s) blocked`);
  if (capped) add("capped", "the run stopped at its per-issue attempt cap");
  if (integration?.status === "skipped") add("integration", `the integration check was skipped (${integration.reason})`);
  else if (!integration && integrationEnabled) add("integration", "the integration check did not run");
  else if (integration && !["pass", "cached"].includes(integration.status)) add("integration", `the integration check ${integration.status}`);
  if (featureReviewFailed) add("review", `the feature review did not run (${featureReviewFailed})`);
  if (unfixedFindings.length) {
    const names = unfixedFindings.slice(0, 5).map((f) => `${f.location} (${f.severity})`).join(", ");
    add("findings", `${unfixedFindings.length} feature review finding(s) past the promotion cap or the fix issue's limit were reported, not fixed: ${names}${unfixedFindings.length > 5 ? ", …" : ""}`);
  }
  return causes;
}

const notGreenReasons = (state) => notGreenCauses(state).map((c) => c.text);

/**
 * The PR block's `<!-- crew-afk:draft <kinds> -->` marker, "" when green: `/address-pr-comments`
 * reads it to tell a draft for its findings alone from a draft for anything else.
 */
export function draftMarker(state) {
  const kinds = [...new Set(notGreenCauses(state).map((c) => c.kind))];
  return kinds.length ? `<!-- crew-afk:draft ${kinds.join(",")} -->` : "";
}

export const isGreen = (state) => notGreenReasons(state).length === 0;

/**
 * Last, after squash: the feature PR (open-pr.sh), the tracker's closing lines under the PR writer's
 * body. Without `openPr`, those lines are printed for the human's own PR.
 */
async function pullRequest(ctx, tracker, integration, { stalled = false, capped = false, wallCap = null, unfixedFindings = [], featureReviewFailed = null } = {}) {
  const { sprint, effects, options } = ctx;
  let refs = [];
  let refsError = null;
  try {
    refs = tracker.closingRefs?.(effects.mainRoot, { featureSlug: sprint.featureSlug }) ?? [];
  } catch (err) {
    refsError = err.message;
  }
  if (refsError) ctx.log(`closing refs: ${refsError}`, "warn");

  if (!options.openPr) {
    // Not opened: say how to open the PR and (github) which lines close the merged issues.
    if (!sprint.get("merged") && !refs.length) return null;
    return { heading: "Next", text: [
      `Merged into ${sprint.featureBranch}; nothing was pushed. To open the PR:`,
      "",
      `  gh pr create --head ${sprint.featureBranch} --title ${sprint.featureSlug}`,
      ...(refs.length ? [
        "",
        "The issues stay open until that PR closes them — put these in its body:",
        "",
        ...refs,
      ] : []),
      "",
      "Or have crew-afk push the branch and open the PR itself: re-run with --open-pr (config: afk.openPr: true).",
    ].join("\n") };
  }
  // A red merged branch is not shipped: a PR an earlier run opened becomes a draft, nothing pushed,
  // its marker rewritten to name `integration`.
  if (integration?.status === "fail") {
    const notOpened = `**Not opened:** the integration check failed on ${sprint.featureBranch} — see ## Integration check above.`;
    const marker = draftMarker({ exitCode: stalled ? 2 : 0, blocked: sprint.getList("blocked"), integration, capped, wallCap, unfixedFindings, featureReviewFailed });
    const r = effects.bash("open-pr.sh", ["--no-push", "--draft", "--draft-marker", marker], { env: sprint.childEnv() });
    const url = /^PR: (.*)$/m.exec(r.stdout ?? "")?.[1]?.trim();
    if (r.dryRun || r.code !== 0 || !url || url === "none") return { text: notOpened };
    const stateFailed = /^PR-STATE-FAILED: (.*)$/m.exec(r.stdout)?.[1];
    return { text: `${notOpened}\n\nThe PR already open for it (${url}) ${stateFailed ? `could not be made a draft: ${stateFailed}` : "is now a draft"}.` };
  }
  // A PR without its closing lines would ship the work and strand the issues open.
  if (refsError) return { text: `**Not opened:** could not list the issues it closes — ${refsError}` };
  const closesFile = join(sprint.env.SPRINT_DIR, "pr-closes.txt");
  writeFileSync(closesFile, refs.length ? `${refs.join("\n")}\n` : "");
  const body = await writePrBody(ctx, { integration });
  const blockedSlugs = sprint.getList("blocked");
  const { retention = {}, blocked_reasons: blockedReasons = {} } = sprint.readState();
  const state = { exitCode: stalled ? 2 : 0, blocked: blockedSlugs, integration, capped, wallCap, integrationEnabled: options.integrationCheck !== false, unfixedFindings, featureReviewFailed };
  const reasons = notGreenReasons(state);
  const green = reasons.length === 0;
  const args = ["--closes-file", closesFile];
  if (!green) {
    const note = join(sprint.env.SPRINT_DIR, "pr-note.md");
    const lines = [`**Not green:** ${reasons.join("; ")}. This PR is a draft.`, draftMarker(state)];
    if (blockedSlugs.length) {
      lines.push("", "Blocked issues:", ...blockedSlugs.map((slug) => {
        // A blocked issue keeps its reason in retention, or (no branch) in blocked_reasons.
        const why = retention[slug]?.reason ?? blockedReasons[slug];
        return `- ${slug}${why ? ` — ${why}` : ""}`;
      }));
    }
    writeFileSync(note, `${lines.join("\n")}\n`);
    args.push("--draft", "--note-file", note);
  }
  if (body) args.push("--body-file", body.file);
  if (body?.title) args.push("--title", body.title);
  const r = effects.bash("open-pr.sh", args, { env: sprint.childEnv() });
  if (r.dryRun) return null;
  if (r.code !== 0) return { text: `**Failed:** ${r.stderr.trim() || `exit ${r.code}`}` };
  const url = /^PR: (.*)$/m.exec(r.stdout)?.[1]?.trim() ?? r.stdout.trim().split("\n")[0];
  const stateFailed = /^PR-STATE-FAILED: (.*)$/m.exec(r.stdout)?.[1];
  const actual = /^PR-STATE: (\w+)$/m.exec(r.stdout)?.[1] ?? (green ? "ready" : "draft");
  const stateLine = green
    ? `**Ready:** the run finished green.`
    : `**Draft:** the run did not finish green — ${reasons.join("; ")}.`;
  if (stateFailed) ctx.log(`PR state: ${stateFailed}`, "warn");
  const opened0 = `${url}\n\n${stateLine}${stateFailed ? `\n\n**PR state not changed (now ${actual}):** ${stateFailed}` : ""}`;
  const opened = body?.failed ? `${opened0}\n\n**PR body has no summary:** ${body.failed}` : opened0;
  const post = effects.bash("post-findings.sh", [], { env: sprint.childEnv() });
  const m = /^POSTED: (\d+) \((\d+) inline\)/m.exec(post.stdout ?? "");
  if (post.code !== 0 || !m) {
    const why = (post.stderr ?? "").trim() || `exit ${post.code}`;
    ctx.log(`post-findings: ${why}`, "warn");
    return { text: `${opened}\n\n**Findings not posted:** ${why}` };
  }
  return { text: `${opened}\n\n${m[1]} finding(s) posted (${m[2]} inline).`, url, posted: Number(m[1]) };
}

/** Per-sprint review report file: one timestamped file, appended to across the whole run. */
export function makeRoundReviewFile(sprint) {
  const stamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\..+/, "");
  let cached = null;
  return () => {
    if (!cached) {
      mkdirSync(sprint.reviewDir, { recursive: true });
      cached = join(sprint.reviewDir, `sprint-review-${stamp}.md`);
    }
    return cached;
  };
}
