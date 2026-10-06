/**
 * loop.mjs — the sprint loop and the wrap-up, as a continuous dispatch pool.
 *
 * `options.parallel` workers pull from the same live queue for the whole sprint — there
 * is no batch boundary where the pool waits for every currently-running issue to finish
 * before a freed slot can pick up the next one. A worker that just failed becomes
 * dispatchable again (via its retry) the moment it's retained, and a sibling that just
 * unblocked a dependent issue makes that issue dispatchable the moment it completes —
 * both get picked up by whichever slot frees first, not by whatever slower issue the old
 * round-batch model happened to still be waiting on.
 *
 * What used to be "round" — a wave of issues dispatched together — no longer exists as a
 * synchronization point. What's left of the word is repurposed as each *issue's own*
 * attempt count (see sprint.bumpAttempt, spent once per dispatch in runOne below, and
 * pipeline/finish.mjs's finishRetryOrBlock): the per-issue retry cap that used to fall out
 * accidentally from a round's real wall-clock cost is now the only thing throttling
 * retries, so it has to be explicit.
 *
 * It ends when nothing is left to do (every open issue completed, or permanently blocked by a
 * spent retry cap or an unresolvable dependency), when the wall-clock cap stops new claims, when a
 * red baseline stops the run, or at the per-issue attempt cap (CREW_MAX_ROUNDS, a test seam) — each
 * issue may reach that many attempts, the same guarantee a round-batch sprint gave for
 * free (every issue gets one attempt per round before any issue gets a second). Checked
 * per issue, not as a global dispatch count, so a small attempt cap still lets every
 * issue take its turn instead of the first one claimed exhausting the whole budget while
 * its siblings never run. Either way, findings are flushed first — see flush() below —
 * because a sprint that stalled on unrelated issues may still have merged code carrying a
 * CRITICAL finding.
 *
 * The integration check (afk.integrationCheck) runs at every drain, first — after Phase 1 and
 * again after every Phase 2: each branch passed its own verify, but the merged feature branch is
 * checked nowhere else, and fixes can break it again. Red, it is triaged (integration-fix.mjs): a
 * fixable failure becomes a parked fix issue the same flush sends into Phase 2, and the next
 * drain checks again; at most INTEGRATION_FIX_LIMIT of them per run, and a red drain after that
 * ends the run stalled. A failure no code can fix is reported, queues nothing, and skips the
 * drain's remaining checks. A red final one keeps the PR from being opened.
 *
 * The feature review (runFeatureReview) runs once per run, at the first drain where something
 * merged, after the integration check: crew-reviewer over the whole feature diff the first run, then
 * over the commits since the last run's review (no reviewer when there are none). Its findings are
 * parked like a branch's, so the same flush sends them into Phase 2, until one review has created the
 * feature's single fix issue (counted across runs); later runs' reviews only report, and each finding
 * the fixFindings rule would have promoted keeps the PR a draft. A red integration check skips it
 * without spending the run's review, so the next drain whose check passes runs it; the wall-clock cap
 * skips it too, and ends the run.
 */

import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { resumeRoute, runHousekeeping, runWorker } from "./pipeline.mjs";
import { getTracker } from "./tracker.mjs";
import { writeLog } from "./log.mjs";
import { labelIssue } from "./labels.mjs";
import { checkRequires, integrationSection, lintMidRunIssues, runIntegrationCheck } from "./preflight.mjs";
import { fixIntegration } from "./integration-fix.mjs";
import { writePrBody } from "./pipeline/pr-body.mjs";
import { promoteSeverities } from "./report.mjs";
import { reportOnlyFeatureFindings, runFeatureReview } from "./pipeline/feature-review.mjs";

export async function runSprint(ctx) {
  const { sprint, effects, options } = ctx;
  // Resolved once per sprint, per `tracker.mjs`'s own contract — see its docstring — so
  // this loop dispatches against whichever backend `tracker-config.mjs` names, github or
  // local, instead of always the local file scan `tracker.mjs`'s static re-exports are
  // bound to.
  const tracker = ctx.tracker ?? (await getTracker(effects.mainRoot));
  // Test seam: the per-issue pipeline stages, replaceable by a stub.
  const stages = ctx.stages ?? { runWorker, runHousekeeping, checkRequires, lintMidRunIssues };
  const parallel = Math.max(1, options.parallel ?? 1);
  const inFlight = new Set();
  // At most one merge-conflict retry at a time: each resolves against the feature-branch
  // tip, so two in flight together resolve against the same tip, and whichever merges
  // second conflicts again with the first's resolution — spending its retry cap on a
  // conflict its sibling caused. Serialized, each syncs after the previous one merged.
  let conflictRetryInFlight = null;
  const conflictWaitsLogged = new Set();
  const history = [];
  let waiters = [];
  // Issues this run labelled `in-progress` and has not seen leave it: a merge (mark-done) and a
  // block (issue-labels.sh block) each remove it themselves; whatever is left is released at run end.
  const held = new Map();
  // github fix issues this run created already ready-for-agent (a review's findings, an
  // integration fix), not yet seen in the milestone listing — see awaitListed.
  const unseen = new Set();
  const unlisted = [];

  const notifyAll = () => {
    const pending = waiters;
    waiters = [];
    for (const resolve of pending) resolve();
  };
  const waitForChange = () => new Promise((resolve) => waiters.push(resolve));

  // Idle-slot polling (--poll-interval): while work is in flight and a slot is idle, one poller lists
  // the tracker once per interval and hands what it found to that many idle workers. 0 = off.
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

  // Scoped to this sprint's own feature — see selectDispatchable()'s docstring. An
  // unscoped scan here would dispatch a ready-for-agent issue from an unrelated
  // .scratch/<other-feature>/ onto this sprint's feature branch. sprint.isBlockedThisRun
  // (in-memory, this invocation only) is consulted here — not the persisted
  // `blocked_slugs` — because a slug that spent its retry cap never has its issue file's
  // own `Status:` rewritten (only close-issue.sh writes that), so nothing on disk marks it
  // unavailable; if this checked the persisted list instead, a fresh `crew-afk` run could
  // never retry it, breaking crew-summary.sh's own "resolve blockers and re-run" advice.
  function isClaimable(i) {
    return (
      !inFlight.has(i.slug) &&
      !sprint.isBlockedThisRun(i.slug) &&
      (!options.maxRounds || sprint.attemptCount(i.slug) < options.maxRounds) &&
      !waitsForConflictRetry(i.slug)
    );
  }

  // A red baseline (ctx.baseline, started by main.mjs alongside dispatch) ends further claims and
  // stops the dispatches already running: their work would not be verified this run anyway.
  // ctx.baselineRed tells the pipeline to keep each stopped branch for the next run.
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

  // Soft wall-clock cap (afk.maxWallMinutes / --max-wall): once elapsed nothing new is claimed;
  // workers already running finish, merge and close.
  const now = ctx.now ?? (() => Date.now());
  const startedAt = now();
  const wallMs = Math.max(0, Number(options.maxWallMinutes) || 0) * 60_000;
  const wallElapsed = () => wallMs > 0 && now() - startedAt >= wallMs;
  // Claimable issues the wall-clock cap left unclaimed: none until the cap has passed.
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

  /** True once every remaining open issue is either done, blocked, or at its attempt cap (CREW_MAX_ROUNDS)
   * limit — as opposed to genuinely nothing left, which flush() still needs to check. */
  function cappedByMaxRounds() {
    if (!options.maxRounds) return false;
    return tracker.selectDispatchable(effects.mainRoot, { featureSlug: sprint.featureSlug }).some(
      (i) => !sprint.isBlockedThisRun(i.slug) && sprint.attemptCount(i.slug) >= options.maxRounds,
    );
  }

  async function runOne(issue) {
    inFlight.add(issue.slug);
    // An issue preflight did not probe (it was waiting on a blocker then): its ## Requires runs
    // now, before its first dispatch. A no-op for any issue already probed this run.
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

  // One of `parallel` of these runs concurrently. Each keeps claiming and running issues
  // until there's genuinely nothing left to claim (nothing claimable and nothing any
  // sibling is still working on that could unblock or free up more).
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
    // Once per run, at the first drain with something merged: a later drain's review could open no
    // second fix issue. Reviews promote until one has created the feature's fix issue (counted per
    // feature in sprint-state.json, across runs); a later run's findings are reported. A red
    // integration check skips it without spending the run's one review: the next drain retries.
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
    // Past the cap Phase 2 stays parked: the fix issues wait for the next run. With none parked
    // (and, under github, none created and still awaiting the listing) the cap cut nothing short.
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

  // The closing review: what merged after the run's first feature review (the fix issue, integration
  // fixes) reaches the PR reviewed. Report-only — the feature keeps its one fix issue — and only when a
  // review ran earlier in the run: featureReviewRange skips an unchanged tip, so a run where nothing
  // merged since dispatches nothing. Past the wall-clock cap it is not run; a red last check skips it
  // (runFeatureReview), and a skip adds no summary entry.
  const reviewedThisRun = featureReviews.some((r) => r.report && !r.failed);
  if (reviewedThisRun && !options.dryRun && !wallElapsed()) {
    const review = await runFeatureReview(ctx, { integration, wallCap: null, promote: false, drain: featureReviews.length + 1 });
    if (!review.skipped) featureReviews.push(review);
  }

  // Unclaimed because of the cap: claimable issues, listed before anything releases them.
  const wallUnclaimed = unclaimedByCap().map((i) => i.slug);
  const wallCap = wallUnclaimed.length || flushSkipped ? { minutes: options.maxWallMinutes, unclaimed: wallUnclaimed } : null;
  // A cap hit stalls the run even when the attempt cap (CREW_MAX_ROUNDS) also ended it.
  const stalled =
    Boolean(wallCap) ||
    (!capped &&
      // The last drain's check, not any earlier one: a drain red at the fix-issue limit stalls
      // the run only if no later drain turned it green.
      (integration?.fix?.verdict === "limit" ||
        openIssues(tracker, effects.mainRoot, sprint.featureSlug).length > 0));

  // Before the summary: drained, capped or stalled, no issue keeps a label saying it is being worked.
  for (const issue of held.values()) labelIssue(ctx, "release", issue);
  held.clear();

  await wrapUp(ctx, { tracker, stalled, capped, wallCap, unlisted, integration, integrationFixes, featureReviews });
  return { stalled, capped, wallCapped: Boolean(wallCap), history };
}

/**
 * The feature's work issues not yet `done`, parked fix issues included: a blocked issue keeps its
 * status until close-issue.sh closes it. The milestone's PRD issue stays open for the life of the
 * feature; it is not work.
 */
function openIssues(tracker, mainRoot, featureSlug) {
  return tracker.listFeatureIssues(mainRoot, { featureSlug }).filter((i) => i.status !== "done" && !tracker.isPrdIssue(i));
}

/** Polls of the milestone listing, and the wait before each, for awaitListed. */
const LISTED_POLL = { tries: 15, delayMs: 2000 };

/**
 * github's issue listing lags a create by a few seconds, so a round started for a fix issue
 * created just before the queue drained could list the milestone without it, claim nothing,
 * and end the sprint with it open. Waits, bounded, until the listing has every ref in `refs`;
 * returns those it never showed.
 */
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

/** Phase 1 → Phase 2: flip parked fix issues to ready-for-agent. */
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

async function wrapUp(ctx, { tracker, stalled, capped = false, wallCap = null, unlisted = [], integration = null, integrationFixes = [], featureReviews = [] }) {
  const { sprint, effects, options } = ctx;

  // --- squash ---------------------------------------------------------------
  // --platform picks the co-author trailer: the coder's runtime wrote the commits.
  const squashArgs = ["--platform", options.crew.coder.runtime];
  if (!options.squashCommits) squashArgs.push("--no-squash");
  const squash = effects.bash("squash-commits.sh", squashArgs, { env: sprint.childEnv() });
  ctx.log(squash.stdout.trim());
  const squashFailed = squash.code !== 0 ? (squash.stderr.trim() || `exit ${squash.code}`) : null;
  if (squashFailed) ctx.log(`Squash failed: ${squashFailed}`);

  // --- worktree cleanup (mechanical, idempotent) ----------------------------
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

  // --- summary (rendered from disk, never from recollection) -----------------
  // The PR comes first: the summary points at it when the findings were posted there.
  const pr = await pullRequest(ctx, tracker, integration, { stalled, capped, wallCap, unfixedFindings: unfixedFeatureFindings(sprint) });
  const summaryArgs = ["--promoted", promoteSeverities(sprint.fixFindings)];
  if (stalled) summaryArgs.push("--stalled");
  if (wallCap) summaryArgs.push("--capped");
  if (pr?.posted != null) summaryArgs.push("--posted-to", pr.url);
  const summary = effects.bash("crew-summary.sh", summaryArgs, { env: sprint.childEnv() });
  ctx.out(summary.stdout);
  // Also kept with the run's trace: stdout goes to whoever launched the run, and a launcher
  // that retells it can drop a line (the cost) nobody can then recover.
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
  if (squashFailed) ctx.out(`\n## Squash\n\n**Failed:** ${squashFailed}\n`);
  if (pr) ctx.out(`\n## ${pr.heading ?? "Pull Request"}\n\n${pr.text}\n`);
  ctx.out("NO MORE TASKS");
}

/**
 * A feature gets one findings fix issue — per feature, not per run: the count of reviews that created
 * one lives in sprint-state.json (`feature_review.promotions`), so a later run is report-only too, and
 * an earlier version's count of 2 reads as capped. To keep LOW findings out of fix issues altogether,
 * use `fixFindings: medium`.
 */
const FEATURE_REVIEW_PROMOTIONS = 1;

/** The findings a report-only feature review left that the fixFindings rule would have promoted, read from the review report on disk (an earlier run's count too). */
function unfixedFeatureFindings(sprint) {
  return sprint.fixFindings === "none" ? [] : reportOnlyFeatureFindings(sprint.reviewDir);
}

/** One drain's entry of the summary's `## Feature Review`: its range, finding count, and what became of them. */
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
 * Why a run is not green, one line per cause, for the PR block and the summary — none when it
 * is: exited 0 (not stalled, not capped by the wall clock), no issue blocked, not cut short by the
 * attempt cap (CREW_MAX_ROUNDS), and the integration check passed or was cached. A check that
 * could not run (`skipped`) is not green; one the user switched off is not held against it.
 */
function notGreenCauses({ exitCode = 0, blocked = [], integration = null, capped = false, integrationEnabled = true, wallCap = null, unfixedFindings = [] }) {
  const causes = [];
  const add = (kind, text) => causes.push({ kind, text });
  if (wallCap) add("wall-cap", `the ${wallCap.minutes}-minute wall-clock cap was hit (${wallCap.unclaimed.length ? `${wallCap.unclaimed.length} issue(s) unclaimed` : "Phase 2 fix issues stayed parked"})`);
  else if (exitCode !== 0) add("stalled", "the run stalled with issues unfinished");
  if (blocked.length) add("blocked", `${blocked.length} issue(s) blocked`);
  if (capped) add("capped", "the run stopped at its per-issue attempt cap");
  if (integration?.status === "skipped") add("integration", `the integration check was skipped (${integration.reason})`);
  else if (!integration && integrationEnabled) add("integration", "the integration check did not run");
  else if (integration && !["pass", "cached"].includes(integration.status)) add("integration", `the integration check ${integration.status}`);
  if (unfixedFindings.length) {
    const names = unfixedFindings.slice(0, 5).map((f) => `${f.location} (${f.severity})`).join(", ");
    add("findings", `${unfixedFindings.length} feature review finding(s) past the promotion cap or the fix issue's limit were reported, not fixed: ${names}${unfixedFindings.length > 5 ? ", …" : ""}`);
  }
  return causes;
}

const notGreenReasons = (state) => notGreenCauses(state).map((c) => c.text);

/**
 * The PR block's machine-readable draft reason (`<!-- crew-afk:draft findings,blocked -->`), one token
 * per kind of not-green cause, or "" when the run is green. `/address-pr-comments` reads it to tell a
 * PR that is a draft only for its findings from one that is a draft for anything else.
 */
export function draftMarker(state) {
  const kinds = [...new Set(notGreenCauses(state).map((c) => c.kind))];
  return kinds.length ? `<!-- crew-afk:draft ${kinds.join(",")} -->` : "";
}

export const isGreen = (state) => notGreenReasons(state).length === 0;

/**
 * Last, after squash: the feature PR. `openPr` pushes the branch and creates or updates the PR
 * with the tracker's closing lines in its body (open-pr.sh), under the body the PR writer wrote
 * for a reviewer (pipeline/pr-body.mjs). Off, those lines are printed for
 * the human's own PR — the tracker leaves each merged issue open until a PR closes it. Returns
 * `{text, heading?, url?, posted?}` — the section's text (heading `Next` when off), and when the findings were posted to the PR
 * (post-findings.sh) its URL and their count — or null when there is nothing to say. A posting
 * failure is reported in the text and never fails the sprint.
 */
async function pullRequest(ctx, tracker, integration, { stalled = false, capped = false, wallCap = null, unfixedFindings = [] } = {}) {
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
    // Nothing merged → nothing to ship, so nothing to say. Otherwise the branch is local only:
    // say how to turn it into a PR, and (github) which lines close the issues it merged.
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
  // A red merged branch is not shipped: the PR would ask a reviewer to merge what fails its checks.
  // A PR an earlier, green run opened is turned into a draft, with nothing pushed to it.
  if (integration?.status === "fail") {
    const notOpened = `**Not opened:** the integration check failed on ${sprint.featureBranch} — see ## Integration check above.`;
    const r = effects.bash("open-pr.sh", ["--no-push", "--draft"], { env: sprint.childEnv() });
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
  const state = { exitCode: stalled ? 2 : 0, blocked: blockedSlugs, integration, capped, wallCap, integrationEnabled: options.integrationCheck !== false, unfixedFindings };
  const reasons = notGreenReasons(state);
  const green = reasons.length === 0;
  const args = ["--closes-file", closesFile];
  if (!green) {
    const note = join(sprint.env.SPRINT_DIR, "pr-note.md");
    const lines = [`**Not green:** ${reasons.join("; ")}. This PR is a draft.`, draftMarker(state)];
    if (blockedSlugs.length) {
      lines.push("", "Blocked issues:", ...blockedSlugs.map((slug) => {
        // A blocked issue with a branch keeps its reason in retention; one without (a failing
        // `## Requires`) only in blocked_reasons.
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
