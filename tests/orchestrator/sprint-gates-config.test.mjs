/**
 * Sprint suite — the gate order, the per-role config, and the PRD audit.
 * Shared helpers: ./helpers/sprint.mjs.
 */

import assert from "node:assert/strict";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { MAIN, TMPDIR, SCRIPTS, FAKE, sh, fixtureRepo, addIssue, BRANCH_REVIEW, runSprint, traceLog, markerAt, reviewReports, state, fake, AUDIT_WITH_GAP, commandLines, test } from "./helpers/sprint.mjs";

// ─── what the deleted claude prose used to assert about itself ───────────────
//
// The claude cutover removed the last hand-written orchestrator body that named the
// pipeline. Its prose assertions (review before merge, review before squash, no
// post-squash review, the report path, the skip case, the resume note, retention
// surviving cleanup, the wrap-up order) are behaviour, so they are asserted here on a
// real run with every model dispatch faked.

test("the gates run in order: verify → AC receipt → merge → close, and squash last", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const r = runSprint(root, ["--squash"]);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const log = traceLog(root);
  const verify = markerAt(log, "VERIFY");
  const ac = markerAt(log, "ACVERIFY");
  const merge = markerAt(log, "MERGE");
  const close = markerAt(log, "CLOSE");
  const squash = markerAt(log, "SQUASH");
  assert.ok(verify < ac, "the AC receipt was written before verification finished");
  assert.ok(ac < merge, "the branch merged before its acceptance criteria were verified");
  assert.ok(merge < close, "the issue closed before the merge — a failed merge would orphan it");
  assert.ok(close < squash, "the squash ran before the pipeline finished");
});

test("a squash refused by a hook is reported in the summary, and the merged commits stay committed", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  // Refuses only the squash's own message, so the worker's commits and the merge still land.
  const hook = join(root, ".git/hooks/commit-msg");
  writeFileSync(hook, "#!/bin/sh\ngrep -q '^Demo:' \"$1\" && { echo 'commit-msg: rejected' >&2; exit 1; }\nexit 0\n");
  chmodSync(hook, 0o755);
  const r = runSprint(root, ["--squash"]);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stdout, /## Squash\n\n\*\*Failed:\*\* [\s\S]*commit-msg: rejected/);
  const git = (...args) => sh("git", ["-C", root, ...args]).stdout.trim();
  assert.equal(git("status", "--porcelain", "--untracked-files=no"), "");
  assert.match(git("log", "--format=%s", "main..HEAD"), /Merge/);
});

test("the review is written to the sprint's reviews dir, before the squash", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  runSprint(root, ["--squash"]);
  const reports = reviewReports(root);
  assert.equal(reports.length, 1, `expected one sprint-review file, got ${JSON.stringify(reports)}`);
  const text = readFileSync(join(root, ".scratch/demo/reviews", reports[0]), "utf8");
  assert.match(text, /## Branch: /);
  // The review is the merge's gate, so it cannot be a post-squash pass over merged code.
  const log = traceLog(root);
  assert.ok(markerAt(log, "ACVERIFY") < markerAt(log, "SQUASH"));
});

test("a branch that fails verification is never reviewed, and no report is written", () => {
  // The old prose said: with no verified branches this round, print "skipped" and write
  // no report. The code equivalent is that nothing is dispatched and no file appears.
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  writeFileSync(join(root, "Makefile"), "test:\n\t@echo boom && exit 1\nlint:\n\t@echo ok\ntypecheck:\n\t@echo ok\n");
  sh("git", ["-C", root, "add", "-A"]);
  sh("git", ["-C", root, "commit", "-q", "-m", "make test always fail"]);
  runSprint(root);
  assert.deepEqual(reviewReports(root), []);
  assert.equal(existsSync(join(root, ".scratch/demo/dispatch/01-alpha/review.md")), false);
});

test("a retained branch survives cleanup, is named in the summary, and resumes next round", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.worker", '## Issue: alpha\nStatus: partial\n\n```json\n{"status":"partial","progress":"stuck"}\n```');
  // The partial's commits go to verify, which fails; triage leaves no verdict, so a restart.
  writeFileSync(join(root, "Makefile"), "test:\n\t@echo boom && exit 1\nlint:\n\t@echo ok\ntypecheck:\n\t@echo ok\n");
  sh("git", ["-C", root, "add", "-A"]);
  sh("git", ["-C", root, "commit", "-q", "-m", "make test always fail"]);
  const r = runSprint(root);
  assert.equal(r.code, 2);
  // Cleanup deletes merged branches only; a retained one keeps its committed WIP.
  const branches = sh("git", ["-C", root, "branch", "--list", "crew/demo/alpha"]).stdout.trim();
  assert.match(branches, /crew\/demo\/alpha/, "cleanup deleted a retained branch");
  assert.match(r.stdout, /## Retained Branches/);
  assert.match(r.stdout, /crew\/demo\/alpha: retained \(.*verification-failed\)/);
  // Round 2 was told to resume on that branch rather than start over — and that the
  // notes are context alongside the preserved code, not a substitute for it.
  const prompt = readFileSync(join(root, ".scratch/demo/dispatch/01-alpha/prompt.md"), "utf8");
  assert.match(prompt, /Resume on that existing branch/);
  assert.match(prompt, /crew\/demo\/alpha/);
  assert.match(prompt, /not a substitute for it/);
});

test("a merged branch's worktree and ref are both gone after cleanup", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  runSprint(root);
  assert.equal(existsSync(join(root, ".scratch/worktrees/crew/demo/alpha")), false);
  assert.equal(sh("git", ["-C", root, "branch", "--list", "crew/demo/alpha"]).stdout.trim(), "");
});

test("the summary is kept in the trace log too, not only printed", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(traceLog(root), / INFO  \[SUMMARY\]\n  Rounds: \d+\n  Model: /);
});

test("the summary names the resolved model, rendered from disk", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const r = runSprint(root, ["--model", "sonnet"]);
  assert.match(r.stdout, /Model:\s+sonnet/);
  assert.equal(state(root).model, "sonnet");
  assert.match(traceLog(root), /\[MODEL\]/);
});

test(".coding-crew/config.json lets the reviewer diverge from the coder's model, on the claude platform", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  mkdirSync(join(root, ".coding-crew"), { recursive: true });
  writeFileSync(
    join(root, ".coding-crew/config.json"),
    JSON.stringify({ afk: { models: { claude: { coder: "sonnet", reviewer: "opus" } } } }),
  );
  const { r, lines } = commandLines(root, [], { platform: "claude" });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.ok(
    lines.some((l) => /^SPAWN .*--agent crew-coder/.test(l) && / --model sonnet/.test(l)),
    `expected the coder dispatched with --model sonnet, got:\n${lines.join("\n")}`,
  );
  assert.ok(
    lines.some((l) => BRANCH_REVIEW.test(l) && / --model opus/.test(l)),
    `expected the reviewer dispatched with --model opus, got:\n${lines.join("\n")}`,
  );
});

test("a legacy afk-models.json is moved into config.json by `run`, and still ignored on a non-claude platform", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  mkdirSync(join(root, ".coding-crew"), { recursive: true });
  writeFileSync(
    join(root, ".coding-crew/afk-models.json"),
    JSON.stringify({ coder: "sonnet", reviewer: "opus" }),
  );
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stderr, /moved \.coding-crew\/afk-models\.json into \.coding-crew\/config\.json/);
  assert.equal(existsSync(join(root, ".coding-crew/afk-models.json")), false);
  assert.deepEqual(JSON.parse(readFileSync(join(root, ".coding-crew/config.json"), "utf8")), {
    afk: { models: { claude: { coder: "sonnet", reviewer: "opus" } } },
  });
  assert.ok(
    lines.some((l) => /^SPAWN .*--agent crew-coder/.test(l) && !/ --model /.test(l)),
    `expected the pi coder dispatched with no --model, got:\n${lines.join("\n")}`,
  );
});

test("a `run` that fails setup leaves a legacy afk-models.json where it is", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  mkdirSync(join(root, ".coding-crew"), { recursive: true });
  writeFileSync(join(root, ".coding-crew/afk-models.json"), JSON.stringify({ coder: "opus" }));
  const r = sh("node", [MAIN, "run", "--platform", "claude", "--feature-slug", "demo", "--max-parallel"], {
    cwd: root,
    env: { ...process.env, CREW_SCRIPTS: SCRIPTS, CREW_FAKE_DISPATCH: FAKE, MAIN_ROOT: root },
  });
  assert.equal(r.code, 1, `${r.stdout}\n${r.stderr}`);
  assert.doesNotMatch(r.stderr, /moved \.coding-crew\/afk-models\.json/);
  assert.equal(existsSync(join(root, ".coding-crew/afk-models.json")), true);
  assert.equal(existsSync(join(root, ".coding-crew/config.json")), false);
});

test("`plan` does not move a legacy afk-models.json, only says it would", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  mkdirSync(join(root, ".coding-crew"), { recursive: true });
  writeFileSync(join(root, ".coding-crew/afk-models.json"), JSON.stringify({ coder: "opus" }));
  const r = sh("node", [MAIN, "plan", "--platform", "claude", "--feature-slug", "demo"], {
    cwd: root,
    env: { ...process.env, CREW_SCRIPTS: SCRIPTS, CREW_FAKE_DISPATCH: FAKE, MAIN_ROOT: root },
  });
  assert.match(r.stderr, /will be moved into \.coding-crew\/config\.json/);
  assert.equal(existsSync(join(root, ".coding-crew/afk-models.json")), true);
  assert.equal(existsSync(join(root, ".coding-crew/config.json")), false);
  assert.match(r.stdout, /coder\s+claude\s+opus/);
});

test("`plan` shows which config file set each role's runtime and model", () => {
  const root = fixtureRepo();
  const home = mkdtempSync(join(TMPDIR, "crew-sprint-userhome-"));
  mkdirSync(join(home, ".coding-crew"), { recursive: true });
  mkdirSync(join(root, ".coding-crew"), { recursive: true });
  writeFileSync(join(home, ".coding-crew/config.json"), JSON.stringify({ afk: { runtime: { reviewer: "codex" } } }));
  writeFileSync(join(root, ".coding-crew/config.json"), JSON.stringify({ afk: { models: { claude: { triage: "opus" } } } }));
  const r = sh("node", [MAIN, "plan", "--platform", "claude", "--feature-slug", "demo"], {
    cwd: root,
    env: { ...process.env, HOME: home, CREW_SCRIPTS: SCRIPTS, CREW_FAKE_DISPATCH: FAKE, MAIN_ROOT: root },
  });
  assert.match(r.stdout, /reviewer\s+codex\s+runtime default\s+\[runtime: user\]/, r.stdout);
  assert.match(r.stdout, /triage\s+claude\s+opus.*\[model: project\]/, r.stdout);
  assert.match(r.stdout, /coder\s+claude\s+sonnet(?!.*\[)/, r.stdout);
  rmSync(home, { recursive: true, force: true });
});

test("`plan` credits --model, not the config file, when it overrides the file's coder model", () => {
  const root = fixtureRepo();
  mkdirSync(join(root, ".coding-crew"), { recursive: true });
  writeFileSync(join(root, ".coding-crew/config.json"), JSON.stringify({ afk: { models: { claude: { coder: "haiku" } } } }));
  const r = sh("node", [MAIN, "plan", "--platform", "claude", "--model", "opus", "--feature-slug", "demo"], {
    cwd: root,
    env: { ...process.env, CREW_SCRIPTS: SCRIPTS, CREW_FAKE_DISPATCH: FAKE, MAIN_ROOT: root },
  });
  assert.match(r.stdout, /coder\s+claude\s+opus.*\[model: --model\]/, r.stdout);
  assert.doesNotMatch(r.stdout, /coder.*\[model: project\]/, r.stdout);
});

test("a mixed crew dispatches each role on its own runtime, with only that runtime's model", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  mkdirSync(join(root, ".coding-crew"), { recursive: true });
  writeFileSync(
    join(root, ".coding-crew/config.json"),
    JSON.stringify({ afk: { runtime: { reviewer: "codex" }, models: { claude: { coder: "sonnet" } } } }),
  );
  const { r, lines } = commandLines(root, [], { platform: "claude" });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const spawn = (agent) => lines.find((l) => new RegExp(`^SPAWN .*--agent ${agent} `).test(l)) ?? "";
  assert.match(spawn("crew-coder"), / --runtime claude .* --model sonnet/);
  assert.match(spawn("crew-reviewer"), / --runtime codex /);
  assert.doesNotMatch(spawn("crew-reviewer"), / --model /, "a claude alias must never reach codex");
});

test("a runtime's model env var (ANTHROPIC_DEFAULT_*_MODEL) reaches the dispatched child", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const { r } = commandLines(root, [], {
    platform: "claude",
    env: { ANTHROPIC_DEFAULT_SONNET_MODEL: "au.anthropic.claude-sonnet-5", CREW_FAKE_ECHO_ENV: "ANTHROPIC_DEFAULT_SONNET_MODEL" },
  });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  // Agent dispatches and the agent-less plain dispatch (command discovery) alike.
  for (const agent of ["crew-coder", "crew-reviewer", "commands-discovery"]) {
    assert.equal(
      readFileSync(join(root, ".scratch/fake", `env.${agent}`), "utf8").trim(),
      "ANTHROPIC_DEFAULT_SONNET_MODEL=au.anthropic.claude-sonnet-5",
      agent,
    );
  }
});

test("an invalid config.json is a setup error naming every problem", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  mkdirSync(join(root, ".coding-crew"), { recursive: true });
  writeFileSync(
    join(root, ".coding-crew/config.json"),
    JSON.stringify({ afk: { runtime: { reviwer: "codex", triage: "cursor" } } }),
  );
  const { r } = commandLines(root);
  assert.equal(r.code, 1);
  assert.match(r.stderr, /unknown role "afk\.runtime\.reviwer"/);
  assert.match(r.stderr, /"afk\.runtime\.triage" is "cursor"/);
});

test("doctor names the role when a runtime other than the launcher's is not installed", () => {
  const root = fixtureRepo();
  mkdirSync(join(root, ".coding-crew"), { recursive: true });
  writeFileSync(join(root, ".coding-crew/config.json"), JSON.stringify({ afk: { runtime: { reviewer: "codex" } } }));
  const env = { ...process.env, CREW_SCRIPTS: SCRIPTS, MAIN_ROOT: root, HOME: root };
  delete env.CREW_FAKE_DISPATCH;
  const r = sh("node", [MAIN, "doctor", "--platform", "claude"], { cwd: root, env });
  assert.equal(r.code, 1);
  assert.match(r.stdout, /PROBLEM: reviewer → codex: crew-reviewer agent definition not installed for codex/);
  assert.doesNotMatch(r.stdout, /→ codex: crew-coder/);
});

const lineOf = (log, text) => log.split("\n").findIndex((l) => l.includes(text));

test("the PRD audit runs by default after Phase 1, before the flush and the squash", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  writeFileSync(join(root, ".scratch/demo/PRD.md"), "# PRD\n\n- The widget exists\n");
  const r = runSprint(root, ["--squash"]);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(existsSync(join(root, ".scratch/demo/prd-audit.md")), true);
  assert.match(r.stdout, /## PRD Audit/);
  const log = traceLog(root);
  const audit = lineOf(log, "step=prd-audit mode=fix");
  assert.notEqual(audit, -1, log);
  assert.ok(markerAt(log, "MERGE") < audit, "the audit follows Phase 1's merges");
  assert.ok(audit < markerAt(log, "FLUSH"), "…and precedes the flush that starts Phase 2");
  assert.ok(audit < markerAt(log, "SQUASH"));
  assert.match(log, /PRD audit: no missing requirements\./);

  // off: never runs, however much PRD there is.
  const root2 = fixtureRepo();
  addIssue(root2, "01-alpha.md");
  writeFileSync(join(root2, ".scratch/demo/PRD.md"), "# PRD\n\n- The widget exists\n");
  const off = runSprint(root2, ["--prd-audit", "off"]);
  assert.equal(off.code, 0, `${off.stdout}\n${off.stderr}`);
  assert.equal(existsSync(join(root2, ".scratch/demo/prd-audit.md")), false);
  assert.doesNotMatch(off.stdout, /## PRD Audit/);
});

test("PRDAudit fix: missing requirements become one Phase 2 fix issue, audited no further", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  writeFileSync(join(root, ".scratch/demo/PRD.md"), "# PRD\n\n- Export to CSV\n");
  fake(root, "prd-audit.response", AUDIT_WITH_GAP);
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.deepEqual(state(root).completed_slugs, ["alpha", "fix-prd-gaps"]);
  const issue = readFileSync(join(root, ".scratch/demo/issues/done/02-fix-prd-gaps.md"), "utf8");
  assert.match(issue, /^Source: .*prd-audit\.md \(prd-audit\)$/m, "the Source: line is the depth bound");
  assert.match(issue, /- \[[ x]\] Users can export to CSV — PRD: Export/);
  const log = traceLog(root);
  assert.equal(log.split("step=prd-audit").length - 1, 1, "one audit per sprint, none after Phase 2");
});

test("PRDAudit report: the audit runs, and its gaps are left for a human", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  writeFileSync(join(root, ".scratch/demo/PRD.md"), "# PRD\n\n- Export to CSV\n");
  fake(root, "prd-audit.response", AUDIT_WITH_GAP);
  mkdirSync(join(root, ".coding-crew"), { recursive: true });
  writeFileSync(join(root, ".coding-crew/config.json"), JSON.stringify({ afk: { PRDAudit: "report" } }));
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.deepEqual(state(root).completed_slugs, ["alpha"]);
  assert.match(r.stdout, /## PRD Audit/);
  // --coverage, the old flag, is `report` too.
  const root2 = fixtureRepo();
  addIssue(root2, "01-alpha.md");
  writeFileSync(join(root2, ".scratch/demo/PRD.md"), "# PRD\n\n- Export to CSV\n");
  fake(root2, "prd-audit.response", AUDIT_WITH_GAP);
  const old = runSprint(root2, ["--coverage"]);
  assert.equal(old.code, 0, `${old.stdout}\n${old.stderr}`);
  assert.deepEqual(state(root2).completed_slugs, ["alpha"]);
  assert.match(readFileSync(join(root2, ".scratch/demo/sprint.env"), "utf8"), /CREW_PRD_AUDIT="report"/);
});

test("PRDAudit: a superseded requirement is named in the summary and never queued", () => {
  const audit = [
    "⊘ Sessions expire after 30 minutes: docs/adr/0007-no-session-expiry.md",
    "```json",
    JSON.stringify({
      covered: 1,
      partial: 0,
      missing: [],
      superseded: [{ requirement: "Sessions expire after 30 minutes", by: "docs/adr/0007-no-session-expiry.md" }],
    }),
    "```",
  ].join("\n");
  for (const mode of ["fix", "report"]) {
    const root = fixtureRepo();
    addIssue(root, "01-alpha.md");
    writeFileSync(join(root, ".scratch/demo/PRD.md"), "# PRD\n\n- Sessions expire after 30 minutes\n");
    fake(root, "prd-audit.response", audit);
    const r = runSprint(root, ["--prd-audit", mode]);
    assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
    assert.deepEqual(state(root).completed_slugs, ["alpha"], `${mode}: nothing queued`);
    assert.match(
      r.stdout,
      /\*\*Superseded — update the PRD, nothing queued:\*\*\n- Sessions expire after 30 minutes — docs\/adr\/0007-no-session-expiry\.md/,
      mode,
    );
  }
});

test("a PRD audit that fails is named in the summary, not only the trace", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  writeFileSync(join(root, ".scratch/demo/PRD.md"), "# PRD\n\n- Export to CSV\n");
  fake(root, "prd-audit.md.exit", "1");
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stdout, /## PRD Audit\n\n\*\*Failed:\*\* the audit did not complete \(exit 1\)/);
});

test("the PRD audit does not run while a Phase 1 issue is still open", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-beta.md");
  writeFileSync(join(root, ".scratch/demo/PRD.md"), "# PRD\n\n- Export to CSV\n");
  fake(root, "prd-audit.response", AUDIT_WITH_GAP);
  fake(root, "beta.exit", "1");
  const r = runSprint(root);
  assert.equal(r.code, 2, `${r.stdout}\n${r.stderr}`);
  const log = traceLog(root);
  assert.match(log, /PRD audit: skipped — 1 Phase 1 issue\(s\) still open \(beta\)/);
  assert.equal(log.includes("step=prd-audit"), false, "no auditor is dispatched");
  assert.equal(existsSync(join(root, ".scratch/demo/prd-audit.md")), false);
  assert.match(r.stdout, /\*\*Not run:\*\* 1 Phase 1 issue\(s\) still open \(beta\)/, "the summary says so, not only the trace");
  assert.equal(readdirSync(join(root, ".scratch/demo/issues/open")).some((f) => /fix-prd-gaps/.test(f)), false);
});

test("a feature slug containing 'skipped' does not silently cancel the PRD audit", () => {
  // Regression: loop.mjs used to test /skipped/i against the audit script's *entire*
  // stdout, not just its one-line skip message. That stdout embeds $PRD_PATH (which embeds
  // $FEATURE_SLUG) on every non-skip line ("PRD found at .scratch/<slug>/PRD.md", "Extract
  // all requirements from ...", "Completed issues in .scratch/<slug>/issues/done/"), so a
  // feature slug that happens to contain the substring "skipped" — a perfectly ordinary name
  // for a feature about skip logic — made that regex match and cancelled a validation the
  // user explicitly asked for. The same bug as command discovery's, just
  // triggered through the slug instead of a quoted file's content.
  const root = mkdtempSync(join(TMPDIR, "crew-sprint-"));
  const git = (...args) => sh("git", ["-C", root, ...args]);
  git("init", "-q", "-b", "main");
  git("config", "user.email", "t@test");
  git("config", "user.name", "T");
  writeFileSync(join(root, "Makefile"), "test:\n\t@echo ok\nlint:\n\t@echo ok\ntypecheck:\n\t@echo ok\n");
  writeFileSync(join(root, ".gitignore"), ".scratch/\n");
  git("add", "-A");
  git("commit", "-q", "-m", "init");
  git("checkout", "-q", "-b", "feature/skipped-flow");
  mkdirSync(join(root, ".scratch/skipped-flow/issues/open"), { recursive: true });
  mkdirSync(join(root, ".scratch/fake"), { recursive: true });
  writeFileSync(
    join(root, ".scratch/skipped-flow/issues/open/01-alpha.md"),
    "# alpha\n\nStatus: ready-for-agent\n\n## Acceptance criteria\n\n- [ ] alpha exists\n",
  );
  writeFileSync(join(root, ".scratch/skipped-flow/PRD.md"), "# PRD\n\n- The widget exists\n");

  const r = runSprint(root, ["--prd-audit", "report", "--feature-slug", "skipped-flow"]);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(
    existsSync(join(root, ".scratch/skipped-flow/prd-audit.md")),
    true,
    "a feature slug containing 'skipped' must not cancel a requested PRD audit",
  );
  assert.match(r.stdout, /## PRD Audit/);
});
