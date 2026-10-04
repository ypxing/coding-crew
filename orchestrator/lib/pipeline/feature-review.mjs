/**
 * The feature review: crew-reviewer's feature mode over the feature diff — the whole feature, or only
 * the commits since the last review — once per run, at the first drain of the queue. Each branch was
 * reviewed on its own diff, so what exists only across issues — a duplicated helper, inconsistent
 * error handling, a flow unsafe only combined — is seen nowhere else. Its findings join the sprint
 * review report under `feature` and flow through the same promotion (afk.fixFindings) as a branch's;
 * it is advisory and never fails the sprint.
 *
 * A whole-feature review is split into areas (feature-areas.mjs), one concurrent reviewer each, all
 * findings joined in one `feature` block and promoted once.
 */

import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { dispatch } from "../dispatch.mjs";
import { assetDir } from "../install-dir.mjs";
import { FEATURE_REVIEW, criteriaFile, featureReviewPrompt } from "../prompts.mjs";
import { sprintReviewContext } from "../review-context.mjs";
import { parseReviewReport } from "../report.mjs";
import { loadPrdDecisions } from "../prd-decisions.mjs";
import { promotedAs, selectPromotable } from "./findings-triage.mjs";
import { FEATURE_PLAN, planAreas } from "./feature-areas.mjs";
import { defaultBranchBase, limitExceeded, readOnlyDispatch, readSidecar, roleBinding } from "./shared.mjs";

/**
 * What this run's feature review covers: `{ mode, base, tip, exclude, reason? }`. `whole` starts at
 * the merge-base with the default branch (never this run's `base_sha`); `increment` starts at the
 * `reviewed_tip` an earlier review recorded and leaves out what `exclude` (the default branch) holds,
 * so commits merged in from it are not reviewed; `skip` has no range, `reason` says why.
 */
export function featureReviewRange(ctx) {
  const { sprint, effects } = ctx;
  const tipRead = effects.gitRead(["rev-parse", "--verify", "-q", `${sprint.featureBranch}^{commit}`]);
  const tip = tipRead.code === 0 ? tipRead.stdout.trim() : null;
  const def = defaultBranchBase(effects, sprint.featureBranch);
  if (!tip || !def) {
    const reason = !tip
      ? `${sprint.featureBranch} does not resolve to a commit, so there is no diff to review.`
      : `no default branch (origin or local) to measure ${sprint.featureBranch} from, so there is no range to review.`;
    return { mode: "skip", base: null, tip, exclude: null, reason };
  }
  const reviewed = sprint.readState().feature_review?.reviewed_tip;
  if (reviewed && reviewed === tip) {
    return { mode: "skip", base: null, tip, exclude: null, reason: `nothing new since ${reviewed} (the feature branch tip the last feature review covered).` };
  }
  if (reviewed && effects.gitRead(["merge-base", "--is-ancestor", reviewed, tip]).code === 0) {
    return { mode: "increment", base: reviewed, tip, exclude: def.ref };
  }
  return { mode: "whole", base: def.sha, tip, exclude: null };
}

/**
 * Returns `{ report?, skipped?, failed?, findings?, promoted?, promotedRef? }`: `skipped` is why it
 * was deliberately not run, `failed` why a dispatch that was made left no review (recorded as
 * not-run in the report), `report` the review report file holding its block.
 */
export async function runFeatureReview(ctx, { integration = null, wallCap = null } = {}) {
  const { sprint, effects } = ctx;

  if (wallCap) {
    const skipped = `the ${wallCap.minutes}-minute wall-clock cap stopped claims with ${wallCap.unclaimed} issue(s) still claimable — the feature is not whole yet, so the next run reviews it.`;
    ctx.log(`FEATURE-REVIEW: skipped — ${skipped}`);
    return { skipped };
  }
  if (integration?.status === "fail") {
    const skipped = "the integration check is red on the merged feature branch — a review of code that fails its checks would only restate that.";
    ctx.log(`FEATURE-REVIEW: skipped — ${skipped}`);
    return { skipped };
  }
  const range = featureReviewRange(ctx);
  if (range.mode === "skip") {
    ctx.log(`FEATURE-REVIEW: skipped — ${range.reason}`);
    return { skipped: range.reason };
  }
  const { base, exclude } = range;

  const dir = join(sprint.dispatchDir, FEATURE_REVIEW);
  mkdirSync(dir, { recursive: true });
  const reportFile = ctx.roundReviewFile();

  const reviewAssets = sprint.installDir ? assetDir(sprint.installDir, "reviewer") : null;
  const reviewContext = reviewAssets ? sprintReviewContext(sprint, effects, reviewAssets, effects.mainRoot) : null;

  // A whole-feature review is split into areas by the planner; an increment is one reviewer, no planner.
  let areas = [null];
  if (range.mode === "whole") {
    const planDir = join(sprint.dispatchDir, FEATURE_PLAN);
    mkdirSync(planDir, { recursive: true });
    areas = (await planAreas(ctx, { base, tip: range.tip, dir: planDir })).areas;
  }
  const decisions = loadPrdDecisions(ctx);

  const reviewer = roleBinding(ctx, "reviewer");
  const runs = await Promise.all(areas.map((area, i) => {
    const slug = `${FEATURE_REVIEW}-${i + 1}`;
    const areaDir = join(sprint.dispatchDir, slug);
    mkdirSync(areaDir, { recursive: true });
    const promptFile = join(areaDir, "review-prompt.md");
    const outFile = join(areaDir, "review.md");
    const sidecarFile = join(areaDir, "review.report.json");
    rmSync(sidecarFile, { force: true });
    const lines = area ? area.decisions.map((id) => decisions.get(id)).filter(Boolean) : [];
    writeFileSync(promptFile, featureReviewPrompt({ featureBranch: sprint.featureBranch, base, exclude, reportPath: sidecarFile, reviewAssets, reviewContext, area, decisions: lines }));
    ctx.log(`[STEP] step=feature-review slug=${slug} model=${reviewer.model ?? "inherit"} runtime=${reviewer.runtime}`);
    return reviewArea(ctx, { reviewer, slug, promptFile, outFile, sidecarFile });
  }));

  const ok = runs.filter((r) => !r.reason);
  const failures = runs.filter((r) => r.reason);
  // A gap on disk, so remind and the summary show it instead of reading as a clean review. With a
  // `feature` block it is written after it: the block closes an earlier run's gaps when the rollup folds.
  const markGaps = () => {
    for (const r of failures) {
      ctx.log(`FEATURE-REVIEW: ${r.slug} not run — ${r.reason}`, "warn");
      effects.bash("promote-findings.sh", [
        "mark-not-run",
        "--feature-slug", sprint.featureSlug,
        "--branch", r.slug,
        "--slug", r.slug,
        "--report", reportFile,
        "--reason", r.reason,
      ], { env: sprint.childEnv() });
    }
  };
  if (!ok.length) {
    markGaps();
    return { failed: runs.length === 1 ? failures[0].reason : failures.map((r) => `${r.slug}: ${r.reason}`).join("; "), report: reportFile };
  }

  // One `feature` block whatever the reviewers called themselves: the aggregate keys on it.
  const seen = new Set();
  const findings = ok.flatMap((r) => r.parsed.findings ?? []).filter((f) => {
    const key = JSON.stringify([f.severity, f.location, f.criterion]);
    return seen.has(key) ? false : (seen.add(key), true);
  });
  mkdirSync(sprint.reviewDir, { recursive: true });
  const written = { branch: FEATURE_REVIEW, slug: FEATURE_REVIEW, verdict: "all-met", detail: "", findings };
  const block = `## Branch: ${FEATURE_REVIEW} (${FEATURE_REVIEW})\n\n\`\`\`json\n${JSON.stringify(written)}\n\`\`\``;
  const prefix = existsSync(reportFile) ? "\n\n" : "";
  writeFileSync(reportFile, `${existsSync(reportFile) ? readFileSync(reportFile, "utf8") : ""}${prefix}${block}\n`);

  markGaps();

  // An area that left no review is a gap the next run should still cover, so the tip is kept for a full pass.
  if (!failures.length) sprint.state(["feature-reviewed", "--tip", range.tip]);
  ctx.log(`FEATURE-REVIEW: ${findings.length} finding(s) from ${ok.length} of ${runs.length} area reviewer(s) (${range.mode}: ${base.slice(0, 12)}..${sprint.featureBranch})`);
  return {
    report: reportFile,
    findings,
    areas: runs.length,
    ...(failures.length ? { areaFailures: failures.map((r) => `${r.slug}: ${r.reason}`) } : {}),
    ...(await promoteFeature(ctx, {
      findings,
      reportFile,
      dir,
      written,
      change: exclude
        ? `git log -p --reverse ${base}..${sprint.featureBranch} --not ${exclude}`
        : `git diff ${base}..${sprint.featureBranch}`,
    })),
  };
}

/** One area's crew-reviewer dispatch: `{ slug, parsed }`, or `{ slug, reason }` when it left no review. */
async function reviewArea(ctx, { reviewer, slug, promptFile, outFile, sidecarFile }) {
  const { sprint, effects, options } = ctx;
  const guarded = await readOnlyDispatch(ctx, { label: slug }, () => dispatch(
    effects,
    reviewer.runtime,
    {
      agent: "crew-reviewer",
      cwd: effects.mainRoot,
      promptFile,
      outFile,
      model: reviewer.model,
      mainRoot: effects.mainRoot,
      logFile: sprint.traceLog,
      featureSlug: sprint.featureSlug,
      slug,
      round: 1,
      reportPath: sidecarFile,
      maxBudgetUsd: reviewer.maxBudgetUsd,
    },
    {
      timeoutMs: options.timeoutMs.reviewer,
      onTrace: (line) => ctx.heartbeat(`step=feature-review ${line}`),
    },
  ));
  const result = guarded.result ?? { text: "", stderr: "", timedOut: false };
  if (guarded.result) sprint.recordDispatchCost(result, { slug, role: "reviewer", attempt: 1 });

  const sidecar = guarded.violation ? null : readSidecar(sidecarFile);
  const parsed = guarded.violation ? { ok: false, detail: guarded.violation } : parseReviewReport(result.text, sidecar);
  const capped = guarded.violation ? null : limitExceeded(result, "reviewer", reviewer);
  if (capped || result.timedOut || !parsed.ok) {
    const stderrHint = (result.stderr ?? "").trim().slice(0, 300).replace(/\s+/g, " ");
    return { slug, reason: capped ?? (result.timedOut ? "review dispatch timed out" : `${parsed.detail}${stderrHint ? ` — ${stderrHint}` : ""}`) };
  }
  return { slug, parsed };
}

/** The same fixFindings rule as a branch's findings; the feature has no issue file, so no depth guard. */
async function promoteFeature(ctx, { findings, reportFile, dir, written, change }) {
  const { sprint, effects } = ctx;
  const selected = await selectPromotable(ctx, {
    findings,
    label: FEATURE_REVIEW,
    scope: `Findings raised against the whole feature diff (${sprint.featureBranch}), reviewed once across all its issues.`,
    ref: sprint.featureBranch,
    change,
    dir,
    dispatchSlug: `${FEATURE_REVIEW}-findings`,
    round: 1,
    ledgerSlug: FEATURE_REVIEW,
    reportFile,
    written,
  });
  const { promotable } = selected;
  if (!promotable.length) {
    ctx.log(`FEATURE-REVIEW: promote: none — ${selected.rule === "actionable" ? "no Actionable finding" : "no findings at or above the threshold"}`);
    return {};
  }
  const criteriaPath = join(sprint.reviewDir, `${FEATURE_REVIEW}.criteria.md`);
  writeFileSync(criteriaPath, criteriaFile({ branch: FEATURE_REVIEW, findings: promotable }));
  const defer = effects.bash("promote-findings.sh", [
    "defer",
    "--feature-slug", sprint.featureSlug,
    "--branch", FEATURE_REVIEW,
    "--slug", FEATURE_REVIEW,
    "--title", `Fix feature review findings: ${sprint.featureSlug}`,
    "--report", reportFile,
    "--criteria-file", criteriaPath,
    "--severities", promotedAs(sprint.fixFindings, selected),
  ], { env: sprint.childEnv() });
  ctx.log(`FEATURE-REVIEW: promote: ${promotable.length} finding(s) → ${defer.stdout.trim() || defer.stderr.trim()}`);
  if (defer.code !== 0 || !/^defer: /m.test(defer.stdout)) return {};
  return {
    promoted: promotable.length,
    promotedRef: Number(/\/issues\/(\d+)\s*$/m.exec(defer.stdout)?.[1]) || null,
  };
}
