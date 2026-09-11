#!/usr/bin/env node
/**
 * review-rollup — the one parser of the aggregate review report file(s), for the bash
 * scripts that used to each re-derive it by hand.
 *
 * crew-summary.sh's code_review_summary() and promote-findings.sh's remind both parsed
 * the same `reviews/sprint-review-*.md` files independently, each with its own
 * line-anchored awk. They drifted: a herdr-captured retry report that landed indented
 * and without a leading "##" matched neither awk's `^## Branch:`/`^AC:`/`^FINDING:`
 * anchors, so a genuinely successful review was reported as not-reviewed. Both callers
 * now shell out to this instead, over parseReviewAggregate — see report.mjs's doc
 * comment on that function for the fold semantics.
 *
 * Usage: node review-rollup.mjs <report-file>...
 * Prints one JSON object to stdout: {"branches": [{branch, slug, verdict, detail,
 * findings}, ...]}. Files are folded in argument order — pass them already sorted by
 * creation order (globbed sprint-review-*.md files sort that way by name) so a later
 * file's verdict for a branch overrides an earlier one's, the same as within one file.
 */
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { parseReviewAggregate } from "./lib/report.mjs";

function main(argv) {
  const files = argv.filter((f) => existsSync(f));
  const order = [];
  const byBranch = new Map();
  for (const file of files) {
    const text = readFileSync(file, "utf8");
    for (const rec of parseReviewAggregate(text)) {
      const key = rec.branch ?? `#${order.length}`;
      if (!byBranch.has(key)) order.push(key);
      byBranch.set(key, rec);
    }
  }
  // Only the fields callers actually need — `raw` duplicates the whole source block per
  // branch and buys jq/bash consumers nothing.
  const branches = order.map((key) => {
    const { branch, slug, verdict, detail, findings } = byBranch.get(key);
    return { branch, slug, verdict, detail, findings };
  });
  process.stdout.write(`${JSON.stringify({ branches })}\n`);
}

const isMain = process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1];
if (isMain) main(process.argv.slice(2));

export { main };
