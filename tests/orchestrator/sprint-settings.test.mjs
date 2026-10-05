/**
 * Sprint suite — flag and config settings, and the end-of-sprint report.
 * Shared helpers: ./helpers/sprint.mjs.
 */

import assert from "node:assert/strict";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { MAIN, SCRIPTS, FAKE, sh, fixtureRepo, addIssue, runSprint, traceLog, state, fake, featureReviewFile, test } from "./helpers/sprint.mjs";

// ─── what the last prose bodies used to assert about themselves ──────────────
//
// The copilot cutover emptied AFK_PROSE_VARIANTS, so the bats suites that looped over it
// stopped having a subject. Three of those assertions had no direct code equivalent, only
// an adjacent one, and are written here before they are deleted there: the promotion
// threshold has one source, the sprint reports once and last, and a review gap is named in
// the summary rather than merely counted in the state file.

test("the promotion threshold has one source: fixFindings reaches findingsAtOrAbove", () => {
  // Findings come from the feature review alone; the Phase 2 drain's review finds nothing.
  const reviewWith = (severity) =>
    featureReviewFile([{ severity, location: "src/alpha.txt:1", criterion: "Move the trust boundary check before the write" }]);
  const sprintWith = (severity, extra = [], config = null) => {
    const root = fixtureRepo();
    addIssue(root, "01-alpha.md");
    fake(root, "feature.review", reviewWith(severity));
    fake(root, "feature.review-later", featureReviewFile([]));
    if (config) {
      mkdirSync(join(root, ".coding-crew"), { recursive: true });
      writeFileSync(join(root, ".coding-crew/config.json"), JSON.stringify({ afk: config }));
    }
    const r = runSprint(root, extra);
    assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
    return { root, r };
  };

  // Default: actionable, and with no triage verdict (the fake leaves none) the `high` rule applies.
  // The HIGH becomes a Phase 2 fix issue; the rule is read from sprint.env (CREW_FIX_FINDINGS),
  // not restated anywhere. Explicitly `high` it is the same, with no triage dispatch at all.
  const high = sprintWith("HIGH");
  assert.equal(state(high.root).completed_slugs.length, 2, "the HIGH should have run as its own fix issue");
  const criteria = readFileSync(join(high.root, ".scratch/demo/reviews/feature.criteria.md"), "utf8");
  assert.match(criteria, /\[HIGH\] Move the trust boundary check before the write/);
  assert.match(readFileSync(join(high.root, ".scratch/demo/sprint.env"), "utf8"), /CREW_FIX_FINDINGS="actionable"/);
  assert.match(traceLog(high.root), /FEATURE-REVIEW: promote: 1 finding\(s\) → /);
  const explicit = sprintWith("HIGH", ["--fix-findings", "high"]);
  assert.equal(state(explicit.root).completed_slugs.length, 2);
  assert.match(readFileSync(join(explicit.root, ".scratch/demo/sprint.env"), "utf8"), /CREW_FIX_FINDINGS="high"/);
  assert.doesNotMatch(traceLog(explicit.root), /FINDINGS-TRIAGE|dispatch-findings-triage/, "a severity level dispatches no triage");

  // A MEDIUM is reported, never promoted, at the default — left open and attributed.
  const medium = sprintWith("MEDIUM");
  assert.deepEqual(state(medium.root).completed_slugs, ["alpha"], "no fix issue for a MEDIUM at the default");
  assert.match(medium.r.stdout, /## Next Step/);
  const mediumLog = traceLog(medium.root);
  assert.doesNotMatch(mediumLog, /promotable/);
  assert.match(mediumLog, /FEATURE-REVIEW: promote: none — /);

  // config.json's afk.fixFindings: medium promotes it.
  const onMedium = sprintWith("MEDIUM", [], { fixFindings: "medium" });
  assert.equal(state(onMedium.root).completed_slugs.length, 2);

  // none: nothing promoted, whatever the severity.
  const none = sprintWith("CRITICAL", ["--fix-findings", "none"]);
  assert.deepEqual(state(none.root).completed_slugs, ["alpha"]);
});

test("a bad flag value is a setup error naming the flag", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const r = runSprint(root, ["--fix-findings", "severe", "--coder-timeout", "0"]);
  assert.equal(r.code, 1);
  assert.match(r.stderr, /--fix-findings is "severe"/);
  assert.match(r.stderr, /--coder-timeout must be a positive number of minutes/);
  // A setting flag left without its value is an error, not silently the default.
  const bare = runSprint(root, ["--prd-audit"]);
  assert.equal(bare.code, 1);
  assert.match(bare.stderr, /--prd-audit is ""/);
});

test("by default the sprint is not squashed: each issue's merge stays its own commit", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.doesNotMatch(traceLog(root), /\[SQUASH\]/);
  const log = sh("git", ["-C", root, "log", "--format=%s", "main..HEAD"]).stdout;
  assert.match(log, /Merge/);
});

test("config.json's squashCommits and installDeps turn those steps off, as their flags do", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  mkdirSync(join(root, ".coding-crew"), { recursive: true });
  writeFileSync(join(root, ".coding-crew/config.json"), JSON.stringify({ afk: { squashCommits: false, installDeps: false } }));
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const log = traceLog(root);
  assert.doesNotMatch(log, /step=deps/);
  assert.match(`${r.stdout}\n${r.stderr}\n${log}`, /squash skipped|--no-squash|skipping squash/i);
});

test("`plan` shows each setting and which file or flag set it", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  mkdirSync(join(root, ".coding-crew"), { recursive: true });
  writeFileSync(join(root, ".coding-crew/config.json"), JSON.stringify({ afk: { fixFindings: "medium", timeouts: { coder: 60 } } }));
  const r = sh("node", [MAIN, "plan", "--platform", "pi", "--feature-slug", "demo", "--prd-audit", "report"], {
    cwd: root,
    env: { ...process.env, CREW_SCRIPTS: SCRIPTS, CREW_FAKE_DISPATCH: FAKE, MAIN_ROOT: root },
  });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stdout, /findings: +fix medium and above in Phase 2 +\[project\]/);
  assert.match(r.stdout, /PRD audit: report +\[flag\]/);
  assert.match(r.stdout, /timeouts: +coder 60m \[project\], reviewer 20m, triage 20m, commandFinder 5m, prdAuditor 20m, prWriter 10m, merge 5m/);
});

test("`plan` shows the worktree root and which file set it", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  mkdirSync(join(root, ".coding-crew"), { recursive: true });
  writeFileSync(join(root, ".coding-crew/config.json"), JSON.stringify({ afk: { worktreeRoot: "../wt" } }));
  const env = { ...process.env, CREW_SCRIPTS: SCRIPTS, CREW_FAKE_DISPATCH: FAKE, MAIN_ROOT: root };
  delete env.CREW_WORKTREE_ROOT;
  const r = sh("node", [MAIN, "plan", "--platform", "pi", "--feature-slug", "demo"], { cwd: root, env });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.ok(r.stdout.includes(`worktrees: ${join(root, "../wt")}  [project]`), r.stdout);
  assert.doesNotMatch(r.stderr, /not gitignored/);
});

test("`plan` warns when a configured worktree root inside the repo is not gitignored", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const env = { ...process.env, CREW_SCRIPTS: SCRIPTS, CREW_FAKE_DISPATCH: FAKE, MAIN_ROOT: root, CREW_WORKTREE_ROOT: "wt" };
  const r = sh("node", [MAIN, "plan", "--platform", "pi", "--feature-slug", "demo"], { cwd: root, env });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stdout, /worktrees: .*\/wt  \[CREW_WORKTREE_ROOT\]/);
  assert.match(r.stderr, /WARNING: worktree root wt is inside the repo but not gitignored/);
});

test("the sprint reports once, from disk, and the summary is the last thing printed", () => {
  // Three copies of the same content used to reach one context window: a per-round rollup
  // (`crew-summary.sh --no-reminder`), a verbatim echo of every worker report, and the
  // summary's per-issue detail. The wrap-up renders it once, and the findings reminder is
  // part of that single render — so it prints exactly once, last.
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-beta.md");
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);

  const rollups = r.stdout.match(/^Rounds: /gm) ?? [];
  assert.equal(rollups.length, 1, "the rollup is rendered once, not once per round");
  const reminders = r.stdout.match(/No open review findings\.|^## Next Step/gm) ?? [];
  assert.equal(reminders.length, 1, "the findings reminder prints exactly once");

  const tail = r.stdout.trim().split("\n");
  assert.equal(tail.at(-1), "NO MORE TASKS");
  // The pipeline's own narration goes to stderr; stdout is the one render, so the summary
  // is the whole of it.
  assert.equal(tail[0], "Rounds: 1", `stdout starts with something other than the summary:\n${r.stdout}`);
  assert.doesNotMatch(r.stdout, /^(RECEIPT|MERGE|Closed|Verifying)/m, "pipeline output leaked into the report");
  assert.doesNotMatch(r.stdout, /^## Issue: /m, "a worker report was echoed verbatim");
  assert.doesNotMatch(r.stdout, /^### Per-issue/m, "per-issue detail is a third copy of the state file");
});

test("a review that never ran is named in the summary, not just counted in the state", () => {
  // "advisory" must not degrade into "reported as clean": the gap is recorded with
  // promote-findings.sh mark-not-run and surfaced under its own heading, on every attempt —
  // including the one that escalates the repeat failure to blocked (see the previous test).
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.review", "");
  const r = runSprint(root);
  assert.match(r.stdout, /## Unreviewed Branches/);
  assert.match(r.stdout, /crew\/demo\/alpha/);
  assert.match(state(root).retention.alpha.reason, /^blocked — retry limit reached \(2 attempts\) — review-not-run — no report\.json — the reviewer never wrote its verdict file$/);
});

test("--max-wall: past the cap nothing new is claimed, the running issue merges, and the run exits 2 naming the cap", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-beta.md");
  // alpha runs past the 0.6 s cap; beta, next in line, is never claimed.
  fake(root, "alpha.worker-sleep", "2\n");
  const r = runSprint(root, ["--max-parallel", "1", "--max-wall", "0.01"]);
  assert.equal(r.code, 2, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stdout, /## Wall-clock cap[\s\S]*- beta/);
  assert.match(traceLog(root), /\[WALL-CAP\] 0\.01 minute cap elapsed/);
  assert.match(r.stdout, /CAPPED: the wall-clock cap stopped new claims/);
  assert.match(traceLog(root), /FEATURE-REVIEW: skipped — the 0\.01-minute wall-clock cap/);
  assert.doesNotMatch(r.stdout, /STALLED:/);
  assert.deepEqual(state(root).merged_branches ?? [], ["crew/demo/alpha"]);
});
