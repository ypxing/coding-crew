/**
 * The tracker boundary: orchestrator code learns a feature's issues only from its tracker backend.
 * `.scratch/<slug>/issues/` is `trackers/local.mjs`'s storage, so no other orchestrator file may
 * build a path into it, and none outside `trackers/` may branch on which backend it got by
 * probing for `listOpenIssueFiles` — `listFeatureIssues` and `fixIssuesCreatedReady` are the
 * surface both backends share.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const REPO = join(dirname(fileURLToPath(import.meta.url)), "../..");
const ORCHESTRATOR = join(REPO, "orchestrator");

/** Source with its comments blanked (line numbers kept): a `/* … *\/` block, and `//` to end of line where it opens a comment. */
export function stripComments(source) {
  return source.replace(/\/\*[\s\S]*?\*\//g, (block) => block.replace(/[^\n]/g, "")).replace(/(^|[\s;,(){}])\/\/.*$/gm, "$1");
}

const ISSUE_DIR_READS = [
  /["'`]issues["'`]/, // join(mainRoot, ".scratch", slug, "issues", …)
  /\bissues[\\/]+(?:open|done)\b/, // "issues/open", `…/issues/done`
  /\.scratch[\\/][^"'`\s]*[\\/]issues\b/, // `.scratch/${slug}/issues`
];

/** The lines of `source` (comments aside) that read a local issue directory, as `n: text`. */
export function issueDirReads(source) {
  return stripComments(source)
    .split("\n")
    .flatMap((line, i) => (ISSUE_DIR_READS.some((re) => re.test(line)) ? [`${i + 1}: ${line.trim()}`] : []));
}

/** The lines of `source` (comments aside) that probe a tracker for `listOpenIssueFiles`. */
export function backendProbes(source) {
  return stripComments(source)
    .split("\n")
    .flatMap((line, i) => (/\btracker\??\.listOpenIssueFiles\b/.test(line) ? [`${i + 1}: ${line.trim()}`] : []));
}

function sources(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    const p = join(dir, e.name);
    if (e.isDirectory()) return sources(p);
    return e.name.endsWith(".mjs") ? [p] : [];
  });
}

const rel = (p) => relative(REPO, p).split("\\").join("/");

test("no orchestrator file but trackers/local.mjs reads .scratch/<slug>/issues/", () => {
  const offenders = sources(ORCHESTRATOR)
    .filter((p) => rel(p) !== "orchestrator/lib/trackers/local.mjs")
    .flatMap((p) => issueDirReads(readFileSync(p, "utf8")).map((l) => `${rel(p)}:${l}`));
  assert.deepEqual(offenders, [], `issue files read outside the local backend:\n${offenders.join("\n")}`);
});

test("no orchestrator file outside trackers/ branches on tracker.listOpenIssueFiles", () => {
  const offenders = sources(ORCHESTRATOR)
    .filter((p) => !rel(p).startsWith("orchestrator/lib/trackers/"))
    .flatMap((p) => backendProbes(readFileSync(p, "utf8")).map((l) => `${rel(p)}:${l}`));
  assert.deepEqual(offenders, [], `backend probes outside trackers/:\n${offenders.join("\n")}`);
});

test("the scan catches each way of naming an issue dir, and ignores comments and GitHub API paths", () => {
  for (const code of [
    'const d = join(mainRoot, ".scratch", featureSlug, "issues", dir);',
    "const d = `${root}/.scratch/${slug}/issues`;",
    'readdirSync(join(root, "x/issues/done"));',
    "const open = 'issues/open';",
  ]) {
    assert.equal(issueDirReads(code).length, 1, code);
  }
  for (const code of [
    '// join(mainRoot, ".scratch", featureSlug, "issues", dir)',
    '/* see .scratch/demo/issues/open/ */ const x = 1;',
    "/**\n * a sibling of `.scratch/<slug>/issues/open/`\n */\nconst y = 2;",
    'const x = 1; // reads issues/done',
    "exec(\"gh\", [\"api\", `${apiBase}/issues/${blocker}`]);",
    'const url = "https://github.com/o/r/issues/1";',
  ]) {
    assert.deepEqual(issueDirReads(code), [], code);
  }
  assert.equal(backendProbes("if (!tracker.listOpenIssueFiles) unseen.add(ref);").length, 1);
  assert.deepEqual(backendProbes("// tracker.listOpenIssueFiles used to decide"), []);
});
