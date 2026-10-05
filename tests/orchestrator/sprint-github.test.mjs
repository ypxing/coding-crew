/**
 * Sprint suite — the GitHub tracker backend and its in-progress label.
 * Shared helpers: ./helpers/sprint.mjs.
 */

import { after } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { REPO, MAIN, TMPDIR, SCRIPTS, FAKE, sh, fixtureRepo, addIssue, traceLog, state, fake, workerReport, AUDIT_WITH_GAP, githubFixtureRepo, stubGh, GH_ALPHA, commandLines, featureReviewFile, test } from "./helpers/sprint.mjs";

// ─── GitHub tracker backend wiring ────────────────────────────────────────────
//
// Regression for a gap the PRD's own Decisions section explicitly called for (callers
// "stop importing local.mjs directly and call through the factory instead") but no
// issue's acceptance criteria ever operationalised: main.mjs/loop.mjs/pipeline.mjs used
// to import tracker.mjs's static, local-only re-exports directly, so a repo configured
// for `tracker: github` still dispatched against local .scratch/ files — finding none —
// instead of ever calling into trackers/github.mjs. `gh` is stubbed on PATH; these tests
// pin that the wiring reaches it at all, not real GitHub behaviour (already covered by
// tracker-github.test.mjs).


/**
 * A fake `gh` on its own PATH-prepended dir: logs every invocation (one line per call) to
 * `gh.log` and answers just enough of the CLI surface a live sprint's dispatch loop and
 * close-issue.sh's github branch actually call — `issue list` from the fixture's own
 * `gh-issues.json` (mutated by `issue edit --add-label/--remove-label` and by `issue close`,
 * so a second `listFeatureIssues` fetch sees the new labels/state the same way a real re-fetch
 * would), `issue view --json body --jq .body` echoing that same issue's body, `issue
 * comment`/`label create` as plain no-ops. Everything else exits 0 — this pins the wiring, not the full `gh` surface
 * (already covered by tracker-github.test.mjs / tracker-mark-done-github.bats).
 */


const GH_PRD = {
  number: 9,
  title: "PRD: Demo",
  body: "# PRD\n\n- Export to CSV\n",
  labels: [],
  state: "OPEN",
};

test("plan resolves the github backend and lists a milestone issue instead of silently finding nothing", () => {
  const root = githubFixtureRepo();
  const { stub, log } = stubGh(root, [GH_ALPHA]);
  const r = sh("node", [MAIN, "plan", "--platform", "pi", "--feature-slug", "demo"], {
    cwd: root,
    env: { ...process.env, CREW_SCRIPTS: SCRIPTS, CREW_FAKE_DISPATCH: FAKE, PATH: `${stub}:${process.env.PATH}` },
  });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stdout, /dispatchable now \(1\):/);
  assert.match(r.stdout, /- alpha .*#1/);
  const calls = readFileSync(log, "utf8");
  assert.match(calls, /issue list .*--milestone demo/, "plan never called gh issue list at all");
});

function leaseRun(root, stub, extra = []) {
  return sh("node", [MAIN, "run", "--platform", "pi", "--feature-slug", "demo", ...extra], {
    cwd: root,
    env: {
      ...process.env,
      CREW_SCRIPTS: SCRIPTS,
      CREW_FAKE_DISPATCH: FAKE,
      CREW_FAKE_DIR: join(root, ".scratch/fake"),
      MAIN_ROOT: root,
      PATH: `${stub}:${process.env.PATH}`,
    },
  });
}
const lockRefs = (root) => sh("git", ["-C", root, "ls-remote", "origin", "refs/crew-lock/demo"]).stdout.trim();

test("a github run holds no lease after it finishes, and a live one held by another run stops it in preflight", () => {
  const root = githubFixtureRepo();
  const { stub, log } = stubGh(root, [GH_ALPHA]);
  const held = leaseRun(root, stub);
  assert.equal(held.code, 0, `${held.stdout}\n${held.stderr}`);
  assert.equal(lockRefs(root), "", "the lease was not released on completion");

  // Another host's lease: never auto-reclaimed.
  sh("bash", [join(SCRIPTS, "lease.sh"), "acquire", "--slug", "demo", "--owner", "run=other-run host=elsewhere pid=1 at=2026-01-01T00:00:00Z"], {
    cwd: root,
    env: { ...process.env, MAIN_ROOT: root },
  });
  const before = readFileSync(log, "utf8");
  const r = leaseRun(root, stub);
  assert.equal(r.code, 1);
  assert.match(r.stderr, /leased by run other-run on elsewhere since 2026-01-01T00:00:00Z.*--reclaim/);
  assert.equal(readFileSync(log, "utf8"), before, "a refused run still touched the tracker");
  assert.notEqual(lockRefs(root), "", "a refused run deleted someone else's lease");

  const re = leaseRun(root, stub, ["--reclaim"]);
  assert.equal(re.code, 0, `${re.stdout}\n${re.stderr}`);
  assert.match(re.stderr, /LEASE: reclaimed demo from run other-run/);
  assert.equal(lockRefs(root), "");
});

test("a github-configured sprint dispatches, marks the issue awaiting-merge without closing it, and stops finding work", () => {
  const root = githubFixtureRepo();
  const { stub, log, issuesFile } = stubGh(root, [GH_ALPHA]);
  const r = sh("node", [MAIN, "run", "--platform", "pi", "--feature-slug", "demo"], {
    cwd: root,
    env: {
      ...process.env,
      CREW_SCRIPTS: SCRIPTS,
      CREW_FAKE_DISPATCH: FAKE,
      CREW_FAKE_DIR: join(root, ".scratch/fake"),
      MAIN_ROOT: root,
      PATH: `${stub}:${process.env.PATH}`,
    },
  });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const calls = readFileSync(log, "utf8");
  assert.match(calls, /issue list .*--milestone demo/, "the dispatch loop never listed github issues");
  assert.match(calls, /issue edit 1 --add-label awaiting-merge --remove-label ready-for-agent/, "the issue was never marked done via gh");
  assert.doesNotMatch(calls, /issue close/, "merged into the feature branch is not shipped — only the PR closes it");
  const alpha = JSON.parse(readFileSync(issuesFile, "utf8")).find((i) => i.number === 1);
  assert.equal(alpha.state, "OPEN");
  assert.match(r.stdout, /NO MORE TASKS/);
  assert.match(r.stdout, /^## Next$[\s\S]*gh pr create --head [^\n]+[\s\S]*Closes #1[\s\S]*--open-pr[\s\S]*afk\.openPr/m, "the summary never told the human how to open the PR, closing line under it");
  assert.doesNotMatch(r.stdout, /## Pull Request/);
  assert.ok(r.stdout.lastIndexOf("\n## Next\n") > r.stdout.lastIndexOf("## Code Review"), "## Next is not the tail of the summary");
});

test("github: a blocked issue is labelled blocked, keeps ready-for-agent, the summary says how to unblock it, and the next run skips it", () => {
  const root = githubFixtureRepo();
  const { stub, log, issuesFile } = stubGh(root, [GH_ALPHA]);
  fake(root, "alpha.nocommit");
  fake(
    root,
    "alpha.worker",
    ['## Issue: alpha', 'Status: complete', '', '```json', '{"status":"complete","checks":{"test":"fail","lint":"pass","typecheck":"pass"},"progress":"tests red"}', '```'].join("\n"),
  );
  const env = {
    ...process.env,
    CREW_SCRIPTS: SCRIPTS,
    CREW_FAKE_DISPATCH: FAKE,
    CREW_FAKE_DIR: join(root, ".scratch/fake"),
    MAIN_ROOT: root,
    PATH: `${stub}:${process.env.PATH}`,
  };
  const run = () => sh("node", [MAIN, "run", "--platform", "pi", "--feature-slug", "demo"], { cwd: root, env });
  const first = run();
  const calls = readFileSync(log, "utf8");
  assert.match(calls, /label create blocked .*--force/);
  assert.match(calls, /issue edit 1 --add-label blocked/);
  const labels = () => JSON.parse(readFileSync(issuesFile, "utf8")).find((i) => i.number === 1).labels.map((l) => l.name);
  assert.deepEqual(labels().sort(), ["blocked", "ready-for-agent"]);
  assert.match(first.stdout, /gh issue edit 1 --remove-label blocked/);

  const before = readFileSync(log, "utf8").split("\n").length;
  run();
  const after = readFileSync(log, "utf8").slice(readFileSync(log, "utf8").split("\n").slice(0, before - 1).join("\n").length);
  assert.doesNotMatch(after, /issue edit 1 --add-label blocked/, "a labelled issue was dispatched again");
});

// ─── in-progress: the display label ──────────────────────────────────────────

const ghEnv = (root, stub, extra = {}) => ({ PATH: `${stub}:${process.env.PATH}`, ...extra });
const issueLabels = (issuesFile, n) =>
  JSON.parse(readFileSync(issuesFile, "utf8")).find((i) => i.number === n).labels.map((l) => l.name).sort();
const ghLines = (log) => readFileSync(log, "utf8").split("\n").filter(Boolean);

test("github: a claimed issue is labelled in-progress before its worker is dispatched, and the merge swaps it out in one edit", () => {
  const root = githubFixtureRepo();
  const { stub, log, issuesFile } = stubGh(root, [GH_ALPHA]);
  const { r, lines } = commandLines(root, [], { env: ghEnv(root, stub) });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const claim = lines.findIndex((l) => /issue-labels\.sh claim 1$/.test(l));
  const spawn = lines.findIndex((l) => /^SPAWN .*--agent crew-coder/.test(l));
  assert.ok(claim >= 0, "the issue was never labelled in-progress");
  assert.ok(spawn >= 0 && claim < spawn, "the label was written after the worker was dispatched");
  const edits = ghLines(log).filter((l) => l.startsWith("issue edit 1 "));
  assert.deepEqual(edits, [
    "issue edit 1 --add-label in-progress",
    "issue edit 1 --add-label awaiting-merge --remove-label ready-for-agent --remove-label in-progress",
  ]);
  assert.deepEqual(issueLabels(issuesFile, 1), ["awaiting-merge"]);
});

test("github: a blocked issue ends with blocked and without in-progress, in one edit", () => {
  const root = githubFixtureRepo();
  const { stub, log, issuesFile } = stubGh(root, [GH_ALPHA]);
  fake(root, "alpha.nocommit");
  fake(
    root,
    "alpha.worker",
    ['## Issue: alpha', 'Status: complete', '', '```json', '{"status":"complete","checks":{"test":"fail","lint":"pass","typecheck":"pass"},"progress":"tests red"}', '```'].join("\n"),
  );
  commandLines(root, [], { env: ghEnv(root, stub) });
  assert.deepEqual(issueLabels(issuesFile, 1), ["blocked", "ready-for-agent"]);
  assert.ok(ghLines(log).includes("issue edit 1 --add-label blocked --remove-label in-progress"));
  assert.ok(!ghLines(log).some((l) => l === "issue edit 1 --remove-label in-progress"), "a blocked issue was released a second time");
});

test("github: a partial issue still held at run end (round cap) is released before the summary", () => {
  const root = githubFixtureRepo();
  const { stub, log, issuesFile } = stubGh(root, [GH_ALPHA]);
  fake(root, "alpha.worker", workerReport({ status: "partial", checks: { test: "pass", lint: "pass", typecheck: "pass" }, progress: "half done" }));
  fake(root, "alpha.nocommit");
  const { r, lines } = commandLines(root, ["--max-rounds", "1"], { env: ghEnv(root, stub) });
  assert.match(r.stdout, /NO MORE TASKS/, `${r.stdout}\n${r.stderr}`);
  assert.deepEqual(issueLabels(issuesFile, 1), ["ready-for-agent"]);
  const release = lines.findIndex((l) => /issue-labels\.sh release 1$/.test(l));
  const summary = lines.findIndex((l) => /crew-summary\.sh/.test(l));
  assert.ok(release >= 0 && release < summary, "the label was not released before the summary was written");
  assert.equal(ghLines(log).filter((l) => l === "issue edit 1 --add-label in-progress").length, 1);
});

test("github: a requires-failed issue never carries in-progress or blocked", () => {
  const root = githubFixtureRepo();
  const { stub, log, issuesFile } = stubGh(root, [
    { ...GH_ALPHA, body: `${GH_ALPHA.body}\n## Requires\n\n- \`exit 1\`\n` },
  ]);
  const { r } = commandLines(root, [], { env: ghEnv(root, stub) });
  assert.match(r.stdout + r.stderr, /REQUIRES-FAILED/);
  assert.deepEqual(issueLabels(issuesFile, 1), ["ready-for-agent"]);
  assert.ok(!ghLines(log).some((l) => /in-progress/.test(l) && l.startsWith("issue edit 1")), "the issue was labelled in-progress");
});

test("github: the new lease holder sweeps in-progress from the milestone before dispatching, and the label gates nothing", () => {
  const root = githubFixtureRepo();
  const stale = { number: 2, title: "stale", body: "# stale\n", labels: [{ name: "in-progress" }], state: "CLOSED" };
  const { stub, log, issuesFile } = stubGh(root, [{ ...GH_ALPHA, labels: [{ name: "ready-for-agent" }, { name: "in-progress" }] }, stale]);
  const { r, lines } = commandLines(root, [], { env: ghEnv(root, stub) });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.deepEqual(issueLabels(issuesFile, 2), [], "a dead run's in-progress survived the sweep");
  const calls = ghLines(log);
  const sweptStale = calls.indexOf("issue edit 2 --remove-label in-progress");
  const firstClaim = calls.indexOf("issue edit 1 --add-label in-progress");
  assert.ok(sweptStale >= 0 && firstClaim > sweptStale, "the sweep did not run before the first claim");
  assert.ok(lines.some((l) => /^SPAWN .*--agent crew-coder/.test(l)), "an issue carrying in-progress was not dispatched");
  assert.deepEqual(issueLabels(issuesFile, 1), ["awaiting-merge"]);
});

test("github: the new lease holder closes the issues a merged PR names, before dispatching, and keeps the PRD open while work remains", () => {
  const root = githubFixtureRepo();
  const shipped = { number: 2, title: "shipped", body: "# shipped\n", labels: [{ name: "awaiting-merge" }], state: "OPEN" };
  const prd = { number: 3, title: "PRD: demo", body: "# PRD\n", labels: [], state: "OPEN" };
  const { stub, log, issuesFile } = stubGh(root, [GH_ALPHA, shipped, prd]);
  writeFileSync(join(root, "gh-prs.json"), JSON.stringify([{ number: 9, baseRefName: "main", body: "Closes #2\n" }]));
  const { r } = commandLines(root, [], { env: ghEnv(root, stub) });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const state = (n) => JSON.parse(readFileSync(issuesFile, "utf8")).find((i) => i.number === n).state;
  assert.equal(state(2), "CLOSED", "an issue its merged PR names was left open");
  assert.equal(state(3), "OPEN", "the PRD closed while a work issue was still open");
  const calls = ghLines(log);
  const closed = calls.findIndex((l) => l.startsWith("issue close 2 "));
  const firstClaim = calls.indexOf("issue edit 1 --add-label in-progress");
  assert.ok(closed >= 0 && firstClaim > closed, "the shipped issues were not closed before the first claim");
  assert.match(traceLog(root), /\[SHIPPED\] CLOSED: #2 \(PR #9\)/);
});

test("github: a failed close-shipped warns and the sprint goes on", () => {
  const root = githubFixtureRepo();
  const { stub, issuesFile } = stubGh(root, [GH_ALPHA]);
  writeFileSync(join(root, "gh-prs.json"), "not json");
  const { r } = commandLines(root, [], { env: ghEnv(root, stub) });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(traceLog(root), /WARN .*CLOSE-SHIPPED-FAILED/);
  assert.deepEqual(issueLabels(issuesFile, 1), ["awaiting-merge"]);
});

test("github: a failed in-progress write warns and the sprint goes on", () => {
  const root = githubFixtureRepo();
  const { stub, issuesFile } = stubGh(root, [GH_ALPHA]);
  const { r } = commandLines(root, [], { env: ghEnv(root, stub, { GH_FAIL_CLAIM: "1" }) });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(traceLog(root), /WARN .*IN-PROGRESS-LABEL-FAILED.*claim/);
  assert.deepEqual(issueLabels(issuesFile, 1), ["awaiting-merge"]);
});

test("local tracker: no in-progress label is ever written", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.ok(!lines.some((l) => /issue-labels\.sh/.test(l)));
});

test("github --open-pr: the sprint pushes the feature branch and opens a PR whose body closes the issue", () => {
  const root = githubFixtureRepo();
  const { stub, log } = stubGh(root, [GH_ALPHA]);
  const remote = join(root, ".scratch/remote.git");
  sh("git", ["init", "-q", "--bare", remote]);
  sh("git", ["-C", root, "remote", "set-url", "origin", remote]);
  fake(root, "feature.review", featureReviewFile([{ severity: "MEDIUM", location: "somewhere in alpha", criterion: "Rename the variable" }]));
  const r = sh("node", [MAIN, "run", "--platform", "pi", "--feature-slug", "demo", "--open-pr"], {
    cwd: root,
    env: {
      ...process.env,
      CREW_SCRIPTS: SCRIPTS,
      CREW_FAKE_DISPATCH: FAKE,
      CREW_FAKE_DIR: join(root, ".scratch/fake"),
      MAIN_ROOT: root,
      PATH: `${stub}:${process.env.PATH}`,
    },
  });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(readFileSync(log, "utf8"), /pr create --head feature\/demo --title Fake title for reviewers/);
  const body = readFileSync(join(root, "pr-body.md"), "utf8");
  assert.match(body, /^Closes #1$/m);
  assert.doesNotMatch(body, /^# Fake title/m, "the title is the PR's title, not a line of its body");
  // The PR writer's body opens the block, preamble dropped; its own **Tested:** line carries the
  // checks, so the sprint's mechanical checks line is not added beside it.
  assert.match(body, /<!-- crew-afk:begin -->\n## Why\n\nFake why\.[\s\S]*## Risk[\s\S]*\*\*Tested:\*\* [\s\S]*Implemented by a crew-afk sprint[\s\S]*Closes #1/);
  assert.doesNotMatch(body, /\*\*Checks on the merged branch:\*\*/);
  assert.doesNotMatch(body, /Here is the body/);
  assert.doesNotMatch(r.stdout, /PR body has no summary/);
  // Command discovery (uncached here) and the PR writer are dispatches too: both are in this
  // run's cost ledger, which is what the summary's run total sums.
  const trace = traceLog(root);
  assert.match(trace, /dispatch-cost slug=\S+ role=commandFinder /);
  assert.match(trace, /dispatch-cost slug=\S+ role=prWriter /);
  const s = state(root);
  const roles = (s.dispatches ?? []).filter((d) => d.run === s.current_run).map((d) => d.role);
  assert.ok(roles.includes("commandFinder") && roles.includes("prWriter"), `this run's ledger: ${roles}`);
  assert.equal(sh("git", ["-C", remote, "rev-parse", "feature/demo"]).stdout.trim(), sh("git", ["-C", root, "rev-parse", "feature/demo"]).stdout.trim());
  assert.match(r.stdout, /## Pull Request\s+https:\/\/github.com\/o\/r\/pull\/7\s+\*\*Ready:\*\* the run finished green\.\s+1 finding\(s\) posted \(0 inline\)/);
  assert.doesNotMatch(r.stdout, /^## Next$/m, "openPr on: the PR is opened, nothing is left to tell the human");
  const review = JSON.parse(readFileSync(join(root, "review-post.json"), "utf8"));
  assert.equal(review.event, "COMMENT");
  assert.match(review.body, /### MEDIUM[\s\S]*Rename the variable[\s\S]*crew-finding:/);
  // The findings are on the PR, so the summary points there, not at /crew-address-findings.
  assert.match(r.stdout, /1 finding\(s\) posted to https:\/\/github.com\/o\/r\/pull\/7/);
  assert.doesNotMatch(r.stdout, /\/crew-address-findings/);
});

test("github --open-pr: a PR writer with no ## Why still opens the PR, with the checks line, and the summary says why", () => {
  const root = githubFixtureRepo();
  const { stub, log } = stubGh(root, [GH_ALPHA]);
  const remote = join(root, ".scratch/remote.git");
  sh("git", ["init", "-q", "--bare", remote]);
  sh("git", ["-C", root, "remote", "set-url", "origin", remote]);
  fake(root, "pr-writer.response", "I could not read the diff.\n");
  const r = sh("node", [MAIN, "run", "--platform", "pi", "--feature-slug", "demo", "--open-pr"], {
    cwd: root,
    env: {
      ...process.env,
      CREW_SCRIPTS: SCRIPTS,
      CREW_FAKE_DISPATCH: FAKE,
      CREW_FAKE_DIR: join(root, ".scratch/fake"),
      MAIN_ROOT: root,
      PATH: `${stub}:${process.env.PATH}`,
    },
  });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(readFileSync(log, "utf8"), /pr create --head feature\/demo/);
  const body = readFileSync(join(root, "pr-body.md"), "utf8");
  assert.doesNotMatch(body, /## Why|could not read/);
  assert.match(body, /<!-- crew-afk:begin -->\n\*\*Checks on the merged branch:\*\* [\s\S]*Closes #1/);
  assert.match(r.stdout, /## Pull Request\s+https:\/\/github.com\/o\/r\/pull\/7\s+\*\*Ready:\*\* the run finished green\.\s+\*\*PR body has no summary:\*\* the writer's answer has no `## Why` section\./);
});

test("github PRDAudit fix: the gaps issue, created ready-for-agent, is implemented in Phase 2", () => {
  // github has no parked state, so flush promotes nothing: the loop must go round on the
  // audit's own word, or the sprint ends stalled with the gaps issue open.
  // As to-prd publishes it: the milestone's open "PRD:" issue, and no local PRD.md.
  const root = githubFixtureRepo();
  const { stub, issuesFile } = stubGh(root, [GH_PRD, GH_ALPHA]);
  writeFileSync(join(root, ".scratch/fake/prd-audit.response"), AUDIT_WITH_GAP);
  const r = sh("node", [MAIN, "run", "--platform", "pi", "--feature-slug", "demo"], {
    cwd: root,
    env: {
      ...process.env,
      CREW_SCRIPTS: SCRIPTS,
      CREW_FAKE_DISPATCH: FAKE,
      CREW_FAKE_DIR: join(root, ".scratch/fake"),
      MAIN_ROOT: root,
      CREW_GITHUB_TRACKER_CLI: join(REPO, "orchestrator/lib/trackers/github.mjs"),
      PATH: `${stub}:${process.env.PATH}`,
    },
  });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const gaps = JSON.parse(readFileSync(issuesFile, "utf8")).find((i) => i.title === "Fix PRD gaps: demo");
  assert.ok(gaps, `defer-gaps never created the issue\n${traceLog(root)}`);
  assert.ok(gaps.labels.some((l) => l.name === "awaiting-merge"), "the gaps issue was never implemented");
  assert.equal(traceLog(root).split("step=prd-audit").length - 1, 1, "one audit per sprint");
  assert.match(readFileSync(join(root, ".scratch/demo/prd-issue.md"), "utf8"), /Export to CSV/);
  assert.doesNotMatch(r.stdout, /Gaps not queued/);
});

test("github PRDAudit fix: a gaps issue the listing does not show yet is still implemented in Phase 2", () => {
  // The listing lags the create: without a wait, the round the audit starts claims nothing and
  // the sprint ends with the gaps issue open and ready.
  const root = githubFixtureRepo();
  const { stub, issuesFile } = stubGh(root, [GH_PRD, GH_ALPHA]);
  writeFileSync(join(root, ".scratch/fake/prd-audit.response"), AUDIT_WITH_GAP);
  const r = sh("node", [MAIN, "run", "--platform", "pi", "--feature-slug", "demo"], {
    cwd: root,
    env: {
      ...process.env,
      CREW_SCRIPTS: SCRIPTS,
      CREW_FAKE_DISPATCH: FAKE,
      CREW_FAKE_DIR: join(root, ".scratch/fake"),
      MAIN_ROOT: root,
      CREW_GITHUB_TRACKER_CLI: join(REPO, "orchestrator/lib/trackers/github.mjs"),
      GH_LIST_LAG_MS: "3000",
      PATH: `${stub}:${process.env.PATH}`,
    },
  });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const gaps = JSON.parse(readFileSync(issuesFile, "utf8")).find((i) => i.title === "Fix PRD gaps: demo");
  assert.ok(gaps.labels.some((l) => l.name === "awaiting-merge"), `the gaps issue was never implemented\n${traceLog(root)}`);
  assert.match(traceLog(root), /fix issue\(s\) listed after \d+ poll/);
});

test("github: a feature-review fix issue, not listed yet, is still implemented", () => {
  // The fix issue is created ready-for-agent as the queue drains; a listing that lags the
  // create must not end the sprint with it open.
  const root = githubFixtureRepo();
  const { stub, issuesFile } = stubGh(root, [GH_ALPHA]);
  fake(root, "feature.review", featureReviewFile([{ severity: "HIGH", location: "somewhere in alpha", criterion: "Check the boundary" }]));
  fake(root, "feature.review-later", featureReviewFile([]));
  const r = sh("node", [MAIN, "run", "--platform", "pi", "--feature-slug", "demo"], {
    cwd: root,
    env: {
      ...process.env,
      CREW_SCRIPTS: SCRIPTS,
      CREW_FAKE_DISPATCH: FAKE,
      CREW_FAKE_DIR: join(root, ".scratch/fake"),
      MAIN_ROOT: root,
      CREW_GITHUB_TRACKER_CLI: join(REPO, "orchestrator/lib/trackers/github.mjs"),
      GH_LIST_LAG_MS: "3000",
      PATH: `${stub}:${process.env.PATH}`,
    },
  });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const fix = JSON.parse(readFileSync(issuesFile, "utf8")).find((i) => i.title === "Fix feature review findings: demo");
  assert.ok(fix, `the findings fix issue was never created\n${traceLog(root)}`);
  assert.ok(fix.labels.some((l) => l.name === "awaiting-merge"), `the fix issue was never implemented\n${traceLog(root)}`);
  assert.doesNotMatch(r.stdout, /Fix issues not implemented/);
});

test("a gaps issue that could not be created is named in the summary, not only the trace", () => {
  const root = githubFixtureRepo();
  const { stub } = stubGh(root, [GH_ALPHA]);
  mkdirSync(join(root, ".scratch/demo"), { recursive: true });
  writeFileSync(join(root, ".scratch/demo/PRD.md"), "# PRD\n\n- Export to CSV\n");
  writeFileSync(join(root, ".scratch/fake/prd-audit.response"), AUDIT_WITH_GAP);
  // No CREW_GITHUB_TRACKER_CLI and no install: defer-gaps cannot find github.mjs.
  const r = sh("node", [MAIN, "run", "--platform", "pi", "--feature-slug", "demo"], {
    cwd: root,
    env: {
      ...process.env,
      CREW_SCRIPTS: SCRIPTS,
      CREW_FAKE_DISPATCH: FAKE,
      CREW_FAKE_DIR: join(root, ".scratch/fake"),
      MAIN_ROOT: root,
      HOME: mkdtempSync(join(TMPDIR, "crew-home-")),
      CREW_GITHUB_TRACKER_CLI: "",
      PATH: `${stub}:${process.env.PATH}`,
    },
  });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stdout, /## PRD Audit/);
  assert.match(r.stdout, /\*\*Gaps not queued:\*\* 1 missing requirement\(s\), but the fix issue was not created: .*github\.mjs/);
});

test("github --open-pr: a run with a blocked issue opens a draft PR naming it, and the summary says why", () => {
  const root = githubFixtureRepo();
  const { stub, log } = stubGh(root, [GH_ALPHA]);
  const remote = join(root, ".scratch/remote.git");
  sh("git", ["init", "-q", "--bare", remote]);
  sh("git", ["-C", root, "remote", "set-url", "origin", remote]);
  fake(root, "alpha.nocommit");
  fake(
    root,
    "alpha.worker",
    ['## Issue: alpha', 'Status: complete', '', '```json', '{"status":"complete","checks":{"test":"fail","lint":"pass","typecheck":"pass"},"progress":"tests red"}', '```'].join("\n"),
  );
  const r = sh("node", [MAIN, "run", "--platform", "pi", "--feature-slug", "demo", "--open-pr"], {
    cwd: root,
    env: { ...process.env, CREW_SCRIPTS: SCRIPTS, CREW_FAKE_DISPATCH: FAKE, CREW_FAKE_DIR: join(root, ".scratch/fake"), MAIN_ROOT: root, PATH: `${stub}:${process.env.PATH}` },
  });
  const calls = readFileSync(log, "utf8");
  if (/pr create/.test(calls)) {
    assert.match(calls, /pr create --draft /);
    assert.match(readFileSync(join(root, "pr-body.md"), "utf8"), /crew-afk:begin -->[\s\S]*\*\*Not green:\*\*[\s\S]*Blocked issues:\n- alpha/);
    assert.match(r.stdout, /## Pull Request[\s\S]*\*\*Draft:\*\* the run did not finish green/);
  } else {
    assert.fail(`no PR was created:\n${r.stdout}\n${r.stderr}`);
  }
});
