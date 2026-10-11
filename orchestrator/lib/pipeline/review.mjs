/** Gate 2, the independent review: the acceptance criteria, and no findings. */

import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { dispatch } from "../dispatch.mjs";
import { assetDir } from "../install-dir.mjs";
import { prdPath } from "../prd.mjs";
import { reviewPrompt } from "../prompts.mjs";
import { sprintReviewContext } from "../review-context.mjs";
import { carryFindings, foldReview, parseReviewBlocks, parseReviewReport } from "../report.mjs";
import { dispatchIssueDir, dispatchStem, issueDescriptor, limitExceeded, readOnlyDispatch, readSidecar, roleBinding } from "./shared.mjs";

/** A path that only tests: a test/spec file by name, or anything under a test or fixture dir. */
export function isTestPath(path) {
  return (
    /(^|\/)(__tests__|__mocks__|__snapshots__|tests?|specs?|fixtures?|testdata)\//.test(path) ||
    /\.(test|spec)\.[^/]+$/.test(path) ||
    /(_test\.go|_spec\.rb|\.bats)$/.test(path) ||
    /(^|\/)test_[^/]+\.py$/.test(path)
  );
}

function countLines(logs = {}) {
  const out = {};
  for (const [k, f] of Object.entries(logs)) {
    try {
      out[k] = readFileSync(f, "utf8").split("\n").length;
    } catch {
      /* no size, no hint */
    }
  }
  return out;
}

/** A not_run stub keeps the findings before it. */
function earlierBranchReviews(reviewDir, branch) {
  if (!existsSync(reviewDir)) return [];
  const folded = readdirSync(reviewDir)
    .filter((n) => /^sprint-review-.*\.md$/.test(n))
    .sort()
    .flatMap((n) => parseReviewBlocks(readFileSync(join(reviewDir, n), "utf8")))
    .filter((rec) => rec.branch === branch)
    .reduce(foldReview, undefined);
  return folded ? [folded] : [];
}

export async function runReview(ctx, worker, { checks, logs, notConfigured, file } = {}) {
  const { sprint, effects, options } = ctx;
  const { issue, branch } = worker;
  const issueDir = dispatchIssueDir(sprint.dispatchDir, issue);
  mkdirSync(issueDir, { recursive: true });
  const promptFile = join(issueDir, "review-prompt.md");
  const outFile = join(issueDir, "review.md");
  const sidecarFile = join(issueDir, "review.report.json");
  const reportFile = ctx.roundReviewFile();

  rmSync(sidecarFile, { force: true });

  // The commit the reviewer is given: the AC receipt is written for it, not for a later tip.
  const reviewedSha = effects.gitRead(["rev-parse", "--verify", `refs/heads/${branch}`]).stdout.trim();
  const base = effects.gitRead(["merge-base", sprint.featureBranch, branch]).stdout.trim();
  const changed = base ? effects.gitRead(["diff", "--name-only", `${base}..${branch}`]).stdout.split("\n").filter(Boolean) : [];

  const reviewAssets = sprint.installDir ? assetDir(sprint.installDir, "reviewer") : null;
  const reviewContext = reviewAssets ? sprintReviewContext(sprint, effects, reviewAssets, effects.mainRoot) : null;

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
      logLines: countLines(logs),
      notConfigured,
      verifyFile: file,
      testOnly: changed.length > 0 && changed.every(isTestPath),
      emptyDiff: changed.length === 0,
      reportPath: sidecarFile,
      reviewAssets,
      reviewContext,
      prdPath: prdPath(ctx),
    }),
  );

  const reviewer = roleBinding(ctx, "reviewer");
  ctx.log(
    `[STEP] slug=${dispatchStem(issue)} round=${worker.attempt} step=dispatch-review model=${reviewer.model ?? "inherit"} runtime=${reviewer.runtime}`,
  );
  const guarded = await readOnlyDispatch(ctx, { label: `reviewer ${issue.slug}`, branches: [branch] }, () => dispatch(
    effects,
    reviewer.runtime,
    {
      agent: "crew-reviewer",
      cwd: effects.featureRoot,
      promptFile,
      outFile,
      // Defaults to the coder's model: a weaker reviewer silently lowers the bar.
      model: reviewer.model,
      mainRoot: effects.mainRoot,
      logFile: sprint.traceLog,
      featureSlug: sprint.featureSlug,
      slug: dispatchStem(issue),
      issueNumber: issue.number,
      round: worker.attempt,
      reportPath: sidecarFile,
      maxBudgetUsd: reviewer.maxBudgetUsd,
      effort: reviewer.effort,
    },
    {
      timeoutMs: options.timeoutMs.reviewer,
      onTrace: (line) => ctx.heartbeat(`slug=${dispatchStem(issue)} round=${worker.attempt} ${line}`),
    },
  ));
  const result = guarded.result;
  if (result) sprint.recordDispatchCost(result, { slug: issue.slug, role: "reviewer", attempt: worker.attempt });
  if (guarded.violation) return { completed: false, violation: true, reportFile, reason: guarded.violation, parsed: { ok: false } };

  const sidecar = readSidecar(sidecarFile);

  const parsed = parseReviewReport(result.text, sidecar);
  const capped = limitExceeded(result, "reviewer", reviewer);
  if (capped) return { completed: false, limitExceeded: capped, reportFile, reason: capped, parsed };
  // Sidecar-only, fail-closed: no valid sidecar verdict means not run, whatever the text says.
  if (result.timedOut || !parsed.ok) {
    // stderr holds dispatch-level failures (a dispatcher `die()`, a spawn error).
    const stderrHint = (result.stderr ?? "").trim().slice(0, 300).replace(/\s+/g, " ");
    return {
      completed: false,
      timedOut: result.timedOut,
      reportFile,
      reason: result.timedOut ? "review dispatch timed out" : `${parsed.detail}${stderrHint ? ` — ${stderrHint}` : ""}`,
      parsed,
    };
  }

  // Built from the sidecar's bytes, not the chat reply, so the two can't disagree. Findings come
  // from the feature review alone, so a branch block carries none of its own; what earlier rounds
  // left open stays listed with its verdict, and `criteria_only` tells foldReview to keep it.
  mkdirSync(sprint.reviewDir, { recursive: true });
  const reviewedBranch = sidecar.branch ?? branch;
  parsed.findings = [];
  // `notes` and `reviewed_sha` are for the feature review, which lists the notes in its range.
  const written = {
    ...sidecar,
    findings: carryFindings(earlierBranchReviews(sprint.reviewDir, reviewedBranch), [], { keepVerdicts: true }).map(({ explicit, ...f }) => f),
    notes: parsed.notes,
    reviewed_sha: reviewedSha,
    criteria_only: true,
  };
  const heading = `## Branch: ${reviewedBranch} (${sidecar.slug ?? issue.slug})`;
  const block = `${heading}\n\n\`\`\`json\n${JSON.stringify(written)}\n\`\`\``;
  const prefix = existsSync(reportFile) ? "\n\n" : "";
  writeFileSync(reportFile, `${existsSync(reportFile) ? readFileSync(reportFile, "utf8") : ""}${prefix}${block}\n`);
  return { completed: true, reportFile, parsed, written, reviewedSha };
}
