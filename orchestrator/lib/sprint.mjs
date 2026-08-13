/**
 * sprint.mjs — sprint.env and sprint-state.json, read through the scripts that own them.
 *
 * The slug is derived exactly once, by session-init.sh, where the issues were found.
 * Nothing here re-derives it: no branch-name parsing, and above all no
 * `ls .scratch/*​/sprint-state.json | head -1` glob, which picks the
 * alphabetically-first feature and silently points a whole sprint at the wrong dir.
 */

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

import { depsLine } from "./report.mjs";

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

    // Deps, once, serially, against the main root — before any worker or worktree exists.
    // N parallel workers provisioning N fresh worktrees would otherwise be N cold
    // downloads of the same packages; this warms whatever cache the package manager keeps
    // so the per-worktree installs are local copies. Advisory: the outcome is logged and
    // never acted on, because the gate that can act on it is verify-worktree.sh.
    if (deps) {
      const d = effects.bash("ensure-deps.sh", ["--dir", effects.mainRoot], {
        env: sprint.childEnv(),
      });
      const line = depsLine(d.stdout);
      if (line) log(line);
    }
    return sprint;
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
    return rest;
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

  trace(marker, text = "") {
    return this.effects.bash("trace.sh", [marker, text], { env: this.childEnv() });
  }
}
