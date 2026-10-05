/**
 * preflight.mjs — what must hold before the first dispatch, checked once per run.
 *
 * Each check catches a problem every issue would otherwise hit only after paying for its
 * coder and review: a missing installed asset sends every reviewer and coder hunting for it, a
 * dirty main checkout refuses the merge at the very end, and a feature branch whose own checks
 * already fail makes every issue's verify gate fail on code no issue wrote. An issue whose own
 * `## Requires` does not hold (a credential unset, a service that will not start) would pay for
 * a coder that can only rediscover it. None costs a token.
 */

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { basename, join, resolve } from "node:path";

import { ASSET_DIRS, assetDir } from "./install-dir.mjs";
import { getTracker } from "./tracker.mjs";
import { depsLine, parseRequiresFailures, readVerifyRecord } from "./report.mjs";
import { sectionBody } from "./trackers/body-format.mjs";
import { dispatchIssueDir, logVerifyOutput, REQUIRES_FAILED_TAG, taggedReason, writeTrackerSection } from "./pipeline/shared.mjs";
import { applyWorktreeInclude, removeWorktree, worktreePath } from "./worktree.mjs";

/** The file whose presence says an asset dir is really installed, not just created. */
const ASSET_PROBES = {
  reviewer: "scripts/review-context.sh",
  depInstall: "run.sh",
  solveIssue: "check-requires.sh",
  toIssues: "lint-issues.sh",
  writePr: "SKILL.md",
};

/**
 * Each asset dir under `installDir` (install-dir.mjs) whose probe file is absent: `[{ kind, file }]`.
 * Every run uses each — the reviewer reads its scripts, ensure-deps.sh / verify-worktree.sh run
 * dep-install's, and preflight runs check-requires.sh and lint-issues.sh — so a gap here is one every reviewer or
 * coder would otherwise hunt for. write-pr's SKILL.md is read only with openPr, but it ships with crew-afk.
 */
export function missingAssets(installDir) {
  return Object.keys(ASSET_DIRS)
    .map((kind) => ({ kind, file: join(assetDir(installDir, kind), ASSET_PROBES[kind]) }))
    .filter(({ file }) => !existsSync(file));
}

/** The stop message for a missing asset: the exact paths expected, and the one remedy. */
export function missingAssetsMessage(installDir, missing) {
  return [
    `crew-afk: the install this run was launched from (${installDir}) is missing files its agents use:`,
    ...missing.map(({ kind, file }) => `  ${kind}: ${file}`),
    "Re-run install.sh for crew-afk at the scope it was installed at (the repo, or TARGET_REPO=$HOME), then re-run.",
  ].join("\n");
}

/**
 * The set to lint, as the files lint-issues.sh takes: `{ issues, known, deps, prd }` (`deps` and
 * `prd` null when absent), all from one `listFeatureIssues` call. An open (not done, not PRD) issue
 * the tracker keeps as a file is linted in place; any other has its body written out as
 * `<number>-<slug>.md` — the filename is how `Issue #<n>` refs resolve. `deps` is the tracker's
 * `issues-deps.json` (`featureDepsFile`); `prd` is `.scratch/<slug>/PRD.md`, else the PRD issue's
 * body. `known` is the done issues, as files the same way: a `## Blocked by` ref to one resolves
 * by its filename, as it does for dispatch, and its `## Implements` counts toward PRD coverage, but
 * it is not linted.
 */
async function lintSet(sprint, mainRoot) {
  const slug = sprint.featureSlug;
  const localPrd = join(mainRoot, ".scratch", slug, "PRD.md");
  const prdFile = existsSync(localPrd) ? localPrd : null;
  const tracker = await getTracker(mainRoot);
  const all = tracker.listFeatureIssues(mainRoot, { featureSlug: slug });
  const dir = join(sprint.dispatchDir, "_lint");
  const write = (name, text) => {
    mkdirSync(dir, { recursive: true });
    const file = join(dir, name);
    writeFileSync(file, text);
    return file;
  };
  const fileName = (i) => i.file ?? `${i.number}-${i.slug}.md`;
  const work = all.filter((i) => !tracker.isPrdIssue(i));
  const asFile = (i) => i.path ?? write(fileName(i), i.text);
  const issues = work.filter((i) => i.status !== "done").map(asFile);
  const known = work.filter((i) => i.status === "done").map(asFile);
  const deps = tracker.featureDepsFile(mainRoot, { featureSlug: slug });
  const prdIssue = prdFile ? null : all.find((i) => tracker.isPrdIssue(i));
  return { issues, known, deps, prd: prdFile ?? (prdIssue ? write("PRD.md", prdIssue.text) : null) };
}

/**
 * Once, before command discovery or any worktree: the feature's issue set through `to-issues`'
 * lint-issues.sh. Exit 1 (a cycle, an unmatched `## Blocked by`, drift from issues-deps.json, no
 * acceptance criteria) fails the run, carrying each ERROR line; WARN lines are logged. Exit 2,
 * or a checker that could not run at all, is logged and never fails: a broken checker must not
 * block a sprint the issues themselves would not. `--dry-run` runs it and reports without failing.
 *
 * Returns `{ status: "pass" | "fail" | "skipped", errors, warnings, reason }`.
 */
export async function lintIssues(ctx) {
  const { sprint, effects, options } = ctx;
  const skipped = (reason) => {
    ctx.log(`LINT: skipped — ${reason}`, "warn");
    return { status: "skipped", errors: [], warnings: [], reason };
  };
  let set;
  try {
    set = await lintSet(sprint, effects.mainRoot);
  } catch (err) {
    return skipped(`could not read the issue set: ${err.message}`);
  }
  if (!set.issues.length) return { status: "skipped", errors: [], warnings: [], reason: "no open issues" };
  if (!sprint.installDir) return skipped("no install dir");
  const script = join(assetDir(sprint.installDir, "toIssues"), "lint-issues.sh");
  const args = [script, ...set.issues.flatMap((f) => ["--issue", f]), ...set.known.flatMap((f) => ["--known", f])];
  if (set.deps) args.push("--deps", set.deps);
  if (set.prd) args.push("--prd", set.prd);
  ctx.log(`[STEP] step=lint issues=${set.issues.length}${set.deps ? " deps" : ""}${set.prd ? " prd" : ""}`);
  const r = effects.exec("bash", args, { env: sprint.childEnv(), mutating: false });
  if (r.code !== 0 && r.code !== 1) {
    return skipped(`lint-issues.sh exited ${r.code ?? "without a status"} — ${(r.stderr || r.stdout || "").trim() || "no output"}`);
  }
  const lines = (r.stdout ?? "").split("\n").map((l) => l.trimEnd());
  const errors = lines.filter((l) => /^ERROR /.test(l));
  const warnings = lines.filter((l) => /^WARN /.test(l));
  for (const w of warnings) ctx.log(`LINT: ${w}`, "warn");
  if (r.code === 1) {
    // Exit 1 with no ERROR line is still the checker's verdict; say so rather than pass silently.
    const shown = errors.length ? errors : [(r.stderr || r.stdout || "exit 1 with no output").trim()];
    for (const e of shown) ctx.log(`LINT: ${e}`, "error");
    if (options.dryRun) ctx.log("LINT: fail — a real run would stop here");
    return { status: "fail", errors: shown, warnings };
  }
  ctx.log(`LINT: pass${warnings.length ? ` (${warnings.length} warning${warnings.length > 1 ? "s" : ""})` : ""}`);
  return { status: "pass", errors: [], warnings };
}

/**
 * An issue that became ready mid-run (loop.mjs's idle-slot poll): lints the set and blocks, for this
 * run only, each of `issues` that carries an ERROR — the same bar preflight holds the initial set to,
 * except that one bad issue must not stop the run. Returns the slugs blocked. A checker that could
 * not run blocks nothing (as in lintIssues).
 */
export async function lintMidRunIssues(ctx, issues) {
  const { sprint, effects, options } = ctx;
  if (options?.dryRun || !issues.length) return [];
  const lint = await lintIssues(ctx);
  if (lint.status !== "fail") return [];
  const blocked = [];
  for (const issue of issues) {
    const name = issue.path ? basename(issue.path) : `${issue.number}-${issue.slug}.md`;
    const mine = lint.errors.filter((e) => {
      const file = /^ERROR (.+?):/.exec(e)?.[1];
      return file && basename(file) === name;
    });
    if (!mine.length) continue;
    const reason = `lint: ${mine.map((e) => e.replace(/^ERROR [^:]*:\s*/, "")).join("; ")}`;
    ctx.log(`[LINT-BLOCKED] slug=${issue.slug} — ${reason}`, "warn");
    await writeTrackerSection(effects, issue, "Blocked", `Mid-run lint: ${reason}`, { append: true });
    sprint.blocked(issue.slug, null, reason);
    sprint.markBlockedThisRun(issue.slug);
    blocked.push(issue.slug);
  }
  return blocked;
}

/**
 * Once, at run start: drop each retained-branch record no run can retry — its issue is closed
 * (`done`) or no longer in the tracker at all, or its branch no longer exists — so it stops
 * counting toward Partial, ## Retained Branches, the stall verdict and the PR's draft reasons.
 * Seen once (crew-afk-maintenance, 2026-10-05: #142 shipped in #145, its record kept two runs
 * STALLED and their PR a draft). An open issue whose branch exists is kept, ready or not, blocked
 * or not. A listing that fails or comes back empty drops nothing: it cannot tell a closed issue
 * from one it did not see. `--dry-run` reports only. Returns `[{ slug, branch, reason, issueGone }]`.
 */
export function dropStaleRetained(ctx, tracker) {
  const { sprint, effects, options } = ctx;
  const st = sprint.readState();
  const branches = { ...(st.retained_branches ?? {}) };
  for (const [slug, rec] of Object.entries(st.retention ?? {})) branches[slug] = rec?.branch ?? branches[slug];
  const slugs = Object.keys(branches);
  if (!slugs.length) return [];
  let issues;
  try {
    issues = tracker.listFeatureIssues(effects.mainRoot, { featureSlug: sprint.featureSlug });
  } catch (err) {
    ctx.log(`RETAINED: kept every record — could not list the tracker: ${err.message}`, "warn");
    return [];
  }
  if (!issues.length) return [];
  const stale = [];
  for (const slug of slugs) {
    const branch = branches[slug];
    const matches = issues.filter((i) => i.slug === slug);
    let reason = null;
    let issueGone = false;
    if (!matches.length) [reason, issueGone] = ["issue no longer in the tracker", true];
    else if (matches.every((i) => i.status === "done")) [reason, issueGone] = ["issue closed", true];
    // show-ref exits 1 for a ref that is not there; any other failure says nothing about it.
    else if (branch && effects.gitRead(["show-ref", "--verify", "--quiet", `refs/heads/${branch}`]).code === 1) {
      reason = `branch ${branch} no longer exists`;
    }
    if (!reason) continue;
    stale.push({ slug, branch, reason, issueGone });
    if (options?.dryRun) {
      ctx.log(`RETAINED: would drop slug=${slug}${branch ? ` branch=${branch}` : ""} — ${reason}`);
      continue;
    }
    ctx.log(`[RETAINED-DROPPED] slug=${slug}${branch ? ` branch=${branch}` : ""} — ${reason}`, "warn");
    sprint.dropRetained(slug, reason, { issueGone });
  }
  return stale;
}

/** The stop message for a structurally broken issue set: each ERROR line verbatim. */
export function lintFailureMessage(errors) {
  return [
    "crew-afk: the issue set has structural errors that would break dispatch or the gates — fix them before any coder is paid for:",
    ...errors.map((e) => `  ${e}`),
    "Re-run `lint-issues.sh` by hand (.coding-crew/to-issues/scripts/) to check, then re-run.",
  ].join("\n");
}

/** Files crew-afk itself writes in the main checkout; the summary already reminds about them. */
const CREW_OWNED = new Set([".coding-crew/dev-commands.json"]);

/**
 * Tracked files with uncommitted changes in the main checkout, crew-afk's own excepted.
 * Untracked files are left to the merge gate: most never collide with a branch.
 */
export function dirtyTrackedFiles(effects) {
  const r = effects.gitRead(["status", "--porcelain", "-z", "--untracked-files=no"]);
  if (r.code !== 0) return [];
  const entries = r.stdout.split("\0").filter(Boolean);
  const files = [];
  for (let i = 0; i < entries.length; i++) {
    const e = entries[i];
    files.push(e.slice(3));
    // A rename or copy is followed by its source path, which is not a second change.
    if (/^[RC]/.test(e)) i++;
  }
  return files.filter((f) => !CREW_OWNED.has(f));
}

/** The branch the baseline worktree checks out: a crew branch, so verify-worktree.sh records it. */
export function baselineBranch(featureSlug) {
  return `crew/${featureSlug}/_baseline`;
}

const BASELINE_STEM = "_baseline";
/** The drain-time check of the merged feature branch (loop.mjs): same mechanism, its own stem. */
export const INTEGRATION_STEM = "_integration";

/** The feature branch's pass cache, per stem: a pass for one says nothing about the other. */
const STATE_KEY = { [BASELINE_STEM]: "baseline", [INTEGRATION_STEM]: "integration" };

/**
 * Run the project's checks once on the feature branch's tip, in a throwaway worktree set up
 * exactly as an issue's is (include, deps), so a failure here is the one every issue's verify
 * would repeat. A pass is cached by the tip's commit, and by its git tree (a tree any check already passed); a failure never is, since an
 * environment the human fixed (a service started) should be re-checked on the next run.
 * `stem` names the worktree, the verify record and the cache: `_baseline` before any dispatch
 * (runBaseline), `_integration` at each drain of the queue (runIntegrationCheck).
 *
 * Returns `{ status: "pass" | "cached" | "fail", commit, failed: [{check, log, missing}], reason }`.
 */
export function runFeatureChecks(ctx, { stem }) {
  const prep = prepareChecks(ctx, stem);
  if (prep.result) return prep.result;
  try {
    if (ctx.options.installDeps !== false) {
      const failed = installDeps(ctx, prep, prep.effects.bash("ensure-deps.sh", depsArgs(prep), { env: ctx.sprint.childEnv() }));
      if (failed) return failed;
    }
    return concludeChecks(ctx, prep, prep.effects.bash("verify-worktree.sh", verifyArgs(prep), { env: ctx.sprint.childEnv() }));
  } finally {
    cleanupChecks(prep);
  }
}

/** runFeatureChecks without blocking the event loop (the baseline, which runs alongside dispatch). */
export async function runFeatureChecksAsync(ctx, { stem }) {
  const prep = prepareChecks(ctx, stem);
  if (prep.result) return prep.result;
  try {
    if (ctx.options.installDeps !== false) {
      const deps = await prep.effects.bashAsync("ensure-deps.sh", depsArgs(prep), { env: ctx.sprint.childEnv() });
      const failed = installDeps(ctx, prep, deps);
      if (failed) return failed;
    }
    return concludeChecks(ctx, prep, await prep.effects.bashAsync("verify-worktree.sh", verifyArgs(prep), { env: ctx.sprint.childEnv() }));
  } finally {
    cleanupChecks(prep);
  }
}

const depsArgs = (p) => ["--dir", p.path, "--slug", p.stem, "--stem", p.stem];
const verifyArgs = (p) => ["--dir", p.path, "--stem", p.stem];

/** Was this git tree already checked green — by a baseline, an integration check, or a per-issue verify? */
function treePassed(state, tree) {
  if (!tree) return false;
  if (Array.isArray(state.passing_trees) && state.passing_trees.includes(tree)) return true;
  return [state.baseline, state.integration].some((r) => r?.verdict === "pass" && r.tree === tree);
}

/** The commit, the cache lookup and the worktree: either an early `result` or what the rest needs. */
function prepareChecks(ctx, stem) {
  const { sprint, effects } = ctx;
  const step = stem.replace(/^_/, "");
  const label = step.toUpperCase();
  const stateKey = STATE_KEY[stem];
  const commit = effects.gitRead(["rev-parse", `${sprint.featureBranch}^{commit}`]).stdout.trim();
  const tree = effects.gitRead(["rev-parse", `${sprint.featureBranch}^{tree}`]).stdout.trim();
  const state = sprint.readState();
  const cached = state[stateKey];
  const commitHit = cached?.commit === commit && cached.verdict === "pass";
  if (commit && (commitHit || treePassed(state, tree))) {
    ctx.log(`${label}: pass (cached — ${commitHit ? `${sprint.featureBranch} already passed at ${commit.slice(0, 12)}` : `${sprint.featureBranch}'s tree already passed`})`);
    // A hit by tree, not by this slot's own record: the slot now says pass for this commit too.
    if (!commitHit) {
      sprint.state(["baseline", "--slot", stateKey, "--commit", commit, "--verdict", "pass", ...(tree ? ["--tree", tree] : [])]);
    }
    return { result: { status: "cached", commit, failed: [] } };
  }

  const branch = `crew/${sprint.featureSlug}/${stem}`;
  const path = worktreePath(effects.mainRoot, branch);
  // A crashed earlier run may have left both behind.
  removeWorktree(effects, { mainRoot: effects.mainRoot, path });
  effects.git(["worktree", "prune"]);
  ctx.log(`[STEP] step=${step} branch=${sprint.featureBranch} commit=${commit.slice(0, 12)}`);
  const add = effects.git(["worktree", "add", "-B", branch, path, sprint.featureBranch]);
  if (add.code !== 0) {
    // Not the project's fault: a baseline that could not run says nothing, so it does not stop the run.
    // An integration check that could not run proved nothing either, so it reads `skipped`, not `pass`.
    ctx.log(`${label}: skipped — could not create its worktree: ${add.stderr.trim()}`);
    return { result: { status: stem === INTEGRATION_STEM ? "skipped" : "pass", commit, failed: [], reason: "worktree add failed" } };
  }
  applyWorktreeInclude(effects.mainRoot, path);
  return { stem, step, stateKey, commit, tree, branch, path, effects };
}

const recordVerdict = (ctx, p, verdict) =>
  ctx.sprint.state(["baseline", "--slot", p.stateKey, "--commit", p.commit, "--verdict", verdict, ...(p.tree ? ["--tree", p.tree] : [])]);

/** Logs the deps outcome; returns a failing result when the install failed. */
function installDeps(ctx, p, deps) {
  const line = depsLine(deps.stdout);
  if (line) ctx.log(`${p.step} ${line}`, "debug"); // ensure-deps.sh traced [DEPS]
  if (/^DEPS: failed\b/.test(line)) {
    recordVerdict(ctx, p, "fail");
    return { status: "fail", commit: p.commit, failed: [], reason: `dependency install failed — ${line.replace(/^DEPS:\s*/, "")}` };
  }
  return null;
}

function concludeChecks(ctx, p, verify) {
  const { sprint } = ctx;
  logVerifyOutput(ctx, join(sprint.dispatchDir, p.stem), `step=${p.step}`, null, verify);
  const verdict = verify.code === 0 ? "pass" : "fail";
  recordVerdict(ctx, p, verdict);
  if (verdict === "pass") return { status: "pass", commit: p.commit, failed: [] };
  const recordFile = join(sprint.dispatchDir, p.stem, "verify.json");
  const record = readVerifyRecord(recordFile);
  const failed = Object.entries(record.checks)
    .filter(([, result]) => result === "fail")
    .map(([check]) => ({ check, log: record.logs[check] ?? null, missing: record.missing[check] ?? null }));
  return { status: "fail", commit: p.commit, failed, reason: `verify-worktree.sh failed — see ${recordFile}` };
}

function cleanupChecks(p) {
  removeWorktree(p.effects, { mainRoot: p.effects.mainRoot, path: p.path });
  p.effects.git(["branch", "-D", p.branch]);
}

/** Before any dispatch: the feature branch's own checks. */
export function runBaseline(ctx) {
  return runFeatureChecks(ctx, { stem: BASELINE_STEM });
}

/** The same, started alongside dispatch: resolves to the baseline's result. */
export function runBaselineAsync(ctx) {
  return runFeatureChecksAsync(ctx, { stem: BASELINE_STEM });
}

/**
 * At each drain of the queue: the checks on the merged feature branch, which no per-branch
 * verify saw — two branches green alone can be red together. Same throwaway worktree, cache
 * and modified-tree rule as the baseline, under its own stem; `--no-baseline` leaves it on.
 */
export function runIntegrationCheck(ctx) {
  const result = runFeatureChecks(ctx, { stem: INTEGRATION_STEM });
  const at = `${ctx.sprint.featureBranch} at ${result.commit.slice(0, 12)}`;
  if (result.status === "fail") {
    const what = result.failed.length ? result.failed.map((f) => f.check).join(", ") : result.reason;
    ctx.log(`INTEGRATION: fail — ${what} (${at})`, "error");
  } else if (result.status === "skipped") {
    ctx.log(`INTEGRATION: skipped — ${result.reason} (${at})`, "warn");
  } else if (result.status === "pass") {
    ctx.log(`INTEGRATION: ${result.reason ? `not run — ${result.reason}` : "pass"} (${at})`);
  }
  return result;
}

/** Lines of a failing check's output the summary quotes: enough to name the failure. */
const TAIL_LINES = 20;

/** The tail of one failing check's captured log, or null when it has none or it cannot be read. */
function logTail(mainRoot, log) {
  try {
    return readFileSync(resolve(mainRoot, log), "utf8").trimEnd().split("\n").slice(-TAIL_LINES).join("\n");
  } catch {
    return null;
  }
}

/** Each failing check of an integration result that has a log, with the tail of its output. */
export function failureTails(mainRoot, result) {
  return result.failed.filter((f) => f.log).map((f) => ({ check: f.check, tail: logTail(mainRoot, f.log) ?? "" }));
}

/**
 * The summary's `## Integration check` section for the last integration result: what passed,
 * or each failing check with the tail of its output. A check whose command is not installed is
 * named as the environment, since no change to the merged code would fix it. `fix` (the
 * integration-fix.mjs outcome for that result) says what the failure led to, and `fixes` (every
 * outcome this run) names the fix issues an earlier red drain led to.
 */
export function integrationSection(mainRoot, featureBranch, result, fix = null, fixes = []) {
  const at = `${featureBranch} at ${result.commit.slice(0, 12)}`;
  const earlier = fixes.filter((f) => f.verdict === "queued" && f.commit !== result.commit);
  const history = earlier.length
    ? ["", `Fix issue(s) from earlier red drain(s) this run: ${earlier.map((f) => f.ref).join(", ")}.`]
    : [];
  if (result.status === "cached") return [`Passed on ${at} (cached — this tree already passed).`, ...history].join("\n");
  if (result.status === "skipped") return `**Skipped:** ${result.reason}. Nothing checked the merged branch.`;
  if (result.status === "pass") {
    return [result.reason ? `**Not run:** ${result.reason}.` : `Passed on ${at}.`, ...history].join("\n");
  }
  const lines = [`**Failed** on ${at} — each branch passed its own checks, but the merged feature branch does not.`, ""];
  if (!result.failed.length) lines.push(`- ${result.reason}`);
  for (const f of result.failed) {
    lines.push(`- \`${f.check}\`: fail${f.missing ? ` — command not found: ${f.missing} (an environment problem, not the merged code)` : ""}`);
    if (!f.log) continue;
    const tail = logTail(mainRoot, f.log);
    lines.push("", `  Output tail (${f.log}):`, "", "  ```", ...(tail ? tail.split("\n").map((l) => `  ${l}`) : ["  (no output)"]), "  ```", "");
  }
  if (fix) lines.push("", ...fixLines(fix));
  lines.push(...history);
  return lines.join("\n").trimEnd();
}

/** What a red result led to, for the summary. */
function fixLines(fix) {
  const why = [fix.category, fix.detail].filter(Boolean).join(": ");
  switch (fix.verdict) {
    case "queued":
      if (fix.repeat) return [`**Fix issue ${fix.ref} was queued for this commit and has not landed** — it is still open, so the branch is still red.`];
      return [`**Fix issue queued:** ${fix.ref}${why ? ` — triage: ${why}` : ""}.${fix.triageFailed ? " (Triage did not complete, so it was treated as fixable.)" : ""}`];
    case "pending":
      return [`**No second fix issue:** ${fix.reason}.`];
    case "limit":
      return [`**Not fixed:** ${fix.reason}. The run ends stalled; read the failure above.`];
    default:
      return [`**Not fixable by a code change, no fix issue queued:** ${fix.reason}.`];
  }
}

/**
 * Probe `## Requires` through solve-issue's check-requires.sh (which dedupes a command issues
 * share), and block each issue whose requirement fails before any coder is dispatched for it,
 * with the command and its output in `## Blocked`. Called once in preflight for every issue
 * dispatchable then, and by loop.mjs for each other issue when it is first claimed: an issue
 * still waiting on a blocker may need what that blocker lands. Each issue is probed once per
 * run (sprint.claimRequiresProbe); not cached across runs, so a re-run probes again and the
 * issue is dispatched once its requirement holds. Returns the slugs blocked.
 */
export async function checkRequires(ctx, issues) {
  const { sprint, effects, options } = ctx;
  if (options?.dryRun) return [];
  const fresh = new Set(sprint.claimRequiresProbe(issues.map((i) => i.slug)));
  const declaring = issues.filter((i) => fresh.has(i.slug) && sectionBody(i.text ?? "", "Requires") !== null);
  if (!declaring.length || !sprint.installDir) return [];
  // check-requires.sh reads files; a github issue has only a body, so it is written out.
  const byFile = new Map();
  for (const issue of declaring) {
    let file = issue.path;
    if (!file) {
      const issueDir = dispatchIssueDir(sprint.dispatchDir, issue);
      mkdirSync(issueDir, { recursive: true });
      file = join(issueDir, "requires.md");
      writeFileSync(file, issue.text);
    }
    byFile.set(file, issue);
  }
  ctx.log(`[STEP] step=requires issues=${declaring.map((i) => i.slug).join(",")}`);
  const script = join(assetDir(sprint.installDir, "solveIssue"), "check-requires.sh");
  const r = effects.exec(
    "bash",
    [script, "--project-root", effects.mainRoot, ...[...byFile.keys()].flatMap((f) => ["--issue", f])],
    { env: sprint.childEnv() },
  );
  const blocked = [];
  for (const [file, failures] of parseRequiresFailures(r.stdout, byFile.keys())) {
    const issue = byFile.get(file);
    const reason = taggedReason(REQUIRES_FAILED_TAG, failures.map((f) => `\`${f.command}\` ${f.status || "failed"}`).join("; "));
    const evidence = failures
      .map((f) => [`$ ${f.command}  (${f.status || "failed"})`, f.output].filter(Boolean).join("\n"))
      .join("\n\n");
    ctx.log(`[REQUIRES-FAILED] slug=${issue.slug} — ${reason.slice(REQUIRES_FAILED_TAG.length + 3)}`);
    await writeTrackerSection(effects, issue, "Blocked", `Preflight: ${reason}\n\n\`\`\`\n${evidence}\n\`\`\``, { append: true });
    sprint.blocked(issue.slug, null, reason);
    sprint.markBlockedThisRun(issue.slug);
    blocked.push(issue.slug);
  }
  if (r.code !== 0 && !blocked.length) ctx.log(`REQUIRES: check-requires.sh exited ${r.code} with no failure named — ${(r.stderr || r.stdout).trim()}`);
  return blocked;
}

/**
 * The stop message for a failed install into the shared docker volume. Unlike a host install,
 * no worktree installs again — each only checks that this one happened — so every coder and
 * every verify gate would run without deps. The reason is already on the run's output above:
 * docker-install.sh's own stderr, streamed through ensure-deps.sh.
 */
export function dockerDepsFailureMessage(line) {
  return [
    "crew-afk: dependencies could not be installed into the docker volume every issue's checks run against — every coder would start without them.",
    `  ${line.replace(/^DEPS:\s*/, "")}`,
    "Fix the install (its output is above), then re-run.",
    "To run anyway, with each coder's own dep-install as the only install: --no-deps.",
  ].join("\n");
}

/**
 * The stop message for a red baseline: which checks, where their output is, and the two ways on.
 * When every failed check failed on a command that is not installed, the branch was never
 * judged, so the message names the environment instead of asking for a fix on the branch.
 */
export function baselineFailureMessage(featureBranch, result) {
  const at = result.commit.slice(0, 12);
  const missing = [...new Set(result.failed.map((f) => f.missing).filter(Boolean))];
  const envOnly = result.failed.length > 0 && missing.length > 0 && result.failed.every((f) => f.missing);
  const lines = [
    envOnly
      ? `crew-afk: ${featureBranch}'s checks cannot run here: ${missing.map((m) => `\`${m}\``).join(", ")} ${missing.length > 1 ? "are" : "is"} not installed — an environment problem, not a red branch (${at}). Every issue's verify gate would fail the same way, after paying for its coder.`
      : `crew-afk: ${featureBranch} fails its own checks before any issue has touched it (${at}) — every issue's verify gate would fail the same way, after paying for its coder.`,
  ];
  if (result.failed.length) {
    for (const f of result.failed) {
      lines.push(`  ${f.check}: fail${f.missing ? ` — command not found: ${f.missing}` : ""}${f.log ? ` — ${f.log}` : ""}`);
    }
  } else {
    lines.push(`  ${result.reason}`);
  }
  if (envOnly) {
    lines.push("Install it where the checks run (or give .coding-crew/dev-commands.json an `install` command that does), then re-run.");
  } else {
    lines.push("Fix it on the feature branch (or start the service the checks need), then re-run.");
  }
  lines.push("To run anyway, knowing every issue will be judged against a red branch: --no-baseline.");
  return lines.join("\n");
}

/**
 * Once, after the dirty-checkout check and before anything reads the feature branch: bring
 * origin/<default> into a resumed branch that lacks it (sync-feature-branch.sh does the git).
 * `--no-sync-main` skips; `--dry-run` only reports whether a merge would happen.
 *
 * Returns `{ status: "skipped" | "current" | "merged" | "would-merge" | "conflict", output }`.
 */
export function syncFeatureBranch(ctx) {
  const { sprint, effects, options } = ctx;
  if (options.syncMain === false) return { status: "skipped", output: "" };
  const args = [...(options.dryRun ? ["--dry-run"] : []), sprint.featureBranch];
  const r = effects.bash("sync-feature-branch.sh", args, { env: sprint.childEnv(), mutating: false });
  const output = (r.stdout ?? "").trim();
  if (r.code !== 0) return { status: "conflict", output: (r.stderr || output).trim() };
  for (const line of output.split("\n").filter(Boolean)) ctx.log(line);
  if (!output) return { status: "current", output };
  return { status: options.dryRun ? "would-merge" : "merged", output };
}

/** The stop message for a feature branch that origin/<default> cannot be merged into cleanly. */
export function syncConflictMessage(featureBranch, output) {
  return [
    `crew-afk: ${featureBranch} does not contain origin's default branch and merging it conflicts — the merge was aborted and ${featureBranch} is untouched:`,
    `  ${output.replace(/^SYNC:\s*/, "")}`,
    "Merge origin's default branch into it by hand (scripts/sync-pr-with-main.sh in the crew repo, or `git merge origin/<default>`), then re-run.",
    "To run anyway, from the branch as it is: --no-sync-main.",
  ].join("\n");
}
