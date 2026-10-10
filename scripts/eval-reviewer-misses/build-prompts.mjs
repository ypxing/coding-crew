#!/usr/bin/env node
// build-prompts.mjs <tree> — the review prompts of ONE ref, built from that ref's own modules.
//
// eval-reviewer-misses.mjs runs this once per ref with <tree> = that ref's checkout, so the prompt
// builders (orchestrator/lib/prompts.mjs) and the rendered reviewer role are the ref's, never the
// head's. stdin: JSON {mode, base, tip, branch, slug, issue, criteria, notes?, prdPath?, prdText, reportPath};
// stdout: JSON {role, reviews: [{name, prompt}]}. A feature case is one whole-feature reviewer given
// the PRD's path (`prdPath`, else `prdText` written to a temp file) and the case's `notes` (a ref whose
// featureReviewPrompt predates them ignores them); a branch case is the
// criteria-only branch review.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";

const tree = path.resolve(process.argv[2]);
const load = (rel) => import(pathToFileURL(path.join(tree, rel)).href);
const [prompts, render] = await Promise.all([
  load("orchestrator/lib/prompts.mjs"),
  load("orchestrator/lib/adapters/render.mjs"),
]);
const inp = JSON.parse(fs.readFileSync(0, "utf8"));

const reviewAssets = path.join(tree, "orchestrator", "roles", "reviewer");
const role = render.renderRolePrompt("reviewer", "claude", { mainRoot: null });
const out = { role, reviews: [] };

if (inp.mode === "branch") {
  out.reviews.push({
    name: inp.slug,
    prompt: prompts.reviewPrompt({
      branch: inp.tip, slug: inp.slug, issuePath: inp.issue, criteria: inp.criteria,
      featureBranch: inp.base, checks: { test: "pass", lint: "pass", typecheck: "pass" },
      reportPath: inp.reportPath, reviewAssets,
    }),
  });
} else {
  let prdPath = inp.prdPath ?? null;
  if (!prdPath && inp.prdText) {
    prdPath = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "eval-prd-")), "PRD.md");
    fs.writeFileSync(prdPath, `${inp.prdText}\n`);
  }
  out.reviews.push({
    name: prompts.FEATURE_REVIEW ?? "feature",
    prompt: prompts.featureReviewPrompt({ featureBranch: inp.tip, base: inp.base, reportPath: inp.reportPath, reviewAssets, prdPath, notes: inp.notes ?? [] }),
  });
}
process.stdout.write(JSON.stringify(out));
