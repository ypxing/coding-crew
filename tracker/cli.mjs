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
 *   publish-issues --feature-slug S --drafts DIR [--replace]
 *                                       create the drafts in dependency order; one "<draft> <ref>" line each
 *   publish-prd --feature-slug S --title T --body-file F
 *                                       create or update the feature's PRD; prints its ref
 *   rewrite <ref> --body-file F --status ST --feature-slug S
 *                                       replace a single-slice source issue's body and set its status
 *   mark-done <ref> [--force]           mark an issue done, behind the two close guards
 *
 * Each op dispatches through `getTracker(mainRoot)` to the configured backend, so a new tracker is
 * one backend module; a backend's own extra ops (`cliOps`, e.g. github's `create-issue`) are
 * reachable here too. The main root is `--main-root`, else the main checkout of the git repo the
 * cwd is in (a linked worktree's too), else the cwd.
 *
 * Exit codes, every op: 0 ok, 1 the op failed (stderr carries the tool's own error, verbatim),
 * 2 usage or an invalid ref, 3 not found. `publish-issues` adds 4 (local: the feature has done issues) and
 * 5 (local: open issues exist and `--replace` is absent). `mark-done`'s 3 is "an orchestrator owns
 * the close" and its 4 "a criterion is unchecked"; an issue that does not exist is 1 there.
 *
 * Refs are data from user arguments: a backend's `validateRef` accepts only what it may read
 * (local: a path under the main root's `.scratch/`, symlinks resolved; github: all digits), and
 * anything else exits 2 before any file read or `gh` call.
 */

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { uncheckedCriteria } from "./body-format.mjs";
import { getTracker } from "./index.mjs";

export const EXIT = { OK: 0, FAILED: 1, USAGE: 2, NOT_FOUND: 3, DONE_EXIST: 4, OPEN_EXIST: 5, ORCHESTRATED: 3, UNCHECKED: 4 };

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
  "publish-issues": "publish-issues --feature-slug S --drafts DIR [--replace]",
  "publish-prd": "publish-prd --feature-slug S --title T --body-file F",
  rewrite: "rewrite <ref> --body-file F --status ST --feature-slug S",
  "mark-done": "mark-done <ref> [--force]",
};

/** A draft's filename: `NN-<slug>.md`. */
const DRAFT_NAME = /^[0-9]+-[A-Za-z0-9][\w.-]*\.md$/;

/** A status is a label name on github and a `Status:` value locally: one kebab-case word. */
const STATUS = /^[a-z][a-z0-9-]*$/;

/** A file argument's text; a missing file is a usage error. */
function readArgFile(op, cwd, path) {
  const abs = resolve(cwd, path);
  if (!existsSync(abs) || !statSync(abs).isFile()) throw new UsageError(`${op}: no such file: ${path}`);
  return readFileSync(abs, "utf8");
}

/** `{file, title, status, text}` for one draft, which opens with `# <title>` and `Status: <status>`. */
function parseDraft(file, text) {
  const title = /^#[ \t]+(\S.*?)[ \t]*$/m.exec(text)?.[1];
  const status = /^Status:[ \t]*(\S+)[ \t]*$/m.exec(text)?.[1];
  if (!title) throw new Error(`publish-issues: ${file} has no '# <title>' line`);
  if (!status || !STATUS.test(status)) throw new Error(`publish-issues: ${file} has no 'Status: <status>' line`);
  return { file, title, status, text };
}

/**
 * The drafts in `dir` and the order to create them in: every blocker before its dependents, else
 * filename order. A missing directory or `deps.json` is a usage error; a malformed draft, an edge
 * naming a draft that is not there, or a cycle fails the op — all before anything is created.
 */
function readDrafts(dir) {
  if (!existsSync(dir) || !statSync(dir).isDirectory()) throw new UsageError(`publish-issues: no drafts directory: ${dir}`);
  const depsPath = join(dir, "deps.json");
  if (!existsSync(depsPath)) throw new UsageError(`publish-issues: no deps.json in ${dir}`);
  let deps;
  try {
    deps = JSON.parse(readFileSync(depsPath, "utf8"));
  } catch (e) {
    throw new Error(`publish-issues: deps.json is not JSON: ${e.message}`);
  }
  if (!deps || typeof deps !== "object" || Array.isArray(deps)) {
    throw new Error("publish-issues: deps.json must map a draft filename to its blocker filenames");
  }
  const names = readdirSync(dir)
    .filter((f) => DRAFT_NAME.test(f))
    .sort((a, b) => a.localeCompare(b, "en", { numeric: true }));
  const drafts = new Map(names.map((f) => [f, parseDraft(f, readFileSync(join(dir, f), "utf8"))]));
  const blockersOf = new Map(names.map((f) => [f, []]));
  for (const [file, blockers] of Object.entries(deps)) {
    if (!drafts.has(file)) throw new Error(`publish-issues: deps.json names ${file}, which is not a draft in ${dir}`);
    for (const b of [].concat(blockers)) {
      if (!drafts.has(b)) throw new Error(`publish-issues: deps.json: ${file} is blocked by ${b}, which is not a draft in ${dir}`);
      blockersOf.get(file).push(b);
    }
  }
  const order = [];
  const placed = new Set();
  while (order.length < names.length) {
    const next = names.find((f) => !placed.has(f) && blockersOf.get(f).every((b) => placed.has(b)));
    if (!next) {
      const left = names.filter((f) => !placed.has(f));
      throw new Error(`publish-issues: deps.json has a cycle among: ${left.join(", ")}`);
    }
    placed.add(next);
    order.push(next);
  }
  return { drafts, blockersOf, order };
}

/**
 * `text` with every draft filename under `## Blocked by` replaced by the ref its issue was created
 * under (`refs`: draft filename → that backend's blocker ref). Nothing outside the section changes.
 */
function rewriteBlockedBy(text, refs) {
  const heading = /^#{1,6}[ \t]+Blocked by[ \t]*$/im.exec(text);
  if (!heading) return text;
  const start = heading.index + heading[0].length;
  const lines = text.slice(start).split("\n");
  let end = lines.findIndex((l, i) => i > 0 && /^#{1,6}[ \t]+/.test(l));
  if (end === -1) end = lines.length;
  const section = lines.slice(0, end).join("\n").replace(/(?<![\w.-])([0-9]+-[A-Za-z0-9][\w.-]*\.md)(?![\w.-])/g, (m) =>
    refs.has(m) ? refs.get(m) : m,
  );
  return text.slice(0, start) + [section, ...lines.slice(end)].join("\n");
}

/** Why an orchestrator owns this close, or null: `CREW_ORCHESTRATED`, or the sprint's `.orchestrated` marker. */
function orchestratedReason(env, mainRoot, sprintDir) {
  const dir = sprintDir ?? env.SPRINT_DIR ?? (env.FEATURE_SLUG ? join(mainRoot, ".scratch", env.FEATURE_SLUG) : null);
  if (dir && existsSync(join(dir, ".orchestrated"))) return `sprint marker ${join(dir, ".orchestrated")}`;
  if (/^(1|true|yes)$/.test(env.CREW_ORCHESTRATED ?? "")) return `CREW_ORCHESTRATED=${env.CREW_ORCHESTRATED}`;
  return null;
}

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

  async "publish-issues"(argv, { tracker, mainRoot, exec, cwd, out, err }) {
    const args = parseArgs("publish-issues", argv, { values: ["feature-slug", "drafts"], flags: ["replace"] });
    const featureSlug = args["feature-slug"];
    const dir = resolve(cwd, args.drafts);
    const { drafts, blockersOf, order } = readDrafts(dir);
    const refused = tracker.publishGuard?.(mainRoot, { featureSlug, replace: Boolean(args.replace) });
    if (refused) {
      err(`${refused.message}\n`);
      return refused.code;
    }
    const publisher = tracker.beginPublish(mainRoot, { featureSlug, drafts: order, replace: Boolean(args.replace), exec });
    const refs = new Map();
    const created = [];
    for (const file of order) {
      const draft = drafts.get(file);
      let made;
      try {
        made = publisher.create({ ...draft, text: rewriteBlockedBy(draft.text, refs) });
      } catch (e) {
        err(`${e.message}\n`);
        err(`publish-issues: stopped at ${file}; created before it: ${created.length ? created.join(", ") : "none"}. The drafts are left in ${dir}.\n`);
        return EXIT.FAILED;
      }
      refs.set(file, made.blockerRef);
      created.push(`${file} ${made.ref}`);
      out(`${file} ${made.ref}\n`);
    }
    publisher.finish?.({
      deps: Object.fromEntries(order.filter((f) => blockersOf.get(f).length).map((f) => [refs.get(f), blockersOf.get(f).map((b) => refs.get(b))])),
    });
    rmSync(dir, { recursive: true, force: true });
    return EXIT.OK;
  },

  async "publish-prd"(argv, { tracker, mainRoot, exec, cwd, out, err }) {
    const args = parseArgs("publish-prd", argv, { values: ["feature-slug", "title", "body-file"] });
    const body = readArgFile("publish-prd", cwd, args["body-file"]);
    const ref = tracker.publishPrd(mainRoot, { featureSlug: args["feature-slug"], title: args.title, body, exec, warn: (m) => err(`${m}\n`) });
    out(`${ref}\n`);
    return EXIT.OK;
  },

  async rewrite(argv, { tracker, mainRoot, exec, cwd, out }) {
    const args = parseArgs("rewrite", argv, { positionals: 1, values: ["body-file", "status", "feature-slug"] });
    if (!STATUS.test(args.status)) throw new UsageError(`rewrite: invalid --status: ${args.status}`);
    const ref = tracker.validateRef(mainRoot, args._[0], { cwd });
    if (ref === null) throw new UsageError(`rewrite: invalid ref: ${args._[0]}`);
    const body = readArgFile("rewrite", cwd, args["body-file"]);
    const done = tracker.rewriteIssue(mainRoot, ref, { body, status: args.status, featureSlug: args["feature-slug"], exec });
    if (!done) return EXIT.NOT_FOUND;
    out(`${ref}\n`);
    return EXIT.OK;
  },

  /**
   * The two close guards, once for every backend — an orchestrator owns the close (exit 3); a
   * criterion is still unchecked in a fresh read (exit 4) — then the backend's own done write.
   * `--force` skips both: a crashed sprint's stale marker, or a criterion descoped on purpose.
   */
  async "mark-done"(argv, { tracker, mainRoot, exec, cwd, out, err, env }) {
    const args = parseArgs("mark-done", argv, { positionals: 1, flags: ["force"] });
    const ref = tracker.validateRef(mainRoot, args._[0], { cwd });
    if (ref === null) throw new UsageError(`mark-done: invalid ref: ${args._[0]}`);
    const target = tracker.doneTarget(mainRoot, ref);
    if (target.alreadyDone) {
      out(`DONE: ${target.alreadyDone}\n`);
      return EXIT.OK;
    }
    if (target.missing) {
      err(`ERROR: issue file not found: ${args._[0]}\n`);
      return EXIT.FAILED;
    }
    if (!args.force) {
      const reason = orchestratedReason(env, mainRoot, target.sprintDir);
      if (reason) {
        err(
          `REFUSED: ${target.name} is orchestrated (${reason}) — the orchestrator closes it.\n` +
            "  It closes only after independent check verification, acceptance-criteria\n" +
            "  verification and code review pass on your branch. Report your status and stop.\n" +
            "  If no sprint is running: remove the sprint's .orchestrated marker if it exists,\n" +
            "  unset CREW_ORCHESTRATED, or pass --force.\n",
        );
        return EXIT.ORCHESTRATED;
      }
      const unchecked = uncheckedCriteria(tracker.readIssueBody(mainRoot, ref, { exec }));
      if (unchecked.length) {
        err(
          `REFUSED: ${target.name} still has unchecked criteria — not closing it.\n${unchecked.join("\n")}\n` +
            "  Check each one off once the code satisfies it, or record why it is descoped\n" +
            "  under '## Unmet criteria' and re-run with --force.\n",
        );
        return EXIT.UNCHECKED;
      }
    }
    out(`${tracker.markDone(mainRoot, ref, { exec, warn: (m) => err(`${m}\n`) })}\n`);
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
 * `gh` (the backend's `(cmd, args) => {code, stdout, stderr}`), `out`/`err` for the streams, `env`
 * for `process.env`.
 */
export async function run(argv, io = {}) {
  const cwd = io.cwd ?? process.cwd();
  const out = io.out ?? ((s) => process.stdout.write(s));
  const err = io.err ?? ((s) => process.stderr.write(s));
  const env = io.env ?? process.env;
  try {
    const [op, ...raw] = argv;
    if (!op) throw new UsageError(`usage: cli.mjs <op> … — ops: ${Object.keys(OPS).join(", ")}`);
    const taken = takeMainRoot(raw);
    const mainRoot = resolve(cwd, taken.mainRoot ?? defaultMainRoot(cwd));
    const tracker = await getTracker(mainRoot);
    const ctx = { tracker, mainRoot, exec: io.exec, cwd, out, err, env };
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
