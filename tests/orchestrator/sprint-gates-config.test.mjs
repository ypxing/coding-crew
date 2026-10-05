/**
 * Sprint suite — the gate order, the per-role config, and the retired PRD audit's settings.
 * Shared helpers: ./helpers/sprint.mjs.
 */

import assert from "node:assert/strict";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { MAIN, TMPDIR, SCRIPTS, FAKE, sh, fixtureRepo, addIssue, BRANCH_REVIEW, runSprint, traceLog, markerAt, reviewReports, state, fake, commandLines, test } from "./helpers/sprint.mjs";

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
  assert.match(traceLog(root), / INFO  \[SUMMARY\]\n  Run \d+ for this feature; previous: .*\n  Rounds: \d+\n  Model: /);
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

const lineOf = (log, text) => log.split("\n").findIndex((l) => l.includes(text));

test("a sprint that merged an issue runs no PRD audit, and a config still setting one loads with a notice", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  writeFileSync(join(root, ".scratch/demo/PRD.md"), "# PRD\n\n- Export to CSV\n");
  mkdirSync(join(root, ".coding-crew"), { recursive: true });
  writeFileSync(join(root, ".coding-crew/config.json"), JSON.stringify({ afk: { PRDAudit: "fix", timeouts: { prdAuditor: 20 } } }));
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.deepEqual(state(root).completed_slugs, ["alpha"]);
  assert.equal(r.stderr.split("`afk.PRDAudit` no longer does anything").length - 1, 1, r.stderr);
  assert.equal(r.stderr.split("`afk.timeouts.prdAuditor` no longer does anything").length - 1, 1, r.stderr);
  const log = traceLog(root);
  assert.equal(log.includes("step=prd-audit"), false, "no auditor is dispatched");
  assert.equal(existsSync(join(root, ".scratch/demo/prd-audit.md")), false);
  assert.doesNotMatch(r.stdout, /## PRD Audit/);
  const issues = ["open", "done"].flatMap((d) => (existsSync(join(root, ".scratch/demo/issues", d)) ? readdirSync(join(root, ".scratch/demo/issues", d)) : []));
  assert.equal(issues.some((f) => /fix-prd-gaps/.test(f)), false, issues.join(", "));
});

test("--prd-audit is accepted with any value, prints the notice, and the run proceeds", () => {
  for (const value of ["fix", "nonsense"]) {
    const root = fixtureRepo();
    addIssue(root, "01-alpha.md");
    const r = runSprint(root, ["--prd-audit", value]);
    assert.equal(r.code, 0, `${value}: ${r.stdout}\n${r.stderr}`);
    assert.match(r.stderr, /`--prd-audit` no longer does anything: the feature review checks PRD coverage/, value);
    assert.deepEqual(state(root).completed_slugs, ["alpha"], value);
  }
});
