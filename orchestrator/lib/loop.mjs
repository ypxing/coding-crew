/**
 * loop.mjs — the sprint loop and the wrap-up, as a continuous dispatch pool.
 *
 * `options.parallel` workers pull from the same live queue for the whole sprint — there
 * is no batch boundary where the pool waits for every currently-running issue to finish
 * before a freed slot can pick up the next one. A worker that just failed becomes
 * dispatchable again (via its retry) the moment it's retained, and a sibling that just
 * unblocked a dependent issue makes that issue dispatchable the moment it completes —
 * both get picked up by whichever slot frees first, not by whatever slower issue the old
 * round-batch model happened to still be waiting on.
 *
 * What used to be "round" — a wave of issues dispatched together — no longer exists as a
 * synchronization point. What's left of the word is repurposed as each *issue's own*
 * attempt count (see sprint.bumpAttempt, spent once per dispatch in runOne below, and
 * pipeline/finish.mjs's finishRetryOrBlock): the per-issue retry cap that used to fall out
 * accidentally from a round's real wall-clock cost is now the only thing throttling
 * retries, so it has to be explicit.
 *
 * Two exits: nothing left to do (every open issue completed, or permanently blocked by a
 * spent retry cap or an unresolvable dependency), or the `--max-rounds` safety cap — each
 * issue may reach that many attempts, the same guarantee a round-batch sprint gave for
 * free (every issue gets one attempt per round before any issue gets a second). Checked
 * per issue, not as a global dispatch count, so a small --max-rounds still lets every
 * issue take its turn instead of the first one claimed exhausting the whole budget while
 * its siblings never run. Either way, findings are flushed first — see flush() below —
 * because a sprint that stalled on unrelated issues may still have merged code carrying a
 * CRITICAL finding.
 *
 * The PRD audit (runPrdAudit) runs once, the first time the queue drains: its gaps are parked
 * like findings, so the same flush sends both into Phase 2.
 */

import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { resumeRoute, runHousekeeping, runWorker } from "./pipeline.mjs";
import { getTracker } from "./tracker.mjs";
import { dispatchPlain } from "./dispatch.mjs";
import { writeLog } from "./log.mjs";
import { labelIssue } from "./labels.mjs";
import { checkRequires } from "./preflight.mjs";
import { prdGapsCriteria } from "./prompts.mjs";
import { parsePrdAudit } from "./report.mjs";

export async function runSprint(ctx) {
  const { sprint, effects, options } = ctx;
  // Resolved once per sprint, per `tracker.mjs`'s own contract — see its docstring — so
  // this loop dispatches against whichever backend `tracker-config.mjs` names, github or
  // local, instead of always the local file scan `tracker.mjs`'s static re-exports are
  // bound to.
  const tracker = await getTracker(effects.mainRoot);
  const parallel = Math.max(1, options.parallel ?? 1);
  const inFlight = new Set();
  // At most one merge-conflict retry at a time: each resolves against the feature-branch
  // tip, so two in flight together resolve against the same tip, and whichever merges
  // second conflicts again with the first's resolution — spending its retry cap on a
  // conflict its sibling caused. Serialized, each syncs after the previous one merged.
  let conflictRetryInFlight = null;
  const conflictWaitsLogged = new Set();
  const history = [];
  let waiters = [];
  // Issues this run labelled `in-progress` and has not seen leave it: a merge (mark-done) and a
  // block (issue-labels.sh block) each remove it themselves; whatever is left is released at run end.
  const held = new Map();
  // github fix issues this run created already ready-for-agent (a review's findings, the PRD
  // audit's gaps), not yet seen in the milestone listing — see awaitListed.
  const unseen = new Set();
  const unlisted = [];

  const notifyAll = () => {
    const pending = waiters;
    waiters = [];
    for (const resolve of pending) resolve();
  };
  const waitForChange = () => new Promise((resolve) => waiters.push(resolve));

  // Scoped to this sprint's own feature — see selectDispatchable()'s docstring. An
  // unscoped scan here would dispatch a ready-for-agent issue from an unrelated
  // .scratch/<other-feature>/ onto this sprint's feature branch. sprint.isBlockedThisRun
  // (in-memory, this invocation only) is consulted here — not the persisted
  // `blocked_slugs` — because a slug that spent its retry cap never has its issue file's
  // own `Status:` rewritten (only close-issue.sh writes that), so nothing on disk marks it
  // unavailable; if this checked the persisted list instead, a fresh `crew-afk` run could
  // never retry it, breaking crew-summary.sh's own "resolve blockers and re-run" advice.
  function claimNext() {
    const issues = tracker.selectDispatchable(effects.mainRoot, { featureSlug: sprint.featureSlug });
    return issues.find(
      (i) =>
        !inFlight.has(i.slug) &&
        !sprint.isBlockedThisRun(i.slug) &&
        (!options.maxRounds || sprint.attemptCount(i.slug) < options.maxRounds) &&
        !waitsForConflictRetry(i.slug),
    ) ?? null;
  }

  function isConflictRetry(slug) {
    return resumeRoute(sprint.retentionReason(slug)).kind === "conflict";
  }

  function waitsForConflictRetry(slug) {
    if (conflictRetryInFlight == null || !isConflictRetry(slug)) return false;
    const key = `${slug} ${conflictRetryInFlight}`;
    if (conflictWaitsLogged.has(key)) return true;
    conflictWaitsLogged.add(key);
    ctx.log(`[CONFLICT-RETRY-WAIT] slug=${slug} — waiting for ${conflictRetryInFlight}'s merge-conflict retry to finish`);
    return true;
  }

  /** True once every remaining open issue is either done, blocked, or at its --max-rounds
   * limit — as opposed to genuinely nothing left, which flush() still needs to check. */
  function cappedByMaxRounds() {
    if (!options.maxRounds) return false;
    return tracker.selectDispatchable(effects.mainRoot, { featureSlug: sprint.featureSlug }).some(
      (i) => !sprint.isBlockedThisRun(i.slug) && sprint.attemptCount(i.slug) >= options.maxRounds,
    );
  }

  async function runOne(issue) {
    inFlight.add(issue.slug);
    // An issue preflight did not probe (it was waiting on a blocker then): its ## Requires runs
    // now, before its first dispatch. A no-op for any issue already probed this run.
    if ((await checkRequires(ctx, [issue])).length) {
      inFlight.delete(issue.slug);
      notifyAll();
      return;
    }
    // After the requires probe: a requires-failed issue is never labelled. Display only.
    if (!held.has(issue.slug) && labelIssue(ctx, "claim", issue)) held.set(issue.slug, issue);
    const conflictRetry = isConflictRetry(issue.slug);
    if (conflictRetry) conflictRetryInFlight = issue.slug;
    const attempt = sprint.bumpAttempt(issue.slug);
    const worker = await runWorker(ctx, issue, attempt);
    const outcome = await runHousekeeping(ctx, worker);
    history.push(outcome);
    if (outcome.promotedRef && !tracker.listOpenIssueFiles) unseen.add(outcome.promotedRef);
    if (outcome.status === "complete" || outcome.inProgressCleared) held.delete(issue.slug);
    ctx.log(
      `[ATTEMPT-END] slug=${issue.slug} attempt=${attempt} status=${outcome.status}${outcome.reason ? ` reason=${outcome.reason}` : ""}`,
    );
    inFlight.delete(issue.slug);
    if (conflictRetry) conflictRetryInFlight = null;
    notifyAll();
  }

  // One of `parallel` of these runs concurrently. Each keeps claiming and running issues
  // until there's genuinely nothing left to claim (nothing claimable and nothing any
  // sibling is still working on that could unblock or free up more).
  async function workerLoop() {
    while (true) {
      const issue = claimNext();
      if (issue) {
        await runOne(issue);
        continue;
      }
      if (inFlight.size === 0) return;
      await waitForChange();
    }
  }

  let capped = false;
  let prdAudit = {};
  let audited = false;
  while (true) {
    await Promise.all(Array.from({ length: parallel }, () => workerLoop()));

    capped = cappedByMaxRounds();
    if (capped) {
      flush(ctx);
      ctx.log(`Round cap reached (--max-rounds ${options.maxRounds}).`);
      break;
    }
    // Once, when Phase 1 has drained: its gaps join the findings in the one flush below,
    // so Phase 2 fixes both, and nothing after it is audited again.
    // github creates the gaps issue — like a finding's fix issue — ready-for-agent, so the
    // flush has nothing to promote for it and the loop goes round again once it is listed.
    if (!audited) {
      audited = true;
      prdAudit = await runPrdAudit(ctx, tracker);
      if (prdAudit.queuedReady && prdAudit.queuedRef) unseen.add(prdAudit.queuedRef);
    }
    if (flush(ctx) > 0) continue;
    if (unseen.size) {
      const refs = [...unseen];
      unseen.clear();
      const missing = await awaitListed(ctx, tracker, refs);
      for (const ref of missing) {
        const what = ref === prdAudit.queuedRef ? "PRD gaps" : "review findings";
        const line = `#${ref} (${what}) was created but never appeared in the milestone listing — re-run to implement it.`;
        if (ref === prdAudit.queuedRef) prdAudit.unqueued = line;
        else unlisted.push(line);
        ctx.log(`[FIX-ISSUE-UNLISTED] ${line}`, "warn");
      }
      if (missing.length < refs.length) continue;
    }
    break;
  }

  // listOpenIssueFiles is local-only (a directory scan); github's counterpart is listOpen,
  // whose entries carry their own `status` (a close-state, not a file location) instead of
  // requiring a second directory read to know which are still open.
  const stalled =
    !capped &&
    (tracker.listOpenIssueFiles
      ? tracker.listOpenIssueFiles(effects.mainRoot, { featureSlug: sprint.featureSlug }).length > 0
      : unfinishedIssues(tracker, effects.mainRoot, sprint.featureSlug).length > 0);

  // Before the summary: drained, capped or stalled, no issue keeps a label saying it is being worked.
  for (const issue of held.values()) labelIssue(ctx, "release", issue);
  held.clear();

  await wrapUp(ctx, { tracker, stalled, prdAudit, unlisted });
  return { stalled, history };
}

/**
 * Issues this sprint hasn't finished, other than parked fix issues. Local issues keep their
 * `Status:` until close-issue.sh moves them, so a blocked one is still in open/.
 */
function unfinishedIssues(tracker, mainRoot, featureSlug) {
  if (tracker.listOpenIssueFiles) {
    return tracker
      .listOpenIssueFiles(mainRoot, { featureSlug })
      .map((p) => tracker.parseIssue(p))
      .filter((i) => i.status !== "deferred-findings");
  }
  // The milestone's PRD issue stays open for the life of the feature; it is not work.
  return tracker.listOpen(mainRoot, { featureSlug }).filter((i) => i.status !== "done" && !tracker.isPrdIssue?.(i));
}

/**
 * The PRD audit (prdAuditor, afk.PRDAudit): what no per-branch review can see — a PRD
 * requirement no issue carried, a flow across issues. In `fix` mode its ✗ missing
 * requirements become one parked fix issue, which the caller's flush sends into Phase 2.
 * It does not run while a Phase 1 issue is still open (blocked, retained, stalled): that
 * issue's requirements would read as missing, so the report is noise and its gaps would
 * duplicate the issue — and the re-run that finishes it audits anyway. Returns
 * `{report, queuedReady, queuedRef, unqueued, superseded, failed, skipped}`: the report's path (or null); whether an
 * issue was created already ready-for-agent (github — local parks it for the flush instead), and its number;
 * in fix mode, why gaps were left unqueued; why an audit that ran did not finish; and why it
 * did not run. `superseded` lists the PRD requirements a later decision replaced, in either mode. The last three are for the summary — the trace log alone is too easy to miss.
 */
async function runPrdAudit(ctx, tracker) {
  const { sprint, effects, options } = ctx;
  const mode = sprint.PRDAudit;
  if (mode === "off") return { report: null, queuedReady: false };
  const unfinished = unfinishedIssues(tracker, effects.mainRoot, sprint.featureSlug);
  if (unfinished.length) {
    const skipped = `${unfinished.length} Phase 1 issue(s) still open (${unfinished.map((i) => i.slug).join(", ")}) — resolve them and re-run.`;
    ctx.log(`PRD audit: skipped — ${skipped}`);
    return { report: null, queuedReady: false, skipped };
  }
  const audit = effects.exec("bash", [effects.script("prd-audit.sh"), "--mode", mode], {
    env: sprint.childEnv(),
    mutating: false,
  });
  // Only the script's own first line ever says "skipped" — the PRD it quotes may say it too.
  const firstLine = audit.stdout.split("\n", 1)[0] ?? "";
  if (/^PRD audit: skipped/.test(firstLine)) {
    ctx.log(firstLine);
    return { report: null, queuedReady: false };
  }

  const outFile = join(sprint.env.SPRINT_DIR, "prd-audit.md");
  const { runtime, model } = options.crew.prdAuditor;
  ctx.log(`[STEP] step=prd-audit mode=${mode} model=${model ?? "inherit"} runtime=${runtime}`);
  const r = await dispatchPlain(effects, runtime, {
    prompt: audit.stdout,
    cwd: effects.mainRoot,
    mainRoot: effects.mainRoot,
    model,
    outFile,
    timeoutMs: options.timeoutMs.prdAuditor,
    maxBudgetUsd: options.limitsUsd?.prdAuditor,
  });
  if (r.code !== 0 || r.timedOut) {
    const failed = `the audit did not complete (${r.timedOut ? "timed out" : `exit ${r.code}`}) — no report, nothing queued.`;
    ctx.log(`PRD audit: ${failed}`);
    return { report: null, queuedReady: false, failed };
  }
  ctx.log(`PRD audit report: ${outFile}`);
  if (r.dryRun) return { report: outFile, queuedReady: false };

  // Superseded requirements are named in both modes and queued in neither: the PRD is older
  // than the decision that replaced them, and only a human should rewrite the PRD.
  const parsed = parsePrdAudit(r.text);
  const { superseded } = parsed;
  if (superseded.length) ctx.log(`PRD audit: ${superseded.length} superseded requirement(s), not queued.`);
  if (mode !== "fix") return { report: outFile, queuedReady: false, superseded };
  if (!parsed.ok) {
    ctx.log("PRD audit: no closing json block in the report — nothing queued; read it by hand.");
    return { report: outFile, queuedReady: false, unqueued: "the report has no closing json block — read it by hand." };
  }
  if (!parsed.missing.length) {
    ctx.log("PRD audit: no missing requirements.");
    return { report: outFile, queuedReady: false, superseded };
  }
  const criteriaPath = join(sprint.env.SPRINT_DIR, "prd-gaps.criteria.md");
  writeFileSync(criteriaPath, prdGapsCriteria(parsed.missing));
  const defer = effects.bash(
    "promote-findings.sh",
    ["defer-gaps", "--feature-slug", sprint.featureSlug, "--report", outFile, "--criteria-file", criteriaPath],
    { env: sprint.childEnv() },
  );
  ctx.log(`PRD audit: ${parsed.missing.length} missing requirement(s) → ${defer.stdout.trim() || defer.stderr.trim()}`);
  const queued = defer.code === 0 && /^defer-gaps: (?!skip)/m.test(defer.stdout);
  const unqueued = defer.code === 0 ? null
    : `${parsed.missing.length} missing requirement(s), but the fix issue was not created: ${defer.stderr.trim() || `exit ${defer.code}`}`;
  const queuedRef = Number(/\/issues\/(\d+)\s*$/m.exec(defer.stdout)?.[1]) || null;
  return { report: outFile, queuedReady: queued && !tracker.listOpenIssueFiles, queuedRef, unqueued, superseded };
}

/** Polls of the milestone listing, and the wait before each, for awaitListed. */
const LISTED_POLL = { tries: 15, delayMs: 2000 };

/**
 * github's issue listing lags a create by a few seconds, so a round started for a fix issue
 * created just before the queue drained could list the milestone without it, claim nothing,
 * and end the sprint with it open. Waits, bounded, until the listing has every ref in `refs`;
 * returns those it never showed.
 */
async function awaitListed(ctx, tracker, refs) {
  const { effects, sprint } = ctx;
  let missing = refs;
  for (let n = 0; ; n++) {
    const listed = new Set(tracker.listOpen(effects.mainRoot, { featureSlug: sprint.featureSlug }).map((i) => i.number));
    missing = missing.filter((ref) => !listed.has(ref));
    if (n && missing.length < refs.length) ctx.log(`fix issue(s) listed after ${n} poll(s)`);
    if (!missing.length || n >= LISTED_POLL.tries) return missing;
    await new Promise((resolve) => setTimeout(resolve, LISTED_POLL.delayMs));
  }
}

/** Phase 1 → Phase 2: flip parked fix issues to ready-for-agent. */
function flush(ctx) {
  const { sprint, effects } = ctx;
  const r = effects.bash("promote-findings.sh", ["flush", "--feature-slug", sprint.featureSlug], {
    env: sprint.childEnv(),
  });
  const text = r.stdout.trim();
  ctx.log(text, "debug"); // promote-findings.sh traced [FLUSH]
  const m = /FLUSH:\s*promoted=(\d+)/.exec(text);
  const promoted = m ? Number(m[1]) : 0;
  if (promoted > 0) ctx.log(`Phase 2: ${promoted} fix issue(s) re-entered the loop.`);
  return promoted;
}

async function wrapUp(ctx, { tracker, stalled, prdAudit, unlisted = [] }) {
  const { sprint, effects, options } = ctx;

  // --- squash ---------------------------------------------------------------
  // --platform picks the co-author trailer: the coder's runtime wrote the commits.
  const squashArgs = ["--platform", options.crew.coder.runtime];
  if (!options.squashCommits) squashArgs.push("--no-squash");
  const squash = effects.bash("squash-commits.sh", squashArgs, { env: sprint.childEnv() });
  ctx.log(squash.stdout.trim());
  const squashFailed = squash.code !== 0 ? (squash.stderr.trim() || `exit ${squash.code}`) : null;
  if (squashFailed) ctx.log(`Squash failed: ${squashFailed}`);

  // --- worktree cleanup (mechanical, idempotent) ----------------------------
  const cleanupArgs = [
    "--main-root", effects.mainRoot,
    "--feature-slug", sprint.featureSlug,
  ];
  const merged = sprint.get("merged");
  const retained = sprint.get("retained");
  if (merged) cleanupArgs.push("--merged", merged);
  if (retained) cleanupArgs.push("--retain", retained);
  const cleanup = effects.bash("cleanup-worktrees.sh", cleanupArgs, { env: sprint.childEnv() });
  const lastLine = cleanup.stdout.trim().split("\n").filter(Boolean).pop() ?? "";
  ctx.log(lastLine, "debug"); // cleanup-worktrees.sh traced [CLEANUP]

  // --- summary (rendered from disk, never from recollection) -----------------
  // The PR comes first: the summary points at it when the findings were posted there.
  const pr = pullRequest(ctx, tracker);
  const summaryArgs = [];
  if (stalled) summaryArgs.push("--stalled");
  if (pr?.posted != null) summaryArgs.push("--posted-to", pr.url);
  const summary = effects.bash("crew-summary.sh", summaryArgs, { env: sprint.childEnv() });
  ctx.out(summary.stdout);
  // Also kept with the run's trace: stdout goes to whoever launched the run, and a launcher
  // that retells it can drop a line (the cost) nobody can then recover.
  if (sprint.traceLog && summary.stdout.trim()) writeLog(sprint.traceLog, `[SUMMARY]\n${summary.stdout.trimEnd()}`);
  if (prdAudit.skipped) {
    ctx.out(`\n## PRD Audit\n\n**Not run:** ${prdAudit.skipped}\n`);
  } else if (prdAudit.failed) {
    ctx.out(`\n## PRD Audit\n\n**Failed:** ${prdAudit.failed}\n`);
  } else if (prdAudit.report && existsSync(prdAudit.report)) {
    ctx.out(`\n## PRD Audit\n\n(see ${prdAudit.report})\n`);
    if (prdAudit.unqueued) ctx.out(`\n**Gaps not queued:** ${prdAudit.unqueued}\n`);
    if (prdAudit.superseded?.length) {
      const lines = prdAudit.superseded.map((m) => `- ${m.requirement}${m.by ? ` — ${m.by}` : ""}`);
      ctx.out(`\n**Superseded — update the PRD, nothing queued:**\n${lines.join("\n")}\n`);
    }
  }
  if (unlisted.length) ctx.out(`\n**Fix issues not implemented:**\n${unlisted.map((l) => `- ${l}`).join("\n")}\n`);
  if (squashFailed) ctx.out(`\n## Squash\n\n**Failed:** ${squashFailed}\n`);
  if (pr) ctx.out(`\n## ${pr.heading ?? "Pull Request"}\n\n${pr.text}\n`);
  ctx.out("NO MORE TASKS");
}

/**
 * Last, after squash: the feature PR. `openPr` pushes the branch and creates or updates the PR
 * with the tracker's closing lines in its body (open-pr.sh). Off, those lines are printed for
 * the human's own PR — the tracker leaves each merged issue open until a PR closes it. Returns
 * `{text, heading?, url?, posted?}` — the section's text (heading `Next` when off), and when the findings were posted to the PR
 * (post-findings.sh) its URL and their count — or null when there is nothing to say. A posting
 * failure is reported in the text and never fails the sprint.
 */
function pullRequest(ctx, tracker) {
  const { sprint, effects, options } = ctx;
  let refs = [];
  let refsError = null;
  try {
    refs = tracker.closingRefs?.(effects.mainRoot, { featureSlug: sprint.featureSlug }) ?? [];
  } catch (err) {
    refsError = err.message;
  }
  if (refsError) ctx.log(`closing refs: ${refsError}`, "warn");

  if (!options.openPr) {
    // Nothing merged → nothing to ship, so nothing to say. Otherwise the branch is local only:
    // say how to turn it into a PR, and (github) which lines close the issues it merged.
    if (!sprint.get("merged") && !refs.length) return null;
    return { heading: "Next", text: [
      `Merged into ${sprint.featureBranch}; nothing was pushed. To open the PR:`,
      "",
      `  gh pr create --head ${sprint.featureBranch} --title ${sprint.featureSlug}`,
      ...(refs.length ? [
        "",
        "The issues stay open until that PR closes them — put these in its body:",
        "",
        ...refs,
      ] : []),
      "",
      "Or have crew-afk push the branch and open the PR itself: re-run with --open-pr (config: afk.openPr: true).",
    ].join("\n") };
  }
  // A PR without its closing lines would ship the work and strand the issues open.
  if (refsError) return { text: `**Not opened:** could not list the issues it closes — ${refsError}` };
  const closesFile = join(sprint.env.SPRINT_DIR, "pr-closes.txt");
  writeFileSync(closesFile, refs.length ? `${refs.join("\n")}\n` : "");
  const r = effects.bash("open-pr.sh", ["--closes-file", closesFile], { env: sprint.childEnv() });
  if (r.dryRun) return null;
  if (r.code !== 0) return { text: `**Failed:** ${r.stderr.trim() || `exit ${r.code}`}` };
  const url = r.stdout.trim().replace(/^PR: /, "");
  const post = effects.bash("post-findings.sh", [], { env: sprint.childEnv() });
  const m = /^POSTED: (\d+) \((\d+) inline\)/m.exec(post.stdout ?? "");
  if (post.code !== 0 || !m) {
    const why = (post.stderr ?? "").trim() || `exit ${post.code}`;
    ctx.log(`post-findings: ${why}`, "warn");
    return { text: `${url}\n\n**Findings not posted:** ${why}` };
  }
  return { text: `${url}\n\n${m[1]} finding(s) posted (${m[2]} inline).`, url, posted: Number(m[1]) };
}

/** Per-sprint review report file: one timestamped file, appended to across the whole run. */
export function makeRoundReviewFile(sprint) {
  const stamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\..+/, "");
  let cached = null;
  return () => {
    if (!cached) {
      mkdirSync(sprint.reviewDir, { recursive: true });
      cached = join(sprint.reviewDir, `sprint-review-${stamp}.md`);
    }
    return cached;
  };
}
