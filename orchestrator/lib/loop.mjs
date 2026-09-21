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
 * pipeline.mjs's finishRetryOrBlock): the per-issue retry cap that used to fall out
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
 */

import { existsSync, mkdirSync } from "node:fs";
import { join } from "node:path";

import { runHousekeeping, runWorker } from "./pipeline.mjs";
import { listOpenIssueFiles, selectDispatchable } from "./tracker.mjs";
import { dispatchPlain } from "./dispatch.mjs";

export async function runSprint(ctx) {
  const { sprint, effects, options } = ctx;
  const parallel = Math.max(1, options.parallel ?? 1);
  const inFlight = new Set();
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
    const issues = selectDispatchable(effects.mainRoot, { featureSlug: sprint.featureSlug });
    return issues.find(
      (i) =>
        !inFlight.has(i.slug) &&
        !sprint.isBlockedThisRun(i.slug) &&
        (!options.maxRounds || sprint.attemptCount(i.slug) < options.maxRounds),
    ) ?? null;
  }

  /** True once every remaining open issue is either done, blocked, or at its --max-rounds
   * limit — as opposed to genuinely nothing left, which flush() still needs to check. */
  function cappedByMaxRounds() {
    if (!options.maxRounds) return false;
    return selectDispatchable(effects.mainRoot, { featureSlug: sprint.featureSlug }).some(
      (i) => !sprint.isBlockedThisRun(i.slug) && sprint.attemptCount(i.slug) >= options.maxRounds,
    );
  }

  async function runOne(issue) {
    inFlight.add(issue.slug);
    const attempt = sprint.bumpAttempt(issue.slug);
    ctx.log(`\n=== slug=${issue.slug} attempt=${attempt} — dispatching`);
    const worker = await runWorker(ctx, issue, attempt);
    const outcome = await runHousekeeping(ctx, worker);
    history.push(outcome);
    ctx.log(
      `--- slug=${issue.slug} attempt=${attempt} status=${outcome.status}${outcome.reason ? ` reason=${outcome.reason}` : ""}`,
    );
    inFlight.delete(issue.slug);
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
  while (true) {
    await Promise.all(Array.from({ length: parallel }, () => workerLoop()));

    capped = cappedByMaxRounds();
    if (capped) {
      flush(ctx);
      ctx.log(`Round cap reached (--max-rounds ${options.maxRounds}).`);
      break;
    }
    if (flush(ctx) > 0) continue;
    break;
  }

  const stalled =
    !capped && listOpenIssueFiles(effects.mainRoot, { featureSlug: sprint.featureSlug }).length > 0;

  await wrapUp(ctx, { stalled });
  return { stalled, history };
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

async function wrapUp(ctx, { stalled }) {
  const { sprint, effects, options } = ctx;

  // --- squash ---------------------------------------------------------------
  const squashArgs = ["--platform", ctx.platform];
  if (options.noSquash) squashArgs.push("--no-squash");
  ctx.log(effects.bash("squash-commits.sh", squashArgs, { env: sprint.childEnv() }).stdout.trim());

  // --- coverage validation (opt-in, decided by the script from sprint.env) ---
  const coverage = effects.exec("bash", [effects.script("coverage-validation.sh")], {
    env: sprint.childEnv(),
    mutating: false,
  });
  let coverageReport = null;
  // Only coverage-validation.sh's own *first line* ever says "skipped" — its skip paths echo
  // that single line and exit immediately, before the PRD is ever quoted. Testing the whole
  // of coverage.stdout (as this used to do) matches "skipped" anywhere inside the PRD's own
  // requirements prose — a PRD describing what should or shouldn't be skipped is exactly the
  // kind of text this step exists to read — and would silently skip a real validation with
  // nothing logged to say why. See commands.mjs for the same fix on command discovery's
  // identical shape.
  const coverageFirstLine = coverage.stdout.split("\n", 1)[0] ?? "";
  if (!/^Coverage validation: skipped/.test(coverageFirstLine)) {
    const outFile = join(sprint.env.SPRINT_DIR, "coverage-report.md");
    const r = await dispatchPlain(effects, ctx.platform, {
      prompt: coverage.stdout,
      cwd: effects.mainRoot,
      mainRoot: effects.mainRoot,
      model: options.coverageValidationModel,
      outFile,
      timeoutMs: options.reviewTimeoutMs,
    });
    coverageReport = r.code === 0 ? outFile : null;
    ctx.log(coverageReport ? `Coverage report: ${outFile}` : "Coverage validation dispatch failed.");
  }

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
  if (coverageReport && existsSync(coverageReport)) {
    ctx.out(`\n## Coverage Report\n\n(see ${coverageReport})\n`);
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
