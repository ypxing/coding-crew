/**
 * Sprint suite — a clean issue's lifecycle: verify, review, merge, close, and the retries around them.
 * Shared helpers: ./helpers/sprint.mjs.
 */

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cpSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { MAIN, TMPDIR, SCRIPTS, INSTALL_DIR, FAKE, EMPTY_HOME, sh, FIXTURE_ROOTS, fixtureRepo, addIssue, BRANCH_REVIEW, runSprint, traceLog, state, fake, privateScripts, failFirstCall, commandLines, test } from "./helpers/sprint.mjs";

// Spawned directly, not through sh(): sh() strips both vars, which is exactly what this
// test needs set. `plan`, so no orca is ever called.
test("HERDR_ENV and ORCA_ENV both set: orca, with a notice", () => {
  const root = fixtureRepo();
  const env = { ...process.env, HOME: EMPTY_HOME, HERDR_ENV: "1", ORCA_ENV: "1", HERDR_PANE_ID: "", ORCA_TERMINAL_HANDLE: "", CREW_SCRIPTS: SCRIPTS, CREW_FAKE_DISPATCH: FAKE };
  delete env.CREW_PANE_HOST;
  const r = spawnSync("node", [MAIN, "plan", "--platform", "pi", "--feature-slug", "demo"], { cwd: root, encoding: "utf8", env });
  assert.match(r.stderr, /ORCA_ENV=1 and HERDR_ENV=1 are both set — using orca/);
  assert.match(r.stdout, /pane host: orca {2}\[ORCA_ENV\]/);
});

test("run names the resolved pane host before anything else it does", () => {
  const root = fixtureRepo();
  const r = sh("node", [MAIN, "run", "--dry-run", "--platform", "pi", "--feature-slug", "demo"], {
    cwd: root,
    env: { ...process.env, CREW_SCRIPTS: SCRIPTS, CREW_FAKE_DISPATCH: FAKE },
  });
  assert.match(r.stderr, /^PANE-HOST: none$/m);
});

// A repo can hold installs for several platforms, but only its own has pi's or codex's
// dispatcher. The first install found used to win whatever --platform said, so a codex
// sprint in a repo also installed for pi ran .pi/…/dispatch-codex-agent.sh, which isn't there.
test("the running platform's own install supplies the scripts dir, not whichever is found first", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const dirs = { pi: ".pi/skills", codex: ".agents/skills", claude: ".claude/skills", copilot: ".github/skills" };
  for (const d of Object.values(dirs)) cpSync(SCRIPTS, join(root, d, "crew-afk/scripts"), { recursive: true });
  const home = mkdtempSync(join(TMPDIR, "crew-home-"));
  for (const [platform, d] of Object.entries(dirs)) {
    const r = sh("node", [MAIN, "plan", "--platform", platform], { cwd: root, env: { ...process.env, HOME: home, CREW_SCRIPTS: "" } });
    assert.equal(r.code, 0, r.stderr);
    assert.match(r.stdout, new RegExp(`^scripts: +${join(root, d, "crew-afk/scripts").replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}$`, "m"), platform);
  }
});

test("plan lists dispatchable issues and changes nothing", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-parked.md", { status: "deferred-findings" });
  addIssue(root, "03-blocked.md", { blockedBy: ["01-alpha.md"] });
  const r = sh("node", [MAIN, "plan", "--platform", "pi"], {
    cwd: root,
    env: { ...process.env, CREW_SCRIPTS: SCRIPTS, CREW_FAKE_DISPATCH: FAKE },
  });
  assert.equal(r.code, 0, r.stderr);
  assert.match(r.stdout, /dispatchable now \(1\):/);
  assert.match(r.stdout, /- alpha/);
  assert.match(r.stdout, /parked fix issues \(1\): parked/);
  assert.doesNotMatch(r.stdout, /- blocked/);
  assert.equal(existsSync(join(root, ".scratch/demo/sprint-state.json")), false);
});

test("a clean issue is verified, reviewed, merged and closed", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const s = state(root);
  assert.deepEqual(s.completed_slugs, ["alpha"]);
  assert.deepEqual(s.merged_branches, ["crew/demo/alpha"]);
  assert.equal(existsSync(join(root, ".scratch/demo/issues/done/01-alpha.md")), true);
  assert.equal(existsSync(join(root, ".scratch/demo/issues/open/01-alpha.md")), false);
  // The gate receipts both exist and the sprint ends cleanly.
  assert.equal(existsSync(join(root, ".scratch/demo/dispatch/01-alpha/verify.json")), true);
  assert.equal(existsSync(join(root, ".scratch/demo/dispatch/01-alpha/ac.ok")), true);
  assert.match(r.stdout, /NO MORE TASKS/);
  // The reviewer was handed the verification result, so a criterion that ends "and the
  // tests pass" is answerable by the read-only reviewer instead of stalling the branch.
  const reviewPromptText = readFileSync(join(root, ".scratch/demo/dispatch/01-alpha/review-prompt.md"), "utf8");
  assert.match(reviewPromptText, /Checks already run by the pipeline/);
  assert.match(reviewPromptText, /test=pass/);
  // The install this run resolved, once — the reviewer never searches for its assets.
  assert.ok(reviewPromptText.includes(`Review assets: ${join(INSTALL_DIR, "crew-afk/roles/reviewer")}\n`), reviewPromptText);
  // Nor the coder for the project's config, which its worktree does not hold.
  const coderPromptText = readFileSync(join(root, ".scratch/demo/dispatch/01-alpha/prompt.md"), "utf8");
  assert.ok(coderPromptText.includes(`Project config: ${join(root, ".coding-crew")} `), coderPromptText);
});

test("openPr off, something merged, local tracker: the summary ends with ## Next naming gh pr create and --open-pr", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.deepEqual(state(root).completed_slugs, ["alpha"]);
  const next = r.stdout.slice(r.stdout.lastIndexOf("\n## Next\n") + 1);
  assert.match(next, /^## Next\n/);
  assert.match(next, /gh pr create --head feature\/demo --title demo/);
  assert.match(next, /--open-pr/);
  assert.match(next, /afk\.openPr/);
  assert.doesNotMatch(next, /Closes #/, "a local tracker has no closing lines");
  assert.match(next, /NO MORE TASKS\s*$/);
});

test("openPr off and nothing merged: no ## Next section", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.nocommit");
  fake(
    root,
    "alpha.worker",
    ['## Issue: alpha', 'Status: complete', '', '```json', '{"status":"complete","checks":{"test":"fail","lint":"pass","typecheck":"pass"},"progress":"tests red"}', '```'].join("\n"),
  );
  const r = runSprint(root);
  assert.equal(r.code, 2, "the issue spends its retries and stays blocked");
  assert.deepEqual(state(root).merged_branches ?? [], []);
  assert.doesNotMatch(r.stdout, /^## Next$/m);
});

test("a run whose install is missing an asset stops before any dispatch, naming the path", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const partial = mkdtempSync(join(TMPDIR, "crew-install-"));
  FIXTURE_ROOTS.push(partial);
  cpSync(join(INSTALL_DIR, "dep-install"), join(partial, "dep-install"), { recursive: true });
  cpSync(join(INSTALL_DIR, "solve-issue"), join(partial, "solve-issue"), { recursive: true });
  cpSync(join(INSTALL_DIR, "to-issues"), join(partial, "to-issues"), { recursive: true });
  const r = runSprint(root, [], { CREW_INSTALL_DIR: partial });
  assert.equal(r.code, 1, `${r.stdout}\n${r.stderr}`);
  assert.ok(r.stderr.includes(`reviewer: ${join(partial, "crew-afk/roles/reviewer/scripts/review-context.sh")}`), r.stderr);
  assert.match(r.stderr, /Re-run install\.sh/);
  assert.doesNotMatch(r.stderr, /depInstall:|solveIssue:/);
  assert.equal(existsSync(join(root, ".scratch/demo/dispatch")), false, "nothing was dispatched");
});

test("every cached check is run by the gate, whatever the worker reported, and stated to the reviewer with its log", () => {
  const root = fixtureRepo();
  mkdirSync(join(root, ".coding-crew"), { recursive: true });
  writeFileSync(
    join(root, ".coding-crew/dev-commands.json"),
    JSON.stringify({ test: "make test", lint: "make lint", typecheck: "make typecheck", coverage: "echo Branches: 82.35%", integration: null }),
  );
  sh("git", ["-C", root, "add", "-A"]);
  sh("git", ["-C", root, "commit", "-q", "-m", "cache"]);
  // The fake discovery's default answer nulls coverage/integration; answer as the cache does.
  fake(root, "commands.response", '{"install": null, "env": null, "credential_target": null}');
  addIssue(root, "01-alpha.md");
  fake(
    root,
    "alpha.worker",
    ['## Issue: alpha', 'Status: complete', '', '```json', '{"status":"complete","checks":{"test":"pass","lint":"pass","typecheck":"pass"},"progress":""}', '```'].join("\n"),
  );
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const reviewPromptText = readFileSync(join(root, ".scratch/demo/dispatch/01-alpha/review-prompt.md"), "utf8");
  assert.match(reviewPromptText, /coverage=pass \(full output: [^)]*verify-coverage\.log, \d+ lines\)/);
  // The worker never mentioned coverage; the gate ran it from the cache anyway. integration is
  // `null` there, and the reviewer is told so rather than left to infer it from what is absent.
  assert.doesNotMatch(reviewPromptText, /integration=/);
  assert.match(reviewPromptText, /Not run by the pipeline, no command configured: integration/);
  assert.match(reviewPromptText, /The gate's own record of that run: \S+\/01-alpha\/verify\.json/);
  // The logs live beside the record, so they outlive the worktree.
  assert.match(reviewPromptText, /coverage=pass \(full output: \S+\/dispatch\/01-alpha\/verify-coverage\.log, \d+ lines\)/);
  assert.equal(existsSync(join(root, ".scratch/demo/dispatch/01-alpha/verify-coverage.log")), true);
});

const WORKER_LINT_NOT_RUN = [
  "## Issue: alpha", "Status: complete", "", "```json",
  '{"status":"complete","checks":{"test":"pass","lint":"not_run","typecheck":"pass"},"progress":""}', "```",
].join("\n");

test("a coder's own not_run is no coverage gap when verify ran every check clean", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.worker", WORKER_LINT_NOT_RUN);
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(state(root).coverage_gaps?.alpha, undefined);
});

test("a gap verify itself reports is recorded", () => {
  const root = fixtureRepo();
  mkdirSync(join(root, ".coding-crew"), { recursive: true });
  writeFileSync(
    join(root, ".coding-crew/dev-commands.json"),
    JSON.stringify({ test: "make test", lint: null, typecheck: "make typecheck", coverage: null, integration: null }),
  );
  sh("git", ["-C", root, "add", "-A"]);
  sh("git", ["-C", root, "commit", "-q", "-m", "cache"]);
  fake(root, "commands.response", '{"install": null, "env": null, "credential_target": null}');
  addIssue(root, "01-alpha.md");
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(state(root).coverage_gaps?.alpha, "LINT");
});

test("a clean verify clears a gap an earlier round recorded", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  mkdirSync(join(root, ".scratch/demo"), { recursive: true });
  writeFileSync(join(root, ".scratch/demo/sprint-state.json"), JSON.stringify({ coverage_gaps: { alpha: "lint" } }));
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(state(root).coverage_gaps?.alpha, undefined);
});

test("a worker-reported failing check with commits is overruled by verify, not retried", () => {
  // verify-worktree.sh runs every check itself; the coder's own report is a claim.
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(
    root,
    "alpha.worker",
    ['## Issue: alpha', 'Status: complete', '', '```json', '{"status":"complete","checks":{"test":"fail","lint":"pass","typecheck":"pass"},"progress":"tests red"}', '```'].join("\n"),
  );
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.deepEqual(state(root).completed_slugs, ["alpha"]);
  assert.match(traceLog(root), /\[PREFILTER-OVERRULED\] slug=alpha round=1 — the coder reported reported checks failed: test/);
  assert.equal(lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length, 1, "one coder dispatch — verify decided");
});

test("a worker-reported failing check with no commits is demoted and never merges", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.nocommit");
  fake(
    root,
    "alpha.worker",
    ['## Issue: alpha', 'Status: complete', '', '```json', '{"status":"complete","checks":{"test":"fail","lint":"pass","typecheck":"pass"},"progress":"tests red"}', '```'].join("\n"),
  );
  const r = runSprint(root);
  const s = state(root);
  assert.equal(r.code, 2, "the issue spends both its retry attempts and stays blocked");
  assert.deepEqual(s.completed_slugs ?? [], []);
  assert.deepEqual(s.merged_branches ?? [], []);
  assert.equal(s.retention.alpha.reason, "blocked — retry limit reached (2 attempts) — reported checks failed: test");
  assert.equal(existsSync(join(root, ".scratch/demo/issues/open/01-alpha.md")), true);
  assert.match(readFileSync(join(root, ".scratch/demo/issues/open/01-alpha.md"), "utf8"), /## Progress/);
});

test("a coder that times out after committing gets a free retry", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  // Rounds 1 and 2 commit, then outlast the timeout; round 3 completes. Under the plain
  // two-attempt cap round 2 would have blocked it.
  fake(root, "alpha.worker-sleep", "3 2");
  const { r, lines } = commandLines(root, ["--coder-timeout", "0.02"]);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.deepEqual(state(root).completed_slugs, ["alpha"]);
  assert.equal(lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length, 3);
});

test("free retries stop at the dispatch cap", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.worker-sleep", "3");
  const { r, lines } = commandLines(root, ["--coder-timeout", "0.02"]);
  assert.equal(r.code, 2, `${r.stdout}\n${r.stderr}`);
  assert.match(state(root).retention.alpha.reason, /^blocked — retry limit reached \(3 attempts\) — worker timed out/);
  assert.equal(lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length, 3);
});

test("a worker-reported partial carries its own unmet criteria into the Progress section", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(
    root,
    "alpha.worker",
    [
      '## Issue: alpha',
      'Status: partial',
      '',
      '```json',
      '{"status":"partial","checks":{"test":"pass","lint":"pass","typecheck":"pass"},"criteria":[{"text":"docs updated","met":false},{"text":"resolver implemented","met":true}],"progress":"Remaining work: docs"}',
      '```',
    ].join("\n"),
  );
  // Nothing committed: a partial with commits is a claim the gates judge instead.
  fake(root, "alpha.nocommit");
  const r = runSprint(root);
  const s = state(root);
  assert.equal(r.code, 2, "the issue spends both its retry attempts and stays blocked");
  assert.equal(s.retention.alpha.reason, "blocked — retry limit reached (2 attempts) — partial");
  const issueText = readFileSync(join(root, ".scratch/demo/issues/open/01-alpha.md"), "utf8");
  // The next round's resume must not depend on the coder's own prose having named every
  // gap — the structured criteria array from its report is carried forward verbatim.
  assert.match(issueText, /Unmet criteria \(from the worker's own report\):\n- docs updated/);
  assert.doesNotMatch(issueText, /- resolver implemented/);
});

test("an unmet acceptance-criteria verdict retains the branch and closes nothing", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(
    root,
    "alpha.review",
    `## Branch: crew/demo/alpha\n\`\`\`json\n${JSON.stringify({ branch: "crew/demo/alpha", slug: "alpha", verdict: "unmet", detail: "no test covers the criterion", findings: [] })}\n\`\`\`\n`,
  );
  const r = runSprint(root);
  const s = state(root);
  assert.equal(r.code, 2);
  assert.deepEqual(s.merged_branches ?? [], []);
  assert.match(s.retention.alpha.reason, /criteria-unmet/);
  assert.equal(existsSync(join(root, ".scratch/demo/dispatch/01-alpha/ac.ok")), false);
  assert.equal(existsSync(join(root, ".scratch/demo/issues/open/01-alpha.md")), true);
});

test("a review that produced nothing is a gap, not a clean pass", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.review", ""); // empty review report, every round — never recovers
  const r = runSprint(root);
  const s = state(root);
  // The first attempt's failure is a review-not-run retry (see the next tests for that
  // shape in isolation, via .review-once). This fixture keeps failing every attempt, so the
  // second attempt spends this issue's retry cap and it blocks instead of retrying forever —
  // naming why the review never ran, not only that it didn't.
  assert.match(s.retention.alpha.reason, /^blocked — retry limit reached \(2 attempts\) — review-not-run — no report\.json — the reviewer never wrote its verdict file$/);
  assert.deepEqual(s.merged_branches ?? [], []);
  assert.match(r.stdout, /Unreviewed Branches|review/i);
});

test("a review that ended without a verdict is retried once in the same round", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  // The first review leaves no report (the shape a reviewer that stopped short leaves
  // behind); the in-round retry succeeds — no second round, no second verify.
  fake(root, "alpha.review-once", "1");
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const s = state(root);
  assert.deepEqual(s.merged_branches, ["crew/demo/alpha"]);
  assert.equal(s.rounds, 1);
  assert.equal(lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length, 1);
  assert.equal(lines.filter((l) => BRANCH_REVIEW.test(l)).length, 2);
  const log = traceLog(root);
  assert.match(log, /\[REVIEW-RETRY\] slug=alpha round=1 — no report\.json/);
  assert.equal((log.match(/step=verify/g) ?? []).length, 1);
  assert.doesNotMatch(log, /\[SKIP-WORKER\]/);
});

test("a timed-out review is not retried in the same round", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.review-sleep", "3");
  const { r, lines } = commandLines(root, ["--max-rounds", "1", "--reviewer-timeout", "0.02"]);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(lines.filter((l) => BRANCH_REVIEW.test(l)).length, 1);
  assert.doesNotMatch(traceLog(root), /\[REVIEW-RETRY\]/);
  assert.equal(state(root).retention.alpha.reason, "review-not-run — review dispatch timed out");
});

test("a review-not-run retry round skips the coder dispatch and succeeds on its review", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  // Both round-1 reviews (the first and its in-round retry) leave no report; round 2
  // retries only the review — the worker itself never runs a second time.
  fake(root, "alpha.review-once", "2");
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const s = state(root);
  assert.deepEqual(s.completed_slugs, ["alpha"]);
  assert.deepEqual(s.merged_branches, ["crew/demo/alpha"]);
  assert.equal(s.retention?.alpha, undefined, "the issue should have completed, not stayed retained");
  assert.ok(s.rounds >= 2, `expected at least 2 rounds, got ${s.rounds}`);
  assert.equal(lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length, 1);
  assert.match(traceLog(root), /\[SKIP-WORKER\] slug=alpha reason=review-not-run branch=\S+ — .*verify already passed at this commit — review only/);
  // The commit round 2 reviews is the one round 1 verified: its receipt stands.
  assert.equal(lines.filter((l) => /verify-worktree\.sh --dir/.test(l)).length, 1);
});

test("a non-empty review report with no verdict line and no findings is review-not-run, not criteria-unmet", () => {
  // Distinct from the truly-empty case above: a garbled capture of the reviewer's reply
  // (non-empty text, but no fenced json and no `AC:` line, and no FINDING:/[SEV] content
  // either) used to parse as a genuine `AC: unmet` verdict — routing the retry through a
  // full, expensive coder redispatch to "fix" acceptance criteria the review never
  // actually found unmet. It must route the same cheap way review-once does.
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.review-once-garbled", "");
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const s = state(root);
  assert.deepEqual(s.completed_slugs, ["alpha"]);
  assert.deepEqual(s.merged_branches, ["crew/demo/alpha"]);
  assert.equal(s.retention?.alpha, undefined, "the issue should have completed, not stayed retained");
  // The coder ran exactly once — only the review was retried, and the fixPrompt /
  // criteria-unmet path was never taken.
  assert.equal(lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length, 1);
  assert.match(traceLog(root), /\[REVIEW-RETRY\] slug=alpha /);
  assert.doesNotMatch(traceLog(root), /criteria-unmet/);
});

test("every agent dispatch's cost is recorded, not only the coder's", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.review-once", "1");
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  // One coder, two reviewer dispatches, and the feature review at the drain.
  assert.equal(lines.filter((l) => /^RUN .*state\.sh.* dispatch-cost /.test(l)).length, 4);
});

test("a merge-failed retry skips the worker, verify, and review, and succeeds on a retried merge", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const scripts = privateScripts();
  const marker = join(root, ".scratch/merge-fail.marker");
  failFirstCall(scripts, "merge-branches.sh", marker, "MERGE: forced failure for test");

  const round1 = commandLines(root, ["--max-rounds", "1"], { scripts });
  assert.equal(round1.r.code, 0, `${round1.r.stdout}\n${round1.r.stderr}`);
  let s = state(root);
  assert.equal(s.retention?.alpha?.reason, "merge-failed");
  assert.deepEqual(s.merged_branches ?? [], []);
  assert.deepEqual(s.completed_slugs ?? [], []);
  assert.equal(round1.lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length, 1);
  assert.equal(round1.lines.filter((l) => BRANCH_REVIEW.test(l)).length, 1);
  assert.equal(round1.lines.filter((l) => /verify-worktree\.sh --dir/.test(l)).length, 1);
  assert.equal(existsSync(join(root, ".scratch/demo/issues/open/01-alpha.md")), true);
  // Same mechanism finishPartial already uses for every other partial reason: the
  // Progress section is what makes hasProgress (and sprint.resumeBranch()) true.
  assert.match(
    readFileSync(join(root, ".scratch/demo/issues/open/01-alpha.md"), "utf8"),
    /## Progress/,
  );

  const round2 = commandLines(root, ["--max-rounds", "1"], { scripts });
  assert.equal(round2.r.code, 0, `${round2.r.stdout}\n${round2.r.stderr}`);
  s = state(root);
  assert.deepEqual(s.completed_slugs, ["alpha"]);
  assert.deepEqual(s.merged_branches, ["crew/demo/alpha"]);
  assert.equal(s.retention?.alpha, undefined);
  assert.equal(existsSync(join(root, ".scratch/demo/issues/done/01-alpha.md")), true);
  // No worker, verify, or review ran in round 2 — only the merge (and then close) retried.
  assert.equal(round2.lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length, 0);
  assert.equal(round2.lines.filter((l) => BRANCH_REVIEW.test(l)).length, 0);
  assert.equal(round2.lines.filter((l) => /verify-worktree\.sh --dir/.test(l)).length, 0);
  assert.equal(round2.lines.filter((l) => /merge-branches\.sh /.test(l)).length, 1);
  assert.match(traceLog(root), /\[SKIP-TO-MERGE\] slug=alpha reason=merge-failed/);
});

// ─── verify runs asynchronously ───────────────────────────────────────────────
//
// verify-worktree.sh runs the project's whole test suite. Run through spawnSync it froze the
// event loop: one verify at a time across every worker loop, and no coder dispatched meanwhile.

/** A verify-worktree.sh that records start/end (ms) per stem to <log>, sleeps <slow[stem]> s, then runs the real one. */
function timedVerify(scripts, log, secondsFor) {
  const real = join(scripts, "_real-verify-worktree.sh");
  cpSync(join(scripts, "verify-worktree.sh"), real);
  const cases = Object.entries(secondsFor).map(([stem, s]) => `  *${stem}*) SLEEP=${s} ;;`).join("\n");
  writeFileSync(
    join(scripts, "verify-worktree.sh"),
    [
      "#!/usr/bin/env bash",
      'now() { node -p "Date.now()"; }',
      "SLEEP=0",
      'case " $* " in',
      cases,
      "esac",
      'STEM=$(echo "$*" | sed -E "s/.*--stem ([^ ]+).*/\\1/")',
      `echo "verify-start $STEM $(now)" >> ${JSON.stringify(log)}`,
      'sleep "$SLEEP"',
      `echo "verify-end $STEM $(now)" >> ${JSON.stringify(log)}`,
      `exec bash ${JSON.stringify(real)} "$@"`,
      "",
    ].join("\n"),
  );
}

/** A dispatch wrapper that records when each coder is dispatched, then behaves as the fake. */
function timedDispatch(dir, log) {
  const f = join(dir, "timed-dispatch.sh");
  writeFileSync(
    f,
    [
      "#!/usr/bin/env bash",
      'case " $* " in *" --agent crew-coder "*)',
      '  SLUG=$(echo "$*" | sed -E "s/.*--slug ([^ ]+).*/\\1/")',
      `  echo "coder-start $SLUG $(node -p "Date.now()")" >> ${JSON.stringify(log)} ;;`,
      "esac",
      `exec bash ${JSON.stringify(FAKE)} "$@"`,
      "",
    ].join("\n"),
  );
  return f;
}

const readTimes = (log) =>
  Object.fromEntries(
    readFileSync(log, "utf8").trim().split("\n").map((l) => {
      const [what, stem, ms] = l.split(" ");
      return [`${what} ${stem.replace(/^\d+-/, "")}`, Number(ms)];
    }),
  );

test("two branches whose coders finish together are verified concurrently", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-beta.md");
  const scripts = privateScripts();
  const log = join(root, "times.log");
  timedVerify(scripts, log, { alpha: 2, beta: 2 });
  const { r } = commandLines(root, ["--max-parallel", "2"], { scripts });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.deepEqual(state(root).completed_slugs.sort(), ["alpha", "beta"]);
  const t = readTimes(log);
  assert.ok(t["verify-start beta"] < t["verify-end alpha"], "beta's verify only started after alpha's ended: the verifies were serialized");
  assert.ok(t["verify-start alpha"] < t["verify-end beta"], "alpha's verify did not overlap beta's");
});

test("a slow verify does not delay dispatching another ready issue into a free slot", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-beta.md");
  addIssue(root, "03-gamma.md");
  const scripts = privateScripts();
  const log = join(root, "times.log");
  timedVerify(scripts, log, { alpha: 5 });
  const dispatcher = timedDispatch(root, log);
  const { r } = commandLines(root, ["--max-parallel", "2"], { scripts, env: { CREW_FAKE_DISPATCH: dispatcher } });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.deepEqual(state(root).completed_slugs.sort(), ["alpha", "beta", "gamma"]);
  const t = readTimes(log);
  assert.ok(t["coder-start gamma"] < t["verify-end alpha"], "gamma waited for alpha's slow verify before its coder was dispatched");
});

test("merges stay serialized while verifies overlap", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-beta.md");
  const scripts = privateScripts();
  timedVerify(scripts, join(root, "times.log"), { alpha: 1, beta: 1 });
  const { r, lines } = commandLines(root, ["--max-parallel", "2"], { scripts });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  // Every merge is one blocking effect whose own RUN line follows its checkout directly: no
  // other command is interleaved between a merge's checkout and its close.
  const merges = lines.filter((l) => /merge-branches\.sh/.test(l));
  assert.equal(merges.length, 2);
  const at = (re) => lines.map((l, i) => (re.test(l) ? i : -1)).filter((i) => i >= 0);
  const [m1, m2] = at(/merge-branches\.sh/);
  const closes = at(/close-issue\.sh/);
  assert.ok(m1 < closes[0] && closes[0] < m2, `merge/close pairs interleaved:\n${lines.join("\n")}`);
  assert.deepEqual(state(root).merged_branches.sort(), ["crew/demo/alpha", "crew/demo/beta"]);
});

test("the branch review prompt carries the PRD decisions the issue implements", () => {
  const root = fixtureRepo();
  writeFileSync(join(root, ".scratch/demo/PRD.md"), "# PRD\n\n- **D2** — **Adapters.** one per CLI\n- **D3** — unrelated\n");
  addIssue(root, "01-alpha.md", { body: "## Implements\n\nD2, D9" });
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const prompt = readFileSync(join(root, ".scratch/demo/dispatch/01-alpha/review-prompt.md"), "utf8");
  assert.match(prompt, /PRD decisions this issue implements:\n---\n- \*\*D2\*\* — \*\*Adapters\.\*\* one per CLI\n---/);
  assert.doesNotMatch(prompt, /D3/);
  assert.match(`${r.stdout}\n${r.stderr}\n${traceLog(root)}`, /D9, which has no line in the PRD/);
});

test("an unmet verdict naming a PRD decision retains the branch for its coder, like an unmet criterion", () => {
  const root = fixtureRepo();
  writeFileSync(join(root, ".scratch/demo/PRD.md"), "# PRD\n\n- **D2** — **Adapters.** one per CLI\n");
  addIssue(root, "01-alpha.md", { body: "## Implements\n\nD2" });
  fake(
    root,
    "alpha.review",
    `## Branch: crew/demo/alpha\n\`\`\`json\n${JSON.stringify({ branch: "crew/demo/alpha", slug: "alpha", verdict: "unmet", detail: "D2: the branch dispatches through a per-platform agent file", findings: [] })}\n\`\`\`\n`,
  );
  const r = runSprint(root);
  const s = state(root);
  assert.equal(r.code, 2);
  assert.deepEqual(s.merged_branches ?? [], []);
  assert.match(s.retention.alpha.reason, /criteria-unmet/);
  assert.equal(existsSync(join(root, ".scratch/demo/issues/open/01-alpha.md")), true);
});
