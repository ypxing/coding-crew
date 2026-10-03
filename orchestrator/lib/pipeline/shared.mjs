/**
 * Helpers shared by the pipeline stages: retention-reason tags, issue naming, the
 * milestone push and tracker writes.
 */

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";

import { getTracker } from "../tracker.mjs";
import { queuePaneNotice } from "../pane-host/index.mjs";

// Retention-reason tags, written by the gates and read back by resumeRoute. Defined once
// so writer and reader cannot drift. The two verification tags carry triage's verdict.
export const FIXABLE_TAG = "verification-failed:fixable";
export const NOT_FIXABLE_TAG = "verification-failed:not-fixable";
// An `AC: unmet` review verdict. No triage: the reviewer's detail is already actionable.
export const CRITERIA_UNMET_TAG = "criteria-unmet";
// An `AC: unmet` verdict the reviewer put down to the environment (`cause: "environment"`):
// a precondition of a criterion did not hold, so no recoding can meet it. Blocks at once.
export const CRITERIA_ENVIRONMENT_TAG = "criteria-unmet:environment";
// `receipts.sh write ac` failed after an all-met review. Never the branch's fault: the
// branch is fine, so no route for it re-runs the coder.
export const AC_RECEIPT_FAILED_TAG = "ac-receipt-failed";
// merge-branches.sh hit a conflict: the feature branch moved on under this branch. Only a
// coder can reconcile that; retrying the merge alone would conflict again.
export const MERGE_CONFLICT_TAG = "merge-conflict";
// merge-branches.sh refused because uncommitted changes in the main checkout would be
// overwritten. Not the branch's fault and not fixable by any dispatch, so it blocks at once;
// a re-run resumes at merge, since verify, review and the AC receipt already passed.
export const MAIN_TREE_DIRTY_TAG = "main-tree-dirty";
// The reviewer left no valid verdict, even after its in-round retry. Carries why (a timeout,
// no report.json, no verdict field) — the branch itself is done, so no route recodes it.
export const REVIEW_NOT_RUN_TAG = "review-not-run";
// An issue's own `## Requires` command failed in preflight (check-requires.sh), so it was
// blocked before any dispatch. Re-probed on every run, so a re-run restarts it only once the
// requirement holds.
export const REQUIRES_FAILED_TAG = "requires-failed";
// A dispatch stopped at its role's afk.limits.<role>.usd cap (claude's error_max_budget_usd).
// Blocks at once; a human raises the cap or narrows the issue.
export const LIMIT_EXCEEDED_TAG = "limit-exceeded";
// verify-worktree.sh ended without a verdict: killed from outside (INTERRUPTED), or its
// output named no failing check (INCONCLUSIVE, even after a second run). Neither is
// evidence against the branch, so no route for either dispatches a coder or triage —
// the next round only verifies again.
export const VERIFY_INTERRUPTED_TAG = "verify-interrupted";
export const VERIFY_INCONCLUSIVE_TAG = "verify-inconclusive";
const REASON_SEP = " — ";

export function taggedReason(tag, summary) {
  return `${tag}${REASON_SEP}${summary}`;
}

/**
 * The runtime and model `role` dispatches on (crew-config.mjs's resolveCrew).
 */
export function roleBinding(ctx, role) {
  const { runtime, model } = ctx.options.crew[role];
  // afk.limits.<role>.usd — claude's flag, so no other runtime is handed one.
  const maxBudgetUsd = runtime === "claude" ? (ctx.options.limitsUsd?.[role] ?? null) : null;
  return { runtime, model, maxBudgetUsd, scriptsDir: ctx.effects.scriptsDir };
}

/**
 * The dispatch stopped at its role's afk.limits dollar cap: the reason to block on, or null.
 * Never a retry — the cap is the human's statement of what one attempt may cost, and a retry
 * would spend it again.
 */
export function limitExceeded(result, role, binding) {
  if (result?.subtype !== "error_max_budget_usd") return null;
  return `${LIMIT_EXCEEDED_TAG} ($${binding?.maxBudgetUsd ?? "?"}) — the ${role} dispatch hit afk.limits.${role}.usd after $${(result.costUsd ?? 0).toFixed(2)}`;
}

/** Dispatch filename stem: `NN-<slug>`, sorting like the tracker's files; bare slug if unnumbered. */
export function dispatchStem(issue) {
  return issue.number ? `${issue.number}-${issue.slug}` : issue.slug;
}

/** This issue's own subdirectory under dispatch/ — every prompt, report and receipt of its lives together. */
export function dispatchIssueDir(dispatchDir, issue) {
  return join(dispatchDir, dispatchStem(issue));
}

/**
 * A verify-worktree.sh transcript, kept in its own file (one per round) instead of the trace
 * log, which gets one [VERIFY-OUTPUT] line naming it: debug on a pass, error on a fail, so
 * a level grep for what went wrong also finds where to read why. `who` is the line's fields.
 */
export function logVerifyOutput(ctx, dir, who, round, verify) {
  if (verify.dryRun) return;
  const file = resolve(ctx.effects.mainRoot, dir, round != null ? `verify-r${round}.out` : "verify.out");
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, verify.stdout ?? "");
  const result = verify.code === 0 ? "pass" : verify.interrupted ? "interrupted" : "fail";
  ctx.log(
    `[VERIFY-OUTPUT] ${who}${round != null ? ` round=${round}` : ""} result=${result} file=${relative(ctx.effects.mainRoot, file)}`,
    result === "pass" ? "debug" : result === "interrupted" ? "warn" : "error",
  );
}

/**
 * A milestone: always logged (the only signal without a pane host), then queued for the
 * pane. Not awaited: the push is advisory and must not hold the issue's pipeline.
 */
export function notifyMilestone(ctx, issue, message) {
  ctx.log(`[MILESTONE] ${dispatchStem(issue)}: ${message}`);
  if (!ctx.effects.paneHost) {
    // None was configured: nothing degraded, so not a warning.
    ctx.log(`[MILESTONE-PUSH-SKIPPED] ${dispatchStem(issue)}: no pane host`, "debug");
    return;
  }
  queuePaneNotice(ctx.effects, `[${ctx.sprint.featureSlug}] ${dispatchStem(issue)}: ${message}`, (result) => {
    if (!result.sent) ctx.log(`[MILESTONE-PUSH-SKIPPED] ${dispatchStem(issue)}: ${result.reason}`);
  });
}

/**
 * Which gates `branch`'s current tip already passed, read from the receipts (receipts.sh
 * owns both): `verified` — a `pass` verify record for this exact commit; `reviewed` — also an
 * all-met AC receipt for it; `verifiedThisRun` — that verify pass was this invocation's own.
 * A retry skips what these say is done: re-running a gate on an unchanged commit can only
 * repeat its answer — within one run. Across runs only `reviewed` is reused: an all-met
 * branch has nothing left to learn from its checks, but one still under review may have
 * failed on an environment a human has since fixed. Matched on the positive line, so
 * CREW_RECEIPTS=off (whose `check` passes everything) never skips a gate.
 */
export function gatesAtTip(ctx, branch) {
  const { sprint, effects } = ctx;
  const check = (args) =>
    effects.exec("bash", [effects.script("receipts.sh"), "check", ...args], { env: sprint.childEnv(), mutating: false });
  const v = check(["verify", "--branch", branch]);
  const commit = v.code === 0 ? v.stdout.match(/verified at ([0-9a-f]+)/)?.[1] : null;
  if (!commit) return { verified: false, reviewed: false, verifiedThisRun: false };
  const a = check(["ac", "--branch", branch, "--at-tip"]);
  return {
    verified: true,
    reviewed: a.code === 0 && /criteria-verified at [0-9a-f]+/.test(a.stdout),
    verifiedThisRun: sprint.verifiedThisRun(branch, commit),
  };
}

/** close-issue.sh / promote-findings.sh's issue argument: a file path (local) or number (github). */
export function issueRef(issue) {
  return issue.path ?? String(issue.number);
}

/** The prompts' `issuePath:` — a file for local; for github, how to fetch the body. */
export function issueDescriptor(issue) {
  return issue.path ?? `GitHub issue #${issue.number} — fetch its current body with: gh issue view ${issue.number} --json body -q .body`;
}

/** The free text after a tag this module itself wrote — never applied to a reason whose tag is unknown. */
export function stripReasonTag(reason, tag) {
  return reason.startsWith(tag + REASON_SEP) ? reason.slice(tag.length + REASON_SEP.length) : reason;
}

/** How state.sh records a block (`blocked — <reason>`), and finishRetryOrBlock a capped retry. */
const BLOCKED_PREFIX = /^blocked — (retry limit reached \(\d+ attempts\) — )?/;

/** A retained reason without the block wrapping, so its gate's tag leads again. */
export function unblockedReason(reason) {
  return reason.replace(BLOCKED_PREFIX, "");
}

/**
 * Write a `## <heading>` note against `issue`: local splices the file in place, github
 * posts a new comment. The one place that branches on which the tracker exposes.
 */
export async function writeTrackerSection(effects, issue, heading, body, { append = false } = {}) {
  if (effects.dryRun) return;
  const tracker = await getTracker(effects.mainRoot);
  if (tracker.writeIssueSection) {
    if (issue.path && existsSync(issue.path)) tracker.writeIssueSection(issue.path, heading, body, { append });
    return;
  }
  if (tracker.writeProgress) tracker.writeProgress(issue, body, { heading, mainRoot: effects.mainRoot });
}

/**
 * A dispatch's JSON sidecar, or null when absent or unparseable. Callers rmSync it before
 * dispatching, so a stale file from a prior round is never read back as this one's.
 */
export function readSidecar(file) {
  if (!existsSync(file)) return null;
  try {
    return JSON.parse(readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}

/**
 * What a read-only dispatch (reviewer, triage) must leave untouched, as `{key: value}`: the named
 * branch refs (or, with `all`, every crew/<feature>/ ref and the feature branch), the main
 * checkout's HEAD, and its uncommitted changes (sprint state under .scratch/ aside — the
 * orchestrator and the dispatch's own sidecar write there). Throws when git cannot answer, so
 * the caller fails closed.
 */
export function readOnlySnapshot(ctx, { branches = [], all = false } = {}) {
  const { sprint, effects } = ctx;
  const git = (args) => {
    const r = effects.gitRead(args);
    if (r.code !== 0) throw new Error(`git ${args[0]} exited ${r.code}: ${(r.stderr || "").trim().slice(0, 200)}`);
    return r.stdout;
  };
  const snap = {};
  const names = all ? [sprint.featureBranch, ...branches] : branches;
  if (all) {
    for (const line of git(["for-each-ref", "--format=%(refname) %(objectname)", `refs/heads/crew/${sprint.featureSlug}/`]).split("\n").filter(Boolean)) {
      const [ref, sha] = line.split(" ");
      snap[ref] = sha;
    }
  }
  for (const name of names) snap[`refs/heads/${name}`] = git(["rev-parse", "--verify", `refs/heads/${name}`]).trim();
  snap.HEAD = git(["rev-parse", "HEAD"]).trim();
  snap["uncommitted changes in the main checkout"] = git(["status", "--porcelain"])
    .split("\n")
    .filter((l) => l && !/^.. "?\.scratch\//.test(l) && !/^\?\? "?\.scratch\/?"?$/.test(l))
    .join("\n");
  return snap;
}

/**
 * Run a read-only dispatch under a before/after snapshot. Returns `{result}` when nothing
 * changed, or `{violation}` (a reason string, already logged as [READONLY-VIOLATION]) when
 * the snapshot could not be taken — in which case `run` never starts — or the dispatch
 * changed anything. Never open: a violation is a not-run for the caller to record.
 */
export async function readOnlyDispatch(ctx, { label, ...scope }, run) {
  const fail = (why) => {
    ctx.log(`[READONLY-VIOLATION] ${label}: ${why}`, "warn");
    return { violation: `read-only violation (${why})` };
  };
  let before;
  try {
    before = readOnlySnapshot(ctx, scope);
  } catch (e) {
    return fail(`snapshot failed: ${e.message}`);
  }
  const mutationsBefore = ctx.effects.mutations;
  const result = await run();
  const concurrent = ctx.effects.mutations !== mutationsBefore;
  let after;
  try {
    after = readOnlySnapshot(ctx, scope);
  } catch (e) {
    return fail(`snapshot failed: ${e.message}`);
  }
  // A merge or another worker's git work ran meanwhile, so HEAD, the main tree and the shared refs
  // moved for reasons that are not this dispatch's: only its own branch ref is still attributable.
  // The main checkout's uncommitted changes stay attributable: merges and worker effects commit or run in worktrees, never leave an edit there.
  const attributable = (k) => !concurrent || k === "uncommitted changes in the main checkout" || (scope.branches ?? []).some((b) => k === `refs/heads/${b}`);
  const changed = [...new Set([...Object.keys(before), ...Object.keys(after)])].filter((k) => attributable(k) && before[k] !== after[k]);
  if (changed.length) return fail(`changed ${changed.join(", ")}`);
  return { result };
}
