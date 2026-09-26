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
 * Two exits: nothing left to do (every open issue completed, or permanently blocked by a
 * spent retry cap or an unresolvable dependency), or the `--max-rounds` safety cap — each
 * issue may reach that many attempts, the same guarantee a round-batch sprint gave for
 * free (every issue gets one attempt per round before any issue gets a second). Checked
 * per issue, not as a global dispatch count, so a small --max-rounds still lets every
 * issue take its turn instead of the first one claimed exhausting the whole budget while
 * its siblings never run. Either way, findings are flushed first — see flush() below —
 * because a sprint that stalled on unrelated issues may still have merged code carrying a
 * CRITICAL finding.
 *
 * The PRD audit (runPrdAudit) runs once, the first time the queue drains: its gaps are parked
 * like findings, so the same flush sends both into Phase 2.
 */

import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { resumeRoute, runHousekeeping, runWorker } from "./pipeline.mjs";
import { getTracker } from "./tracker.mjs";
import { dispatchPlain } from "./dispatch.mjs";
import { appendLine } from "./effects.mjs";
import { prdGapsCriteria } from "./prompts.mjs";
import { parsePrdAudit } from "./report.mjs";

export async function runSprint(ctx) {
  const { sprint, effects, options } = ctx;
  // Resolved once per sprint, per `tracker.mjs`'s own contract — see its docstring — so
  // this loop dispatches against whichever backend `tracker-config.mjs` names, github or
  // local, instead of always the local file scan `tracker.mjs`'s static re-exports are
  // bound to.
  const tracker = await getTracker(effects.mainRoot);
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

  const notifyAll = () => {
    const pending = waiters;
    waiters = [];
    for (const resolve of pending) resolve();
  };
  const waitForChange = () => new Promise((resolve) => waiters.push(resolve));

  // Scoped to this sprint's own feature — see selectDispatchable()'s docstring. An
  // unscoped scan here would dispatch a ready-for-agent issue from an unrelated
  // .scratch/<other-feature>/ onto this sprint's feature branch. sprint.isBlockedThisRun
  // (in-memory, this invocation only) is consulted here — not the persisted
  // `blocked_slugs` — because a slug that spent its retry cap never has its issue file's
  // own `Status:` rewritten (only close-issue.sh writes that), so nothing on disk marks it
  // unavailable; if this checked the persisted list instead, a fresh `crew-afk` run could
  // never retry it, breaking crew-summary.sh's own "resolve blockers and re-run" advice.
  function claimNext() {
    const issues = tracker.selectDispatchable(effects.mainRoot, { featureSlug: sprint.featureSlug });
    return issues.find(
      (i) =>
        !inFlight.has(i.slug) &&
        !sprint.isBlockedThisRun(i.slug) &&
        (!options.maxRounds || sprint.attemptCount(i.slug) < options.maxRounds) &&
        !waitsForConflictRetry(i.slug),
    ) ?? null;
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

  /** True once every remaining open issue is either done, blocked, or at its --max-rounds
   * limit — as opposed to genuinely nothing left, which flush() still needs to check. */
  function cappedByMaxRounds() {
    if (!options.maxRounds) return false;
    return tracker.selectDispatchable(effects.mainRoot, { featureSlug: sprint.featureSlug }).some(
      (i) => !sprint.isBlockedThisRun(i.slug) && sprint.attemptCount(i.slug) >= options.maxRounds,
    );
  }

  async function runOne(issue) {
    inFlight.add(issue.slug);
    const conflictRetry = isConflictRetry(issue.slug);
    if (conflictRetry) conflictRetryInFlight = issue.slug;
    const attempt = sprint.bumpAttempt(issue.slug);
    ctx.log(`\n=== slug=${issue.slug} attempt=${attempt} — dispatching`);
    const worker = await runWorker(ctx, issue, attempt);
    const outcome = await runHousekeeping(ctx, worker);
    history.push(outcome);
    ctx.log(
      `--- slug=${issue.slug} attempt=${attempt} status=${outcome.status}${outcome.reason ? ` reason=${outcome.reason}` : ""}`,
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
      await waitForChange();
    }
  }

  let capped = false;
  let prdAudit = {};
  let audited = false;
  while (true) {
    await Promise.all(Array.from({ length: parallel }, () => workerLoop()));

    capped = cappedByMaxRounds();
    if (capped) {
      flush(ctx);
      ctx.log(`Round cap reached (--max-rounds ${options.maxRounds}).`);
      break;
    }
    // Once, when Phase 1 has drained: its gaps join the findings in the one flush below,
    // so Phase 2 fixes both, and nothing after it is audited again.
    // github creates the gaps issue ready-for-agent, so the flush has nothing to promote for
    // it and the loop has to go round again on the audit's word.
    let queuedReady = false;
    if (!audited) {
      audited = true;
      prdAudit = await runPrdAudit(ctx, tracker);
      queuedReady = prdAudit.queuedReady;
    }
    if (flush(ctx) > 0 || queuedReady) continue;
    break;
  }

  // listOpenIssueFiles is local-only (a directory scan); github's counterpart is listOpen,
  // whose entries carry their own `status` (a close-state, not a file location) instead of
  // requiring a second directory read to know which are still open.
  const stalled =
    !capped &&
    (tracker.listOpenIssueFiles
      ? tracker.listOpenIssueFiles(effects.mainRoot, { featureSlug: sprint.featureSlug }).length > 0
      : unfinishedIssues(tracker, effects.mainRoot, sprint.featureSlug).length > 0);

  await wrapUp(ctx, { stalled, prdAudit });
  return { stalled, history };
}

/**
 * Issues this sprint hasn't finished, other than parked fix issues. Local issues keep their
 * `Status:` until close-issue.sh moves them, so a blocked one is still in open/.
 */
function unfinishedIssues(tracker, mainRoot, featureSlug) {
  if (tracker.listOpenIssueFiles) {
    return tracker
      .listOpenIssueFiles(mainRoot, { featureSlug })
      .map((p) => tracker.parseIssue(p))
      .filter((i) => i.status !== "deferred-findings");
  }
  // The milestone's PRD issue stays open for the life of the feature; it is not work.
  return tracker.listOpen(mainRoot, { featureSlug }).filter((i) => i.status !== "done" && !tracker.isPrdIssue?.(i));
}

/**
 * The PRD audit (prdAuditor, afk.PRDAudit): what no per-branch review can see — a PRD
 * requirement no issue carried, a flow across issues. In `fix` mode its ✗ missing
 * requirements become one parked fix issue, which the caller's flush sends into Phase 2.
 * It does not run while a Phase 1 issue is still open (blocked, retained, stalled): that
 * issue's requirements would read as missing, so the report is noise and its gaps would
 * duplicate the issue — and the re-run that finishes it audits anyway. Returns
 * `{report, queuedReady, unqueued, failed, skipped}`: the report's path (or null); whether an
 * issue was created already ready-for-agent (github — local parks it for the flush instead);
 * in fix mode, why gaps were left unqueued; why an audit that ran did not finish; and why it
 * did not run. The last three are for the summary — the trace log alone is too easy to miss.
 */
async function runPrdAudit(ctx, tracker) {
  const { sprint, effects, options } = ctx;
  const mode = sprint.PRDAudit;
  if (mode === "off") return { report: null, queuedReady: false };
  const unfinished = unfinishedIssues(tracker, effects.mainRoot, sprint.featureSlug);
  if (unfinished.length) {
    const skipped = `${unfinished.length} Phase 1 issue(s) still open (${unfinished.map((i) => i.slug).join(", ")}) — resolve them and re-run.`;
    ctx.log(`PRD audit: skipped — ${skipped}`);
    return { report: null, queuedReady: false, skipped };
  }
  const audit = effects.exec("bash", [effects.script("prd-audit.sh"), "--mode", mode], {
    env: sprint.childEnv(),
    mutating: false,
  });
  // Only the script's own first line ever says "skipped" — the PRD it quotes may say it too.
  const firstLine = audit.stdout.split("\n", 1)[0] ?? "";
  if (/^PRD audit: skipped/.test(firstLine)) {
    ctx.log(firstLine);
    return { report: null, queuedReady: false };
  }

  const outFile = join(sprint.env.SPRINT_DIR, "prd-audit.md");
  const { runtime, model } = options.crew.prdAuditor;
  ctx.log(`[STEP] step=prd-audit mode=${mode} model=${model ?? "inherit"} runtime=${runtime}`);
  const r = await dispatchPlain(effects, runtime, {
    prompt: audit.stdout,
    cwd: effects.mainRoot,
    mainRoot: effects.mainRoot,
    model,
    outFile,
    timeoutMs: options.timeoutMs.prdAuditor,
  });
  if (r.code !== 0 || r.timedOut) {
    const failed = `the audit did not complete (${r.timedOut ? "timed out" : `exit ${r.code}`}) — no report, nothing queued.`;
    ctx.log(`PRD audit: ${failed}`);
    return { report: null, queuedReady: false, failed };
  }
  ctx.log(`PRD audit report: ${outFile}`);
  if (mode !== "fix" || r.dryRun) return { report: outFile, queuedReady: false };

  const parsed = parsePrdAudit(r.text);
  if (!parsed.ok) {
    ctx.log("PRD audit: no closing json block in the report — nothing queued; read it by hand.");
    return { report: outFile, queuedReady: false, unqueued: "the report has no closing json block — read it by hand." };
  }
  if (!parsed.missing.length) {
    ctx.log("PRD audit: no missing requirements.");
    return { report: outFile, queuedReady: false };
  }
  const criteriaPath = join(sprint.env.SPRINT_DIR, "prd-gaps.criteria.md");
  writeFileSync(criteriaPath, prdGapsCriteria(parsed.missing));
  const defer = effects.bash(
    "promote-findings.sh",
    ["defer-gaps", "--feature-slug", sprint.featureSlug, "--report", outFile, "--criteria-file", criteriaPath],
    { env: sprint.childEnv() },
  );
  ctx.log(`PRD audit: ${parsed.missing.length} missing requirement(s) → ${defer.stdout.trim() || defer.stderr.trim()}`);
  const queued = defer.code === 0 && /^defer-gaps: (?!skip)/m.test(defer.stdout);
  const unqueued = defer.code === 0 ? null
    : `${parsed.missing.length} missing requirement(s), but the fix issue was not created: ${defer.stderr.trim() || `exit ${defer.code}`}`;
  return { report: outFile, queuedReady: queued && !tracker.listOpenIssueFiles, unqueued };
}

/** Phase 1 → Phase 2: flip parked fix issues to ready-for-agent. */
function flush(ctx) {
  const { sprint, effects } = ctx;
  const r = effects.bash("promote-findings.sh", ["flush", "--feature-slug", sprint.featureSlug], {
    env: sprint.childEnv(),
  });
  const text = r.stdout.trim();
  ctx.log(text);
  const m = /FLUSH:\s*promoted=(\d+)/.exec(text);
  const promoted = m ? Number(m[1]) : 0;
  if (promoted > 0) ctx.log(`Phase 2: ${promoted} fix issue(s) re-entered the loop.`);
  return promoted;
}

async function wrapUp(ctx, { stalled, prdAudit }) {
  const { sprint, effects, options } = ctx;

  // --- squash ---------------------------------------------------------------
  // --platform picks the co-author trailer: the coder's runtime wrote the commits.
  const squashArgs = ["--platform", options.crew.coder.runtime];
  if (!options.squashCommits) squashArgs.push("--no-squash");
  ctx.log(effects.bash("squash-commits.sh", squashArgs, { env: sprint.childEnv() }).stdout.trim());

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
  ctx.log(lastLine);

  // --- summary (rendered from disk, never from recollection) -----------------
  const summaryArgs = [];
  if (stalled) summaryArgs.push("--stalled");
  const summary = effects.bash("crew-summary.sh", summaryArgs, { env: sprint.childEnv() });
  ctx.out(summary.stdout);
  // Also kept with the run's trace: stdout goes to whoever launched the run, and a launcher
  // that retells it can drop a line (the cost) nobody can then recover.
  if (sprint.traceLog && summary.stdout.trim()) appendLine(sprint.traceLog, `[SUMMARY]\n${summary.stdout.trimEnd()}`);
  if (prdAudit.skipped) {
    ctx.out(`\n## PRD Audit\n\n**Not run:** ${prdAudit.skipped}\n`);
  } else if (prdAudit.failed) {
    ctx.out(`\n## PRD Audit\n\n**Failed:** ${prdAudit.failed}\n`);
  } else if (prdAudit.report && existsSync(prdAudit.report)) {
    ctx.out(`\n## PRD Audit\n\n(see ${prdAudit.report})\n`);
    if (prdAudit.unqueued) ctx.out(`\n**Gaps not queued:** ${prdAudit.unqueued}\n`);
  }
  ctx.out("NO MORE TASKS");
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
