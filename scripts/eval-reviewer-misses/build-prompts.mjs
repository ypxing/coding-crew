#!/usr/bin/env node
// build-prompts.mjs <tree> — the crew-review prompt of ONE ref, built from that ref's own files, so
// the reviewer's instructions are the ref's, never the head's: its skills/crew-review/SKILL.md, or before
// the rename review-pr's reviewer-prompt.md, or before that file existed, review-pr.sh's heredoc.
// stdin: JSON {mode, base, tip, branch, slug, issue, criteria, notes?, prdPath?, prdText, reportPath};
// stdout: JSON {role, reviews: [{name, prompt}]}.

import { execFileSync } from "node:child_process";

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const tree = path.resolve(process.argv[2]);
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

process.stdout.write(JSON.stringify({ role: "", reviews: [{ name: "crew-review", prompt: crewReviewPrompt() }] }));
