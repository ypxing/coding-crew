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

import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { ASSET_DIRS, assetDir } from "./install-dir.mjs";
import { depsLine, parseRequiresFailures, readVerifyRecord } from "./report.mjs";
import { sectionBody } from "./trackers/body-format.mjs";
import { dispatchIssueDir, logVerifyOutput, REQUIRES_FAILED_TAG, taggedReason, writeTrackerSection } from "./pipeline/shared.mjs";
import { applyWorktreeInclude, removeWorktree, worktreePath } from "./worktree.mjs";

/** The file whose presence says an asset dir is really installed, not just created. */
const ASSET_PROBES = {
  reviewer: "scripts/review-context.sh",
  depInstall: "run.sh",
  solveIssue: "check-requires.sh",
};

/**
 * Each asset dir under `installDir` (install-dir.mjs) whose probe file is absent: `[{ kind, file }]`.
 * Every run uses each — the reviewer reads its scripts, ensure-deps.sh / verify-worktree.sh run
 * dep-install's, and preflight runs check-requires.sh — so a gap here is one every reviewer or
 * coder would otherwise hunt for.
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

/** Files crew-afk itself writes in the main checkout; the summary already reminds about them. */
const CREW_OWNED = new Set([".coding-crew/dev-commands.json", ".worktreeinclude"]);

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

/**
 * Run the project's checks once on the feature branch's tip, in a throwaway worktree set up
 * exactly as an issue's is (include, deps), so a failure here is the one every issue's verify
 * would repeat. A pass is cached by the tip's commit; a failure never is, since an
 * environment the human fixed (a service started) should be re-checked on the next run.
 *
 * Returns `{ status: "pass" | "cached" | "fail", commit, failed: [{check, log, missing}], reason }`.
 */
export function runBaseline(ctx) {
  const { sprint, effects, options } = ctx;
  const commit = effects.gitRead(["rev-parse", `${sprint.featureBranch}^{commit}`]).stdout.trim();
  const cached = sprint.readState().baseline;
  if (commit && cached?.commit === commit && cached.verdict === "pass") {
    ctx.log(`BASELINE: pass (cached — ${sprint.featureBranch} already passed at ${commit.slice(0, 12)})`);
    return { status: "cached", commit, failed: [] };
  }

  const branch = baselineBranch(sprint.featureSlug);
  const path = worktreePath(effects.mainRoot, branch);
  // A crashed earlier run may have left both behind.
  removeWorktree(effects, { mainRoot: effects.mainRoot, path });
  effects.git(["worktree", "prune"]);
  ctx.log(`[STEP] step=baseline branch=${sprint.featureBranch} commit=${commit.slice(0, 12)}`);
  const add = effects.git(["worktree", "add", "-B", branch, path, sprint.featureBranch]);
  if (add.code !== 0) {
    // Not the project's fault: a baseline that could not run says nothing, so it does not stop the run.
    ctx.log(`BASELINE: skipped — could not create its worktree: ${add.stderr.trim()}`);
    return { status: "pass", commit, failed: [], reason: "worktree add failed" };
  }

  try {
    applyWorktreeInclude(effects.mainRoot, path);
    if (options.installDeps !== false) {
      const deps = effects.bash("ensure-deps.sh", ["--dir", path, "--slug", BASELINE_STEM, "--stem", BASELINE_STEM], {
        env: sprint.childEnv(),
      });
      const line = depsLine(deps.stdout);
      if (line) ctx.log(`baseline ${line}`, "debug"); // ensure-deps.sh traced [DEPS]
      if (/^DEPS: failed\b/.test(line)) {
        sprint.state(["baseline", "--commit", commit, "--verdict", "fail"]);
        return { status: "fail", commit, failed: [], reason: `dependency install failed — ${line.replace(/^DEPS:\s*/, "")}` };
      }
    }
    const verify = effects.bash("verify-worktree.sh", ["--dir", path, "--stem", BASELINE_STEM], { env: sprint.childEnv() });
    logVerifyOutput(ctx, join(sprint.dispatchDir, BASELINE_STEM), "step=baseline", null, verify);
    const verdict = verify.code === 0 ? "pass" : "fail";
    sprint.state(["baseline", "--commit", commit, "--verdict", verdict]);
    if (verdict === "pass") return { status: "pass", commit, failed: [] };
    const recordFile = join(sprint.dispatchDir, BASELINE_STEM, "verify.json");
    const record = readVerifyRecord(recordFile);
    const failed = Object.entries(record.checks)
      .filter(([, result]) => result === "fail")
      .map(([check]) => ({ check, log: record.logs[check] ?? null, missing: record.missing[check] ?? null }));
    return { status: "fail", commit, failed, reason: `verify-worktree.sh failed — see ${recordFile}` };
  } finally {
    removeWorktree(effects, { mainRoot: effects.mainRoot, path });
    effects.git(["branch", "-D", branch]);
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
