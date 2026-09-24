/**
 * Gate 2, the independent review, and promotion of its findings into fix issues.
 */

import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { dispatch } from "../dispatch.mjs";
import { criteriaFile, reviewPrompt } from "../prompts.mjs";
import { findingsAtOrAbove, parseReviewReport } from "../report.mjs";
import { dispatchStem, issueDescriptor, issueRef, readSidecar } from "./shared.mjs";

export async function runReview(ctx, worker, checks) {
  const { sprint, effects, platform, options } = ctx;
  const { issue, branch } = worker;
  const promptFile = join(sprint.dispatchDir, `${dispatchStem(issue)}.review-prompt.md`);
  const outFile = join(sprint.dispatchDir, `${dispatchStem(issue)}.review.md`);
  const sidecarFile = join(sprint.dispatchDir, `${dispatchStem(issue)}.review.report.json`);
  const reportFile = ctx.roundReviewFile();

  // See runWorker's matching rmSync: this path is fixed per issue, so a stale sidecar from
  // a prior review dispatch must not be read back as this round's verdict.
  rmSync(sidecarFile, { force: true });

  writeFileSync(
    promptFile,
    reviewPrompt({
      branch,
      slug: issue.slug,
      issuePath: issueDescriptor(issue),
      criteria: issue.criteria,
      featureBranch: sprint.featureBranch,
      checks,
      reportPath: sidecarFile,
    }),
  );

  ctx.log(
    `[STEP] slug=${dispatchStem(issue)} round=${worker.attempt} step=dispatch-review model=${options.reviewerModel ?? "inherit"}`,
  );
  const result = await dispatch(
    effects,
    platform,
    {
      agent: "crew-code-reviewer",
      cwd: effects.mainRoot,
      promptFile,
      outFile,
      // The reviewer defaults to the coder's model: reviewing on a weaker one silently
      // changes the standard the branch is held to. .coding-crew/afk-models.json can name
      // a different (typically stronger) one explicitly.
      model: options.reviewerModel,
      mainRoot: effects.mainRoot,
      logFile: sprint.traceLog,
      featureSlug: sprint.featureSlug,
      scriptsDir: effects.scriptsDir,
      slug: dispatchStem(issue),
      issueNumber: issue.number,
      round: worker.attempt,
      reportPath: sidecarFile,
    },
    {
      timeoutMs: options.reviewTimeoutMs,
      onTrace: (line) => ctx.log(`slug=${dispatchStem(issue)} round=${worker.attempt} ${line}`),
    },
  );

  const sidecar = readSidecar(sidecarFile);

  const parsed = parseReviewReport(result.text, sidecar);
  // sidecar-only, fail-closed: parsed.ok is false whenever the sidecar is missing or has no
  // valid verdict, whatever the dispatch's captured text happened to contain — there is no
  // separate "real prose findings without a verdict block" case to disambiguate any more,
  // since findings are only ever read from the sidecar too.
  if (result.timedOut || !parsed.ok) {
    // result.stderr is where a dispatch-level failure reason actually lives (a `die()`
    // guard in dispatch-agent.sh, a spawn-level error, ...) — surfaced here so a human
    // reading the review report's `not_run` stub does not have to reproduce the dispatch
    // by hand to find out why.
    const stderrHint = (result.stderr ?? "").trim().slice(0, 300).replace(/\s+/g, " ");
    return {
      completed: false,
      reportFile,
      reason: result.timedOut ? "review dispatch timed out" : `${parsed.detail}${stderrHint ? ` — ${stderrHint}` : ""}`,
      parsed,
    };
  }

  // The aggregate file is fed straight from the sidecar's own bytes, not the dispatch's
  // captured text — the two used to usually agree (the reviewer's protocol asked for the
  // same block twice, once to disk and once in its final message) but only ever *usually*:
  // this makes them identical by construction. The `## Branch:` heading is cosmetic —
  // parseReviewAggregate only ever scans for the fenced json block — but keeps the
  // aggregate readable for a human, sourced from the sidecar's own branch/slug rather than
  // trusting the model's chat reply to have written one correctly.
  mkdirSync(sprint.reviewDir, { recursive: true });
  const heading = `## Branch: ${sidecar.branch ?? branch} (${sidecar.slug ?? issue.slug})`;
  const block = `${heading}\n\n\`\`\`json\n${JSON.stringify(sidecar)}\n\`\`\``;
  const prefix = existsSync(reportFile) ? "\n\n" : "";
  writeFileSync(reportFile, `${existsSync(reportFile) ? readFileSync(reportFile, "utf8") : ""}${prefix}${block}\n`);
  return { completed: true, reportFile, parsed };
}

export async function promote(ctx, worker, review, outcome) {
  const { sprint, effects } = ctx;
  const { issue, branch } = worker;
  const guard = effects.bash("promote-findings.sh", ["guard", "--issue", issueRef(issue)], {
    env: sprint.childEnv(),
  });
  const guardText = guard.stdout.trim();
  ctx.log(`slug=${issue.slug} round=${worker.attempt} ${guardText}`);
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
  ctx.log(`slug=${issue.slug} round=${worker.attempt} ${defer.stdout.trim()}`);
  outcome.promoted = promotable.length;
}
