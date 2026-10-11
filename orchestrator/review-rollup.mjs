#!/usr/bin/env node
/**
 * review-rollup — the one parser of the aggregate review report file(s), for the bash scripts.
 * Usage: node review-rollup.mjs <report-file>...
 * Prints {"branches": [{branch, slug, verdict, detail, findings}, ...]}. Files fold in argument
 * order, so pass them sorted by creation (sprint-review-*.md names sort that way).
 */
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { foldDuplicates, foldReview, parseReviewAggregate } from "./lib/report.mjs";

function main(argv) {
  const files = argv.filter((f) => existsSync(f));
  const order = [];
  const byBranch = new Map();
  for (const file of files) {
    const text = readFileSync(file, "utf8");
    for (const rec of parseReviewAggregate(text)) {
      const key = rec.branch ?? `#${order.length}`;
      if (!byBranch.has(key)) order.push(key);
      byBranch.set(key, foldReview(byBranch.get(key), rec));
      // A whole-feature review that wrote its `feature` block covered every area, so an earlier
      // run's not-run `feature-<n>` gap is closed; a gap written after the block (same run) stays.
      if (rec.branch === "feature") {
        for (const k of [...byBranch.keys()]) {
          if (/^feature-\d+$/.test(k) && byBranch.get(k).verdict === "not_run") {
            byBranch.delete(k);
            order.splice(order.indexOf(k), 1);
          }
        }
      }
    }
  }
  // `raw` would duplicate each whole source block and buys jq/bash consumers nothing.
  const branches = order.map((key) => {
    const { branch, slug, verdict, detail, findings } = byBranch.get(key);
    // A finding triage folded into another (`duplicate_of`) is shown once, as its target.
    return { branch, slug, verdict, detail, findings: foldDuplicates(findings, findings) };
  });
  process.stdout.write(`${JSON.stringify({ branches })}\n`);
}

const isMain = process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1];
if (isMain) main(process.argv.slice(2));

export { main };
