#!/usr/bin/env node
// build-prompts.mjs <tree> — the crew-review prompt of ONE ref, built from that ref's own files, so
// the reviewer's instructions are the ref's, never the head's: its skills/crew-review/SKILL.md.
// stdin: JSON {mode, base, tip, branch, slug, issue, criteria, notes?, prdPath?, prdText, reportPath};
// stdout: JSON {role, reviews: [{name, prompt}]}.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const tree = path.resolve(process.argv[2]);
const inp = JSON.parse(fs.readFileSync(0, "utf8"));

// The case is not a GitHub PR: its spec (the PRD, and a branch case's criteria) is a file.
function crewReviewPrompt() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "eval-crew-review-"));
  const spec = path.join(dir, "spec.md");
  fs.writeFileSync(spec, [inp.prdText, inp.criteria && `## Acceptance criteria\n\n${inp.criteria}`].filter(Boolean).join("\n\n") + "\n");
  const skill = path.join(tree, "skills", "crew-review", "SKILL.md");
  return `Review branch HEAD, base ${inp.base} (the change is \`git diff ${inp.base}..HEAD\`), against the spec in ${spec} ` +
    `following the Review section of ${skill}. You are the reviewer: start no subagent. Write the report to ${inp.reportPath}.`;
}

process.stdout.write(JSON.stringify({ role: "", reviews: [{ name: "crew-review", prompt: crewReviewPrompt() }] }));
