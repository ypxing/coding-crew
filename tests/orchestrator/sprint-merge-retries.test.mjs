/**
 * Sprint suite — merge conflicts and the retries after a merge, close or receipt refusal.
 * Shared helpers: ./helpers/sprint.mjs.
 */

import assert from "node:assert/strict";
import { cpSync, readFileSync, rmSync, writeFileSync, existsSync, unlinkSync } from "node:fs";
import { join, resolve } from "node:path";
import { sh, fixtureRepo, addIssue, BRANCH_REVIEW, traceLog, state, fake, privateScripts, failFirstCall, commandLines, test } from "./helpers/sprint.mjs";

// Two issues editing the same file, dispatched in one round: whichever merges second
// conflicts. Retrying only its merge would conflict again and block; instead the retry
// leaves the conflicted sync merge in its worktree for the coder, then re-runs verify and
// review on the resolution.
test("a merge conflict is retried through the coder, resolved, re-verified, re-reviewed and merged", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-beta.md");
  fake(root, "alpha.shared");
  fake(root, "beta.shared");
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);

  const s = state(root);
  assert.deepEqual([...s.completed_slugs].sort(), ["alpha", "beta"]);
  assert.deepEqual([...s.merged_branches].sort(), ["crew/demo/alpha", "crew/demo/beta"]);
  const shared = sh("git", ["-C", root, "show", "feature/demo:src/shared.txt"]).stdout;
  assert.deepEqual(shared.trim().split("\n").sort(), ["alpha", "beta"], "both sides survive the resolution");

  const log = traceLog(root);
  const kept = log.match(/\[SYNC-CONFLICT-KEPT\] slug=(\w+) branch=\S+ files=src\/shared\.txt/);
  assert.ok(kept, `no kept sync conflict in the trace log:\n${log}`);
  const loser = kept[1];
  assert.match(log, new RegExp(`MERGE\\] branch=crew/demo/${loser} success=false reason=conflict`));
  assert.doesNotMatch(log, /\[SKIP-TO-MERGE\]/, "a conflict must not take the merge-only route");
  const prompt = readFileSync(join(root, `.scratch/demo/dispatch/${loser === "alpha" ? "01" : "02"}-${loser}/conflict-prompt.md`), "utf8");
  assert.match(prompt, /A merge of `feature\/demo` into this branch is in progress/);
  assert.match(prompt, /^- src\/shared\.txt$/m);

  // Three coder runs (two issues, plus the resolution), and verify + review re-ran on it.
  assert.equal(lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length, 3);
  assert.equal(lines.filter((l) => BRANCH_REVIEW.test(l)).length, 3);
  assert.equal(lines.filter((l) => /verify-worktree\.sh --dir/.test(l)).length, 3);
});

// Three issues on one file, all dispatched at once: two conflict. Their retries each resolve
// against the feature-branch tip, so run together the second would conflict again with the
// first's resolution and hit the retry cap. One at a time, both merge.
test("merge-conflict retries run one at a time, so a sibling's resolution can't re-conflict the next", () => {
  const root = fixtureRepo();
  for (const name of ["01-alpha.md", "02-beta.md", "03-gamma.md"]) {
    fake(root, `${addIssue(root, name)}.shared`);
  }
  const { r } = commandLines(root, ["--max-parallel", "3"]);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);

  const s = state(root);
  assert.deepEqual([...s.completed_slugs].sort(), ["alpha", "beta", "gamma"], traceLog(root));
  const shared = sh("git", ["-C", root, "show", "feature/demo:src/shared.txt"]).stdout;
  assert.deepEqual(shared.trim().split("\n").sort(), ["alpha", "beta", "gamma"]);
  assert.match(traceLog(root), /\[CONFLICT-RETRY-WAIT\] slug=\w+/);
});

test("a rerun after a merge conflict spent the retry cap resolves it through the coder, not a restart", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-beta.md");
  fake(root, "alpha.shared");
  fake(root, "beta.shared");
  // Whichever loses the first merge can't resolve it, so its one retry conflicts again.
  fake(root, "alpha.no-resolve");
  fake(root, "beta.no-resolve");
  const capped = commandLines(root, ["--max-parallel", "2"]);
  assert.equal(capped.r.code, 2, `${capped.r.stdout}\n${capped.r.stderr}`);
  let s = state(root);
  assert.equal(s.blocked_slugs?.length, 1, traceLog(root));
  const loser = s.blocked_slugs[0];
  assert.match(s.retention?.[loser]?.reason ?? "", /retry limit reached .* merge-conflict/);

  unlinkSync(join(root, ".scratch/fake", `${loser}.no-resolve`));
  const rerun = commandLines(root);
  assert.equal(rerun.r.code, 0, `${rerun.r.stdout}\n${rerun.r.stderr}`);
  s = state(root);
  assert.deepEqual([...s.completed_slugs].sort(), ["alpha", "beta"]);
  assert.match(traceLog(root), new RegExp(`\\[SYNC-CONFLICT-KEPT\\] slug=${loser} `));
  const shared = sh("git", ["-C", root, "show", "feature/demo:src/shared.txt"]).stdout;
  assert.deepEqual(shared.trim().split("\n").sort(), ["alpha", "beta"]);
});

// Any retry can find the feature branch moved on under its branch, not only a
// merge-conflict one: a sibling merged while this issue waited on its fix. Aborting that
// sync blocked the issue; the coder resolves it instead, alongside whatever it was
// retrying for. Run 1 retains alpha; in run 2, beta (sorted first, --max-parallel 1)
// merges an edit to the same file before alpha's retry syncs.
for (const [label, retained, setup] of [
  ["a criteria-unmet retry", /criteria-unmet/, (root) => fake(root, "alpha.review", `\`\`\`json\n${JSON.stringify({ branch: "crew/demo/alpha", slug: "alpha", verdict: "unmet", detail: "AC 1 has no test", findings: [] })}\n\`\`\`\n`)],
  ["a review-only retry", /^review-not-run — /, (root) => fake(root, "alpha.review-once", "2")],
]) {
  test(`${label} whose sync conflicts hands the conflict to the coder instead of blocking`, () => {
    const root = fixtureRepo();
    addIssue(root, "01-alpha.md");
    fake(root, "alpha.shared");
    setup(root);
    const first = commandLines(root, ["--max-rounds", "1"]);
    assert.equal(first.r.code, 0, `${first.r.stdout}\n${first.r.stderr}`);
    assert.match(state(root).retention?.alpha?.reason ?? "", retained);

    rmSync(join(root, ".scratch/fake/alpha.review"), { force: true });
    // The fix dispatch runs after the conflict one; it must not rewrite the merged file.
    rmSync(join(root, ".scratch/fake/alpha.shared"), { force: true });
    addIssue(root, "00-beta.md");
    fake(root, "beta.shared");
    const second = commandLines(root, ["--max-parallel", "1"]);
    assert.equal(second.r.code, 0, `${second.r.stdout}\n${second.r.stderr}`);
    const s = state(root);
    assert.deepEqual([...s.completed_slugs].sort(), ["alpha", "beta"], traceLog(root));
    assert.match(traceLog(root), /\[SYNC-CONFLICT-KEPT\] slug=alpha /);
    assert.doesNotMatch(traceLog(root), /\[SYNC-CONFLICT\] slug=alpha/);
    const dir = join(root, ".scratch/demo/dispatch/01-alpha");
    assert.match(readFileSync(join(dir, "conflict-prompt.md"), "utf8"), /A merge of `feature\/demo` into this branch is in progress/);
    if (label.startsWith("a criteria")) {
      const prompt = readFileSync(join(dir, "prompt.md"), "utf8");
      assert.match(prompt, /AC 1 has no test/, "the review fix is still asked for");
      assert.doesNotMatch(prompt, /in progress|git commit --no-edit/, "no conflict text in the fix prompt");
    }
    const shared = sh("git", ["-C", root, "show", "feature/demo:src/shared.txt"]).stdout;
    assert.deepEqual(shared.trim().split("\n").sort(), ["alpha", "beta"]);
  });
}

// The conflict dispatch is recorded under its own role: a fix attempt at the same tip must not
// resume it as the coder's session. Attempt 1 is a verify route (review-not-run) whose sync
// conflicts; its review then finds the criteria unmet, so attempt 2 is a fix round.
test("a fix attempt after a verify-route attempt's conflict dispatch starts a fresh coder session", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.shared");
  fake(root, "alpha.review-once", "2");
  const first = commandLines(root, ["--max-rounds", "1"], { platform: "claude" });
  assert.equal(first.r.code, 0, `${first.r.stdout}\n${first.r.stderr}`);
  assert.match(state(root).retention?.alpha?.reason ?? "", /^review-not-run — /);

  rmSync(join(root, ".scratch/fake/alpha.review-once"), { force: true });
  rmSync(join(root, ".scratch/fake/alpha.review-once.calls"), { force: true });
  rmSync(join(root, ".scratch/fake/alpha.shared"), { force: true });
  fake(root, "alpha.review", `\`\`\`json\n${JSON.stringify({ branch: "crew/demo/alpha", slug: "alpha", verdict: "unmet", detail: "AC 1 has no test", findings: [] })}\n\`\`\`\n`);
  addIssue(root, "00-beta.md");
  fake(root, "beta.shared");
  commandLines(root, ["--max-parallel", "1", "--resume-coder-session"], { platform: "claude" });

  const log = traceLog(root);
  assert.match(log, /\[SYNC-CONFLICT-KEPT\] slug=alpha /);
  assert.match(log, /slug=01-alpha round=1 step=dispatch-conflict/);
  assert.match(log, /\[FRESH-SESSION\] slug=alpha round=2 /, log);
  assert.doesNotMatch(log, /\[RESUME-SESSION\] slug=alpha/);
  const ledger = state(root).dispatches.filter((d) => d.slug === "alpha");
  const conflict = ledger.find((d) => d.role === "conflict");
  assert.ok(conflict?.head, "the conflict dispatch is recorded under its own role");
  assert.equal(ledger.some((d) => d.role === "coder" && d.head === conflict.head), false, "no coder entry at the conflict's tip");
});

test("a conflict dispatch that leaves the merge unresolved is judged by git, and the original route does not run", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.shared");
  fake(root, "alpha.review-once", "2");
  const first = commandLines(root, ["--max-rounds", "1"]);
  assert.equal(first.r.code, 0, `${first.r.stdout}\n${first.r.stderr}`);
  rmSync(join(root, ".scratch/fake/alpha.shared"), { force: true });
  addIssue(root, "00-beta.md");
  fake(root, "beta.shared");
  fake(root, "alpha.no-resolve");
  const second = commandLines(root, ["--max-parallel", "1"]);
  const log = traceLog(root);
  assert.match(log, /\[CONFLICT-UNRESOLVED\] slug=alpha /, `${second.r.stdout}\n${log}`);
  assert.match(log, /merge-conflict/, "retained as a conflict");
  assert.match(log, /step=dispatch-conflict/);
  assert.doesNotMatch(log, /slug=01-alpha round=\d+ step=dispatch-coder/, "the original route's coder never ran");
});

test("a close-refused retry skips the worker, verify, and review, no-ops the already-merged retry, and succeeds on a retried close", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const scripts = privateScripts();
  const marker = join(root, ".scratch/close-fail.marker");
  failFirstCall(scripts, "close-issue.sh", marker, "ERROR: forced close failure for test");

  const round1 = commandLines(root, ["--max-rounds", "1"], { scripts });
  assert.equal(round1.r.code, 0, `${round1.r.stdout}\n${round1.r.stderr}`);
  let s = state(root);
  assert.match(s.retention?.alpha?.reason ?? "", /^close-refused/);
  // retain() (unlike complete()) never adds to merged_branches, and actively strips the
  // branch back out of it — merged_branches tracks *closed* issues, not git-level merge
  // success — so the merge having actually succeeded shows up in the trace log instead.
  assert.deepEqual(s.merged_branches ?? [], []);
  assert.deepEqual(s.completed_slugs ?? [], []);
  assert.match(traceLog(root), /\[MERGE\] branch=crew\/demo\/alpha success=true/);
  assert.equal(round1.lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length, 1);
  assert.equal(round1.lines.filter((l) => BRANCH_REVIEW.test(l)).length, 1);
  assert.equal(round1.lines.filter((l) => /verify-worktree\.sh --dir/.test(l)).length, 1);
  assert.equal(existsSync(join(root, ".scratch/demo/issues/open/01-alpha.md")), true, "close was refused, so the issue stays open");
  assert.match(
    readFileSync(join(root, ".scratch/demo/issues/open/01-alpha.md"), "utf8"),
    /## Progress/,
  );

  const round2 = commandLines(root, ["--max-rounds", "1"], { scripts });
  assert.equal(round2.r.code, 0, `${round2.r.stdout}\n${round2.r.stderr}`);
  s = state(root);
  assert.deepEqual(s.completed_slugs, ["alpha"]);
  assert.equal(s.retention?.alpha, undefined);
  assert.equal(existsSync(join(root, ".scratch/demo/issues/done/01-alpha.md")), true);
  // No worker, verify, or review ran in round 2. The merge ran again too — merge-
  // branches.sh's own already-merged short-circuit is what makes that safe, not new
  // pipeline logic — and reported success with no action before close retried.
  assert.equal(round2.lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length, 0);
  assert.equal(round2.lines.filter((l) => BRANCH_REVIEW.test(l)).length, 0);
  assert.equal(round2.lines.filter((l) => /verify-worktree\.sh --dir/.test(l)).length, 0);
  assert.match(round2.r.stderr, /already-merged/);
  assert.match(traceLog(root), /\[SKIP-TO-MERGE\] slug=alpha reason=close-refused/);
});

test("an ac receipt that can't be written retries review without the coder, blocks with the error, and resumes at verify once fixed", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  // `receipts.sh write ac` fails while the flag exists; every other receipts.sh call (the
  // verify receipt, the checks) runs the real script. Removing the flag is the human fix.
  const scripts = privateScripts();
  const flag = join(root, ".scratch/ac-receipt-broken");
  writeFileSync(flag, "");
  const real = join(scripts, "_real-receipts.sh");
  cpSync(join(scripts, "receipts.sh"), real);
  writeFileSync(
    join(scripts, "receipts.sh"),
    [
      "#!/usr/bin/env bash",
      `if [ "$1 $2" = "write ac" ] && [ -f ${JSON.stringify(flag)} ]; then`,
      '  echo "ERROR: forced ac receipt failure" >&2',
      "  exit 1",
      "fi",
      `exec bash ${JSON.stringify(real)} "$@"`,
      "",
    ].join("\n"),
  );
  const count = (lines, re) => lines.filter((l) => re.test(l)).length;

  const broken = commandLines(root, [], { scripts });
  assert.equal(broken.r.code, 2, `${broken.r.stdout}\n${broken.r.stderr}`);
  let s = state(root);
  assert.deepEqual(s.blocked_slugs, ["alpha"]);
  assert.match(s.retention?.alpha?.reason ?? "", /retry limit reached .* ac-receipt-failed — ERROR: forced ac receipt failure/);
  assert.equal(count(broken.lines, /^SPAWN .*--agent crew-coder/), 1, "the retry never re-ran the coder");
  assert.equal(count(broken.lines, BRANCH_REVIEW), 2, "the retry re-ran review before rewriting the receipt");
  assert.match(traceLog(root), /\[SKIP-WORKER\] slug=alpha reason=ac-receipt-retry/);
  const issue = readFileSync(join(root, ".scratch/demo/issues/open/01-alpha.md"), "utf8");
  assert.match(issue, /## Blocked[\s\S]*ERROR: forced ac receipt failure/, "the human sees the real cause");

  rmSync(flag);
  const fixed = commandLines(root, [], { scripts });
  assert.equal(fixed.r.code, 0, `${fixed.r.stdout}\n${fixed.r.stderr}`);
  s = state(root);
  assert.deepEqual(s.completed_slugs, ["alpha"]);
  assert.deepEqual(s.merged_branches, ["crew/demo/alpha"]);
  assert.equal(count(fixed.lines, /^SPAWN .*--agent crew-coder/), 0, "resumed at verify, not a coder restart");
  assert.equal(count(fixed.lines, BRANCH_REVIEW), 1);
  assert.equal(existsSync(join(root, ".scratch/demo/issues/done/01-alpha.md")), true);
});

test("a blocked issue's branch is resumed and synced on the next run, not re-blocked as stale once siblings merge", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-beta.md");
  // alpha's worker commits, then reports itself blocked; beta then merges, moving the
  // feature branch past the point alpha's branch forked from.
  const blockedReport = (dir) =>
    `## Issue: alpha\nStatus: blocked\n\n\`\`\`json\n${JSON.stringify({ status: "blocked", branch: "crew/demo/alpha", working_directory: dir, checks: { test: "pass", lint: "pass", typecheck: "pass" }, progress: "", notes: "needs a decision on the API shape" })}\n\`\`\`\n`;
  fake(root, "alpha.worker", blockedReport(join(root, ".scratch/worktrees/crew/demo/alpha")));

  const first = commandLines(root, ["--max-parallel", "1"]);
  let s = state(root);
  assert.deepEqual(s.blocked_slugs, ["alpha"], `${first.r.stdout}\n${first.r.stderr}`);
  assert.deepEqual(s.merged_branches, ["crew/demo/beta"]);
  assert.match(readFileSync(join(root, ".scratch/demo/issues/open/01-alpha.md"), "utf8"), /## Blocked/);

  // The human answers the question; the worker now completes.
  rmSync(join(root, ".scratch/fake/alpha.worker"));
  const second = commandLines(root, ["--max-parallel", "1"]);
  assert.equal(second.r.code, 0, `${second.r.stdout}\n${second.r.stderr}`);
  s = state(root);
  assert.doesNotMatch(traceLog(root), /\[STALE-BRANCH\] slug=alpha/);
  assert.deepEqual([...s.completed_slugs].sort(), ["alpha", "beta"]);
  assert.equal(second.lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length, 1);
  // Resumed on the blocked worker's branch: each fake worker run appends one line, so the
  // blocked attempt's line is still there alongside the resumed one's.
  assert.equal(readFileSync(join(root, "src/alpha.txt"), "utf8"), "// alpha\n// alpha\n");
});

test("a branch refused as stale stays refused on the next run, not resumed as the issue's own", () => {
  const root = fixtureRepo();
  const git = (...args) => sh("git", ["-C", root, ...args]);
  const count = (lines, re) => lines.filter((l) => re.test(l)).length;
  addIssue(root, "01-alpha.md");
  // A leftover branch with unique work, forked before the feature branch moved on.
  git("checkout", "-q", "-b", "crew/demo/alpha");
  writeFileSync(join(root, "leftover.txt"), "abandoned work\n");
  git("add", "-A");
  git("commit", "-q", "-m", "leftover work");
  git("checkout", "-q", "feature/demo");
  writeFileSync(join(root, "advance.txt"), "advance\n");
  git("add", "-A");
  git("commit", "-q", "-m", "advance the feature branch");

  const first = commandLines(root, ["--max-parallel", "1"]);
  assert.deepEqual(state(root).blocked_slugs, ["alpha"], `${first.r.stdout}\n${first.r.stderr}`);
  assert.equal(state(root).retained_branches?.alpha, undefined, "a refused branch is not this issue's own");

  const second = commandLines(root, ["--max-parallel", "1"]);
  assert.match(traceLog(root), /\[STALE-BRANCH\] slug=alpha/, "still refused on the rerun");
  assert.equal(count(second.lines, /^SPAWN .*--agent crew-coder/), 0, "no coder is dispatched onto the leftover branch");
});

test("a criteria-unmet retry still redispatches the full worker, not just review", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(
    root,
    "alpha.review",
    `## Branch: crew/demo/alpha\n\`\`\`json\n${JSON.stringify({ branch: "crew/demo/alpha", slug: "alpha", verdict: "unmet", detail: "no test covers the criterion", findings: [] })}\n\`\`\`\n`,
  );
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 2, "unmet criteria never resolve on their own, so the sprint stalls");
  const s = state(root);
  assert.match(s.retention.alpha.reason, /criteria-unmet/);
  assert.match(s.retention.alpha.reason, /^blocked — retry limit reached/, "the retry cap blocks it");
  assert.match(s.retention.alpha.fingerprint ?? "", /^[0-9a-f]{64}$/, "a blocked retention keeps the issue fingerprint");
  assert.equal(
    lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length,
    2,
    "the coder must run again — a criteria-unmet retention means the branch's content needs work, not just another review",
  );
});

const unmetReview = (extra = {}) =>
  `## Branch: crew/demo/alpha\n\`\`\`json\n${JSON.stringify({ branch: "crew/demo/alpha", slug: "alpha", verdict: "unmet", detail: "no test covers the criterion", findings: [], ...extra })}\n\`\`\`\n`;

test("a review fix round that commits nothing blocks without a second review", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.review", unmetReview());
  fake(root, "alpha.commit-once", "1");
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 2);
  assert.equal(lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length, 2);
  assert.equal(lines.filter((l) => BRANCH_REVIEW.test(l)).length, 1, "the unchanged commit is not reviewed again");
  assert.match(state(root).retention.alpha.reason, /^blocked — criteria-unmet — the fix round made no commit, so crew\/demo\/alpha is still at [0-9a-f]{12}, already judged unmet: no test covers the criterion$/);
});

test("an unmet verdict the reviewer puts down to the environment blocks at once, and a re-run re-checks without the coder", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.review", unmetReview({ cause: "environment", detail: "LocalStack unreachable, specs skipped" }));
  const first = commandLines(root);
  assert.equal(first.r.code, 2);
  assert.equal(first.lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length, 1, "no coder round can fix the environment");
  assert.equal(state(root).retention.alpha.reason, "blocked — criteria-unmet:environment — LocalStack unreachable, specs skipped");

  // The human fixes the environment and re-runs: verify runs again (its pass was another
  // run's), review passes, and the branch merges — with no coder.
  unlinkSync(join(root, ".scratch/fake/alpha.review"));
  const second = commandLines(root);
  assert.equal(second.r.code, 0, `${second.r.stdout}\n${second.r.stderr}`);
  assert.equal(second.lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length, 0);
  assert.equal(second.lines.filter((l) => /verify-worktree\.sh --dir/.test(l)).length, 1);
  assert.deepEqual(state(root).merged_branches, ["crew/demo/alpha"]);
});

test("a verify pass from an earlier run is not reused: a re-run verifies the same commit again", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  // Both round-1 reviews leave no report, and --max-rounds 1 ends the run there.
  fake(root, "alpha.review-once", "2");
  const first = commandLines(root, ["--max-rounds", "1"]);
  assert.match(state(root).retention.alpha.reason, /^review-not-run/, `${first.r.stdout}\n${first.r.stderr}`);
  const second = commandLines(root);
  assert.equal(second.r.code, 0, `${second.r.stdout}\n${second.r.stderr}`);
  assert.equal(second.lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length, 0);
  assert.equal(second.lines.filter((l) => /verify-worktree\.sh --dir/.test(l)).length, 1);
  assert.doesNotMatch(traceLog(root), /verify already passed at this commit/);
});

test("a verification-failed retry still redispatches the full worker, not just review", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  // Override the Makefile so the real check the pipeline runs fails, regardless of what
  // the worker's own report claims (the default fake worker reports every check as pass).
  writeFileSync(join(root, "Makefile"), "test:\n\t@echo boom && exit 1\nlint:\n\t@echo ok\ntypecheck:\n\t@echo ok\n");
  sh("git", ["-C", root, "add", "-A"]);
  sh("git", ["-C", root, "commit", "-q", "-m", "make test always fail"]);
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 2);
  const s = state(root);
  assert.equal(s.retention.alpha.reason, "blocked — retry limit reached (2 attempts) — verification-failed");
  assert.equal(
    lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length,
    2,
    "the coder must run again — a verification-failed branch needs its content fixed, not just a review retry",
  );
  // A failed verify routes to triage (not the coder) to classify the failure — that
  // dispatch needs the same live-stream visibility as the coder/review dispatches.
  const steps = r.stderr.split("\n").filter((l) => l.startsWith("[STEP]") && l.includes("slug=01-alpha"));
  assert.ok(
    steps.some((l) => /^\[STEP\] slug=01-alpha round=1 step=dispatch-triage model=.+$/.test(l)),
    `expected a round-1 dispatch-triage step marker, got:\n${steps.join("\n")}`,
  );
});
