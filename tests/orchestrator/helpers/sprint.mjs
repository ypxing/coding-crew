/**
 * Shared helpers for the sprint suite's topic files (tests/orchestrator/sprint-<topic>.test.mjs).
 *
 * The suite drives the whole state machine end to end with every model dispatch faked: a clean issue
 * merges and closes, a failing check never merges, an unmet criteria verdict never merges, a review
 * that did not happen is a gap rather than a clean pass, and two dry rounds stall instead of looping.
 *
 * Importing this module builds the shared fixtures (a scripts dir, an install dir, an empty HOME) once
 * per test file's process and removes them after it. Each topic file is its own `node --test` file,
 * so they run in parallel — these tests are synchronous and each drives a whole faked sprint.
 */

import { test as nodeTest, after } from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { chmodSync, cpSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync, existsSync, unlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
export const REPO = join(HERE, "../../..");
export const MAIN = join(REPO, "orchestrator/main.mjs");

// Resolved once: on macOS (and some Windows runners) os.tmpdir() is a symlink/short-name
// path (/var/folders/... -> /private/var/folders/...), but a child process's cwd is
// reported back canonicalized — `git rev-parse --show-toplevel` (main.mjs's gitRoot())
// returns the OS's resolved getcwd(), not the string a test passed as `cwd`. Building every
// fixture root from the already-resolved base keeps test-side path strings identical to
// what the orchestrator prints, instead of only matching on Linux where /tmp isn't a symlink.
export const TMPDIR = realpathSync(tmpdir());

// Mirrors what install.sh actually produces for a real crew-afk install: its own
// skills/crew-afk/scripts/ merged with the shared scripts its registry.json entry declares
// (feature-branch-setup.sh, discover-commands.sh, write-commands-cache.sh), whose canonical
// source is scripts/skill-utils/git-workflow/, not skills/crew-afk/scripts/ — see that
// directory's README. Computed once here rather than duplicating those files by hand, which
// is exactly the drift the skill-utils mechanism exists to avoid.
//
// Nested three levels under REPO (.scratch/<random>/scripts), the same depth as the real
// skills/crew-afk/scripts/ — ensure-deps.sh's own _script_roots() walks up exactly that many
// parents to find a sibling dep-install install, so a flat os.tmpdir() location (any other
// depth) makes it search the wrong ancestry and report DEPS: none for every fixture.
mkdirSync(join(REPO, ".scratch"), { recursive: true });
export const SCRIPTS_BASE = mkdtempSync(join(REPO, ".scratch", "test-scripts-"));
export const SCRIPTS = join(SCRIPTS_BASE, "scripts");
mkdirSync(SCRIPTS);
cpSync(join(REPO, "skills/crew-afk/scripts"), SCRIPTS, { recursive: true });
for (const f of ["feature-branch-setup.sh", "discover-commands.sh", "write-commands-cache.sh"]) {
  cpSync(join(REPO, "scripts/skill-utils/git-workflow", f), join(SCRIPTS, f));
}
after(() => rmSync(SCRIPTS_BASE, { recursive: true, force: true }));
// The `.coding-crew/` an installed orchestrator would sit in (CREW_INSTALL_DIR): this source
// tree's orchestrator/ has no installed assets beside it, so every run points here instead.
export const INSTALL_DIR = join(SCRIPTS_BASE, "install");
cpSync(join(REPO, "agents/crew-reviewer/assets"), join(INSTALL_DIR, "code-review"), { recursive: true });
cpSync(join(REPO, "skills/dep-install/scripts"), join(INSTALL_DIR, "dep-install/scripts"), { recursive: true });
cpSync(join(REPO, "skills/solve-issue/scripts"), join(INSTALL_DIR, "solve-issue/scripts"), { recursive: true });
cpSync(join(REPO, "skills/to-issues/scripts"), join(INSTALL_DIR, "to-issues/scripts"), { recursive: true });
cpSync(join(REPO, "skills/write-pr"), join(INSTALL_DIR, "write-pr"), { recursive: true });
export const FAKE = join(HERE, "../fixtures/fake-dispatch.sh");


// Every call site below spreads process.env into its own `env` (or omits `env` and gets
// it by default); this test's own process inherits CREW_PANE_HOST, HERDR_ENV/HERDR_PANE_ID (or
// ORCA_ENV/ORCA_TERMINAL_HANDLE) whenever it runs inside a real herdr/orca pane, and
// main.mjs's notifyTriggeringPane sends the fixture sprint's outcome straight to that real
// pane if those leak through — stripped here, once, so no call site has to remember to.
//
// HOME likewise: a real ~/.coding-crew/config.json would retarget every fixture sprint's roles,
// so an inherited HOME is swapped for an empty one. A test that sets its own HOME keeps it.
export const EMPTY_HOME = mkdtempSync(join(TMPDIR, "crew-sprint-home-"));
after(() => rmSync(EMPTY_HOME, { recursive: true, force: true }));
export function sh(cmd, args, opts = {}) {
  const env = { ...(opts.env ?? process.env) };
  if (env.HOME === process.env.HOME) env.HOME = EMPTY_HOME;
  if (env.CREW_INSTALL_DIR === process.env.CREW_INSTALL_DIR) env.CREW_INSTALL_DIR = INSTALL_DIR;
  delete env.CREW_PANE_HOST;
  delete env.HERDR_ENV;
  delete env.HERDR_PANE_ID;
  delete env.ORCA_ENV;
  delete env.ORCA_TERMINAL_HANDLE;
  const r = spawnSync(cmd, args, { encoding: "utf8", ...opts, env });
  return { code: r.status, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
}

// Every fixture repo, removed after the file: ~130 per run otherwise fill /tmp's inodes.
export const FIXTURE_ROOTS = [];
after(() => FIXTURE_ROOTS.forEach((d) => rmSync(d, { recursive: true, force: true })));

export function fixtureRepo() {
  const root = mkdtempSync(join(TMPDIR, "crew-sprint-"));
  FIXTURE_ROOTS.push(root);
  const git = (...args) => sh("git", ["-C", root, ...args]);
  git("init", "-q", "-b", "main");
  git("config", "user.email", "t@test");
  git("config", "user.name", "T");
  // A Makefile gives verify-worktree.sh discoverable check commands.
  writeFileSync(
    join(root, "Makefile"),
    "test:\n\t@echo ok\nlint:\n\t@echo ok\ntypecheck:\n\t@echo ok\n",
  );
  writeFileSync(join(root, ".gitignore"), ".scratch/\n");
  git("add", "-A");
  git("commit", "-q", "-m", "init");
  git("checkout", "-q", "-b", "feature/demo");
  mkdirSync(join(root, ".scratch/demo/issues/open"), { recursive: true });
  mkdirSync(join(root, ".scratch/fake"), { recursive: true });
  return root;
}

export function addIssue(root, name, { status = "ready-for-agent", body = "", blockedBy = [] } = {}) {
  const slug = name.replace(/\.md$/, "").replace(/^[0-9]+[-_]?/, "");
  const lines = [
    `# ${slug}`,
    "",
    `Status: ${status}`,
    "",
    "## Acceptance criteria",
    "",
    `- [ ] ${slug} exists`,
    "",
  ];
  if (blockedBy.length) lines.push("## Blocked by", "", ...blockedBy.map((b) => `- ${b}`), "");
  if (body) lines.push(body, "");
  writeFileSync(join(root, ".scratch/demo/issues/open", name), lines.join("\n"));
  return slug;
}

// The baseline (preflight.mjs) runs the checks once more before any dispatch; the per-issue
// tests below count those calls, so the helpers leave it out unless a test asks for it.
export const NO_BASELINE = ["--no-baseline"];
// Likewise the integration check (at each drain, on the merged feature branch) is one more set of
// check runs; the helpers leave it out unless a test asks for it.
export const NO_INTEGRATION = ["--no-integration-check"];
// A per-branch review dispatch: the feature review (slug `feature`, once at the first drain) is
// the same agent, counted by the feature-review tests alone.
export const BRANCH_REVIEW = /^SPAWN .*--agent crew-reviewer(?!.* --slug feature( |$))/;

/**
 * `--max-rounds N` and `--no-commands` are no longer flags; the orchestrator keeps them as the
 * test-only env seams CREW_MAX_ROUNDS / CREW_NO_COMMANDS. Tests still write them as flags.
 */
export function seamArgs(extra) {
  const args = [];
  const env = {};
  for (let i = 0; i < extra.length; i++) {
    if (extra[i] === "--max-rounds") env.CREW_MAX_ROUNDS = String(extra[++i]);
    else if (extra[i] === "--no-commands") env.CREW_NO_COMMANDS = "1";
    else args.push(extra[i]);
  }
  return { args, env };
}

export function runSprint(root, extraIn = [], envIn = {}, { baseline = false, integration = false } = {}) {
  const { args: extra, env: seam } = seamArgs(extraIn);
  const env = { ...seam, ...envIn };
  return sh("node", [MAIN, "run", "--platform", "pi", "--feature-slug", "demo", ...(baseline ? [] : NO_BASELINE), ...(integration ? [] : NO_INTEGRATION), ...extra], {
    cwd: root,
    env: {
      ...process.env,
      CREW_SCRIPTS: SCRIPTS,
      CREW_FAKE_DISPATCH: FAKE,
      CREW_FAKE_DIR: join(root, ".scratch/fake"),
      MAIN_ROOT: root,
      ...env,
    },
  });
}

export function traceLog(root) {
  const f = join(root, ".scratch/demo/traces/orchestrator.log");
  return existsSync(f) ? readFileSync(f, "utf8") : "";
}

/** Line index of the first occurrence of a marker in the trace log. */
export function markerAt(log, marker) {
  const lines = log.split("\n");
  const i = lines.findIndex((l) => l.includes(`[${marker}]`));
  assert.notEqual(i, -1, `no [${marker}] line in the trace log:\n${log}`);
  return i;
}

export function reviewReports(root) {
  const dir = join(root, ".scratch/demo/reviews");
  return existsSync(dir) ? readdirSync(dir).filter((f) => f.startsWith("sprint-review-")) : [];
}

export function state(root) {
  const f = join(root, ".scratch/demo/sprint-state.json");
  return existsSync(f) ? JSON.parse(readFileSync(f, "utf8")) : {};
}

export function fake(root, name, content = "") {
  writeFileSync(join(root, ".scratch/fake", name), content);
}

// ─── private script copies, for tests that must make one specific script fail once ──
//
// The global SCRIPTS dir above is shared by every test in this file, so patching a
// script in place would leak into every other test that runs after it. These tests
// need merge-branches.sh / close-issue.sh to fail exactly once and then behave exactly
// as the real script does — the retry itself (already-merged short-circuit, receipt
// re-checks) is that script's own job, not the pipeline's, so the real script still
// has to run on the second call. A private copy of SCRIPTS, patched only there, keeps
// that fault contained to the one test that injected it.
export const PRIVATE_SCRIPT_DIRS = [];
after(() => PRIVATE_SCRIPT_DIRS.forEach((d) => rmSync(d, { recursive: true, force: true })));

export function privateScripts() {
  const base = mkdtempSync(join(REPO, ".scratch", "test-scripts-"));
  PRIVATE_SCRIPT_DIRS.push(base);
  const dir = join(base, "scripts");
  cpSync(SCRIPTS, dir, { recursive: true });
  return dir;
}

/**
 * Replaces <scriptName> inside <scriptsDir> with a shim that fails once — the first
 * time it is invoked, it writes <marker> and exits 1 with <message> on stderr, without
 * touching anything else the real script would have touched. Every call after that
 * delegates to the untouched original, copied alongside it under the same directory so
 * its own sibling-script lookups (receipts.sh, trace.sh, ...) still resolve.
 */
export function failFirstCall(scriptsDir, scriptName, marker, message) {
  const real = join(scriptsDir, `_real-${scriptName}`);
  cpSync(join(scriptsDir, scriptName), real);
  const lines = [
    "#!/usr/bin/env bash",
    "set -uo pipefail",
    `MARKER=${JSON.stringify(marker)}`,
    'if [ ! -f "$MARKER" ]; then',
    '  mkdir -p "$(dirname "$MARKER")"',
    '  touch "$MARKER"',
    `  echo ${JSON.stringify(message)} >&2`,
    "  exit 1",
    "fi",
    `exec bash ${JSON.stringify(real)} "$@"`,
    "",
  ];
  writeFileSync(join(scriptsDir, scriptName), lines.join("\n"));
}


export function workerReport(obj) {
  return ["## Issue", "", "```json", JSON.stringify(obj), "```"].join("\n");
}

export function triageVerdict(fixable, category, detail) {
  return ["```json", JSON.stringify({ fixable, category, detail }), "```"].join("\n");
}

export const coderSpawns = (lines) => lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length;

export const AUDIT_WITH_GAP = [
  "✗ Users can export to CSV: no evidence",
  "```json",
  JSON.stringify({ covered: 1, partial: 0, missing: [{ requirement: "Users can export to CSV", detail: "PRD: Export" }] }),
  "```",
].join("\n");

export function githubFixtureRepo() {
  const root = mkdtempSync(join(TMPDIR, "crew-sprint-gh-"));
  FIXTURE_ROOTS.push(root);
  const git = (...args) => sh("git", ["-C", root, ...args]);
  git("init", "-q", "-b", "main");
  git("config", "user.email", "t@test");
  git("config", "user.name", "T");
  writeFileSync(join(root, "Makefile"), "test:\n\t@echo ok\nlint:\n\t@echo ok\ntypecheck:\n\t@echo ok\n");
  writeFileSync(join(root, ".gitignore"), ".scratch/\n");
  mkdirSync(join(root, ".coding-crew/docs"), { recursive: true });
  writeFileSync(
    join(root, ".coding-crew/docs/issue-tracker.md"),
    "---\ntracker: github\n---\n\n# Issue tracker: GitHub Issues\n",
  );
  // close-issue.sh/promote-findings.sh look for tracker-config.sh at their own script dir,
  // then at .coding-crew/scripts/ (the installed layout), then at scripts/tracker/ (this
  // source tree) — none of which a bare fixture repo has, so without this copy every
  // lookup falls through to its own "missing means local" default, silently defeating the
  // very test this fixture exists for.
  mkdirSync(join(root, ".coding-crew/scripts"), { recursive: true });
  cpSync(join(REPO, "scripts/tracker/tracker-config.sh"), join(root, ".coding-crew/scripts/tracker-config.sh"));
  // close-issue.sh's github close is mark-issue-done.sh's label swap, installed beside it.
  cpSync(join(REPO, "scripts/tracker/mark-issue-done.sh"), join(root, ".coding-crew/scripts/mark-issue-done.sh"));
  git("add", "-A");
  git("commit", "-q", "-m", "init");
  git("checkout", "-q", "-b", "feature/demo");
  mkdirSync(join(root, ".scratch/fake"), { recursive: true });
  // The feature lease lives on origin, so a github run needs one.
  const origin = `${root}-origin.git`;
  FIXTURE_ROOTS.push(origin);
  sh("git", ["init", "-q", "--bare", origin]);
  git("remote", "add", "origin", origin);
  return root;
}

export function stubGh(root, issues) {
  const stub = join(root, ".stub");
  mkdirSync(stub, { recursive: true });
  const log = join(root, "gh.log");
  writeFileSync(log, "");
  const issuesFile = join(root, "gh-issues.json");
  writeFileSync(issuesFile, JSON.stringify(issues));
  // The issues-file path is passed as a node argv, never interpolated into the -e source
  // itself — nesting a JSON.stringify()'d path *inside* an already-double-quoted `-e "..."`
  // string breaks out of bash's outer quoting the moment the path itself is unquoted
  // between the two halves, silently truncating the script (node then throws before ever
  // touching the file, node exits non-zero, but the wrapping `if` block still `exit 0`s —
  // so a write that never happened still reports success to the caller).
  const viewJs = "const fs=require('fs');const p=process.argv[1];const n=Number(process.argv[2]);" +
    "const issues=JSON.parse(fs.readFileSync(p,'utf8'));" +
    "process.stdout.write((issues.find(i=>i.number===n)||{}).body||'')";
  const closeJs = "const fs=require('fs');const p=process.argv[1];const n=Number(process.argv[2]);" +
    "const issues=JSON.parse(fs.readFileSync(p,'utf8'));const i=issues.find(x=>x.number===n);" +
    "if(i)i.state='CLOSED';fs.writeFileSync(p,JSON.stringify(issues))";
  // `issue list [--label L] [--state open|closed|all]`: filtered as gh would. GH_LIST_LAG_MS=N
  // hides the newest created issue for N ms after its create, as GitHub's listing lags one.
  const listJs = "const fs=require('fs');const [p,...a]=process.argv.slice(1);const v=(k)=>a.includes(k)?a[a.indexOf(k)+1]:null;" +
    "let issues=JSON.parse(fs.readFileSync(p,'utf8'));const label=v('--label'),st=v('--state');" +
    "const lag=p+'.lag';if(fs.existsSync(lag)){const l=JSON.parse(fs.readFileSync(lag,'utf8'));" +
    "if(Date.now()<l.until)issues=issues.filter(i=>i.number!==l.number);}" +
    "if(label)issues=issues.filter(i=>(i.labels||[]).some(l=>l.name===label));" +
    "if(st&&st!=='all')issues=issues.filter(i=>i.state===st.toUpperCase());" +
    "process.stdout.write(a.includes('--jq')?issues.map(i=>i.number).join('\\n'):JSON.stringify(issues))";
  // `issue edit N [--add-label L] [--remove-label L]…`: the label swap close-issue.sh makes.
  const editJs = "const fs=require('fs');const [p,n,...a]=process.argv.slice(1);" +
    "const issues=JSON.parse(fs.readFileSync(p,'utf8'));const i=issues.find(x=>x.number===Number(n));" +
    "if(i){const names=new Set((i.labels||[]).map(l=>l.name));" +
    "a.forEach((x,k)=>{if(x==='--add-label')names.add(a[k+1]);if(x==='--remove-label')names.delete(a[k+1]);});" +
    "i.labels=[...names].map(name=>({name}));}fs.writeFileSync(p,JSON.stringify(issues))";
  // `issue create --title T --body-file F [--label L]…`: appended open, so the next list sees it.
  const createJs = "const fs=require('fs');const [p,...a]=process.argv.slice(1);" +
    "const issues=JSON.parse(fs.readFileSync(p,'utf8'));const v=(k)=>a[a.indexOf(k)+1];" +
    "const labels=a.flatMap((x,i)=>x==='--label'?[{name:a[i+1]}]:[]);" +
    "const number=Math.max(0,...issues.map(i=>i.number))+1;" +
    "issues.push({number,title:v('--title'),body:fs.readFileSync(v('--body-file'),'utf8'),labels,state:'OPEN'});" +
    "fs.writeFileSync(p,JSON.stringify(issues));process.stdout.write('https://github.com/o/r/issues/'+number+'\\n');" +
    "const ms=Number(process.env.GH_LIST_LAG_MS||0);if(ms)fs.writeFileSync(p+'.lag',JSON.stringify({number,until:Date.now()+ms}))";
  writeFileSync(
    join(stub, "gh"),
    [
      "#!/usr/bin/env bash",
      `echo "$@" >> ${JSON.stringify(log)}`,
      // GH_FAIL_CLAIM=1: the write that adds `in-progress` fails, as a revoked token or a rate limit would.
      'if [ -n "${GH_FAIL_CLAIM:-}" ] && [ "$1 $2" = "issue edit" ] && [[ " $* " == *" --add-label in-progress "* ]]; then echo denied >&2; exit 1; fi',
      'if [ "$1" = "issue" ] && [ "$2" = "list" ]; then',
      `  node -e ${JSON.stringify(listJs)} ${JSON.stringify(issuesFile)} "\${@:3}"`,
      "  exit 0",
      "fi",
      'if [ "$1" = "issue" ] && [ "$2" = "view" ]; then',
      `  node -e ${JSON.stringify(viewJs)} ${JSON.stringify(issuesFile)} "$3"`,
      "  exit 0",
      "fi",
      'if [ "$1" = "issue" ] && [ "$2" = "create" ]; then',
      `  node -e ${JSON.stringify(createJs)} ${JSON.stringify(issuesFile)} "\${@:3}"`,
      "  exit 0",
      "fi",
      // open-pr.sh: no PR yet; `pr create` keeps the body it was given, for the test to read.
      // post-findings.sh runs after the create: the PR exists, its diff shows nothing (so every
      // finding goes in the review body), and the review posted is kept for the test to read.
      'if [ "$1" = "pr" ] && [ "$2" = "view" ]; then',
      '  [ -f ' + JSON.stringify(join(root, "pr-body.md")) + ' ] || exit 1',
      '  echo \'{"number":7,"url":"https://github.com/o/r/pull/7","state":"OPEN","body":""}\'; exit 0',
      "fi",
      'if [ "$1" = "repo" ] && [ "$2" = "view" ]; then [[ " $* " == *"defaultBranchRef"* ]] && echo "o/r main" || echo o/r; exit 0; fi',
      // close-shipped.sh: the feature branch's merged PRs, from gh-prs.json when a test writes one.
      'if [ "$1" = "pr" ] && [ "$2" = "list" ]; then',
      '  f=' + JSON.stringify(join(root, "gh-prs.json")) + '; [ -f "$f" ] && cat "$f" || echo "[]"; exit 0',
      "fi",
      'if [ "$1" = "pr" ] && [ "$2" = "diff" ]; then exit 0; fi',
      'if [ "$1" = "api" ]; then',
      '  case " $* " in',
      '    *" POST "*) while [ $# -gt 0 ]; do [ "$1" = "--input" ] && cp "$2" ' + JSON.stringify(join(root, "review-post.json")) + '; shift; done ;;',
      '    *) echo "[]" ;;',
      "  esac",
      "  exit 0",
      "fi",
      'if [ "$1" = "pr" ] && [ "$2" = "create" ]; then',
      '  while [ $# -gt 0 ]; do [ "$1" = "--body-file" ] && cp "$2" ' + JSON.stringify(join(root, "pr-body.md")) + '; shift; done',
      '  echo https://github.com/o/r/pull/7',
      "  exit 0",
      "fi",
      'if [ "$1" = "issue" ] && [ "$2" = "edit" ]; then',
      `  node -e ${JSON.stringify(editJs)} ${JSON.stringify(issuesFile)} "\${@:3}"`,
      "  exit 0",
      "fi",
      'if [ "$1" = "issue" ] && [ "$2" = "close" ]; then',
      `  node -e ${JSON.stringify(closeJs)} ${JSON.stringify(issuesFile)} "$3"`,
      "  exit 0",
      "fi",
      "exit 0",
      "",
    ].join("\n"),
  );
  chmodSync(join(stub, "gh"), 0o755);
  return { stub, log, issuesFile };
}

export const GH_ALPHA = {
  number: 1,
  title: "alpha",
  body: "# alpha\n\n## Acceptance criteria\n\n- [x] alpha exists\n",
  labels: [{ name: "ready-for-agent" }],
  state: "OPEN",
};

export function commandLines(root, extraIn = [], { scripts = SCRIPTS, env: envIn = {}, platform = "pi", baseline = false, integration = false } = {}) {
  const { args: extra, env: seam } = seamArgs(extraIn);
  const env = { ...seam, ...envIn };
  const r = sh("node", [MAIN, "run", "--platform", platform, "--feature-slug", "demo", ...(baseline ? [] : NO_BASELINE), ...(integration ? [] : NO_INTEGRATION), ...extra], {
    cwd: root,
    env: {
      ...process.env,
      CREW_SCRIPTS: scripts,
      CREW_FAKE_DISPATCH: FAKE,
      CREW_FAKE_DIR: join(root, ".scratch/fake"),
      MAIN_ROOT: root,
      CREW_VERBOSE: "1",
      ...env,
    },
  });
  return { r, lines: r.stderr.split("\n").filter((l) => /^(RUN|SPAWN|DRY) /.test(l)) };
}

export const featureReviewFile = (findings) =>
  `## Branch: feature (feature)\n\`\`\`json\n${JSON.stringify({ branch: "feature", slug: "feature", verdict: "all-met", detail: "", findings })}\n\`\`\`\n`;

export const crossIssue = (severity, criterion = "Share one retry helper between alpha and beta") => ({ severity, location: "src/alpha.txt:1", criterion });

export const sprintReport = (root) => {
  const dir = join(root, ".scratch/demo/reviews");
  return readdirSync(dir).filter((f) => f.startsWith("sprint-review-")).map((f) => readFileSync(join(dir, f), "utf8")).join("\n");
};

export { nodeTest as test };
