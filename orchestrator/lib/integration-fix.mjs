/**
 * integration-fix.mjs — a red drain-time integration check is triaged by `crew-triage` and, when
 * fixable, becomes one parked fix issue the next Phase 2 implements. Bounded by
 * INTEGRATION_FIX_LIMIT, or two commits that keep breaking each other would loop forever.
 */

import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join, relative, resolve } from "node:path";

import { dispatch } from "./dispatch.mjs";
import { integrationFixCriteria, integrationTriagePrompt } from "./prompts.mjs";
import { parseTriageReport } from "./report.mjs";
import { INTEGRATION_STEM, failureTails } from "./preflight.mjs";
import { limitExceeded, readOnlyDispatch, readSidecar, roleBinding } from "./pipeline/shared.mjs";

export const INTEGRATION_FIX_LIMIT = 2;

/**
 * `prior`: this run's earlier red drains; the same commit red again is answered from its verdict.
 * Verdict `queued` (`queuedReady`: wait for github to list it), `pending` (an earlier fix issue is
 * open), `not-fixable` (`reason` says why) or `limit` (INTEGRATION_FIX_LIMIT spent).
 */
export async function fixIntegration(ctx, tracker, result, prior) {
  const done = prior.find((p) => p.commit === result.commit);
  if (done) {
    ctx.log(`[INTEGRATION-TRIAGE] commit=${result.commit.slice(0, 12)} reused=${done.verdict} — the same commit is red again; no second triage`);
    return { ...done, repeat: true };
  }
  const made = prior.filter((p) => p.verdict === "queued").length;
  if (made >= INTEGRATION_FIX_LIMIT) {
    const reason = `${made} integration fix issues were already implemented this run and the merged feature branch is still red — no further fix issue`;
    ctx.log(`[INTEGRATION-TRIAGE] commit=${result.commit.slice(0, 12)} verdict=limit — ${reason}`, "error");
    return { verdict: "limit", reason, commit: result.commit };
  }

  // A check whose command is not installed failed before judging any code (see verify.mjs); so did
  // a dependency install. No coder could fix either, and there is nothing for triage to weigh.
  const missing = result.failed.filter((f) => f.missing);
  if (missing.length || !result.failed.length) {
    const reason = missing.length
      ? `missing command: ${missing.map((f) => `${f.missing} is not installed (${f.check})`).join("; ")}`
      : result.reason;
    ctx.log(`[INTEGRATION-TRIAGE] commit=${result.commit.slice(0, 12)} verdict=not-fixable — ${reason}; triage skipped`);
    return { verdict: "not-fixable", reason, commit: result.commit };
  }

  const attempt = made + 1;
  const triage = await runIntegrationTriage(ctx, result, attempt);
  if (triage.limitExceeded) {
    ctx.log(`[INTEGRATION-TRIAGE] commit=${result.commit.slice(0, 12)} verdict=not-fixable — ${triage.limitExceeded}`, "error");
    return { verdict: "not-fixable", reason: triage.limitExceeded, commit: result.commit };
  }
  // Triage itself failed: treated as fixable, the same fall-back a failed per-branch triage takes
  // (one more coder attempt) rather than letting a helper's failure leave the branch red.
  const triageFailed = !triage.completed;
  const fixable = triageFailed || triage.parsed.fixable;
  const category = triageFailed ? "triage did not complete" : triage.parsed.category;
  const detail = triageFailed
    ? "the triage dispatch produced no verdict, so the failure is treated as fixable"
    : triage.parsed.detail;
  ctx.log(
    `[INTEGRATION-TRIAGE] commit=${result.commit.slice(0, 12)} fixable=${triageFailed ? "failed→yes" : fixable ? "yes" : "no"} category=${category || "unspecified"} detail=${detail || "none"}`,
    fixable ? "info" : "warn",
  );
  if (!fixable) {
    return { verdict: "not-fixable", reason: `${category || "unspecified"}: ${detail || "no detail given"}`, category, detail, commit: result.commit };
  }

  const queued = queueFixIssue(ctx, tracker, result, { category, detail });
  return { ...queued, category, detail, triageFailed, commit: result.commit };
}

/** Dispatched to `crew-triage`, never a coder: a coder has every reason to call a failure environmental. */
async function runIntegrationTriage(ctx, result, attempt) {
  const { sprint, effects, options } = ctx;
  const dir = join(sprint.dispatchDir, INTEGRATION_STEM);
  mkdirSync(dir, { recursive: true });
  const promptFile = join(dir, "triage-prompt.md");
  const outFile = join(dir, "triage.md");
  const sidecarFile = join(dir, "triage.report.json");
  // A stale sidecar at this fixed path must not be read back as this drain's verdict.
  rmSync(sidecarFile, { force: true });
  writeFileSync(
    promptFile,
    integrationTriagePrompt({
      featureBranch: sprint.featureBranch,
      commit: result.commit.slice(0, 12),
      checkOutput: readOutput(effects.mainRoot, dir),
      reportPath: sidecarFile,
    }),
  );

  const triage = roleBinding(ctx, "triage");
  ctx.log(`[STEP] slug=${INTEGRATION_STEM} round=${attempt} step=dispatch-triage model=${triage.model ?? "inherit"} runtime=${triage.runtime}`);
  const guarded = await readOnlyDispatch(ctx, { label: "integration-triage" }, () => dispatch(
    effects,
    triage.runtime,
    {
      agent: "crew-triage",
      cwd: effects.featureRoot,
      promptFile,
      outFile,
      model: triage.model,
      mainRoot: effects.mainRoot,
      logFile: sprint.traceLog,
      featureSlug: sprint.featureSlug,
      slug: INTEGRATION_STEM,
      round: attempt,
      reportPath: sidecarFile,
      maxBudgetUsd: triage.maxBudgetUsd,
      effort: triage.effort,
    },
    {
      timeoutMs: options.timeoutMs.triage,
      onTrace: (line) => ctx.heartbeat(`slug=${INTEGRATION_STEM} round=${attempt} ${line}`),
    },
  ));
  const dispatched = guarded.result;
  if (dispatched) sprint.recordDispatchCost(dispatched, { slug: INTEGRATION_STEM, role: "triage", attempt });
  if (guarded.violation) return { completed: false, parsed: { ok: false, detail: guarded.violation }, limitExceeded: null };
  const parsed = parseTriageReport(dispatched.text, readSidecar(sidecarFile));
  return { completed: !dispatched.timedOut && parsed.ok, parsed, limitExceeded: limitExceeded(dispatched, "triage", triage) };
}

function readOutput(mainRoot, dir) {
  try {
    return readFileSync(resolve(mainRoot, dir, "verify.out"), "utf8");
  } catch {
    return "";
  }
}

/** One parked fix issue, through promote-findings.sh — the one writer of fix issues. */
function queueFixIssue(ctx, tracker, result, { category, detail }) {
  const { sprint, effects } = ctx;
  const criteriaPath = join(sprint.env.SPRINT_DIR, "integration-fix.criteria.md");
  writeFileSync(
    criteriaPath,
    integrationFixCriteria({ featureBranch: sprint.featureBranch, category, detail, tails: failureTails(effects.mainRoot, result) }),
  );
  const report = relative(effects.mainRoot, join(sprint.dispatchDir, INTEGRATION_STEM, "verify.out"));
  const defer = effects.bash(
    "promote-findings.sh",
    ["defer-integration", "--feature-slug", sprint.featureSlug, "--report", report, "--criteria-file", criteriaPath, "--at", result.commit.slice(0, 12)],
    { env: sprint.childEnv() },
  );
  const text = defer.stdout.trim() || defer.stderr.trim();
  if (defer.code !== 0) {
    const reason = `the fix issue was not created: ${defer.stderr.trim() || `exit ${defer.code}`}`;
    ctx.log(`[INTEGRATION-FIX] ${reason}`, "error");
    return { verdict: "not-fixable", reason };
  }
  ctx.log(`[INTEGRATION-FIX] ${text}`);
  if (/^defer-integration: skip/m.test(defer.stdout)) {
    return { verdict: "pending", reason: text.replace(/^defer-integration: skip — /, "") };
  }
  const ref = /^defer-integration: (.+)$/m.exec(defer.stdout)?.[1]?.trim() ?? text;
  const number = Number(/\/issues\/(\d+)\s*$/m.exec(defer.stdout)?.[1]) || null;
  // github creates the issue ready-for-agent (local parks it for the flush), and its listing lags.
  return { verdict: "queued", ref, number, queuedReady: tracker.fixIssuesCreatedReady };
}
