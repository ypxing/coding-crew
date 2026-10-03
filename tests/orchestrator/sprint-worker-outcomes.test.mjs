/**
 * Sprint suite — a coder that stops short, ## Requires, and the coder's dollar cap.
 * Shared helpers: ./helpers/sprint.mjs.
 */

import assert from "node:assert/strict";
import { chmodSync, mkdirSync, readFileSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { MAIN, SCRIPTS, sh, fixtureRepo, addIssue, BRANCH_REVIEW, runSprint, traceLog, state, fake, workerReport, triageVerdict, coderSpawns, privateScripts, githubFixtureRepo, stubGh, GH_ALPHA, commandLines, test } from "./helpers/sprint.mjs";

// ─── a coder that stops short with commits: its report is a claim, the gates decide ───────


function failingTests(root) {
  writeFileSync(join(root, "Makefile"), "test:\n\t@echo boom && exit 1\nlint:\n\t@echo ok\ntypecheck:\n\t@echo ok\n");
  sh("git", ["-C", root, "add", "-A"]);
  sh("git", ["-C", root, "commit", "-q", "-m", "make test always fail"]);
}



test("partial with commits, verify fails, triage not-fixable: no second coder, blocked after the recheck", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  failingTests(root);
  fake(root, "alpha.worker", workerReport({ status: "partial", checks: { test: "fail" }, progress: "LocalStack license activation failed" }));
  fake(root, "alpha.triage", triageVerdict("no", "missing credential", "LOCALSTACK_AUTH_TOKEN is unset"));
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 2, `${r.stdout}\n${r.stderr}`);
  assert.equal(coderSpawns(lines), 1, "a not-fixable verdict must not re-dispatch the coder");
  assert.match(traceLog(root), /\[CODER-CLAIM\] slug=alpha round=1 — the coder reported partial/);
  assert.match(traceLog(root), /\[SKIP-WORKER\] slug=alpha reason=not-fixable-recheck/);
  assert.match(state(root).retention.alpha.reason, /^blocked — retry limit reached \(2 attempts\) — verification-failed:not-fixable — missing credential/);
});

test("blocked as not-fixable: every later re-run only re-checks, with no coder or triage", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  failingTests(root);
  fake(root, "alpha.worker", workerReport({ status: "partial", checks: { test: "fail" }, progress: "LocalStack license activation failed" }));
  fake(root, "alpha.triage", triageVerdict("no", "missing credential", "LOCALSTACK_AUTH_TOKEN is unset"));
  commandLines(root);
  // Two re-runs: the second catches a reason that nested the block prefix on the first.
  for (const run of [2, 3]) {
    const { r, lines } = commandLines(root);
    assert.equal(r.code, 2, `run ${run}:\n${r.stdout}\n${r.stderr}`);
    assert.equal(coderSpawns(lines), 0, `run ${run} must not re-dispatch the coder`);
    assert.equal(lines.filter((l) => /^SPAWN .*--agent crew-triage/.test(l)).length, 0, `run ${run} must not re-triage`);
    assert.match(
      state(root).retention.alpha.reason,
      /^blocked — retry limit reached \(2 attempts\) — verification-failed:not-fixable — missing credential/,
    );
  }
});

test("partial with commits, verify fails, triage fixable: the retry is a fix round told triage's detail", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  failingTests(root);
  fake(root, "alpha.worker", workerReport({ status: "partial", checks: { test: "fail" }, progress: "tests red" }));
  fake(root, "alpha.triage", triageVerdict("yes", "wrong host", "src/config.ts uses localhost:4566; the service is localstack:4566"));
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 2, `${r.stdout}\n${r.stderr}`);
  assert.equal(coderSpawns(lines), 2);
  const prompt = readFileSync(join(root, ".scratch/demo/dispatch/01-alpha/prompt.md"), "utf8");
  assert.match(prompt, /already judged acceptable — it only failed verification/);
  assert.match(prompt, /classified this failure as fixable: wrong host: src\/config\.ts uses localhost:4566/);
});

test("a coder that deferred its tests gets one free fix round on a fixable verify failure, then blocks", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  failingTests(root);
  fake(root, "alpha.worker", workerReport({ status: "partial", checks: { test: "deferred" }, progress: "tests deferred" }));
  fake(root, "alpha.triage", triageVerdict("yes", "wrong host", "fix it"));
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 2, `${r.stdout}\n${r.stderr}`);
  assert.equal(coderSpawns(lines), 3, "first failure refunded, second spends, limit reached on the third");
  assert.match(state(root).retention.alpha.reason, /^blocked — retry limit reached \(3 attempts\)/);
});

test("a coder that did not defer its tests gets no refund on a fixable verify failure", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  failingTests(root);
  fake(root, "alpha.worker", workerReport({ status: "partial", checks: { test: "fail" }, progress: "tests red" }));
  fake(root, "alpha.triage", triageVerdict("yes", "wrong host", "fix it"));
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 2, `${r.stdout}\n${r.stderr}`);
  assert.equal(coderSpawns(lines), 2);
});

test("github tracker: a re-run after a fixable failure gets fixPrompt though Progress lives only in a comment", () => {
  // The issue body carries no ## Progress (writeProgress posts a comment), so hasProgress
  // and hasBlocked are false on every fetch; the retained branch is known from state alone.
  const root = githubFixtureRepo();
  failingTests(root); // before the stub: its gh.log must not be committed as a tracked file
  const { stub, issuesFile } = stubGh(root, [GH_ALPHA]);
  const env = { PATH: `${stub}:${process.env.PATH}` };
  fake(root, "alpha.worker", workerReport({ status: "partial", checks: { test: "fail" }, progress: "tests red" }));
  fake(root, "alpha.triage", triageVerdict("yes", "wrong host", "src/config.ts uses localhost:4566; the service is localstack:4566"));
  commandLines(root, [], { env });
  assert.match(state(root).retention.alpha.reason, /verification-failed:fixable/);
  const promptFile = join(root, ".scratch/demo/dispatch/1-alpha/prompt.md");
  rmSync(promptFile);
  // The block labelled the issue `blocked`; a human removes it to put the issue back in the queue.
  const gh = JSON.parse(readFileSync(issuesFile, "utf8"));
  gh[0].labels = gh[0].labels.filter((l) => l.name !== "blocked");
  writeFileSync(issuesFile, JSON.stringify(gh));
  // Triage now rules it out, so the re-run cannot reach a fix prompt through its own gate:
  // the only fixPrompt possible is the one the retained reason routed to.
  fake(root, "alpha.triage", triageVerdict("no", "x", "y"));
  const { lines } = commandLines(root, [], { env });
  const prompt = readFileSync(promptFile, "utf8");
  assert.match(prompt, /classified this failure as fixable: wrong host: src\/config\.ts uses localhost:4566/);
});

test("a verify fix round that commits nothing blocks without re-verifying or re-triaging", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  failingTests(root);
  fake(root, "alpha.worker", workerReport({ status: "partial", checks: { test: "fail" }, progress: "tests red" }));
  fake(root, "alpha.triage", triageVerdict("yes", "wrong host", "src/config.ts uses localhost:4566"));
  fake(root, "alpha.commit-once", "1");
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 2, `${r.stdout}\n${r.stderr}`);
  assert.equal(coderSpawns(lines), 2);
  assert.equal(lines.filter((l) => /verify-worktree\.sh --dir/.test(l)).length, 1, "the unchanged commit is not verified again");
  assert.equal(lines.filter((l) => /^SPAWN .*--agent crew-triage/.test(l)).length, 1, "nor triaged again");
  assert.match(
    state(root).retention.alpha.reason,
    /^blocked — verification-failed:fixable — the fix round made no commit, so crew\/demo\/alpha is still at [0-9a-f]{12}, where verify last failed; triage's unaddressed detail: wrong host: src\/config\.ts uses localhost:4566$/,
  );
});

test("partial with commits and a passing verify goes to review, and merges on all-met", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.worker", workerReport({ status: "partial", checks: { test: "pass", lint: "pass", typecheck: "pass" }, progress: "unsure about AC 2" }));
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(coderSpawns(lines), 1);
  assert.ok(lines.some((l) => BRANCH_REVIEW.test(l)), "review ran");
  assert.deepEqual(state(root).merged_branches, ["crew/demo/alpha"]);
});

test("blocked on the environment with commits: verify, then triage, which is handed the coder's evidence", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  failingTests(root);
  fake(
    root,
    "alpha.worker",
    workerReport({
      status: "blocked",
      cause: "environment",
      evidence: { command: "make test-integration", exit: 1, output: "License activation failed" },
      notes: "LocalStack pro needs a token",
    }),
  );
  fake(root, "alpha.triage", triageVerdict("no", "missing credential", "no token"));
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 2, `${r.stdout}\n${r.stderr}`);
  assert.ok(lines.some((l) => /verify-worktree\.sh --dir/.test(l)), "verify ran");
  assert.ok(lines.some((l) => /^SPAWN .*--agent crew-triage/.test(l)), "triage ran");
  const triage = readFileSync(join(root, ".scratch/demo/dispatch/01-alpha/triage-prompt.md"), "utf8");
  assert.match(triage, /its own claim — check\nit against the diff/);
  assert.match(triage, /^cause: environment\ncommand: make test-integration\nexit: 1\noutput:\nLicense activation failed$/m);
});

test("blocked with no cause is a stop at once, with no verify, even with commits", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.worker", workerReport({ status: "blocked", notes: "the issue contradicts the PRD" }));
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 2, `${r.stdout}\n${r.stderr}`);
  assert.equal(lines.filter((l) => /verify-worktree\.sh --dir/.test(l)).length, 0);
  assert.equal(coderSpawns(lines), 1);
  assert.deepEqual(state(root).blocked_slugs, ["alpha"]);
});

test("a premise stop (blocked, cause code, nothing committed) reaches the issue's ## Blocked, with no retry", () => {
  // solve-issue §3's premise check: the issue contradicts the code, so the coder stops before
  // writing any. A human must see the contradiction itself, and no second coder may re-derive it.
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const notes = "BLOCKED: premise: issue assumes parseToken() in src/auth.ts — no such function; auth is in src/session.ts:42 verifySession()";
  fake(
    root,
    "alpha.worker",
    workerReport({
      status: "blocked",
      cause: "code",
      evidence: { command: "grep -rn parseToken src", exit: 1, output: "" },
      notes,
    }),
  );
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 2, `${r.stdout}\n${r.stderr}`);
  assert.equal(coderSpawns(lines), 1, "a premise stop is not retried");
  assert.equal(lines.filter((l) => /verify-worktree\.sh --dir/.test(l)).length, 0, "nothing to verify");
  assert.ok(!lines.some((l) => /^SPAWN .*--agent crew-triage/.test(l)), "no triage on a premise stop");
  assert.deepEqual(state(root).blocked_slugs, ["alpha"]);
  const issue = readFileSync(join(root, ".scratch/demo/issues/open/01-alpha.md"), "utf8");
  assert.match(issue, /## Blocked[\s\S]*BLOCKED: premise: issue assumes parseToken\(\)/, "the human sees the contradiction");
});

test("an issue the code already satisfies closes with no commits, and its dependent runs", () => {
  // solve-issue §3's "already met": nothing to build and nothing to add, so the branch has no
  // commits. The reviewer judges the criteria against the tree instead of an (empty) diff, and
  // the issue closes like any other — a dependent is not stranded behind a finished issue.
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-beta.md", { blockedBy: ["01-alpha.md"] });
  fake(root, "alpha.nocommit");
  fake(
    root,
    "alpha.worker",
    workerReport({
      status: "complete",
      checks: { test: "pass", lint: "pass", typecheck: "pass" },
      criteria: [{ text: "alpha exists", met: true }],
      notes: "already met: alpha exists at src/alpha.ts:1, pinned by src/alpha.test.ts:3",
    }),
  );
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(coderSpawns(lines), 2, "one coder for alpha, one for beta — no retry");
  assert.ok(existsSync(join(root, ".scratch/demo/issues/done/01-alpha.md")), "alpha closed");
  assert.ok(existsSync(join(root, ".scratch/demo/issues/done/02-beta.md")), "beta ran and closed");
  const review = readFileSync(join(root, ".scratch/demo/dispatch/01-alpha/review-prompt.md"), "utf8");
  assert.match(review, /^Diff scope: empty/m, "the reviewer is told to judge the tree, not the diff");
  const betaReview = readFileSync(join(root, ".scratch/demo/dispatch/02-beta/review-prompt.md"), "utf8");
  assert.doesNotMatch(betaReview, /^Diff scope: empty/m);
});

// ─── ## Requires: probed once in preflight, before any dispatch ───────────────────────

test("an issue whose ## Requires fails is blocked before any dispatch, with the command and its output", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md", { body: "## Requires\n\n- `echo License activation failed; exit 1`" });
  addIssue(root, "02-beta.md", { body: "## Requires\n\n- `true`" });
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 2, `${r.stdout}\n${r.stderr}`);
  assert.equal(lines.filter((l) => /check-requires\.sh/.test(l)).length, 1, "one probe for every issue");
  assert.ok(!lines.some((l) => /^SPAWN .*--agent crew-coder.*--slug 01-alpha/.test(l)), "alpha's coder never ran");
  assert.ok(lines.some((l) => /^SPAWN .*--agent crew-coder.*--slug 02-beta/.test(l)), "beta's requirement holds, so it runs");
  const s = state(root);
  assert.deepEqual(s.blocked_slugs, ["alpha"]);
  assert.deepEqual(s.merged_branches, ["crew/demo/beta"]);
  const text = readFileSync(join(root, ".scratch/demo/issues/open/01-alpha.md"), "utf8");
  assert.match(text, /## Blocked\n\nPreflight: requires-failed — `echo License activation failed; exit 1` exit 1/);
  assert.match(text, /License activation failed\n```/);
});

test("an issue waiting on a blocker has its ## Requires probed when it unblocks, not in preflight", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  // Holds only once alpha has landed: what a blocker that adds the target the command runs looks like.
  addIssue(root, "02-beta.md", {
    blockedBy: ["01-alpha.md"],
    body: "## Requires\n\n- `test -f .scratch/demo/issues/done/01-alpha.md`",
  });
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(lines.filter((l) => /check-requires\.sh/.test(l)).length, 1, "probed once, at claim");
  const s = state(root);
  assert.deepEqual(s.blocked_slugs ?? [], []);
  assert.deepEqual(s.merged_branches, ["crew/demo/alpha", "crew/demo/beta"]);
});

test("a ## Requires that holds on a re-run lets the issue dispatch", () => {
  const root = fixtureRepo();
  const flag = join(root, ".scratch/token-present");
  addIssue(root, "01-alpha.md", { body: `## Requires\n\n- \`test -f ${flag}\`` });
  const first = commandLines(root);
  assert.equal(coderSpawns(first.lines), 0);
  writeFileSync(flag, "");
  const second = commandLines(root);
  assert.equal(second.r.code, 0, `${second.r.stdout}\n${second.r.stderr}`);
  assert.equal(coderSpawns(second.lines), 1);
  assert.deepEqual(state(root).merged_branches, ["crew/demo/alpha"]);
});

// ─── afk.limits.<role>.usd: a dispatch that hits its dollar cap blocks, never retries ────

test("a coder that hits afk.limits.coder.usd is blocked at once, not retried", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  for (const a of ["crew-coder", "crew-reviewer", "crew-triage"]) {
    mkdirSync(join(root, ".claude/agents"), { recursive: true });
    writeFileSync(join(root, ".claude/agents", `${a}.md`), `---\nname: ${a}\n---\n`);
  }
  mkdirSync(join(root, ".coding-crew"), { recursive: true });
  writeFileSync(join(root, ".coding-crew/config.json"), JSON.stringify({ afk: { limits: { coder: { usd: 0.5 } } } }));
  // What claude 2.1.283 prints when --max-budget-usd is reached: exit 1, no result text.
  const stub = join(root, ".stub");
  mkdirSync(stub, { recursive: true });
  const argsLog = join(root, ".scratch/claude.args");
  writeFileSync(
    join(stub, "claude"),
    [
      "#!/usr/bin/env bash",
      `printf '%s\\n' "$*" >> ${JSON.stringify(argsLog)}`,
      `echo '{"type":"result","subtype":"error_max_budget_usd","is_error":true,"terminal_reason":"budget_exhausted","total_cost_usd":0.61,"result":null}'`,
      "exit 1",
      "",
    ].join("\n"),
  );
  chmodSync(join(stub, "claude"), 0o755);
  const r = sh("node", [MAIN, "run", "--platform", "claude", "--feature-slug", "demo", "--no-baseline", "--no-integration-check"], {
    cwd: root,
    env: { ...process.env, CREW_NO_COMMANDS: "1", CREW_SCRIPTS: SCRIPTS, CREW_FAKE_DISPATCH: "", MAIN_ROOT: root, PATH: `${stub}:${process.env.PATH}` },
  });
  assert.equal(r.code, 2, `${r.stdout}\n${r.stderr}`);
  const calls = readFileSync(argsLog, "utf8").trim().split("\n").filter((l) => l.includes("--disallowedTools Agent"));
  assert.equal(calls.length, 1, "a capped coder is never dispatched again");
  assert.match(calls[0], /--max-budget-usd 0\.5/);
  const s = state(root);
  assert.deepEqual(s.blocked_slugs, ["alpha"]);
  assert.match(s.retention.alpha.reason, /^blocked — limit-exceeded \(\$0\.5\) — the coder dispatch hit afk\.limits\.coder\.usd after \$0\.61$/);
});

test("an unparseable worker report is blocked, never complete", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.worker", "All done, everything works great!");
  const r = runSprint(root);
  const s = state(root);
  assert.deepEqual(s.blocked_slugs, ["alpha"]);
  assert.deepEqual(s.merged_branches ?? [], []);
  assert.match(readFileSync(join(root, ".scratch/demo/issues/open/01-alpha.md"), "utf8"), /## Blocked/);
});

test("a dead dispatch is blocked with the worker-failed reason", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.exit", "7");
  const r = runSprint(root);
  const s = state(root);
  assert.deepEqual(s.blocked_slugs, ["alpha"]);
  assert.match(s.retention.alpha.reason, /worker process failed/);
});

test("a rerun after a block with no commits is not told commits are preserved", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.exit", "7");
  runSprint(root);
  assert.deepEqual(state(root).blocked_slugs, ["alpha"]);

  rmSync(join(root, ".scratch/fake/alpha.exit"));
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const prompt = readFileSync(join(root, ".scratch/demo/dispatch/01-alpha/prompt.md"), "utf8");
  assert.match(prompt, /## Blocked/);
  assert.doesNotMatch(prompt, /preserved on branch/);
});

test("a blocked-by dependency is not dispatched until its blocker closes, and dispatches the moment it does", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-beta.md", { blockedBy: ["01-alpha.md"] });
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const s = state(root);
  assert.deepEqual(s.completed_slugs.sort(), ["alpha", "beta"]);
  // Neither issue needs a retry — beta is picked up by a freed pool slot the instant alpha
  // closes, not on some later synchronization point, so both complete on their first
  // attempt: "Rounds: 1" (the highest per-issue attempt count reached by either).
  assert.equal(s.rounds, 1, `expected exactly 1 attempt per issue, got ${s.rounds}`);
});

test("CREW_MAX_ROUNDS caps attempts per issue, not the sprint's total dispatch count", () => {
  // A continuous pool has no round barrier serializing "everyone gets one attempt before
  // anyone gets a second" for free — --max-rounds has to enforce that itself, per issue,
  // or the first issue a worker claims could exhaust the whole budget while its siblings
  // never run even once.
  const root = fixtureRepo();
  const slugs = ["alpha", "beta", "gamma"];
  slugs.forEach((n, i) => {
    addIssue(root, `0${i + 1}-${n}.md`);
    fake(
      root,
      `${n}.worker`,
      ['## Issue: ' + n, 'Status: partial', '', '```json', '{"status":"partial","checks":{"test":"pass","lint":"pass","typecheck":"pass"},"progress":"stuck"}', '```'].join("\n"),
    );
    fake(root, `${n}.nocommit`);
  });
  const { r, lines } = commandLines(root, ["--max-rounds", "1"]);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const s = state(root);
  for (const slug of slugs) {
    assert.equal(s.retention?.[slug]?.reason, "partial", `${slug} never got its one attempt`);
  }
  assert.equal(
    lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length,
    3,
    "all three issues must be dispatched once, not just the first one claimed",
  );
});

test("CRITICAL findings are promoted into a Phase 2 fix issue and run again", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(
    root,
    "alpha.review",
    `## Branch: crew/demo/alpha\n\`\`\`json\n${JSON.stringify({
      branch: "crew/demo/alpha",
      slug: "alpha",
      verdict: "all-met",
      findings: [
        { severity: "CRITICAL", location: "src/alpha.txt:1", criterion: "Reject unsigned input before use" },
        { severity: "MEDIUM", location: "src/alpha.txt:2", criterion: "Rename the variable" },
      ],
    })}\n\`\`\`\n`,
  );
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const s = state(root);
  assert.ok(s.completed_slugs.includes("alpha"));
  // The promoted fix issue ran as its own issue in Phase 2.
  const fixIssues = s.completed_slugs.filter((x) => x !== "alpha");
  assert.equal(fixIssues.length, 1, `expected one promoted fix issue, got ${JSON.stringify(s.completed_slugs)}`);
  const criteria = join(root, ".scratch/demo/reviews/alpha.criteria.md");
  assert.equal(existsSync(criteria), true);
  const text = readFileSync(criteria, "utf8");
  assert.match(text, /\[CRITICAL\] Reject unsigned input before use \(src\/alpha\.txt:1\)/);
  assert.doesNotMatch(text, /MEDIUM/, "MEDIUM is never promoted");
});

test("two dry rounds stall instead of looping forever", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.worker", '## Issue: alpha\nStatus: partial\n\n```json\n{"status":"partial","progress":"stuck"}\n```');
  fake(root, "alpha.nocommit");
  const r = runSprint(root);
  assert.equal(r.code, 2, "stall exits 2");
  const s = state(root);
  assert.equal(s.rounds, 2, "one dry round is a retry, two is a stall");
  assert.match(s.retention.alpha.reason, /partial/);
});

// ─── a verify with no verdict: killed from outside, or output that names no failing check ──

/** Replaces verify-worktree.sh in a private scripts copy with `body`. */
function shimVerify(body) {
  const scripts = privateScripts();
  writeFileSync(join(scripts, "verify-worktree.sh"), `#!/usr/bin/env bash\n${body}\n`);
  return scripts;
}

const triageSpawns = (lines) => lines.filter((l) => /^SPAWN .*--agent crew-triage/.test(l)).length;

test("a verify killed by SIGTERM is interrupted, not failed: no triage, no coder, a free retry", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const scripts = shimVerify('echo "TYPECHECK: not_run"\necho "TEST: running: bats tests/*.bats"\nkill -TERM $$');
  fake(root, "alpha.triage", triageVerdict("yes", "inconclusive", "no evidence"));
  const { r, lines } = commandLines(root, ["--max-rounds", "1"], { scripts });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(triageSpawns(lines), 0, "an interrupted verify is not triaged");
  assert.equal(coderSpawns(lines), 1, "and no coder is redispatched");
  assert.match(traceLog(root), /\[VERIFY-INTERRUPTED\] slug=alpha round=1 — verify-worktree\.sh was killed by SIGTERM/);
  assert.match(traceLog(root), /\[VERIFY-OUTPUT\] slug=alpha round=1 result=interrupted/);
  assert.doesNotMatch(traceLog(root), /result=fail/);
  assert.match(state(root).retention.alpha.reason, /^verify-interrupted — killed by SIGTERM$/);
});

test("an interrupted verify is verified again next round, still without a coder or triage", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const scripts = shimVerify(
    'M="$(dirname "$0")/.killed"\nif [ ! -f "$M" ]; then touch "$M"; echo "TEST: running: x"; kill -TERM $$; fi\nexec bash "$(dirname "$0")/_real-verify-worktree.sh" "$@"',
  );
  // The real gate, kept next to the shim for its sibling-script lookups.
  sh("cp", [join(SCRIPTS, "verify-worktree.sh"), join(scripts, "_real-verify-worktree.sh")]);
  const { r, lines } = commandLines(root, [], { scripts });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(coderSpawns(lines), 1);
  assert.equal(triageSpawns(lines), 0);
  assert.match(traceLog(root), /\[SKIP-WORKER\] slug=alpha reason=verify-interrupted/);
  assert.deepEqual(state(root).completed_slugs, ["alpha"]);
});

test("verify output with no failing check is run a second time before anything is triaged or recoded", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const scripts = shimVerify('echo "TEST: running: bats tests/*.bats"\nexit 1');
  fake(root, "alpha.triage", triageVerdict("yes", "inconclusive", "no evidence"));
  const { r, lines } = commandLines(root, ["--max-rounds", "1"], { scripts });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(lines.filter((l) => /verify-worktree\.sh --dir/.test(l)).length, 2, "a second verify");
  assert.equal(triageSpawns(lines), 0, "no triage on output with no assertion");
  assert.equal(coderSpawns(lines), 1, "no coder redispatch");
  assert.match(state(root).retention.alpha.reason, /^verify-inconclusive — exit 1 with no failing check in the output$/);
});

test("a verify that really fails still goes to triage", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  failingTests(root);
  fake(root, "alpha.triage", triageVerdict("yes", "wrong host", "src/config.ts uses localhost:4566"));
  const { lines } = commandLines(root, ["--max-rounds", "1"]);
  assert.equal(lines.filter((l) => /verify-worktree\.sh --dir/.test(l)).length, 1, "a named failure is not re-run");
  assert.equal(triageSpawns(lines), 1);
});
