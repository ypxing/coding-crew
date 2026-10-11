/**
 * sprint.mjs — sprint.env and sprint-state.json, read through the scripts that own them. The slug
 * is derived once, by session-init.sh, and never re-derived here: a glob would pick the wrong sprint.
 */

import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { pathWithShim } from "./install-dir.mjs";
import { depsLine } from "./report.mjs";

// Handed to every bash() child, so crew-summary.sh and promote-findings.sh never guess an install location.
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
  "CREW_INSTALL_DIR",
  "CREW_FIX_FINDINGS",
];

/** Parse the `export K="v"` lines session-init.sh wrote to `file`. */
export function parseSprintEnv(file) {
  if (!existsSync(file)) return null;
  const env = {};
  for (const m of readFileSync(file, "utf8").matchAll(/^\s*export\s+(\w+)="?([^"\n]*)"?\s*$/gm)) {
    if (ENV_KEYS.includes(m[1])) env[m[1]] = m[2];
  }
  return Object.keys(env).length ? { ...env, sprintEnvFile: file } : null;
}

/** One sprint's env, `.scratch/<slug>/sprint.env`. There is no pointer to "the" sprint: several run in one repo. */
export function readSprintEnv(mainRoot, slug) {
  return slug ? parseSprintEnv(join(mainRoot, ".scratch", slug, "sprint.env")) : null;
}

export class Sprint {
  constructor(effects, env) {
    this.effects = effects;
    this.env = env;
    // In-memory: a persisted count would make "resolve blockers and re-run" refuse to retry.
    this._attempts = new Map();
    // slug -> attempts refunded to a coder that timed out after committing (grantFreeAttempt).
    this._freeAttempts = new Map();
    // slug set: issues whose one deferred-run refund (claimDeferredRefund) is spent.
    this._deferredRefunds = new Set();
    // slug set: issues finishBlocked gave up on this invocation, in-memory for the same reason.
    this._blockedThisRun = new Set();
    // Findings triages that fell back to the `high` rule: [{ scope, reason }], for the summary.
    this.triageFallbacks = [];
    // `<branch>@<commit>` set: what verify-worktree.sh passed this invocation (markVerifiedThisRun).
    this._verifiedThisRun = new Set();
    // slug set: issues whose `## Requires` this invocation already probed (checkRequires).
    this._requiresProbed = new Set();
  }

  /** The branch and slug session-init.sh would use, before anything touches disk. */
  static resolveBranch(effects, { featureSlug, branchPrefix = null, passthrough = [] }) {
    const args = ["--print-branch"];
    if (featureSlug) args.push("--feature-slug", featureSlug);
    if (branchPrefix != null) args.push("--branch-prefix", branchPrefix);
    args.push(...passthrough);
    const r = effects.bash("session-init.sh", args, { mutating: false });
    if (r.code !== 0) throw new Error(`session-init.sh failed (${r.code}): ${(r.stderr || r.stdout || "").trim()}`);
    const out = Object.fromEntries((r.stdout ?? "").split("\n").map((l) => l.split(/=(.*)/s).slice(0, 2)).filter(([k, v]) => k && v != null));
    return { slug: out.FEATURE_SLUG, branch: out.FEATURE_BRANCH, defaultBranch: out.DEFAULT_BRANCH };
  }

  static async init(effects, { featureSlug, fixFindings, branchPrefix = null, passthrough = [], deps = true, log = () => {} }) {
    const args = [];
    if (featureSlug) args.push("--feature-slug", featureSlug);
    if (fixFindings) args.push("--fix-findings", fixFindings);
    // Only when set: "" is a real prefix (none), and unset leaves session-init.sh's default.
    if (branchPrefix != null) args.push("--branch-prefix", branchPrefix);
    args.push(...passthrough);
    const r = effects.bash("session-init.sh", args);
    if (r.code !== 0) {
      throw new Error(`session-init.sh failed (${r.code}): ${r.stderr || r.stdout}`);
    }
    // A run that succeeds can still have been told something worth hearing (`--jira` ignored).
    for (const line of (r.stderr ?? "").split("\n")) if (/^WARNING:/.test(line)) log(`session-init: ${line}`);
    const file = /^SPRINT_ENV: (.+)$/m.exec(r.stdout ?? "")?.[1];
    // A --dry-run session-init.sh prints nothing: the env an earlier run left is the sprint's.
    const env = (file ? parseSprintEnv(file) : null) ?? readSprintEnv(effects.mainRoot, featureSlug);
    if (!env) throw new Error("session-init.sh did not produce a readable sprint.env");
    const sprint = new Sprint(effects, env);

    // main.mjs runs command discovery first, so its cached install override is on disk for ensure-deps.sh.
    if (deps) await sprint.installDeps(log);
    return sprint;
  }

  /**
   * Deps, once, in mainRoot before any worktree exists, warming the package cache for the parallel
   * worktree installs. Streamed, since a cold install is otherwise silent for minutes.
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

  static attach(effects, featureSlug) {
    const env = readSprintEnv(effects.mainRoot, featureSlug);
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
  /** The `.coding-crew/` this run's assets are read from (install-dir.mjs); null on a hand-made sprint.env. */
  get installDir() {
    return this.env.CREW_INSTALL_DIR || null;
  }
  /** What is auto-fixed: "actionable" (triage's verdict) | "critical" | "high" | "medium" (lowest severity) | "none". */
  get fixFindings() {
    return this.env.CREW_FIX_FINDINGS || "actionable";
  }

  childEnv() {
    const { sprintEnvFile, ...rest } = this.env;
    // Only when unset: a caller pinning another review-rollup.mjs is overriding it on purpose.
    const env = { CREW_REVIEW_ROLLUP: REVIEW_ROLLUP_PATH, ...rest };
    if (this.installDir) env.PATH = pathWithShim(this.installDir, rest.PATH ?? process.env.PATH);
    return env;
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
  /** Spent at claim time, so every pass counts toward the retry cap; returns its 1-based number. */
  bumpAttempt(slug) {
    const n = (this._attempts.get(slug) ?? 0) + 1;
    this._attempts.set(slug, n);
    this.state(["attempt", "--slug", slug, "--n", String(n)]);
    return n;
  }

  /** Per issue, not a global count, which would let the first issue claimed exhaust the cap. */
  attemptCount(slug) {
    return this._attempts.get(slug) ?? 0;
  }

  /** Refunds one attempt to `slug` — see finishRetryOrBlock in pipeline/finish.mjs. */
  grantFreeAttempt(slug) {
    this._freeAttempts.set(slug, this.freeAttempts(slug) + 1);
  }

  /** True once per issue per run: the deferred-run refund for a first fixable verify failure. */
  claimDeferredRefund(slug) {
    if (this._deferredRefunds.has(slug)) return false;
    this._deferredRefunds.add(slug);
    return true;
  }

  freeAttempts(slug) {
    return this._freeAttempts.get(slug) ?? 0;
  }

  markBlockedThisRun(slug) {
    this._blockedThisRun.add(slug);
  }

  /** In-memory, so a fresh run gets a fresh attempt budget once a human fixes the blocker. */
  isBlockedThisRun(slug) {
    return this._blockedThisRun.has(slug);
  }

  /** Records `slugs` as probed; returns those that were not yet — see checkRequires. */
  claimRequiresProbe(slugs) {
    const fresh = slugs.filter((s) => !this._requiresProbed.has(s));
    for (const s of fresh) this._requiresProbed.add(s);
    return fresh;
  }

  markVerifiedThisRun(branch, commit) {
    this._verifiedThisRun.add(`${branch}@${commit}`);
  }

  /** Only this invocation's verify counts: a receipt is bound to the commit, not the environment it ran in. */
  verifiedThisRun(branch, commit) {
    return this._verifiedThisRun.has(`${branch}@${commit}`);
  }
  complete(slug, branch) {
    return this.state(["complete", "--slug", slug, "--branch", branch]);
  }
  retain(slug, branch, reason, fingerprint = null) {
    const args = ["retain", "--slug", slug, "--branch", branch, "--reason", reason];
    if (fingerprint) args.push("--fingerprint", fingerprint);
    return this.state(args);
  }
  /** A stale retention (preflight.mjs's dropStaleRetained); `issueGone` also forgets the slug's blocked entries. */
  dropRetained(slug, reason, { issueGone = false } = {}) {
    const args = ["drop-retained", "--slug", slug, "--reason", reason];
    if (issueGone) args.push("--issue-gone");
    return this.state(args);
  }
  blocked(slug, branch, reason, number = null, fingerprint = null) {
    const args = ["blocked", "--slug", slug];
    if (number != null) args.push("--number", String(number));
    if (branch) args.push("--branch", branch);
    if (reason) args.push("--reason", reason);
    if (fingerprint && branch) args.push("--fingerprint", fingerprint);
    return this.state(args);
  }
  coverageGap(slug, categories) {
    return this.state(["coverage-gap", "--slug", slug, "--categories", categories.join(",")]);
  }

  /** A coder-side departure from the procedure (a full-suite run): named in the summary, never a failure. */
  deviation(slug, reason) {
    return this.state(["deviation", "--slug", slug, "--reason", reason]);
  }

  coverageClear(slug) {
    return this.state(["coverage-clear", "--slug", slug]);
  }

  /** Adds a dispatch's cost to the totals, blocked or timed out alike, and files it in the ledger. */
  recordDispatchCost({ costUsd, durationMs, numTurns, sessionId, contextTokens, costUnknown, tokens }, { slug, role, attempt, head } = {}) {
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
    // A cost-unknown dispatch has no session id; its context size is still worth keeping.
    else if (costUnknown) args.push("--context-tokens", String(contextTokens ?? 0));
    if (head) args.push("--head", head);
    // A dispatch killed on timeout has no cost to add; what it spent is its tokens.
    if (costUnknown) args.push("--cost-unknown", "--tokens", String(tokens ?? 0));
    return this.state(args);
  }

  /** Tag every later dispatch-cost entry with this run, so the summary can tell it from earlier runs. */
  startRun(id = new Date().toISOString()) {
    return this.state(["run-start", "--id", id]);
  }

  /** Why this run ended, for the next run's summary; one that never says was killed or crashed. */
  endRun(reason, code) {
    return this.state(["run-end", "--reason", reason, "--code", String(code)]);
  }

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

  /** Why the prior round retained this slug's branch (`verification-failed`, `criteria-unmet`, …), or null. */
  retentionReason(slug) {
    return this.retentionRecord(slug).reason;
  }

  /** The retention record's `reason` and `fingerprint` (the issue's, when it was retained); each `null` when absent. */
  retentionRecord(slug) {
    const r = this.effects.exec(
      "bash",
      [this.effects.script("state.sh"), "retention", "--slug", slug],
      { env: this.childEnv(), mutating: false },
    );
    const reason = /^reason:\s*(.+)$/m.exec(r.stdout || "");
    const fingerprint = /^fingerprint:\s*(\S+)$/m.exec(r.stdout || "");
    return { reason: reason ? reason[1].trim() : null, fingerprint: fingerprint ? fingerprint[1] : null };
  }

  trace(marker, text = "") {
    return this.effects.bash("trace.sh", [marker, text], { env: this.childEnv() });
  }

}
