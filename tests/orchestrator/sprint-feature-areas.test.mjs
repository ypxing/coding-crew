/**
 * Sprint suite — the feature review's areas: the planner, the area reviewers, one merged block.
 * Shared helpers: ./helpers/sprint.mjs.
 */

import assert from "node:assert/strict";
import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { default as nodeTest } from "node:test";
import { sh, fixtureRepo, addIssue, traceLog, state, fake, commandLines, featureReviewFile, crossIssue, sprintReport, test } from "./helpers/sprint.mjs";
import { implementsLookup, normalizeAreas, parsePlannerAnswer, plannerPrompt } from "../../orchestrator/lib/pipeline/feature-areas.mjs";
import { featureReviewPrompt } from "../../orchestrator/lib/prompts.mjs";

const areaReviews = (lines) => lines.filter((l) => /^SPAWN .*--agent crew-reviewer.* --slug feature-\d+( |$)/.test(l));
const planners = (lines) => lines.filter((l) => /^SPAWN .*--agent feature-planner/.test(l));
const plan = (root, areas) => fake(root, "feature-planner.response", `Plan:\n\`\`\`json\n${JSON.stringify({ areas })}\n\`\`\`\n`);

const PRD = ["# PRD", "", "- **D1** — Retries are bounded.", "- **D2** — Errors name the file.", ""].join("\n");

/** A repo with a PRD and two issues, alpha implementing D1 and beta D2. */
function twoIssues() {
  const root = fixtureRepo();
  writeFileSync(join(root, ".scratch/demo/PRD.md"), PRD);
  addIssue(root, "01-alpha.md", { body: "## Implements\n\nD1\n" });
  addIssue(root, "02-beta.md", { body: "## Implements\n\nD2\n" });
  return root;
}

test("the planner is dispatched once, with the stat, each issue's files and IDs, and the decision lines", () => {
  const root = twoIssues();
  const { r, lines } = commandLines(root, ["--max-parallel", "2"]);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(planners(lines).length, 1);
  const prompt = readFileSync(join(root, ".scratch/demo/dispatch/feature-plan/planner.md.prompt.md"), "utf8");
  assert.match(prompt, /src\/alpha\.txt\s+\|/);
  assert.match(prompt, /crew\/demo\/alpha: files src\/alpha\.txt; implements D1/);
  assert.match(prompt, /crew\/demo\/beta: files src\/beta\.txt; implements D2/);
  assert.match(prompt, /^- \*\*D1\*\* — Retries are bounded\.$/m);
  assert.match(prompt, /^- \*\*D2\*\* — Errors name the file\.$/m);
});

test("the planner's diff stat names a long path in full, not as .../name", () => {
  const root = fixtureRepo();
  writeFileSync(join(root, ".scratch/demo/PRD.md"), PRD);
  const long = "a-very-long-issue-slug-whose-changed-file-path-runs-well-past-the-default-stat-width";
  addIssue(root, `01-${long}.md`, { body: "## Implements\n\nD1\n" });
  const { r } = commandLines(root, ["--max-parallel", "2"]);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const prompt = readFileSync(join(root, ".scratch/demo/dispatch/feature-plan/planner.md.prompt.md"), "utf8");
  assert.match(prompt, new RegExp(` src/${long}\\.txt\\s+\\|`));
  assert.doesNotMatch(prompt, /^ \.\.\.\//m);
});

test("K valid areas give K concurrent reviewers with their own dir, report and cost; one feature block; one promotion", () => {
  const root = twoIssues();
  plan(root, [
    { name: "alpha flow", files: ["src/alpha.txt"], decisions: ["D1"] },
    { name: "beta flow", files: ["src/beta.txt"], decisions: ["D2"] },
  ]);
  fake(root, "feature-1.review", featureReviewFile([crossIssue("HIGH", "Bound the alpha retry")]));
  fake(root, "feature-2.review", featureReviewFile([crossIssue("HIGH", "Name the file in beta's error")]));
  const { r, lines } = commandLines(root, ["--max-parallel", "2"]);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(areaReviews(lines).length, 2);
  for (const n of [1, 2]) {
    assert.ok(readFileSync(join(root, `.scratch/demo/dispatch/feature-${n}/review-prompt.md`), "utf8").includes("Area:"));
    readFileSync(join(root, `.scratch/demo/dispatch/feature-${n}/review.report.json`), "utf8");
  }
  const slugs = state(root).dispatches.map((d) => d.slug);
  assert.ok(slugs.includes("feature-1") && slugs.includes("feature-2"), slugs.join());
  const report = sprintReport(root);
  assert.equal(report.match(/^## Branch: feature \(feature\)$/gm).length, 1);
  assert.match(report, /Bound the alpha retry/);
  assert.match(report, /Name the file in beta's error/);
  assert.equal(lines.filter((l) => /^SPAWN .*--agent crew-triage.* --slug feature-findings/.test(l)).length, 1);
  assert.equal(readdirSync(join(root, ".scratch/demo/issues/done")).filter((f) => /fix-findings-feature/.test(f)).length, 1);
});

test("an answer with more areas than maxParallel is merged down to maxParallel", () => {
  const root = twoIssues();
  plan(root, [
    { name: "a", files: ["src/alpha.txt"], decisions: ["D1"] },
    { name: "b", files: ["src/beta.txt"], decisions: ["D2"] },
  ]);
  const { r, lines } = commandLines(root, ["--max-parallel", "1"]);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(areaReviews(lines).length, 1);
  const prompt = readFileSync(join(root, ".scratch/demo/dispatch/feature-1/review-prompt.md"), "utf8");
  assert.match(prompt, /- src\/alpha\.txt/);
  assert.match(prompt, /- src\/beta\.txt/);
  assert.match(prompt, /^- \*\*D1\*\* — Retries are bounded\.$/m);
  assert.match(prompt, /^- \*\*D2\*\* — Errors name the file\.$/m);
});

test("a planner that fails, or answers with no json or no areas, gives one whole-diff area and logs why", () => {
  for (const [label, setup, why] of [
    ["no json", () => {}, /no fenced json block/],
    ["zero areas", (root) => plan(root, []), /no usable area/],
    ["bad paths only", (root) => plan(root, [{ name: "x", files: ["nope.txt"], decisions: [] }]), /no usable area/],
    ["exit", (root) => fake(root, "feature-planner.exit", "3"), /planner exited 3/],
  ]) {
    const root = twoIssues();
    setup(root);
    const { r, lines } = commandLines(root, ["--max-parallel", "3"]);
    assert.equal(r.code, 0, `${label}: ${r.stdout}\n${r.stderr}`);
    assert.equal(areaReviews(lines).length, 1, label);
    const prompt = readFileSync(join(root, ".scratch/demo/dispatch/feature-1/review-prompt.md"), "utf8");
    assert.match(prompt, /- src\/alpha\.txt/, label);
    assert.match(prompt, /- src\/beta\.txt/, label);
    assert.match(prompt, /\*\*D1\*\*[\s\S]*\*\*D2\*\*/, label);
    assert.match(traceLog(root), new RegExp(`FEATURE-REVIEW: planner fallback — .*${why.source}`), label);
  }
});

test("a planner that times out falls back to one whole-diff area and logs why", () => {
  const root = twoIssues();
  fake(root, "feature-planner.sleep", "10");
  const { r, lines } = commandLines(root, ["--reviewer-timeout", "0.02"]);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(planners(lines).length, 1);
  assert.equal(areaReviews(lines).length, 1);
  const prompt = readFileSync(join(root, ".scratch/demo/dispatch/feature-1/review-prompt.md"), "utf8");
  assert.match(prompt, /- src\/alpha\.txt/);
  assert.match(prompt, /- src\/beta\.txt/);
  assert.match(traceLog(root), /FEATURE-REVIEW: planner fallback — the planner timed out/);
});

test("one failed area is recorded not-run as feature-<n>; the others' findings are still reported and promoted", () => {
  const root = twoIssues();
  plan(root, [
    { name: "alpha flow", files: ["src/alpha.txt"], decisions: ["D1"] },
    { name: "beta flow", files: ["src/beta.txt"], decisions: ["D2"] },
  ]);
  fake(root, "feature-1.review", "");
  fake(root, "feature-2.review", featureReviewFile([crossIssue("HIGH", "Name the file in beta's error")]));
  const { r } = commandLines(root, ["--max-parallel", "2"]);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const report = sprintReport(root);
  assert.match(report, /^## Branch: feature-1 \(feature-1\)$/m);
  assert.match(report, /^## Branch: feature \(feature\)$/m);
  assert.match(report, /Name the file in beta's error/);
  assert.match(r.stdout, /- feature-1: not-reviewed/);
  assert.match(r.stdout, /\*\*Not run \(1 of 2 area reviewers\):\*\*/);
  assert.ok(readdirSync(join(root, ".scratch/demo/issues/done")).some((f) => /fix-findings-feature/.test(f)));
  assert.equal(state(root).feature_review, undefined, "an area gap leaves no reviewed tip, so the next run reviews it again");
});

test("an incremental review dispatches no planner and one reviewer", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const first = commandLines(root);
  assert.equal(first.r.code, 0, `${first.r.stdout}\n${first.r.stderr}`);
  assert.equal(planners(first.lines).length, 1);
  // New commit on the feature branch: the next run reviews only it.
  sh("git", ["-C", root, "checkout", "-q", "feature/demo"]);
  writeFileSync(join(root, "later.txt"), "later\n");
  sh("git", ["-C", root, "add", "-A"]);
  sh("git", ["-C", root, "commit", "-q", "-m", "later"]);
  addIssue(root, "02-beta.md");
  const again = commandLines(root);
  assert.equal(again.r.code, 0, `${again.r.stdout}\n${again.r.stderr}`);
  assert.equal(planners(again.lines).length, 0);
  assert.equal(areaReviews(again.lines).length, 1);
  assert.doesNotMatch(readFileSync(join(root, ".scratch/demo/dispatch/feature-1/review-prompt.md"), "utf8"), /^Area:/m);
});

// ─── pure pieces ──────────────────────────────────────────────────────────────────────

const ctx = { diffFiles: ["a.js", "b.js", "c.js"], decisionIds: ["D1", "D2"], max: 3 };

nodeTest("normalizeAreas drops unknown paths and IDs, and an area left with no file", () => {
  const areas = normalizeAreas(
    [
      { name: "one", files: ["a.js", "ghost.js"], decisions: ["D1", "D9"] },
      { name: "empty", files: ["ghost.js"], decisions: ["D2"] },
    ],
    ctx,
  );
  assert.equal(areas.length, 1);
  assert.deepEqual(areas[0].decisions, ["D1"]);
  assert.deepEqual(areas[0].files.sort(), ["a.js", "b.js", "c.js"], "uncovered files are appended");
});

nodeTest("normalizeAreas appends an uncovered file to the smallest area and merges down to max", () => {
  const two = normalizeAreas([{ name: "x", files: ["a.js", "b.js"], decisions: [] }, { name: "y", files: ["c.js"], decisions: [] }], { ...ctx, diffFiles: [...ctx.diffFiles, "d.js"] });
  assert.deepEqual(two.find((a) => a.name === "y").files, ["c.js", "d.js"]);
  const merged = normalizeAreas(
    [
      { name: "x", files: ["a.js"], decisions: ["D1"] },
      { name: "y", files: ["b.js"], decisions: ["D2"] },
      { name: "z", files: ["c.js"], decisions: [] },
    ],
    { ...ctx, max: 2 },
  );
  assert.equal(merged.length, 2);
  assert.deepEqual(merged.flatMap((a) => a.files).sort(), ["a.js", "b.js", "c.js"]);
});

nodeTest("implementsLookup reads ## Implements from a non-file tracker's listing, by the branch's issue number, listing once", () => {
  let listings = 0;
  const tracker = {
    listOpen: (_root, { featureSlug }) => {
      listings++;
      assert.equal(featureSlug, "demo");
      return [
        { number: 188, status: "done", text: "## Implements\n\nD1, D2\n" },
        { number: 191, status: "awaiting-merge", text: "## Implements\n\nD3\n" },
      ];
    },
  };
  const ctx = { effects: { mainRoot: "/nowhere" }, sprint: { featureSlug: "demo" }, log: () => {} };
  const idsFor = implementsLookup(ctx, tracker);
  assert.deepEqual(idsFor("crew/demo/188-whole-feature"), ["D1", "D2"]);
  assert.deepEqual(idsFor("crew/demo/191-areas"), ["D3"]);
  assert.deepEqual(idsFor("crew/demo/999-unknown"), []);
  assert.equal(listings, 1);
});

nodeTest("implementsLookup warns and names nothing when the tracker listing fails", () => {
  const logs = [];
  const tracker = { listOpen: () => { throw new Error("gh down"); } };
  const ctx = { effects: { mainRoot: "/nowhere" }, sprint: { featureSlug: "demo" }, log: (m, lvl) => logs.push([lvl, m]) };
  assert.deepEqual(implementsLookup(ctx, tracker)("crew/demo/1-a"), []);
  assert.ok(logs.some(([lvl, m]) => lvl === "warn" && /gh down/.test(m)));
});

nodeTest("parsePlannerAnswer reads the last fenced json block and nothing else", () => {
  assert.deepEqual(parsePlannerAnswer('x\n```json\n{"areas":[]}\n```\n'), { areas: [] });
  assert.equal(parsePlannerAnswer("no block"), null);
  assert.equal(parsePlannerAnswer("```json\nnot json\n```"), null);
});

nodeTest("plannerPrompt holds the stat, the issues' files and IDs, and the decision lines", () => {
  const p = plannerPrompt({
    featureBranch: "feature/x",
    base: "abc",
    max: 2,
    stat: " a.js | 1 +\n",
    issues: [{ branch: "crew/x/1-a", files: ["a.js"], ids: ["D1"] }],
    decisions: new Map([["D1", "- **D1** — one."]]),
  });
  assert.match(p, / a\.js \| 1 \+/);
  assert.match(p, /crew\/x\/1-a: files a\.js; implements D1/);
  assert.match(p, /- \*\*D1\*\* — one\./);
});

nodeTest("featureReviewPrompt carries an Area: block with the files and the full decision text; none without an area", () => {
  const base = { featureBranch: "feature/x", base: "abc", reportPath: "/r.json" };
  const withArea = featureReviewPrompt({ ...base, area: { name: "flow", files: ["a.js"] }, decisions: ["- **D1** — Retries are bounded."] });
  assert.match(withArea, /^Area:\nName: flow\nFiles:\n- a\.js\nDecisions:\n- \*\*D1\*\* — Retries are bounded\.$/m);
  assert.doesNotMatch(featureReviewPrompt(base), /^Area:/m);
});
