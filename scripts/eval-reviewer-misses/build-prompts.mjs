#!/usr/bin/env node
// build-prompts.mjs <tree> — the review prompts of ONE ref, built from that ref's own modules.
//
// eval-reviewer-misses.mjs runs this once per ref with <tree> = that ref's checkout, so the prompt
// builders (orchestrator/lib/prompts.mjs, pipeline/feature-areas.mjs, prd-decisions.mjs) and the
// rendered reviewer role are the ref's, never the head's. stdin: JSON
// {mode, base, tip, branch, slug, criteria, prdPath, prdText, implements, areas?, max}; stdout: JSON
// {role, planner?, diffFiles, reviews: [{name, prompt}]}. `areas` is the planner's raw answer;
// without it a feature case gets one whole-feature area (what a failed planner falls back to).

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const tree = path.resolve(process.argv[2]);
const load = (rel) => import(pathToFileURL(path.join(tree, rel)).href);
const [prompts, areasMod, decMod, render] = await Promise.all([
  load("orchestrator/lib/prompts.mjs"),
  load("orchestrator/lib/pipeline/feature-areas.mjs"),
  load("orchestrator/lib/prd-decisions.mjs"),
  load("orchestrator/lib/adapters/render.mjs"),
]);
const inp = JSON.parse(fs.readFileSync(0, "utf8"));

const git = (args) => {
  const r = spawnSync("git", args, { cwd: tree, encoding: "utf8" });
  return { code: r.status ?? 1, stdout: r.stdout ?? "" };
};
const names = (r) => (r.code === 0 ? r.stdout : "").split("\0").filter(Boolean);
const DIFF = ["-c", "core.quotePath=false", "diff", "--no-renames"];

const reviewAssets = path.join(tree, "orchestrator", "roles", "reviewer");
const role = render.renderRolePrompt("reviewer", "claude", { mainRoot: null });
const decisions = decMod.parsePrdDecisions(inp.prdText);
const out = { role, diffFiles: [], reviews: [] };

if (inp.mode === "branch") {
  const lines = decMod.implementedIds(`## Implements\n\n${inp.implements}\n`).map((id) => decisions.get(id)).filter(Boolean);
  out.reviews.push({
    name: inp.slug,
    prompt: prompts.reviewPrompt({
      branch: inp.tip, slug: inp.slug, issuePath: inp.issue, criteria: inp.criteria, prdDecisions: lines,
      featureBranch: inp.base, checks: { test: "pass", lint: "pass", typecheck: "pass" },
      reportPath: inp.reportPath, reviewAssets,
    }),
  });
} else {
  const ids = [...decisions.keys()];
  const diffFiles = names(git([...DIFF, "--name-only", "-z", `${inp.base}..${inp.tip}`]));
  out.diffFiles = diffFiles;
  const stat = git([...DIFF, "--stat=1000", "--stat-name-width=1000", `${inp.base}..${inp.tip}`]).stdout;
  const ctx = { effects: { gitRead: (a) => git(a) } };
  out.planner = areasMod.plannerPrompt({
    featureBranch: inp.tip, base: inp.base, max: inp.max, stat,
    issues: areasMod.mergedIssues(ctx, { base: inp.base, tip: inp.tip }), decisions,
  });
  let areas = [];
  if (inp.areas) areas = areasMod.normalizeAreas(inp.areas, { diffFiles, decisionIds: ids, max: inp.max });
  if (!areas.length) areas = [areasMod.wholeFeatureArea(diffFiles, ids)];
  out.areas = areas;
  out.reviews = areas.map((area, i) => ({
    name: `feature-${i + 1}`,
    prompt: prompts.featureReviewPrompt({
      featureBranch: inp.tip, base: inp.base, reportPath: inp.reportPath, reviewAssets, area,
      decisions: area.decisions.map((id) => decisions.get(id)).filter(Boolean),
    }),
  }));
}
process.stdout.write(JSON.stringify(out));
