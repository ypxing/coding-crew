/**
 * local.mjs — the local markdown issue tracker backend.
 */

import { existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";

import { spliceSection, tickCriteria } from "./body-format.mjs";

export const READY_STATUS = "ready-for-agent";

/** Where every feature's issues and PRD live, relative to the main root. */
const SCRATCH = ".coding-crew/scratch";

/** Local has no PRD issue: the PRD is `.coding-crew/scratch/<slug>/PRD.md`, never a file in `issues/`. */
export const isPrdIssue = () => false;

/** Filename minus leading digits and extension. */
export function issueSlug(file) {
  return basename(file).replace(/\.md$/, "").replace(/^[0-9]+[-_]?/, "");
}

/** The filename's leading digits (`NN-<slug>.md` — see tracker/docs/local.md), or null when absent. */
export function issueNumber(file) {
  return /^([0-9]+)/.exec(basename(file))?.[1] ?? null;
}

/** Every open issue file of feature `featureSlug`, sorted. */
export function listOpenIssueFiles(mainRoot, { featureSlug }) {
  const openDir = join(mainRoot, SCRATCH, featureSlug, "issues", "open");
  if (!existsSync(openDir)) return [];
  return readdirSync(openDir)
    .filter((f) => f.endsWith(".md"))
    .sort()
    .map((f) => join(openDir, f));
}

export function issueDepsPath(issuePath) {
  return join(dirname(dirname(issuePath)), "issues-deps.json");
}

/**
 * `issues-deps.json`, which `publish-issues` and `rewrite` write: the only source of a local issue's blockers.
 * Null when absent or unparseable.
 */
export function readIssueDeps(issuePath) {
  const path = issueDepsPath(issuePath);
  if (!existsSync(path)) return null;
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return null;
  }
}

export function parseIssue(path, text = readFileSync(path, "utf8")) {
  const statusMatch = /^\s*(?:[-*]\s*)?(?:\*\*)?Status(?:\*\*)?:\s*(?:`)?([a-z-]+)/im.exec(text);
  const titleMatch = /^#\s+(.*)$/m.exec(text);
  const deps = readIssueDeps(path);
  const file = basename(path);
  const blockedBy = deps && Object.prototype.hasOwnProperty.call(deps, file) ? deps[file] : [];
  return {
    path,
    file,
    slug: issueSlug(path),
    number: issueNumber(path),
    title: titleMatch ? titleMatch[1].trim() : issueSlug(path),
    status: statusMatch ? statusMatch[1] : "",
    blockedBy,
    text,
  };
}

/** Every issue of one feature, in every state; a file in `done/` is `done` whatever its text says. */
export function listFeatureIssues(mainRoot, { featureSlug } = {}) {
  const dir = join(mainRoot, SCRATCH, featureSlug, "issues");
  const files = (state) => {
    const d = join(dir, state);
    if (!existsSync(d)) return [];
    return readdirSync(d)
      .filter((f) => f.endsWith(".md"))
      .sort()
      .map((f) => join(d, f));
  };
  return [
    ...files("open").map((p) => parseIssue(p)),
    ...files("done").map((p) => ({ ...parseIssue(p), status: "done" })),
  ];
}

/** Every feature: each `.coding-crew/scratch/<slug>/` with an `issues/` subdirectory, sorted by slug, with the
 * count of issues dispatch would start now. */
export function listFeatures(mainRoot) {
  const scratch = join(mainRoot, SCRATCH);
  if (!existsSync(scratch)) return [];
  const out = [];
  for (const entry of readdirSync(scratch, { withFileTypes: true })) {
    if (!entry.isDirectory() || !existsSync(join(scratch, entry.name, "issues"))) continue;
    const open = listOpenIssueFiles(mainRoot, { featureSlug: entry.name });
    const ready = selectDispatchable(mainRoot, { featureSlug: entry.name }).length;
    out.push({ slug: entry.name, state: open.length ? "open" : "closed", ready });
  }
  return out.sort((a, b) => (a.slug < b.slug ? -1 : a.slug > b.slug ? 1 : 0));
}

export function doneFiles(issuePath) {
  const done = join(dirname(dirname(issuePath)), "done");
  return existsSync(done) ? new Set(readdirSync(done)) : new Set();
}

export function blockers(issue, done = doneFiles(issue.path)) {
  return issue.blockedBy.filter((f) => !done.has(f));
}

/** Feature `featureSlug`'s ready and unblocked issues, in filename order. */
export function selectDispatchable(mainRoot, { featureSlug }) {
  const issues = listOpenIssueFiles(mainRoot, { featureSlug }).map((p) => parseIssue(p));
  return issues
    .filter((i) => i.status === READY_STATUS)
    .map((i) => ({ ...i, blockers: blockers(i) }))
    .filter((i) => i.blockers.length === 0);
}

/**
 * The CLI ref for `issue`: its absolute path in the main checkout. Absolute, so an agent in a worktree,
 * where the gitignored `.coding-crew/scratch/` is absent, finds the file it names rather than a copy elsewhere.
 */
export const issueRef = (mainRoot, issue) => resolve(mainRoot, issue.path);

export function writeIssueSection(path, heading, body) {
  const next = spliceSection(readFileSync(path, "utf8"), heading, body);
  writeFileSync(path, next);
  return next;
}

/** `p` with every symlink resolved, as far as it exists; the missing tail is appended as written. */
function realpathAsFarAsExists(p) {
  let head = p;
  const tail = [];
  while (!existsSync(head)) {
    const up = dirname(head);
    if (up === head) return p;
    tail.unshift(basename(head));
    head = up;
  }
  return join(realpathSync(head), ...tail);
}

/**
 * The absolute issue path a CLI ref names, or null unless it sits under the main root's `.coding-crew/scratch/`
 * with symlinks resolved. A relative ref resolves against `cwd` when that names a file, else the
 * main root: a worker in a worktree names `.coding-crew/scratch/…` paths that live only in the main checkout.
 */
export function validateRef(mainRoot, ref, { cwd = process.cwd() } = {}) {
  if (!ref) return null;
  const candidates = isAbsolute(ref) ? [ref] : [resolve(cwd, ref), resolve(mainRoot, ref)];
  const path = candidates.find((c) => existsSync(c)) ?? candidates.at(-1);
  const scratch = realpathAsFarAsExists(resolve(mainRoot, SCRATCH));
  const real = realpathAsFarAsExists(path);
  const rel = relative(scratch, real);
  if (!rel || rel === ".." || rel.startsWith(`..${sep}`) || isAbsolute(rel)) return null;
  return real;
}

/** `{title, body}` for the issue file at `path`, or null; no `# <title>` line means its slug is the title. */
export function fetchIssue(mainRoot, path) {
  if (!existsSync(path) || !statSync(path).isFile()) return null;
  const issue = parseIssue(path);
  const body = issue.text.replace(/^#[ \t]+.*(?:\r?\n|$)(?:[ \t]*\r?\n)*/m, "");
  return { title: issue.title, body };
}

/** The status of the issue at `path`, `done` once it is in `done/`, found there by its `open/` path too; null for neither. */
export function issueStatus(mainRoot, path) {
  const target = doneTarget(mainRoot, path);
  if (target.alreadyDone) return "done";
  return target.missing ? null : parseIssue(path).status;
}

/** The feature's PRD, `.coding-crew/scratch/<slug>/PRD.md`, or null when there is none. */
export function readPrd(mainRoot, { featureSlug } = {}) {
  const path = join(mainRoot, SCRATCH, featureSlug, "PRD.md");
  return existsSync(path) ? readFileSync(path, "utf8") : null;
}

/** The file `known` writes for one issue: the issue file itself, under its own name. */
export function knownFile(issue) {
  return { name: issue.file, text: issue.text };
}

function stateFiles(mainRoot, featureSlug, state) {
  const d = join(mainRoot, SCRATCH, featureSlug, "issues", state);
  return existsSync(d) ? readdirSync(d).filter((f) => f.endsWith(".md")).sort() : [];
}

/**
 * `publish-issues`' re-run rule: a feature with done issues is not re-published over (exit 4), and
 * open issues are only overwritten with `--replace` (exit 5), never one a draft's `## Blocked by`
 * names, which would leave that draft blocked for good (exit 1). Null when publishing may go ahead.
 */
export function publishGuard(mainRoot, { featureSlug, replace = false, blockers = [] } = {}) {
  const issues = `${SCRATCH}/${featureSlug}/issues`;
  if (stateFiles(mainRoot, featureSlug, "done").length) {
    return {
      code: 4,
      message: `publish-issues: ${issues}/done/ has issues — some are already completed. Reconcile by hand (delete or archive ${issues}/) before re-running.`,
    };
  }
  const open = stateFiles(mainRoot, featureSlug, "open");
  const deleted = replace ? blockers.filter((b) => open.includes(b)) : [];
  if (deleted.length) {
    return {
      code: 1,
      message: `publish-issues: a draft's ## Blocked by names ${deleted.join(", ")} in ${issues}/open/, which --replace deletes. Point it at the draft that replaces it, or drop the edge, then re-run. Nothing was published.`,
    };
  }
  if (open.length && !replace) {
    return {
      code: 5,
      message: `publish-issues: ${issues}/open/ already has issues, which publishing would overwrite: ${open.join(", ")}. Pass --replace to overwrite them.`,
    };
  }
  return null;
}

/**
 * `.coding-crew/scratch/.gitignore` holding `*`, unless one exists: issue files are never meant to be committed,
 * and a consuming repo's own .gitignore need not know about `.coding-crew/scratch/` for its tree to stay clean.
 */
function ignoreScratch(mainRoot) {
  const scratch = join(mainRoot, SCRATCH);
  mkdirSync(scratch, { recursive: true });
  const path = join(scratch, ".gitignore");
  if (!existsSync(path)) writeFileSync(path, "*\n");
}

/**
 * `publish-issues`' local side: drafts numbered from one past the feature's highest issue number. With
 * `append`, the feature's `issues-deps.json` keeps its entries and gains the drafts'.
 */
export function beginPublish(mainRoot, { featureSlug, drafts, replace = false, append = false } = {}) {
  const issues = join(mainRoot, SCRATCH, featureSlug, "issues");
  const openDir = join(issues, "open");
  const existing = [...stateFiles(mainRoot, featureSlug, "open"), ...stateFiles(mainRoot, featureSlug, "done")];
  const base = Math.max(0, ...existing.map((f) => Number(issueNumber(f) ?? 0)));
  const ordered = [...drafts].sort((a, b) => a.localeCompare(b, "en", { numeric: true }));
  const width = Math.max(2, String(base + ordered.length).length);
  const names = new Map(ordered.map((f, i) => [f, `${String(base + i + 1).padStart(width, "0")}-${f.replace(/^[0-9]+-/, "")}`]));
  if (replace) for (const f of stateFiles(mainRoot, featureSlug, "open")) rmSync(join(openDir, f));
  ignoreScratch(mainRoot);
  mkdirSync(openDir, { recursive: true });
  return {
    create(draft) {
      const name = names.get(draft.file);
      const path = join(openDir, name);
      writeFileSync(path, draft.text);
      return { ref: path, blockerRef: name };
    },
    finish({ deps }) {
      const path = join(issues, "issues-deps.json");
      const kept = append && existsSync(path) ? JSON.parse(readFileSync(path, "utf8")) : {};
      writeFileSync(path, `${JSON.stringify({ ...kept, ...deps }, null, 2)}\n`);
    },
  };
}

/** Write the feature's PRD to `.coding-crew/scratch/<slug>/PRD.md` (the title is the body's own heading); returns that path. */
export function publishPrd(mainRoot, { featureSlug, body } = {}) {
  const path = join(mainRoot, SCRATCH, featureSlug, "PRD.md");
  ignoreScratch(mainRoot);
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, body);
  return path;
}

/** `text` with its `Status:` line set to `status`: the first one replaced, else one added under the title (or on top). */
function withStatus(text, status) {
  if (/^Status:.*$/m.test(text)) return text.replace(/^Status:.*$/m, `Status: ${status}`);
  const title = /^#[ \t]+.*(?:\r?\n|$)/.exec(text);
  if (title) return `${title[0].replace(/\r?\n?$/, "\n")}\nStatus: ${status}\n\n${text.slice(title[0].length).replace(/^(?:[ \t]*\r?\n)+/, "")}`;
  return `Status: ${status}\n\n${text}`;
}

/**
 * Rewrite a single-slice source issue in place with its `Status:` set, and its `issues-deps.json`
 * entry set to `blockers` (the files its `## Blocked by` names); null when there is no file.
 */
export function rewriteIssue(mainRoot, path, { body, status, blockers = [] } = {}) {
  if (!existsSync(path) || !statSync(path).isFile()) return null;
  ignoreScratch(mainRoot);
  writeFileSync(path, withStatus(body, status));
  const deps = { ...readIssueDeps(path), [basename(path)]: blockers };
  writeFileSync(issueDepsPath(path), `${JSON.stringify(deps, null, 2)}\n`);
  return true;
}

/** Every criterion in the file at `path` ticked; the count, or null when there is no such file. */
export function tickIssue(mainRoot, path) {
  if (!existsSync(path) || !statSync(path).isFile()) return null;
  const { text, ticked } = tickCriteria(readFileSync(path, "utf8"));
  if (ticked) {
    ignoreScratch(mainRoot);
    writeFileSync(path, text);
  }
  return ticked;
}

/** `## <heading>` written into the file at `path`, replacing one already there; null when there is no such file. */
export function writeSection(mainRoot, path, { heading, body } = {}) {
  if (!existsSync(path) || !statSync(path).isFile()) return null;
  ignoreScratch(mainRoot);
  writeIssueSection(path, heading, body);
  return true;
}

/** What `mark-done` closes at `path`: its name, and whether it is already done or missing. */
export function doneTarget(mainRoot, path) {
  const name = basename(path);
  const stateDir = dirname(path);
  const doneDir = join(dirname(stateDir), "done");
  if (basename(stateDir) === "done" && existsSync(path)) return { name, alreadyDone: `${name} already closed (${path})`, donePath: path };
  if (!existsSync(path)) {
    const done = join(doneDir, name);
    return existsSync(done) ? { name, alreadyDone: `${name} already closed (${done})`, donePath: done } : { name, missing: true };
  }
  return { name };
}

/** A file already in done/ (moved by hand, or a re-run): its `Status:` made `done` in place, nothing else touched. */
export function reconcileDone(mainRoot, donePath) {
  const text = readFileSync(donePath, "utf8");
  const next = text.replace(/^Status: *.*$/gm, "Status: done");
  if (next === text) return;
  ignoreScratch(mainRoot);
  writeFileSync(donePath, next);
}

export function readIssueBody(mainRoot, path) {
  return readFileSync(path, "utf8");
}

/** Close the issue file: every `Status:` line becomes `Status: done`, then it moves to the sibling `done/`. */
export function markDone(mainRoot, path) {
  const doneDir = join(dirname(dirname(path)), "done");
  const dest = join(doneDir, basename(path));
  ignoreScratch(mainRoot);
  writeFileSync(path, readFileSync(path, "utf8").replace(/^Status: *.*$/gm, "Status: done"));
  mkdirSync(doneDir, { recursive: true });
  renameSync(path, dest);
  return `DONE: ${basename(path)} → ${dest}`;
}

/**
 * Undo markDone: every `Status:` line becomes `ready-for-agent`, and a file in `done/` moves back to the sibling
 * `open/`. `path` may name either copy. Null when neither exists.
 */
export function reopenIssue(mainRoot, path) {
  const name = basename(path);
  const featureIssues = dirname(dirname(path));
  const open = join(featureIssues, "open", name);
  const done = join(featureIssues, "done", name);
  const from = existsSync(done) ? done : existsSync(open) ? open : null;
  if (!from) return null;
  writeFileSync(from, readFileSync(from, "utf8").replace(/^Status: *.*$/gm, `Status: ${READY_STATUS}`));
  if (from === done) {
    mkdirSync(dirname(open), { recursive: true });
    renameSync(done, open);
  }
  return `REOPENED: ${name} → ${open}`;
}
