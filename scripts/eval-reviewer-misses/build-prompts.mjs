#!/usr/bin/env node
// build-prompts.mjs <tree> — the review prompts of ONE ref, built from that ref's own modules, so
// the prompt builders and rendered reviewer role are the ref's, never the head's.
// stdin: JSON {mode, base, tip, branch, slug, issue, criteria, notes?, prdPath?, prdText, reportPath, reviewer?};
// stdout: JSON {role, reviews: [{name, prompt}]}. reviewer "crew-review" builds crew-review's prompt instead of
// crew-afk's: the ref's skills/crew-review/SKILL.md, or before the rename review-pr's reviewer-prompt.md, or before
// that file existed, review-pr.sh's heredoc.

import { execFileSync } from "node:child_process";

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";

const tree = path.resolve(process.argv[2]);
const load = (rel) => import(pathToFileURL(path.join(tree, rel)).href);
const inp = JSON.parse(fs.readFileSync(0, "utf8"));

// The case is not a GitHub PR: its spec (the PRD, and a branch case's criteria) and its diff are files.
function crewReviewPrompt() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "eval-crew-review-"));
  const spec = path.join(dir, "spec.md"), diff = path.join(dir, "pr.diff");
  fs.writeFileSync(spec, [inp.prdText, inp.criteria && `## Acceptance criteria\n\n${inp.criteria}`].filter(Boolean).join("\n\n") + "\n");
  const skill = path.join(tree, "skills", "crew-review", "SKILL.md");
  if (fs.existsSync(skill)) {
    return `Review branch HEAD, base ${inp.base} (the change is \`git diff ${inp.base}..HEAD\`), against the spec in ${spec} ` +
      `following the Review section of ${skill}. You are the reviewer: start no subagent. Write the report to ${inp.reportPath}.`;
  }
  fs.writeFileSync(diff, execFileSync("git", ["diff", `${inp.base}..${inp.tip}`], { cwd: tree, maxBuffer: 1 << 28 }));
  const file = path.join(tree, "skills", "review-pr", "reviewer-prompt.md");
  if (fs.existsSync(file)) {
    return `Review PR #0 following ${file}. Write your report to ${inp.reportPath}.\n` +
      `This PR is not on GitHub: instead of \`gh pr view\`, its spec is ${spec}; instead of \`gh pr diff\`, its diff is ${diff} (\`git diff ${inp.base}..${inp.tip}\`).`;
  }
  const sh = fs.readFileSync(path.join(tree, "skills", "review-pr", "scripts", "review-pr.sh"), "utf8");
  const body = sh.match(/cat >"\$PROMPT" <<EOF\n([\s\S]*?)\nEOF\n/)?.[1];
  if (!body) throw new Error("no reviewer prompt in review-pr.sh");
  const vars = { PR: "0", URL: "(not on GitHub)", SPEC: spec, DIFF: diff, REPORT: inp.reportPath };
  return body.replace(/\$(PR|URL|SPEC|DIFF|REPORT)\b/g, (_, k) => vars[k]);
}

if (inp.reviewer === "crew-review") {
  process.stdout.write(JSON.stringify({ role: "", reviews: [{ name: "crew-review", prompt: crewReviewPrompt() }] }));
  process.exit(0);
}

const [prompts, render] = await Promise.all([
  load("orchestrator/lib/prompts.mjs"),
  load("orchestrator/lib/adapters/render.mjs"),
]);

const reviewAssets = path.join(tree, "orchestrator", "roles", "reviewer");
// A feature case also gets the feature part (a ref that predates the split ignores `part`).
const role = render.renderRolePrompt("reviewer", "claude", { mainRoot: null, ...(inp.mode === "branch" ? {} : { part: "feature" }) });
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
