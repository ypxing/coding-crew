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
  "CREW_COVERAGE",
  "CREW_PROMOTE",
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
    // slug -> {state: "pending"|"used", tabId, paneId} — herdr pane-reuse bookkeeping.
    // In-memory only, never persisted to sprint-state.json: it bounds a herdr coder's pane
    // reuse to exactly one retry per issue for *this* process's run. A crashed/resumed
    // sprint just loses the optimisation (falls back to a fresh pane), never correctness.
    this._herdrReuse = new Map();
  }

  static init(effects, { featureSlug, coverage, promote, passthrough = [], deps = true, log = () => {} }) {
    const args = [];
    if (featureSlug) args.push("--feature-slug", featureSlug);
    if (coverage) args.push("--coverage");
    if (promote) args.push("--promote", promote);
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
    if (deps) sprint.installDeps(log);
    return sprint;
  }

  /**
   * Deps, once, serially, against `effects.mainRoot` — before any worker or worktree
   * exists. N parallel workers provisioning N fresh worktrees would otherwise be N cold
   * downloads of the same packages; this warms whatever cache the package manager keeps
   * so the per-worktree installs are local copies. Advisory: the outcome is logged and
   * never acted on, because the gate that can act on it is verify-worktree.sh.
   *
   * Call this after one-time command discovery (see commands.mjs), not before: discovery
   * may cache a documented install override at `.coding-crew/dev-commands.json`, and
   * `ensure-deps.sh` only reads that cache, it never waits for one to appear.
   */
  installDeps(log = () => {}) {
    const d = this.effects.bash("ensure-deps.sh", ["--dir", this.effects.mainRoot], {
      env: this.childEnv(),
    });
    const line = depsLine(d.stdout);
    if (line) log(line);
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
  get coverage() {
    return this.env.CREW_COVERAGE === "1";
  }
  get promoteThreshold() {
    return this.env.CREW_PROMOTE || "critical";
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
  setRound(n, issues) {
    return this.state(["round", String(n), ...(issues != null ? ["--issues", String(issues)] : [])]);
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

  /** "none" (never offered or already spent) | "pending" (one reuse queued for next round). */
  herdrReuseState(slug) {
    return this._herdrReuse.get(slug)?.state ?? "none";
  }

  /**
   * Queue this slug's just-kept-open pane and worktree for exactly one reuse, next round.
   * worktree rides along only so a queued-but-never-consumed entry can still be cleaned up
   * (see pendingHerdrReuses) — consumeHerdrReusePending itself never hands worktree back,
   * since the caller that spends the reuse already has its own worktree path.
   */
  markHerdrReusePending(slug, { tabId, paneId, name, worktree }) {
    this._herdrReuse.set(slug, { state: "pending", tabId, paneId, name, worktree });
  }

  /**
   * Reads and spends the one queued reuse in the same call — a slug can only ever get this
   * back non-null once. Returns null when nothing was queued (options.herdr was off when
   * the failure happened, the retry already consumed it, or this is a fresh dispatch).
   * `name` rides along so dispatchViaHerdr can target this exact pane's own herdr agent name
   * instead of recomputing one from the *retry's* round number (see herdrDispatchName).
   */
  consumeHerdrReusePending(slug) {
    const entry = this._herdrReuse.get(slug);
    if (!entry || entry.state !== "pending") return null;
    this._herdrReuse.set(slug, { state: "used" });
    return { tabId: entry.tabId, paneId: entry.paneId, name: entry.name };
  }

  /**
   * Every slug whose queued reuse was never consumed — the sprint stopped (max-rounds, an
   * unhandled error, every other issue resolving first) before a next round redispatched it.
   * main.mjs's end-of-run sweep reads this once to close each pane and remove each worktree
   * that would otherwise sit there with nothing left to reuse them.
   */
  pendingHerdrReuses() {
    return [...this._herdrReuse.entries()]
      .filter(([, entry]) => entry.state === "pending")
      .map(([slug, entry]) => ({ slug, tabId: entry.tabId, paneId: entry.paneId, worktree: entry.worktree }));
  }
}
