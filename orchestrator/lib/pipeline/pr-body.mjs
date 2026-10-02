/**
 * The PR body: the prWriter role, a plain dispatch that follows write-pr's SKILL.md (installed
 * as an asset beside crew-afk) over the feature's whole range, once, just before open-pr.sh. It
 * gives a human reviewer the change's shape (Summary), why to believe it (Evidence) and what a
 * bad merge breaks (Merge Danger). The checks line is written here, from the integration check's
 * own record, so the body never states a result no check produced. Advisory: a writer that
 * leaves no usable body never stops the PR — it opens with the checks line alone.
 */

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { dispatchPlain } from "../dispatch.mjs";
import { assetDir } from "../install-dir.mjs";
import { INTEGRATION_STEM } from "../preflight.mjs";
import { prBodyPrompt } from "../prompts.mjs";
import { CHECK_CATEGORIES, readVerifyRecord } from "../report.mjs";
import { roleBinding } from "./shared.mjs";

/**
 * What the integration check proved, as one line (`test pass, lint pass`), or null when it did
 * not run — off, a dry run, or a worktree it could not create. Only reached when it is not red.
 */
export function checksLine(sprint, integration) {
  if (integration?.status !== "pass" || integration.reason) return null;
  const { checks } = readVerifyRecord(join(sprint.dispatchDir, INTEGRATION_STEM, "verify.json"));
  const ran = CHECK_CATEGORIES.filter((c) => checks[c] !== "not_run").map((c) => `${c} ${checks[c]}`);
  return ran.length ? ran.join(", ") : "pass";
}

/** The writer's answer from its first `## Summary` line, or null when it has none. */
export function extractBody(text) {
  const at = (text ?? "").search(/^## Summary\b/m);
  return at < 0 ? null : `${text.slice(at).trimEnd()}\n`;
}

/** The writer's `# <title>` — the last `# ` line before its `## Summary` — or null. */
export function extractTitle(text) {
  const at = (text ?? "").search(/^## Summary\b/m);
  if (at < 0) return null;
  const titles = [...text.slice(0, at).matchAll(/^#\s+(.+)$/gm)].map((m) => m[1].trim()).filter(Boolean);
  return titles.at(-1) ?? null;
}

/** The PRD's first `# ` heading, without a `PRD:` prefix — the PR's title — or null. */
export function prdTitle(prdFile) {
  if (!prdFile) return null;
  const m = /^#\s+(.+)$/m.exec(readFileSync(prdFile, "utf8"));
  return m ? m[1].replace(/^PRD:\s*/i, "").trim() || null : null;
}

/**
 * Writes `<SPRINT_DIR>/pr-body.md` and returns `{ file, title, failed }`: `title` the writer's,
 * else the PRD's, else null (open-pr.sh then uses the slug), `failed` why the body has no writer prose (null when it has), for the summary. Null on a
 * dry run.
 */
export async function writePrBody(ctx, { integration = null } = {}) {
  const { sprint, effects, options } = ctx;
  const checks = checksLine(sprint, integration);
  const file = join(sprint.env.SPRINT_DIR, "pr-body.md");
  const facts = `**Checks on the merged branch:** ${checks ?? "not run"}\n`;
  const scratch = join(effects.mainRoot, ".scratch", sprint.featureSlug);
  const prd = ["PRD.md", "prd-issue.md"].map((f) => join(scratch, f)).find((p) => existsSync(p)) ?? null;
  const finish = (prose, failed, title = null) => {
    writeFileSync(file, prose ? `${prose}\n${facts}` : facts);
    if (failed) ctx.log(`PR body: ${failed}`, "warn");
    return { file, title: title ?? prdTitle(prd), failed };
  };

  const base = sprint.readState().branches?.[sprint.featureBranch]?.base_sha;
  if (!base) return finish(null, `no base commit recorded for ${sprint.featureBranch}, so there is no range to describe.`);
  const skillFile = sprint.installDir ? join(assetDir(sprint.installDir, "writePr"), "SKILL.md") : null;
  if (!skillFile || !existsSync(skillFile)) return finish(null, `write-pr's SKILL.md is not installed (${skillFile ?? "no install dir"}).`);

  const reviewReport = ctx.roundReviewFile?.();
  const prompt = prBodyPrompt({
    skillFile,
    featureBranch: sprint.featureBranch,
    base,
    prd,
    reviewReport: reviewReport && existsSync(reviewReport) ? reviewReport : null,
    checks,
  });

  const writer = roleBinding(ctx, "prWriter");
  ctx.log(`[STEP] step=pr-body model=${writer.model ?? "inherit"} runtime=${writer.runtime}`);
  const r = await dispatchPlain(effects, writer.runtime, {
    prompt,
    cwd: effects.mainRoot,
    mainRoot: effects.mainRoot,
    model: writer.model,
    outFile: join(sprint.env.SPRINT_DIR, "pr-writer.md"),
    timeoutMs: options.timeoutMs.prWriter,
    maxBudgetUsd: writer.maxBudgetUsd,
    fakeAgent: "pr-writer",
  });
  if (r.dryRun) return null;
  if (r.code !== 0 || r.timedOut) return finish(null, `the writer did not complete (${r.timedOut ? "timed out" : `exit ${r.code}`}).`);
  const prose = extractBody(r.text);
  return prose ? finish(prose, null, extractTitle(r.text)) : finish(null, "the writer's answer has no `## Summary` section.");
}
