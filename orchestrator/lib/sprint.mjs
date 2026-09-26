/**
 * sprint.mjs — sprint.env and sprint-state.json, read through the scripts that own them.
 *
 * The slug is derived exactly once, by session-init.sh, where the issues were found.
 * Nothing here re-derives it: no branch-name parsing, and above all no
 * `ls .scratch/*​/sprint-state.json | head -1` glob, which picks the
 * alphabetically-first feature and silently points a whole sprint at the wrong dir.
 */

import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { depsLine } from "./report.mjs";

// review-rollup.mjs is always this module's sibling one level up (lib/sprint.mjs ->
// ../review-rollup.mjs), whether that's the repo's own orchestrator/ during dev/test or
// an installed .coding-crew/crew-afk/ in production — so childEnv() can hand every
// bash() child the exact path to the one parser of the aggregate review report, instead
// of crew-summary.sh/promote-findings.sh guessing an install location themselves.
const REVIEW_ROLLUP_PATH = join(dirname(dirname(fileURLToPath(import.meta.url))), "review-rollup.mjs");

const ENV_KEYS = [
  "MAIN_ROOT",
  "FEATURE_SLUG",
  "FEATURE_BRANCH",
  "SPRINT_DIR",
  "STATE_FILE",
  "TRACE_LOG",
  "DISPATCH_DIR",
  "REVIEW_DIR",
  "CREW_SCRIPTS",
  "CREW_PRD_AUDIT",
  "CREW_FIX_FINDINGS",
];

/** Parse the `export K="v"` lines session-init.sh writes. Follows the `.` pointer. */
export function readSprintEnv(mainRoot) {
  const pointer = join(mainRoot, ".scratch", "sprint.env");
  if (!existsSync(pointer)) return null;
  let file = pointer;
  const pointerText = readFileSync(pointer, "utf8");
  const follow = /^\s*\.\s+"?([^"\n]+)"?\s*$/m.exec(pointerText);
  if (follow) {
    if (!existsSync(follow[1])) return null;
    file = follow[1];
  }
  const text = readFileSync(file, "utf8");
  const env = {};
  for (const m of text.matchAll(/^\s*export\s+(\w+)="?([^"\n]*)"?\s*$/gm)) {
    if (ENV_KEYS.includes(m[1])) env[m[1]] = m[2];
  }
  return Object.keys(env).length ? { ...env, sprintEnvFile: file } : null;
}

export class Sprint {
  /**
   * @param {import("./effects.mjs").Effects} effects
   * @param {Record<string,string>} env  the parsed sprint.env
   */
  constructor(effects, env) {
    this.effects = effects;
    this.env = env;
    // slug -> count, in-memory only, this invocation's own retry-cap counter (see
    // bumpAttempt). Deliberately never read back from sprint-state.json: crew-summary.sh's
    // "STALLED: resolve blockers and re-run" is the documented recovery path for a blocked
    // issue, and a persisted, ever-growing count would make that re-run permanently refuse
    // to retry it. What's written to disk (`.attempts`, `.round`, `.rounds`) is a mirror
    // for reporting only, never read back to decide anything.
    this._attempts = new Map();
    // slug set, in-memory only, this invocation's own record of which issues finishBlocked
    // has already given up on (see markBlockedThisRun) — what loop.mjs's claimNext() checks
    // instead of the persisted `blocked_slugs`, for the same cross-invocation reason above.
    this._blockedThisRun = new Set();
  }

  static async init(effects, { featureSlug, fixFindings, PRDAudit, passthrough = [], deps = true, log = () => {} }) {
    const args = [];
    if (featureSlug) args.push("--feature-slug", featureSlug);
    if (PRDAudit) args.push("--prd-audit", PRDAudit);
    if (fixFindings) args.push("--fix-findings", fixFindings);
    args.push(...passthrough);
    const r = effects.bash("session-init.sh", args);
    if (r.code !== 0) {
      throw new Error(`session-init.sh failed (${r.code}): ${r.stderr || r.stdout}`);
    }
    const env = readSprintEnv(effects.mainRoot);
    if (!env) throw new Error("session-init.sh did not produce a readable .scratch/sprint.env");
    const sprint = new Sprint(effects, env);

    // Deps are provisioned by installDeps() below, not here — a caller that also wants
    // one-time command discovery (commands.mjs) must run that first, so a documented
    // install override it caches at .coding-crew/dev-commands.json is already on disk the first
    // time ensure-deps.sh runs: commands finding before deps installing, so the finding
    // can be used rather than raced. main.mjs is that caller; init() itself no longer
    // installs so that ordering is possible.
    if (deps) await sprint.installDeps(log);
    return sprint;
  }

  /**
   * Deps, once, serially, against `effects.mainRoot` — before any worker or worktree
   * exists. N parallel workers provisioning N fresh worktrees would otherwise be N cold
   * downloads of the same packages; this warms whatever cache the package manager keeps
   * so the per-worktree installs are local copies. On the host this is advisory — every
   * worktree installs again, and verify-worktree.sh is the gate — so the outcome is only
   * logged. In docker mode it is the one install into the volume every worktree shares, so
   * the caller stops the run on `DEPS: docker-failed`; hence the returned DEPS: line.
   *
   * Call this after one-time command discovery (see commands.mjs), not before: discovery
   * may cache a documented install override at `.coding-crew/dev-commands.json`, and
   * `ensure-deps.sh` only reads that cache, it never waits for one to appear.
   *
   * Streamed through `log` line-by-line as ensure-deps.sh runs (via spawnWithTimeout's
   * `onLine`, the same mechanism dispatch()'s headless path already uses for a worker's own
   * trace) rather than captured wholesale and reported once at the end — a cold-cache
   * install of hundreds of packages used to produce zero visible output for however long it
   * took, since the previous effects.bash()/spawnSync call only ever surfaced ensure-deps.sh's
   * own final summary line. ensure-deps.sh's own `DEPS: ...` line is filtered out of the live
   * stream and logged exactly once at the end (via depsLine() against the full captured
   * stdout spawnWithTimeout already accumulates) so it is never printed twice.
   */
  async installDeps(log = () => {}) {
    let lineBuffer = "";
    const emit = (line) => {
      if (line.trim() && !/^DEPS:/.test(line)) log(line);
    };
    const d = await this.effects.spawnWithTimeout("bash", [this.effects.script("ensure-deps.sh"), "--dir", this.effects.mainRoot], {
      cwd: this.effects.mainRoot,
      env: this.childEnv(),
      onLine: (chunk) => {
        lineBuffer += String(chunk);
        const parts = lineBuffer.split("\n");
        lineBuffer = parts.pop();
        for (const part of parts) emit(part);
      },
    });
    emit(lineBuffer);
    const line = depsLine(d.stdout);
    if (line) log(line);
    return line;
  }

  /** Attach to an already-initialised sprint (resume, status, dry-run planning). */
  static attach(effects) {
    const env = readSprintEnv(effects.mainRoot);
    return env ? new Sprint(effects, env) : null;
  }

  get featureSlug() {
    return this.env.FEATURE_SLUG;
  }
  get featureBranch() {
    return this.env.FEATURE_BRANCH;
  }
  get dispatchDir() {
    return this.env.DISPATCH_DIR;
  }
  get reviewDir() {
    return this.env.REVIEW_DIR;
  }
  get traceLog() {
    return this.env.TRACE_LOG;
  }
  /** "off" | "report" | "fix" — see crew-config.mjs's PRD_AUDIT. */
  get PRDAudit() {
    return this.env.CREW_PRD_AUDIT || "fix";
  }
  /** The lowest severity auto-fixed: "critical" | "high" | "medium" | "none". */
  get fixFindings() {
    return this.env.CREW_FIX_FINDINGS || "high";
  }

  /** Sprint-scoped env for every child: MAIN_ROOT + STATE_FILE + TRACE_LOG. */
  childEnv() {
    const { sprintEnvFile, ...rest } = this.env;
    // Only set when unset: a caller (a test, a human debugging by hand) that already
    // pins a different review-rollup.mjs is deliberately overriding it, not being
    // overridden back.
    return { CREW_REVIEW_ROLLUP: REVIEW_ROLLUP_PATH, ...rest };
  }

  state(args) {
    const r = this.effects.bash("state.sh", args, { env: this.childEnv() });
    if (r.code !== 0) throw new Error(`state.sh ${args.join(" ")} failed: ${r.stderr.trim()}`);
    return r.stdout.trim();
  }

  /** Read-only state query — real even under --dry-run. */
  get(field) {
    const r = this.effects.exec("bash", [this.effects.script("state.sh"), "get", field], {
      env: this.childEnv(),
      mutating: false,
    });
    return r.code === 0 ? r.stdout.trim() : "";
  }

  getList(field) {
    const v = this.get(field);
    return v ? v.split(",").filter(Boolean) : [];
  }

  readState() {
    const f = this.env.STATE_FILE;
    if (!existsSync(f)) return {};
    try {
      return JSON.parse(readFileSync(f, "utf8"));
    } catch {
      return {};
    }
  }

  setModel(alias) {
    return this.state(["model", alias]);
  }
  /**
   * Spend one attempt at `slug` and return its 1-based number for this invocation. Called
   * exactly once per dispatch, at claim time (see runOne in loop.mjs) — before runWorker/
   * runHousekeeping run, so every pass (including the one that finally completes) is
   * counted, and pipeline.mjs's retry cap (finishRetryOrBlock) can compare this same
   * number against the cap with no separate read needed. The count itself lives only in
   * memory (see the constructor) — what's written to disk here is a mirror for
   * crew-summary.sh's "Rounds: N", not a value anything reads back.
   */
  bumpAttempt(slug) {
    const n = (this._attempts.get(slug) ?? 0) + 1;
    this._attempts.set(slug, n);
    this.state(["attempt", "--slug", slug, "--n", String(n)]);
    return n;
  }

  /**
   * Read-only peek at the same in-memory counter, before spending another attempt — what
   * claimNext() (loop.mjs) uses to enforce `--max-rounds` per issue: every issue may reach
   * that many attempts, the same way a round-batch sprint gave every issue one attempt per
   * round. Checking a global dispatch count instead would let the first issue claimed
   * exhaust the whole budget while its siblings never ran even once.
   */
  attemptCount(slug) {
    return this._attempts.get(slug) ?? 0;
  }

  /** Recorded once finishBlocked gives up on `slug` — see claimNext() in loop.mjs. */
  markBlockedThisRun(slug) {
    this._blockedThisRun.add(slug);
  }

  /**
   * Whether `slug` has already been given up on *this invocation* — deliberately not the
   * persisted `blocked_slugs` (see the constructor's comment): a fresh `crew-afk` run must
   * always get a fresh attempt budget, so a human who fixes whatever blocked it can just
   * re-run rather than needing some separate unblock step.
   */
  isBlockedThisRun(slug) {
    return this._blockedThisRun.has(slug);
  }
  complete(slug, branch) {
    return this.state(["complete", "--slug", slug, "--branch", branch]);
  }
  retain(slug, branch, reason) {
    return this.state(["retain", "--slug", slug, "--branch", branch, "--reason", reason]);
  }
  blocked(slug, branch, reason) {
    const args = ["blocked", "--slug", slug];
    if (branch) args.push("--branch", branch);
    if (reason) args.push("--reason", reason);
    return this.state(args);
  }
  coverageGap(slug, categories) {
    return this.state(["coverage-gap", "--slug", slug, "--categories", categories.join(",")]);
  }

  /**
   * Accumulates one dispatch's cost/duration/turns into the sprint's running totals —
   * called unconditionally, since cost is incurred even on a blocked/timed-out dispatch.
   * Claude-only for now (see extractResultMeta in dispatch.mjs); a dispatch with no metadata
   * (pi/codex/copilot, or a dry run) passes 0s, which the additive state.sh command is a
   * no-op for. `slug`/`role`/`attempt` also file it in this run's per-dispatch ledger;
   * `head` (the branch tip a coder left) goes with the session, for a later resume.
   */
  recordDispatchCost({ costUsd, durationMs, numTurns, sessionId, contextTokens }, { slug, role, attempt, head } = {}) {
    const args = [
      "dispatch-cost",
      "--cost",
      String(costUsd ?? 0),
      "--duration-ms",
      String(durationMs ?? 0),
      "--turns",
      String(numTurns ?? 0),
    ];
    if (slug && role) args.push("--slug", slug, "--role", role, "--attempt", String(attempt ?? 0));
    if (sessionId) args.push("--session-id", sessionId, "--context-tokens", String(contextTokens ?? 0));
    if (head) args.push("--head", head);
    return this.state(args);
  }

  /** Tag every later dispatch-cost entry with this run, so the summary can tell it from earlier runs. */
  startRun(id = new Date().toISOString()) {
    return this.state(["run-start", "--id", id]);
  }

  /** The latest ledger entry for `slug` in `role` (any run), or null. */
  lastDispatch(slug, role) {
    const list = this.readState().dispatches ?? [];
    for (let i = list.length - 1; i >= 0; i--) {
      if (list[i]?.slug === slug && list[i]?.role === role) return list[i];
    }
    return null;
  }

  /** `resume: <branch>` | `no prior branch` — a recorded name plus a live ref check. */
  resumeBranch(slug) {
    const r = this.effects.exec(
      "bash",
      [this.effects.script("state.sh"), "resume", "--slug", slug],
      { env: this.childEnv(), mutating: false },
    );
    const m = /^resume:\s*(\S+)/m.exec(r.stdout || "");
    return m ? m[1] : null;
  }

  /**
   * The reason the prior round retained this slug's branch (`verification-failed`,
   * `criteria-unmet`, `review-not-run`, `merge-failed`, `close-refused`, ...), or `null`
   * when nothing was retained for it. What tells `runWorker` whether the branch's content
   * needs another worker pass or only another review attempt.
   */
  retentionReason(slug) {
    const r = this.effects.exec(
      "bash",
      [this.effects.script("state.sh"), "retention", "--slug", slug],
      { env: this.childEnv(), mutating: false },
    );
    const m = /^reason:\s*(.+)$/m.exec(r.stdout || "");
    return m ? m[1].trim() : null;
  }

  trace(marker, text = "") {
    return this.effects.bash("trace.sh", [marker, text], { env: this.childEnv() });
  }

}
