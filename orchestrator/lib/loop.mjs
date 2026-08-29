/**
 * loop.mjs — the sprint loop and the wrap-up, as a state machine.
 *
 * Round → dispatch → housekeep → repeat, with three exits: no issues left, the stall
 * limit, or a round cap. Every exit runs the findings flush first, because a sprint
 * that stalled on unrelated issues may still have merged code carrying a CRITICAL
 * finding — and a flush that promotes something re-enters the loop as Phase 2 with the
 * stall counter reset (entering Phase 2 at the stall limit would abort it on the first
 * partial round).
 *
 * Phase is deliberately not stored anywhere: the parked `Status: deferred-findings`
 * lines on disk are the only record, which is what makes the flush idempotent.
 */

import { existsSync, mkdirSync } from "node:fs";
import { join } from "node:path";

import { mapPool } from "./effects.mjs";
import { runHousekeeping, runWorker } from "./pipeline.mjs";
import { selectDispatchable } from "./tracker.mjs";
import { dispatchPlain } from "./dispatch.mjs";

const STALL_LIMIT = 2;

export async function runSprint(ctx) {
  const { sprint, effects, options } = ctx;
  let round = 0;
  let dryRounds = 0;
  let stalled = false;
  const history = [];

  while (true) {
    // Scoped to this sprint's own feature — see selectDispatchable()'s docstring. An
    // unscoped scan here would dispatch a ready-for-agent issue from an unrelated
    // .scratch/<other-feature>/ onto this sprint's feature branch.
    const issues = selectDispatchable(effects.mainRoot, { featureSlug: sprint.featureSlug });

    if (!issues.length) {
      if (flush(ctx) > 0) {
        dryRounds = 0;
        continue;
      }
      break;
    }

    round += 1;
    ctx.round = round;
    sprint.setRound(round, issues.length);
    ctx.log(`\n=== Round ${round}: ${issues.length} issue(s) — ${issues.map((i) => i.slug).join(", ")}`);

    const workers = await mapPool(issues, options.parallel, (issue) => runWorker(ctx, issue));

    // Housekeeping is sequential: merges and closes touch the main checkout.
    const outcomes = [];
    for (const w of workers) {
      outcomes.push(await runHousekeeping(ctx, w));
    }
    history.push({ round, outcomes });

    const completed = outcomes.filter((o) => o.status === "complete").length;
    dryRounds = completed > 0 ? 0 : dryRounds + 1;
    ctx.log(
      `--- Round ${round}: complete=${completed} partial=${outcomes.filter((o) => o.status === "partial").length} blocked=${outcomes.filter((o) => o.status === "blocked").length}`,
    );

    if (dryRounds >= STALL_LIMIT) {
      // One dry round is not a stall — retry once first. Two is.
      if (flush(ctx) > 0) {
        dryRounds = 0;
        continue;
      }
      stalled = true;
      break;
    }
    if (options.maxRounds && round >= options.maxRounds) {
      ctx.log(`Round cap reached (--max-rounds ${options.maxRounds}).`);
      break;
    }
  }

  await wrapUp(ctx, { stalled });
  return { rounds: round, stalled, history };
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
  // nothing logged to say why. See commands.mjs's discoverCommands() for the same fix on
  // command discovery's identical shape.
  const coverageFirstLine = coverage.stdout.split("\n", 1)[0] ?? "";
  if (!/^Coverage validation: skipped/.test(coverageFirstLine)) {
    const outFile = join(sprint.env.SPRINT_DIR, "coverage-report.md");
    const r = await dispatchPlain(effects, ctx.platform, {
      prompt: coverage.stdout,
      cwd: effects.mainRoot,
      mainRoot: effects.mainRoot,
      model: options.model,
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

/** Per-round review report file: one timestamped file, appended to across a round. */
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
