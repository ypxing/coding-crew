/**
 * Findings triage: which review findings an unattended sprint fixes. At `afk.fixFindings:
 * actionable` (the default) that is every finding `crew-triage` judges Actionable, whatever its
 * severity; the severity values keep their old meaning and dispatch nothing.
 *
 * The judgement is a dispatch of its own, never the reviewer's: a review does not grade its own
 * findings. The hard rules (an ADR contradiction, a protected path) are applied here, in code, after
 * triage answers (report.mjs's applyFindingVerdicts). A triage that leaves no usable verdict — a
 * dead dispatch, a timeout, a spent `afk.limits.triage` cap, output that does not parse — falls
 * back to the `high` severity rule and is recorded on the sprint for the summary to say so.
 *
 * Shared by the per-branch promotion (review.mjs) and the feature review (feature-review.mjs).
 */

import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { dispatch } from "../dispatch.mjs";
import { findingsTriagePrompt } from "../prompts.mjs";
import { annotateFindings, applyFindingVerdicts, findingsAtOrAbove, foldDuplicates, parseFindingsTriage, promoteSeverities, severityNames } from "../report.mjs";
import { limitExceeded, readOnlyDispatch, readSidecar, roleBinding } from "./shared.mjs";

/** The severity rule a failed triage falls back to. */
export const FALLBACK_LEVEL = "high";

/**
 * What `defer --severities` records for a promotion made under `selected` (selectPromotable's
 * result): the level's own severities, the verdict `actionable`, or — triage having failed — the
 * severities of the fallback.
 */
export function promotedAs(fixFindings, selected) {
  if (fixFindings === "actionable" && selected.fallback) return severityNames(FALLBACK_LEVEL);
  return promoteSeverities(fixFindings);
}

/**
 * Pick the findings to promote.
 *
 * @param {object} ctx
 * @param {object} args
 * @param {object[]} args.findings  report.mjs's normalised findings of one review
 * @param {string} args.label       what is being triaged, for logs and the summary ("alpha", "feature")
 * @param {string} args.scope       one prompt line saying where the findings came from
 * @param {string} args.ref         the branch holding the code under review
 * @param {string} args.change      the git command that shows the reviewed change
 * @param {string} args.dir         where this review's dispatch files live
 * @param {string} args.dispatchSlug  the dispatch's slug (and its fake-dispatch fixture name)
 * @param {number} args.round
 * @param {string} args.ledgerSlug  the slug the dispatch's cost is booked under
 * @param {string} args.reportFile  the sprint review report holding the review's block
 * @param {object} args.written     the review's sidecar object exactly as written to that block
 * @returns {Promise<{promotable: object[], findings: object[], rule: string, fallback?: string}>}
 *   `rule` names what decided: "actionable", or the severity level; `findings` carry
 *   `verdict` and `rationale` when triage judged them.
 */
export async function selectPromotable(ctx, { findings, label, scope, ref, change, dir, dispatchSlug, round, ledgerSlug, reportFile, written }) {
  const { sprint } = ctx;
  const level = sprint.fixFindings;
  if (level !== "actionable") return { promotable: findingsAtOrAbove(findings, level), findings, rule: level };
  // Nothing to judge: no dispatch, and no reason to call it a fallback.
  if (!findings.length) return { promotable: [], findings, rule: "actionable" };

  const triage = await runFindingsTriage(ctx, { findings, scope, ref, change, dir, dispatchSlug, round, ledgerSlug });
  if (triage.failed) {
    sprint.triageFallbacks.push({ scope: label, reason: triage.failed });
    ctx.log(`FINDINGS-TRIAGE: ${label}: no usable verdict — ${triage.failed}; the ${FALLBACK_LEVEL} rule applies`, "warn");
    return { promotable: findingsAtOrAbove(findings, FALLBACK_LEVEL), findings, rule: FALLBACK_LEVEL, fallback: triage.failed };
  }

  const judged = applyFindingVerdicts(findings, triage.verdicts);
  writeVerdicts(reportFile, written, annotateFindings(written, judged));
  const count = (v) => judged.filter((f) => f.verdict === v).length;
  ctx.log(`FINDINGS-TRIAGE: ${label}: ${count("actionable")} actionable, ${count("debatable")} debatable`);
  return { promotable: foldDuplicates(judged, judged.filter((f) => f.verdict === "actionable")), findings: judged, rule: "actionable" };
}

/** Dispatched to `crew-triage` in findings mode. Returns `{verdicts}` or `{failed: reason}`. */
async function runFindingsTriage(ctx, { findings, scope, ref, change, dir, dispatchSlug, round, ledgerSlug }) {
  const { sprint, effects, options } = ctx;
  mkdirSync(dir, { recursive: true });
  const promptFile = join(dir, "findings-triage-prompt.md");
  const outFile = join(dir, "findings-triage.md");
  const sidecarFile = join(dir, "findings-triage.report.json");
  // A stale sidecar at this fixed path must not be read back as this dispatch's verdicts.
  rmSync(sidecarFile, { force: true });
  writeFileSync(promptFile, findingsTriagePrompt({ scope, ref, change, findings, reportPath: sidecarFile }));

  const triage = roleBinding(ctx, "triage");
  ctx.log(`[STEP] slug=${dispatchSlug} round=${round} step=dispatch-findings-triage model=${triage.model ?? "inherit"} runtime=${triage.runtime}`);
  const guarded = await readOnlyDispatch(ctx, { label: `findings-triage ${dispatchSlug}`, ...(ref === sprint.featureBranch ? {} : { branches: [ref] }) }, () => dispatch(
    effects,
    triage.runtime,
    {
      agent: "crew-triage",
      cwd: effects.mainRoot,
      promptFile,
      outFile,
      model: triage.model,
      mainRoot: effects.mainRoot,
      logFile: sprint.traceLog,
      featureSlug: sprint.featureSlug,
      slug: dispatchSlug,
      round,
      reportPath: sidecarFile,
      maxBudgetUsd: triage.maxBudgetUsd,
    },
    {
      timeoutMs: options.timeoutMs.triage,
      onTrace: (line) => ctx.heartbeat(`slug=${dispatchSlug} round=${round} ${line}`),
    },
  ));
  const result = guarded.result;
  if (result) sprint.recordDispatchCost(result, { slug: ledgerSlug, role: "triage", attempt: round });
  if (guarded.violation) return { failed: guarded.violation };

  const capped = limitExceeded(result, "triage", triage);
  if (capped) return { failed: capped };
  if (result.timedOut) return { failed: "the triage dispatch timed out" };
  const parsed = parseFindingsTriage(readSidecar(sidecarFile), findings.length);
  return parsed.ok ? { verdicts: parsed.verdicts } : { failed: parsed.detail };
}

/** Replace the review's block in the sprint review report with its verdict-bearing twin. */
function writeVerdicts(reportFile, written, annotated) {
  if (!existsSync(reportFile)) return;
  const text = readFileSync(reportFile, "utf8");
  const old = JSON.stringify(written);
  const at = text.lastIndexOf(old);
  if (at < 0) return;
  writeFileSync(reportFile, `${text.slice(0, at)}${JSON.stringify(annotated)}${text.slice(at + old.length)}`);
}
