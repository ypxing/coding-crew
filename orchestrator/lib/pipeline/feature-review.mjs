/**
 * The feature review: crew-reviewer's feature mode over the feature diff — the whole feature, or only
 * the commits since the last review — at every drain of the queue (a drain whose tip the last review
 * covered dispatches nothing). Each branch was
 * reviewed on its own diff, so what exists only across issues — a duplicated helper, inconsistent
 * error handling, a flow unsafe only combined — is seen nowhere else. Its findings join the sprint
 * review report under `feature` and flow through the same promotion (afk.fixFindings) as a branch's
 * at the feature's first two reviews that ran, across runs (loop.mjs passes `promote`: the promotion's ordinal, false past the cap); later ones only report. It is advisory and never fails the sprint.
 *
 * A whole-feature review is split into areas (feature-areas.mjs), one concurrent reviewer each, all
 * findings joined in one `feature` block and promoted once.
 */

import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { dispatch } from "../dispatch.mjs";
import { assetDir } from "../install-dir.mjs";
import { FEATURE_REVIEW, criteriaFile, featureReviewPrompt } from "../prompts.mjs";
import { sprintReviewContext } from "../review-context.mjs";
import { carryFindings, findingKey, parseReviewBlocks, parseReviewReport } from "../report.mjs";
import { loadPrdDecisions, loadPrdSection } from "../prd-decisions.mjs";
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
export async function runFeatureReview(ctx, { integration = null, wallCap = null, promote = 1, drain = 1 } = {}) {
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

  // Each drain's artifacts get their own dirs: a later drain's review must not overwrite an earlier one's.
  const dir = join(sprint.dispatchDir, `${FEATURE_REVIEW}-d${drain}`);
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
  const compatibility = loadPrdSection(ctx, "Compatibility & Migration");

  const reviewer = roleBinding(ctx, "reviewer");
  const runs = await Promise.all(areas.map((area, i) => {
    const slug = `${FEATURE_REVIEW}-${i + 1}`;
    const areaDir = join(sprint.dispatchDir, `${FEATURE_REVIEW}-d${drain}-${i + 1}`);
    mkdirSync(areaDir, { recursive: true });
    const promptFile = join(areaDir, "review-prompt.md");
    const outFile = join(areaDir, "review.md");
    const sidecarFile = join(areaDir, "review.report.json");
    rmSync(sidecarFile, { force: true });
    // An area gets its own decisions; an increment has no area, so it gets every one.
    const lines = area ? area.decisions.map((id) => decisions.get(id)).filter(Boolean) : [...decisions.values()];
    writeFileSync(promptFile, featureReviewPrompt({ featureBranch: sprint.featureBranch, base, exclude, reportPath: sidecarFile, reviewAssets, reviewContext, area, decisions: lines, compatibility }));
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
    const key = findingKey(f);
    return seen.has(key) ? false : (seen.add(key), true);
  });
  mkdirSync(sprint.reviewDir, { recursive: true });
  const earlier = earlierFeatureFindings(sprint.reviewDir);
  const written = { branch: FEATURE_REVIEW, slug: FEATURE_REVIEW, verdict: "all-met", detail: "", findings };
  const block = `## Branch: ${FEATURE_REVIEW} (${FEATURE_REVIEW})\n\n\`\`\`json\n${JSON.stringify(written)}\n\`\`\``;
  const prefix = existsSync(reportFile) ? "\n\n" : "";
  writeFileSync(reportFile, `${existsSync(reportFile) ? readFileSync(reportFile, "utf8") : ""}${prefix}${block}\n`);

  markGaps();

  const promotion = await promoteFeature(ctx, {
    findings,
    reportFile,
    dir,
    written,
    promote,
    range,
    change: exclude
      ? `git log -p --reverse ${base}..${sprint.featureBranch} --not ${exclude}`
      : `git diff ${base}..${sprint.featureBranch}`,
  });
  carryEarlierFindings(reportFile, earlier);

  // An area that left no review is a gap the next run should still cover, so the tip is kept for a full pass.
  if (!failures.length) sprint.state(["feature-reviewed", "--tip", range.tip]);
  ctx.log(`FEATURE-REVIEW: ${findings.length} finding(s) from ${ok.length} of ${runs.length} area reviewer(s) (${range.mode}: ${base.slice(0, 12)}..${sprint.featureBranch})`);
  return {
    report: reportFile,
    findings,
    mode: range.mode,
    areas: runs.length,
    ...(failures.length ? { areaFailures: failures.map((r) => `${r.slug}: ${r.reason}`) } : {}),
    ...promotion,
  };
}

/** The findings the sprint review reports last held under `feature` (earlier drains' or runs'), verdicts kept. */
function earlierFeatureFindings(reviewDir) {
  if (!existsSync(reviewDir)) return [];
  const recs = readdirSync(reviewDir)
    .filter((n) => /^sprint-review-.*\.md$/.test(n))
    .sort()
    .flatMap((n) => parseReviewBlocks(readFileSync(join(reviewDir, n), "utf8")))
    .filter((rec) => rec.branch === FEATURE_REVIEW);
  return recs.at(-1)?.findings ?? [];
}

/**
 * The open findings a feature review left report-only (past the promotion cap): the `report_only`
 * ones in the last `feature` block on disk, which no fix issue covers — what promote-findings.sh
 * `open` reads — whichever run or drain wrote them.
 */
export function reportOnlyFeatureFindings(reviewDir) {
  return earlierFeatureFindings(reviewDir).filter((f) => f.report_only === true);
}

/**
 * Rewrites the report's last `feature` block through `edit(block)` (which returns the new findings);
 * the block is left alone when it cannot be located or parsed.
 */
function rewriteFeatureFindings(reportFile, edit) {
  const text = readFileSync(reportFile, "utf8");
  const start = text.lastIndexOf(`## Branch: ${FEATURE_REVIEW} (${FEATURE_REVIEW})`);
  const open = start < 0 ? -1 : text.indexOf("```json\n", start);
  if (open < 0) return;
  const from = open + "```json\n".length;
  const to = text.indexOf("\n```", from);
  if (to < 0) return;
  let block;
  try { block = JSON.parse(text.slice(from, to)); } catch { return; }
  const findings = edit(block.findings ?? []);
  if (!findings) return;
  block.findings = findings;
  writeFileSync(reportFile, `${text.slice(0, from)}${JSON.stringify(block)}${text.slice(to)}`);
}

/**
 * The rollup keeps only a branch's last block, so the review just written would hide what an earlier
 * drain raised and left unfixed. Rewrites that block with those findings appended, `carried: true`,
 * verdicts kept; what the new review repeats (report.mjs's findingKey) is not duplicated.
 */
function carryEarlierFindings(reportFile, earlier) {
  if (!earlier.length) return;
  rewriteFeatureFindings(reportFile, (latest) => {
    const merged = carryFindings([{ findings: earlier.map(({ explicit, ...f }) => f) }], latest, { keepVerdicts: true });
    return merged.length > latest.length ? merged : null;
  });
}

/**
 * Marks `report_only: true` on these findings in the report's last `feature` block: the fix issue an
 * earlier drain promoted leaves a `- feature: …` bullet that would otherwise read them as covered too.
 */
function markReportOnly(reportFile, findings) {
  const marked = new Set(findings.map(findingKey));
  rewriteFeatureFindings(reportFile, (all) => all.map((f) => (marked.has(findingKey(f)) ? { ...f, report_only: true } : f)));
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
async function promoteFeature(ctx, { findings, reportFile, dir, written, change, promote, range }) {
  const { sprint, effects } = ctx;
  const selected = await selectPromotable(ctx, {
    findings,
    label: FEATURE_REVIEW,
    scope: range.mode === "increment"
      ? `Findings raised against the commits added to ${sprint.featureBranch} since the last feature review (${range.base.slice(0, 12)}..${range.tip.slice(0, 12)}).`
      : `Findings raised against the whole feature diff (${sprint.featureBranch}), reviewed across all its issues.`,
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
  // Past the promotion cap: what the rule would have promoted is only reported, never made a fix issue.
  if (!promote) {
    ctx.log(`FEATURE-REVIEW: ${promotable.length} finding(s) the rule would promote are report-only at this drain`);
    // The report holds the unfolded findings; foldDuplicates' copies may differ in severity and location.
    const inReport = selected.rule === "actionable"
      ? selected.findings.filter((f) => f.verdict === "actionable" && (f.duplicate_of === undefined || selected.findings[f.duplicate_of].verdict !== "actionable"))
      : promotable;
    markReportOnly(reportFile, inReport);
    return { reportOnly: promotable };
  }
  const criteriaPath = join(sprint.reviewDir, `${FEATURE_REVIEW}.criteria.md`);
  writeFileSync(criteriaPath, criteriaFile({ branch: FEATURE_REVIEW, findings: promotable }));
  const defer = effects.bash("promote-findings.sh", [
    "defer",
    "--feature-slug", sprint.featureSlug,
    "--branch", FEATURE_REVIEW,
    // A second promotion is a fix issue of its own: a reused slug would read as the finished first one.
    "--slug", promote > 1 ? `${FEATURE_REVIEW}-${promote}` : FEATURE_REVIEW,
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
