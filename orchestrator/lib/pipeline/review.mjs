/**
 * Gate 2, the independent review, and promotion of its findings into fix issues.
 */

import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { dispatch } from "../dispatch.mjs";
import { assetDir } from "../install-dir.mjs";
import { criteriaFile, reviewPrompt } from "../prompts.mjs";
import { decisionsFor } from "../prd-decisions.mjs";
import { sprintReviewContext } from "../review-context.mjs";
import { carryFindings, parseReviewBlocks, parseReviewReport, promoteSeverities, severityNames } from "../report.mjs";
import { promotedAs, selectPromotable } from "./findings-triage.mjs";
import { dispatchIssueDir, dispatchStem, issueDescriptor, issueRef, limitExceeded, readOnlyDispatch, readSidecar, roleBinding } from "./shared.mjs";

/** A path that only tests: a test/spec file by name, or anything under a test or fixture dir. */
export function isTestPath(path) {
  return (
    /(^|\/)(__tests__|__mocks__|__snapshots__|tests?|specs?|fixtures?|testdata)\//.test(path) ||
    /\.(test|spec)\.[^/]+$/.test(path) ||
    /(_test\.go|_spec\.rb|\.bats)$/.test(path) ||
    /(^|\/)test_[^/]+\.py$/.test(path)
  );
}

/** Line count of each log that exists, for the prompt's size hint. */
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

/** A decisions lookup that fails must never fail the review. */
function safeDecisions(ctx, issue) {
  try {
    return decisionsFor(ctx, issue.text, issue.slug);
  } catch (err) {
    ctx.log(`[WARN] PRD decisions: ${err.message} — review proceeds without them`, "warn");
    return [];
  }
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

  // A stale sidecar at this fixed path must not be read back as this round's verdict.
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
      prdDecisions: safeDecisions(ctx, issue),
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
      cwd: effects.mainRoot,
      promptFile,
      outFile,
      // Defaults to the coder's model: a weaker reviewer silently lowers the bar.
      // config.json's afk.models can name another explicitly.
      model: reviewer.model,
      mainRoot: effects.mainRoot,
      logFile: sprint.traceLog,
      featureSlug: sprint.featureSlug,
      slug: dispatchStem(issue),
      issueNumber: issue.number,
      round: worker.attempt,
      reportPath: sidecarFile,
      maxBudgetUsd: reviewer.maxBudgetUsd,
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

  // The aggregate is built from the sidecar's bytes, not the chat reply, so the two can't
  // disagree. The `## Branch:` heading is for humans; parseReviewAggregate reads only the
  // fenced json.
  mkdirSync(sprint.reviewDir, { recursive: true });
  const reviewedBranch = sidecar.branch ?? branch;
  // What an earlier review of this branch raised and this one dropped stays in the block.
  const earlier = readdirSync(sprint.reviewDir)
    .filter((n) => /^sprint-review-.*\.md$/.test(n))
    .sort()
    .flatMap((n) => parseReviewBlocks(readFileSync(join(sprint.reviewDir, n), "utf8")))
    .filter((rec) => rec.branch === reviewedBranch);
  const merged = carryFindings(earlier, parsed.findings ?? []);
  const carried = merged.slice((parsed.findings ?? []).length);
  let written = sidecar;
  if (carried.length) {
    parsed.findings = merged;
    written = {
      ...sidecar,
      findings: [
        ...(Array.isArray(sidecar.findings) ? sidecar.findings : []),
        ...carried.map(({ explicit, ...f }) => f),
      ],
    };
  }
  const heading = `## Branch: ${reviewedBranch} (${sidecar.slug ?? issue.slug})`;
  const block = `${heading}\n\n\`\`\`json\n${JSON.stringify(written)}\n\`\`\``;
  const prefix = existsSync(reportFile) ? "\n\n" : "";
  writeFileSync(reportFile, `${existsSync(reportFile) ? readFileSync(reportFile, "utf8") : ""}${prefix}${block}\n`);
  return { completed: true, reportFile, parsed, written, reviewedSha };
}

export async function promote(ctx, worker, review, outcome) {
  const { sprint, effects } = ctx;
  const { issue, branch } = worker;
  const guard = effects.bash("promote-findings.sh", ["guard", "--issue", issueRef(issue), "--severities", promoteSeverities(sprint.fixFindings)], {
    env: sprint.childEnv(),
  });
  const guardText = guard.stdout.trim();
  ctx.log(`slug=${issue.slug} round=${worker.attempt} ${guardText}`);
  const eligible = /^guard: eligible — threshold: (.+)$/.exec(guardText);
  if (!eligible) return; // source-guarded: the depth bound

  const findings = review.parsed.findings ?? [];
  // Under `actionable` this is crew-triage's judgement (a dispatch of its own); a severity level
  // is a filter. Either way the verdicts land beside each finding in the review report.
  const selected = await selectPromotable(ctx, {
    findings,
    label: issue.slug,
    scope: `Findings raised against branch ${branch} (issue ${issue.slug}), which has merged.`,
    ref: branch,
    dir: dispatchIssueDir(sprint.dispatchDir, issue),
    dispatchSlug: `${dispatchStem(issue)}-findings`,
    round: worker.attempt,
    ledgerSlug: issue.slug,
    reportFile: review.reportFile,
    written: review.written,
  });
  const { promotable } = selected;
  if (!promotable.length) {
    let why = "no findings";
    if (findings.length && selected.rule === "actionable") why = `none of the ${findings.length} finding(s) is Actionable`;
    else if (findings.length) {
      const found = [...new Set(findings.map((f) => f.severity))].join(", ");
      why = `findings (${found}) are below the threshold (${selected.fallback ? severityNames(selected.rule) : eligible[1]})`;
    }
    ctx.log(`slug=${issue.slug} round=${worker.attempt} promote: none — ${why}`);
    return;
  }
  const severities = [...new Set(promotable.map((f) => f.severity))].join(", ");
  ctx.log(`slug=${issue.slug} round=${worker.attempt} promote: ${promotable.length} finding(s) — ${severities}`);

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
    // Names what was promoted: a verdict, or — when triage failed — the severities of the fallback rule.
    "--severities", promotedAs(sprint.fixFindings, selected),
  ], { env: sprint.childEnv() });
  ctx.log(`slug=${issue.slug} round=${worker.attempt} ${defer.stdout.trim()}`);
  outcome.promoted = promotable.length;
  // github's fix issue, created ready-for-agent: the loop waits for the listing to show it.
  outcome.promotedRef = Number(/\/issues\/(\d+)\s*$/m.exec(defer.stdout)?.[1]) || null;
}
