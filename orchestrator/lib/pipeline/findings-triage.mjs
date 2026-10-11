/**
 * Findings triage: which review findings an unattended sprint fixes. Under `fixFindings: actionable`
 * that is every finding `crew-triage` judges Actionable — a dispatch of its own, since a review does
 * not grade its own findings. A triage with no usable verdict falls back to the `high` severity rule.
 */

import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { dispatch } from "../dispatch.mjs";
import { findingsTriagePrompt } from "../prompts.mjs";
import { annotateFindings, applyFindingVerdicts, findingsAtOrAbove, foldDuplicates, parseFindingsTriage, promoteSeverities, severityNames } from "../report.mjs";
import { limitExceeded, readOnlyDispatch, readSidecar, roleBinding } from "./shared.mjs";

export const FALLBACK_LEVEL = "high";

/** The level's own severities, or the fallback's when triage failed. */
export function promotedAs(fixFindings, selected) {
  if (fixFindings === "actionable" && selected.fallback) return severityNames(FALLBACK_LEVEL);
  return promoteSeverities(fixFindings);
}

/**
 * `rule` names what decided ("actionable" or the severity level); `findings` carry `verdict` and
 * `rationale` when triage judged them.
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
      cwd: effects.featureRoot,
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
      effort: triage.effort,
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

function writeVerdicts(reportFile, written, annotated) {
  if (!existsSync(reportFile)) return;
  const text = readFileSync(reportFile, "utf8");
  const old = JSON.stringify(written);
  const at = text.lastIndexOf(old);
  if (at < 0) return;
  writeFileSync(reportFile, `${text.slice(0, at)}${JSON.stringify(annotated)}${text.slice(at + old.length)}`);
}
