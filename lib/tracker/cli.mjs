#!/usr/bin/env node
/**
 * cli.mjs — the tracker CLI: the one way a skill touches an issue tracker.
 *   node <skill-dir>/../coding-crew-lib/scripts/tracker/cli.mjs <op> … [--main-root DIR]   (ops and their usage: USAGE below)
 * Each op dispatches to the configured backend. Exit codes are EXIT below. A ref is user data:
 * the backend's `validateRef` rejects anything it may not read (exit 2) before any file read or `gh` call.
 */

import { existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from "node:fs";
import { basename, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { hasCriteriaSection, uncheckedCriteria } from "./body-format.mjs";
import { getTracker } from "./index.mjs";
import { mainCheckout, readTrackerConfig } from "./tracker-config.mjs";
import { omittedLine } from "./trust.mjs";

export const EXIT = { OK: 0, FAILED: 1, USAGE: 2, NOT_FOUND: 3, UNCHECKED: 4 };

class UsageError extends Error {}

/** A feature slug names a directory under `.coding-crew/scratch/`: one path segment, never `.`/`..`. */
const SLUG = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;

/** Parse `argv` against `spec` (`{positionals, values, flags}`); every value is required unless in `optional`. */
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
  features: "features",
  prd: "prd --feature-slug S",
  next: "next --feature-slug S",
  "closing-refs": "closing-refs --feature-slug S",
  known: "known --feature-slug S --out DIR",
  spec: "spec --feature-slug S",
  "publish-issues": "publish-issues --feature-slug S --drafts DIR [--replace | --append]",
  "publish-prd": "publish-prd --feature-slug S --title T --body-file F",
  rewrite: "rewrite <ref> --body-file F --status ST --feature-slug S",
  "mark-done": "mark-done <ref> [--force]",
  reopen: "reopen <ref>",
  tick: "tick <ref>",
  "write-section": "write-section <ref> --heading H --body-file F",
  config: "config",
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
 * The drafts in `dir`, every blocker before its dependents, else filename order. A malformed draft,
 * an edge to a missing draft, a draft whose `## Blocked by` names other drafts than its deps.json
 * edges, or a cycle fails the op before anything is created.
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
  for (const [file, draft] of drafts) {
    const fromDeps = [...new Set(blockersOf.get(file))].sort();
    const fromProse = draftBlockers(draft.text, drafts).sort();
    if (fromDeps.join("\n") !== fromProse.join("\n")) {
      throw new Error(
        `publish-issues: ${file}: deps.json: [${fromDeps.join(", ")}] differs from ## Blocked by: [${fromProse.join(", ")}] (## Blocked by names a draft by its filename, as \`${file}\`). Nothing was published.`,
      );
    }
  }
  return { drafts, blockersOf, order };
}

/** An issue filename in a `## Blocked by` section: a draft, or a `known` file (`<ref>-<slug>.md`). */
const BLOCKER_FILE = /(?<![\w.-])([0-9]+-[A-Za-z0-9][\w.-]*\.md)(?![\w.-])/g;

/** `text` split around its `## Blocked by` section's body (`{head, section, tail}`), or null when it has none. */
function blockedBySpan(text) {
  const heading = /^#{1,6}[ \t]+Blocked by[ \t]*$/im.exec(text);
  if (!heading) return null;
  const start = heading.index + heading[0].length;
  const lines = text.slice(start).split("\n");
  let end = lines.findIndex((l, i) => i > 0 && /^#{1,6}[ \t]+/.test(l));
  if (end === -1) end = lines.length;
  return { head: text.slice(0, start), section: lines.slice(0, end).join("\n"), tail: lines.slice(end) };
}

/** The issue filenames `text`'s `## Blocked by` names. */
function blockedByFiles(text) {
  const span = blockedBySpan(text);
  return span ? [...span.section.matchAll(BLOCKER_FILE)].map((m) => m[1]) : [];
}

/**
 * The drafts `text`'s `## Blocked by` names by filename. A `known` issue is left out: it appears
 * only in prose, never in deps.json.
 */
function draftBlockers(text, drafts) {
  return [...new Set(blockedByFiles(text).filter((f) => drafts.has(f)))];
}

/**
 * `text` with every draft filename under `## Blocked by` replaced by its created issue's ref, and
 * every `known` filename by `knownRef(name)` when the backend maps it. A draft not created yet is
 * never mapped as a known file.
 */
function rewriteBlockedBy(text, refs, { drafts = new Set(), knownRef = () => null } = {}) {
  const span = blockedBySpan(text);
  if (!span) return text;
  const section = span.section.replace(BLOCKER_FILE, (m) => (refs.has(m) ? refs.get(m) : drafts.has(m) ? m : (knownRef(m) ?? m)));
  return span.head + [section, ...span.tail].join("\n");
}

/**
 * Fail unless every non-draft filename under a draft's `## Blocked by` is an issue of the feature,
 * compared by blocker ref (so a retitled github issue still matches) or else by name: a typo would
 * otherwise become a blocker that never resolves, or under github an unrelated `Issue #<n>`.
 */
function checkExistingBlockers(existing, { tracker, mainRoot, featureSlug, exec, dir }) {
  const key = (name) => tracker.knownBlockerRef?.(name) ?? name;
  const known = new Set(
    tracker
      .listFeatureIssues(mainRoot, { featureSlug, exec })
      .filter((i) => !tracker.isPrdIssue(i))
      .map((i) => key(basename(tracker.knownFile(i).name))),
  );
  const unknown = existing.filter((m) => !known.has(key(m)));
  if (unknown.length) {
    throw new Error(
      `publish-issues: ## Blocked by names ${unknown.join(", ")}, which is neither a draft in ${dir} nor an issue of feature ${featureSlug} (\`known\` lists those). Nothing was published.`,
    );
  }
}

/** The issues `known` writes: neither the PRD issue nor a wontfix one, whose criteria a reader would count as unmet. */
function knownIssues(tracker, mainRoot, featureSlug, exec) {
  return tracker.listFeatureIssues(mainRoot, { featureSlug, exec }).filter((i) => !tracker.isPrdIssue(i) && i.status !== "wontfix");
}

/**
 * One `known` file as a spec section: `### <name> — <title>`, then the file without its first `# <title>` line,
 * every task box a plain bullet (GitHub counts a body's boxes as its open tasks).
 */
function specSection(name, text) {
  const id = name.replace(/\.md$/, "");
  const lines = text.split("\n");
  const at = lines.findIndex((l) => /^#[ \t]+\S/.test(l));
  let title = id;
  if (at !== -1) {
    title = lines[at].replace(/^#[ \t]+/, "").trim();
    lines.splice(at, lines[at + 1]?.trim() === "" ? 2 : 1);
  }
  const body = lines
    .join("\n")
    .replace(/^([ \t]*)[-*] \[[ xX]\] /gm, "$1- ")
    .replace(/^\s*\n/, "")
    .replace(/\s*$/, "\n");
  return `### ${id} — ${title}\n\n${body}`;
}

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
    if (issue.omitted) text += `\n${omittedLine(issue.omitted)}\n`;
    out(text);
    return EXIT.OK;
  },

  async features(argv, { tracker, mainRoot, exec, out, err }) {
    parseArgs("features", argv, {});
    for (const f of tracker.listFeatures(mainRoot, { exec, warn: (m) => err(`${m}\n`) })) out(`${f.slug}\t${f.state}\t${f.ready}\n`);
    return EXIT.OK;
  },

  async prd(argv, { tracker, mainRoot, exec, out }) {
    const args = parseArgs("prd", argv, { values: ["feature-slug"] });
    const text = tracker.readPrd(mainRoot, { featureSlug: args["feature-slug"], exec });
    if (text === null) return EXIT.NOT_FOUND;
    out(text);
    return EXIT.OK;
  },

  /** The ref of the issue an unattended loop runs next: each backend's dispatch rule, lowest first. */
  async next(argv, { tracker, mainRoot, exec, out }) {
    const args = parseArgs("next", argv, { values: ["feature-slug"] });
    const issues = tracker.selectDispatchable(mainRoot, { featureSlug: args["feature-slug"], exec });
    const first = tracker.sortDispatchable ? tracker.sortDispatchable(issues)[0] : issues[0];
    if (!first) return EXIT.NOT_FOUND;
    out(`${tracker.issueRef(mainRoot, first)}\n`);
    return EXIT.OK;
  },

  /** The feature PR's `Closes #n` lines, one per line; a backend without `closingRefs` (local) prints none. */
  async "closing-refs"(argv, { tracker, mainRoot, exec, out }) {
    const args = parseArgs("closing-refs", argv, { values: ["feature-slug"] });
    for (const line of tracker.closingRefs?.(mainRoot, { featureSlug: args["feature-slug"], exec }) ?? []) out(`${line}\n`);
    return EXIT.OK;
  },

  async known(argv, { tracker, mainRoot, exec, cwd }) {
    const args = parseArgs("known", argv, { values: ["feature-slug", "out"] });
    const dir = resolve(cwd, args.out);
    const issues = knownIssues(tracker, mainRoot, args["feature-slug"], exec);
    mkdirSync(dir, { recursive: true });
    for (const issue of issues) {
      const { name, text } = tracker.knownFile(issue);
      writeFileSync(join(dir, basename(name)), text);
    }
    return EXIT.OK;
  },

  /** A feature's spec: `prd`'s output and a blank line when it has one, then each `known` issue, whole, by filename number. */
  async spec(argv, { tracker, mainRoot, exec, out }) {
    if (!argv.includes("--feature-slug")) throw new UsageError(`spec: usage: ${USAGE.spec}`);
    const featureSlug = parseArgs("spec", argv, { values: ["feature-slug"] })["feature-slug"];
    let prd, files;
    try {
      prd = tracker.readPrd(mainRoot, { featureSlug, exec });
      files = knownIssues(tracker, mainRoot, featureSlug, exec).map((i) => tracker.knownFile(i));
    } catch (e) {
      throw new Error(`spec: ${e.message}`);
    }
    const sections = files
      .map(({ name, text }) => ({ name: basename(name), text }))
      .sort((a, b) => a.name.localeCompare(b.name, "en", { numeric: true }))
      .map(({ name, text }) => specSection(name, text));
    const head = prd === null ? [] : [prd.replace(/\n?$/, "\n")];
    out([...head, ...sections].join("\n"));
    return EXIT.OK;
  },

  async "publish-issues"(argv, { tracker, mainRoot, exec, cwd, out, err }) {
    const args = parseArgs("publish-issues", argv, { values: ["feature-slug", "drafts"], flags: ["replace", "append"] });
    if (args.replace && args.append) throw new UsageError(`publish-issues: usage: ${USAGE["publish-issues"]}`);
    const featureSlug = args["feature-slug"];
    const append = Boolean(args.append);
    const dir = resolve(cwd, args.drafts);
    const { drafts, blockersOf, order } = readDrafts(dir);
    const existing = [...new Set([...drafts.values()].flatMap((d) => blockedByFiles(d.text).filter((m) => !drafts.has(m))))];
    const refused = append ? null : tracker.publishGuard?.(mainRoot, { featureSlug, replace: Boolean(args.replace), blockers: existing });
    if (refused) {
      err(`${refused.message}\n`);
      return refused.code;
    }
    if (existing.length) checkExistingBlockers(existing, { tracker, mainRoot, featureSlug, exec, dir });
    const publisher = tracker.beginPublish(mainRoot, { featureSlug, drafts: order, replace: Boolean(args.replace), append, exec });
    const refs = new Map();
    const created = [];
    for (const file of order) {
      const draft = drafts.get(file);
      let made;
      try {
        made = publisher.create({ ...draft, text: rewriteBlockedBy(draft.text, refs, { drafts, knownRef: (m) => tracker.knownBlockerRef?.(m) ?? null }) });
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
      deps: Object.fromEntries(order.map((f) => [refs.get(f), blockersOf.get(f).map((b) => refs.get(b))])),
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
    const body = rewriteBlockedBy(readArgFile("rewrite", cwd, args["body-file"]), new Map(), { knownRef: (m) => tracker.knownBlockerRef?.(m) ?? null });
    const blockers = [...new Set(blockedByFiles(body))];
    const done = tracker.rewriteIssue(mainRoot, ref, { body, status: args.status, featureSlug: args["feature-slug"], blockers, exec });
    if (!done) return EXIT.NOT_FOUND;
    out(`${ref}\n`);
    return EXIT.OK;
  },

  /** Every criterion ticked at once, on either backend: the record `mark-done` checks. */
  async tick(argv, { tracker, mainRoot, exec, cwd, out, err }) {
    const args = parseArgs("tick", argv, { positionals: 1 });
    const ref = tracker.validateRef(mainRoot, args._[0], { cwd });
    if (ref === null) throw new UsageError(`tick: invalid ref: ${args._[0]}`);
    const ticked = tracker.tickIssue(mainRoot, ref, { exec });
    if (ticked === null) {
      err(`ERROR: issue not found: ${args._[0]}\n`);
      return EXIT.NOT_FOUND;
    }
    out(`TICKED: ${tracker.doneTarget(mainRoot, ref).name} — ${ticked} criteria\n`);
    return EXIT.OK;
  },

  /** `## <heading>` recorded on the issue: in its file (local) or as a comment (github). */
  async "write-section"(argv, { tracker, mainRoot, exec, cwd, out, err }) {
    const args = parseArgs("write-section", argv, { positionals: 1, values: ["heading", "body-file"] });
    const heading = args.heading.trim();
    if (!heading || /[\r\n#]/.test(heading)) throw new UsageError(`write-section: invalid --heading: ${args.heading}`);
    const ref = tracker.validateRef(mainRoot, args._[0], { cwd });
    if (ref === null) throw new UsageError(`write-section: invalid ref: ${args._[0]}`);
    const body = readArgFile("write-section", cwd, args["body-file"]);
    if (tracker.writeSection(mainRoot, ref, { heading, body, exec }) === null) {
      err(`ERROR: issue not found: ${args._[0]}\n`);
      return EXIT.NOT_FOUND;
    }
    out(`${ref}\n`);
    return EXIT.OK;
  },

  /**
   * The close guards, for every backend: a fresh read has no criteria section, or a criterion still
   * unchecked (exit 4). `--force` skips them: a descope a person approved.
   */
  async "mark-done"(argv, { tracker, mainRoot, exec, cwd, out, err }) {
    const args = parseArgs("mark-done", argv, { positionals: 1, flags: ["force"] });
    const ref = tracker.validateRef(mainRoot, args._[0], { cwd });
    if (ref === null) throw new UsageError(`mark-done: invalid ref: ${args._[0]}`);
    const target = tracker.doneTarget(mainRoot, ref);
    if (target.alreadyDone) {
      tracker.reconcileDone?.(mainRoot, target.donePath);
      out(`DONE: ${target.alreadyDone}\n`);
      return EXIT.OK;
    }
    if (target.missing) {
      err(`ERROR: issue file not found: ${args._[0]}\n`);
      return EXIT.FAILED;
    }
    if (!args.force) {
      const body = tracker.readIssueBody(mainRoot, ref, { exec });
      if (!hasCriteriaSection(body)) {
        err(
          `REFUSED: ${target.name} has no '## Acceptance criteria' section — not closing it.\n` +
            "  Add the section with one '- [ ]' line per criterion and check each off.\n" +
            "  --force is only for a descope a person approved.\n",
        );
        return EXIT.UNCHECKED;
      }
      const unchecked = uncheckedCriteria(body);
      if (unchecked.length) {
        err(
          `REFUSED: ${target.name} still has unchecked criteria — not closing it.\n${unchecked.join("\n")}\n` +
            "  Check each one off once the code satisfies it; one that is not met stays unchecked.\n" +
            "  --force is only for a descope a person approved.\n",
        );
        return EXIT.UNCHECKED;
      }
    }
    out(`${tracker.markDone(mainRoot, ref, { exec })}\n`);
    return EXIT.OK;
  },

  /** mark-done undone: the issue `ready-for-agent` again, so `next` hands it out; its ticked criteria stay ticked. */
  async reopen(argv, { tracker, mainRoot, exec, cwd, out, err }) {
    const args = parseArgs("reopen", argv, { positionals: 1 });
    const ref = tracker.validateRef(mainRoot, args._[0], { cwd });
    if (ref === null) throw new UsageError(`reopen: invalid ref: ${args._[0]}`);
    const done = tracker.reopenIssue(mainRoot, ref, { exec });
    if (done === null) {
      err(`ERROR: issue not found: ${args._[0]}\n`);
      return EXIT.NOT_FOUND;
    }
    out(`${done}\n`);
    return EXIT.OK;
  },
};

/**
 * The main checkout of the repo `cwd` is in (through a linked worktree too), else `cwd`. A `cwd` outside any repo (a
 * skill's own directory) is refused: read as the project, it has no config, and `local` would answer for it.
 */
function defaultMainRoot(cwd) {
  const root = mainCheckout(cwd);
  if (root === null) throw new UsageError(`not inside a git repository (${cwd}): run from the project's checkout, or pass --main-root <dir>`);
  return root;
}

function takeMainRoot(argv) {
  const i = argv.indexOf("--main-root");
  if (i === -1) return { argv, mainRoot: null };
  if (i + 1 >= argv.length) throw new UsageError("--main-root requires a value");
  return { argv: [...argv.slice(0, i), ...argv.slice(i + 2)], mainRoot: argv[i + 1] };
}

/** Run one op; resolves to its exit code. `io` (`exec`, `out`, `err`) is injectable for tests. */
export async function run(argv, io = {}) {
  const cwd = io.cwd ?? process.cwd();
  const out = io.out ?? ((s) => process.stdout.write(s));
  const err = io.err ?? ((s) => process.stderr.write(s));
  try {
    const [op, ...raw] = argv;
    if (!op) throw new UsageError(`usage: cli.mjs <op> … — ops: ${Object.keys(OPS).join(", ")}, config`);
    if (op !== "config" && !Object.hasOwn(OPS, op)) throw new UsageError(`unknown op: ${op} — ops: ${[...Object.keys(OPS), "config"].join(", ")}`);
    const taken = takeMainRoot(raw);
    const mainRoot = resolve(cwd, taken.mainRoot ?? defaultMainRoot(cwd));
    // Before getTracker: it answers which backend, so it needs none loaded.
    if (op === "config") {
      parseArgs("config", taken.argv, {});
      const { tracker, configured } = readTrackerConfig(mainRoot);
      out(`tracker=${tracker}\nconfigured=${configured ? "yes" : "no"}\n`);
      return EXIT.OK;
    }
    const tracker = await getTracker(mainRoot);
    const ctx = { tracker, mainRoot, exec: io.exec, cwd, out, err };
    return await OPS[op](taken.argv, ctx);
  } catch (e) {
    err(`${e.message}\n`);
    return e instanceof UsageError ? EXIT.USAGE : EXIT.FAILED;
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
