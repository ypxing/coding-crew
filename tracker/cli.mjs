#!/usr/bin/env node
/**
 * cli.mjs — the tracker CLI: the one way a skill touches an issue tracker.
 *
 *   node "$(git rev-parse --show-toplevel)/.coding-crew/tracker/cli.mjs" <op> … [--main-root DIR]
 *   (fallback: $HOME/.coding-crew/tracker/cli.mjs)
 *
 *   fetch <ref> [--comments]            "# <title>\n\n<body>" (+ comments)
 *   prd --feature-slug S                the feature's PRD
 *   known --feature-slug S --out DIR    one file per feature issue, open and done, named by its lint ref
 *
 * Each op dispatches through `getTracker(mainRoot)` to the configured backend, so a new tracker is
 * one backend module; a backend's own extra ops (`cliOps`, e.g. github's `create-issue`) are
 * reachable here too. The main root is `--main-root`, else the main checkout of the git repo the
 * cwd is in (a linked worktree's too), else the cwd.
 *
 * Exit codes, every op: 0 ok, 1 the op failed (stderr carries the tool's own error, verbatim),
 * 2 usage or an invalid ref, 3 not found. 4 and 5 are reserved for `publish-issues`.
 *
 * Refs are data from user arguments: a backend's `validateRef` accepts only what it may read
 * (local: a path under the main root's `.scratch/`, symlinks resolved; github: all digits), and
 * anything else exits 2 before any file read or `gh` call.
 */

import { spawnSync } from "node:child_process";
import { mkdirSync, realpathSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { getTracker } from "./index.mjs";

export const EXIT = { OK: 0, FAILED: 1, USAGE: 2, NOT_FOUND: 3 };

class UsageError extends Error {}

/** A feature slug names a directory under `.scratch/`: one path segment, never `.`/`..`. */
const SLUG = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;

/**
 * Parse `argv` against `spec` (`{positionals, values, flags}`): exactly `positionals` bare
 * arguments, `--name value` for each of `values`, bare `--name` for each of `flags`. Every
 * value is required unless listed in `optional`.
 */
function parseArgs(op, argv, { positionals = 0, values = [], flags = [], optional = [] }) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith("--")) {
      const name = a.slice(2);
      if (flags.includes(name)) out[name] = true;
      else if (values.includes(name)) {
        if (i + 1 >= argv.length) throw new UsageError(`${op}: --${name} requires a value`);
        out[name] = argv[++i];
      } else throw new UsageError(`${op}: unknown argument: ${a}`);
    } else out._.push(a);
  }
  if (out._.length !== positionals) throw new UsageError(`${op}: usage: ${USAGE[op]}`);
  for (const name of values) {
    if (!optional.includes(name) && out[name] === undefined) throw new UsageError(`${op}: requires --${name}`);
  }
  if (out["feature-slug"] !== undefined && !SLUG.test(out["feature-slug"])) {
    throw new UsageError(`${op}: invalid --feature-slug: ${out["feature-slug"]}`);
  }
  return out;
}

const USAGE = {
  fetch: "fetch <ref> [--comments]",
  prd: "prd --feature-slug S",
  known: "known --feature-slug S --out DIR",
};

/** The read ops every backend has. Each returns an exit code. */
const OPS = {
  async fetch(argv, { tracker, mainRoot, exec, cwd, out }) {
    const args = parseArgs("fetch", argv, { positionals: 1, flags: ["comments"] });
    const ref = tracker.validateRef(mainRoot, args._[0], { cwd });
    if (ref === null) throw new UsageError(`fetch: invalid ref: ${args._[0]}`);
    const issue = tracker.fetchIssue(mainRoot, ref, { comments: Boolean(args.comments), exec });
    if (!issue) return EXIT.NOT_FOUND;
    let text = `# ${issue.title}\n\n${issue.body.replace(/\n*$/, "\n")}`;
    if (issue.comments?.length) {
      text += "\n## Comments\n";
      for (const c of issue.comments) text += `\n### @${c.author} — ${c.createdAt}\n\n${c.body.replace(/\n*$/, "\n")}`;
    }
    out(text);
    return EXIT.OK;
  },

  async prd(argv, { tracker, mainRoot, exec, out }) {
    const args = parseArgs("prd", argv, { values: ["feature-slug"] });
    const text = tracker.readPrd(mainRoot, { featureSlug: args["feature-slug"], exec });
    if (text === null) return EXIT.NOT_FOUND;
    out(text);
    return EXIT.OK;
  },

  async known(argv, { tracker, mainRoot, exec, cwd }) {
    const args = parseArgs("known", argv, { values: ["feature-slug", "out"] });
    const dir = resolve(cwd, args.out);
    const issues = tracker.listFeatureIssues(mainRoot, { featureSlug: args["feature-slug"], exec });
    mkdirSync(dir, { recursive: true });
    for (const issue of issues.filter((i) => !tracker.isPrdIssue(i))) {
      const { name, text } = tracker.knownFile(issue);
      writeFileSync(join(dir, basename(name)), text);
    }
    return EXIT.OK;
  },
};

/** The main checkout of the repo `cwd` is in (through a linked worktree too), else `cwd`. */
function defaultMainRoot(cwd) {
  const r = spawnSync("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], { cwd, encoding: "utf8" });
  const commonDir = r.status === 0 ? r.stdout.trim() : "";
  return basename(commonDir) === ".git" ? dirname(commonDir) : cwd;
}

/** Pull `--main-root DIR` out of `argv`, wherever it is. */
function takeMainRoot(argv) {
  const i = argv.indexOf("--main-root");
  if (i === -1) return { argv, mainRoot: null };
  if (i + 1 >= argv.length) throw new UsageError("--main-root requires a value");
  return { argv: [...argv.slice(0, i), ...argv.slice(i + 2)], mainRoot: argv[i + 1] };
}

/**
 * Run one op; resolves to its exit code. `io` is injectable for tests: `exec` stands in for
 * `gh` (the backend's `(cmd, args) => {code, stdout, stderr}`), `out`/`err` for the streams.
 */
export async function run(argv, io = {}) {
  const cwd = io.cwd ?? process.cwd();
  const out = io.out ?? ((s) => process.stdout.write(s));
  const err = io.err ?? ((s) => process.stderr.write(s));
  try {
    const [op, ...raw] = argv;
    if (!op) throw new UsageError(`usage: cli.mjs <op> … — ops: ${Object.keys(OPS).join(", ")}`);
    const taken = takeMainRoot(raw);
    const mainRoot = resolve(cwd, taken.mainRoot ?? defaultMainRoot(cwd));
    const tracker = await getTracker(mainRoot);
    const ctx = { tracker, mainRoot, exec: io.exec, cwd, out, err };
    if (Object.hasOwn(OPS, op)) return await OPS[op](taken.argv, ctx);
    if (tracker.cliOps && Object.hasOwn(tracker.cliOps, op)) {
      await tracker.cliOps[op]([...taken.argv, "--main-root", mainRoot], ctx);
      return EXIT.OK;
    }
    throw new UsageError(`unknown op: ${op} — ops: ${[...Object.keys(OPS), ...Object.keys(tracker.cliOps ?? {})].join(", ")}`);
  } catch (e) {
    err(`${e.message}\n`);
    return e instanceof UsageError || e.usage ? EXIT.USAGE : EXIT.FAILED;
  }
}

function invokedDirectly() {
  try {
    return Boolean(process.argv[1]) && realpathSync(fileURLToPath(import.meta.url)) === realpathSync(process.argv[1]);
  } catch {
    return false;
  }
}

if (invokedDirectly()) {
  process.exitCode = await run(process.argv.slice(2));
}
