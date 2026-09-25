/**
 * Gate 2, the independent review, and promotion of its findings into fix issues.
 */

import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { dispatch } from "../dispatch.mjs";
import { criteriaFile, reviewPrompt } from "../prompts.mjs";
import { findingsAtOrAbove, parseReviewReport } from "../report.mjs";
import { dispatchStem, issueDescriptor, issueRef, readSidecar } from "./shared.mjs";

export async function runReview(ctx, worker, { checks, logs, notConfigured, file } = {}) {
  const { sprint, effects, platform, options } = ctx;
  const { issue, branch } = worker;
  const promptFile = join(sprint.dispatchDir, `${dispatchStem(issue)}.review-prompt.md`);
  const outFile = join(sprint.dispatchDir, `${dispatchStem(issue)}.review.md`);
  const sidecarFile = join(sprint.dispatchDir, `${dispatchStem(issue)}.review.report.json`);
  const reportFile = ctx.roundReviewFile();

  // A stale sidecar at this fixed path must not be read back as this round's verdict.
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
      logs,
      notConfigured,
      verifyFile: file,
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
      // Defaults to the coder's model: a weaker reviewer silently lowers the bar.
      // afk-models.json can name another explicitly.
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
  // Sidecar-only, fail-closed: no valid sidecar verdict means not run, whatever the text says.
  if (result.timedOut || !parsed.ok) {
    // stderr holds dispatch-level failures (a dispatcher `die()`, a spawn error).
    const stderrHint = (result.stderr ?? "").trim().slice(0, 300).replace(/\s+/g, " ");
    return {
      completed: false,
      reportFile,
      reason: result.timedOut ? "review dispatch timed out" : `${parsed.detail}${stderrHint ? ` — ${stderrHint}` : ""}`,
      parsed,
    };
  }

  // The aggregate is built from the sidecar's bytes, not the chat reply, so the two can't
  // disagree. The `## Branch:` heading is for humans; parseReviewAggregate reads only the
  // fenced json.
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
