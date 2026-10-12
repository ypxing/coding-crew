/**
 * local.mjs — the local markdown issue tracker backend.
 * The slug derivation must match `issue_slug_of()` in receipts.sh: it ties an acceptance-criteria
 * receipt to one issue rather than to whichever branch was verified last.
 */

import { existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";

import {
  appendToSection,
  criteriaSection,
  extractBlockedByNumbers,
  isSourceGuarded,
  sectionBody,
  spliceSection,
  tickCriteria,
} from "./body-format.mjs";

export const READY_STATUS = "ready-for-agent";
export const PARKED_STATUS = "deferred-findings";

/** A promoted fix issue is written parked (`deferred-findings`) for the loop's flush to make ready. */
export const fixIssuesCreatedReady = false;

/** Local has no PRD issue: the PRD is `.scratch/<slug>/PRD.md`, never a file in `issues/`. */
export const isPrdIssue = () => false;

/** Filename minus leading digits and extension. Mirrors receipts.sh issue_slug_of(). */
export function issueSlug(file) {
  return basename(file).replace(/\.md$/, "").replace(/^[0-9]+[-_]?/, "");
}

/** The filename's leading digits (`NN-<slug>.md` — see tracker/docs/local.md), or null when absent. */
export function issueNumber(file) {
  return /^([0-9]+)/.exec(basename(file))?.[1] ?? null;
}

export function branchFor(featureSlug, slug) {
  return `crew/${featureSlug}/${slug}`;
}

/**
 * Every open issue file, sorted, across every feature under .scratch/ unless `featureSlug` names
 * one. A live sprint must pass its own slug, or a ready issue of another feature is dispatched and
 * merged onto this sprint's branch.
 */
export function listOpenIssueFiles(mainRoot, { featureSlug = null } = {}) {
  const scratch = join(mainRoot, ".scratch");
  if (!existsSync(scratch)) return [];
  if (featureSlug) {
    const openDir = join(scratch, featureSlug, "issues", "open");
    if (!existsSync(openDir)) return [];
    return readdirSync(openDir)
      .filter((f) => f.endsWith(".md"))
      .sort()
      .map((f) => join(openDir, f));
  }
  const out = [];
  for (const feature of readdirSync(scratch, { withFileTypes: true })) {
    if (!feature.isDirectory()) continue;
    const openDir = join(scratch, feature.name, "issues", "open");
    if (!existsSync(openDir)) continue;
    for (const f of readdirSync(openDir).sort()) {
      if (f.endsWith(".md")) out.push(join(openDir, f));
    }
  }
  return out.sort();
}

/**
 * Resolve a `## Blocked by` section's entries to sibling issue filenames: literal `NN-slug.md`
 * names or `Issue NN` refs, whose leading number is the only stable link back to the file.
 */
export function resolveBlockedBy(section, path) {
  const explicit = [...section.matchAll(/([0-9A-Za-z][\w.-]*\.md)/g)].map((m) => m[1]);
  const numbers = extractBlockedByNumbers(section);
  if (numbers.length === 0) return [...new Set(explicit)];
  const dir = dirname(path);
  const siblingDir = join(dirname(dir), basename(dir) === "open" ? "done" : "open");
  const files = [dir, siblingDir].flatMap((d) => (existsSync(d) ? readdirSync(d) : []));
  const resolved = numbers
    .map((n) => files.find((f) => new RegExp(`^0*${n}[-_.]`).test(f)))
    .filter(Boolean);
  return [...new Set([...explicit, ...resolved])];
}

export function issueDepsPath(issuePath) {
  return join(dirname(dirname(issuePath)), "issues-deps.json");
}

/**
 * `issues-deps.json`, if `to-issues` wrote one: exact where `## Blocked by` prose is not. Null when
 * absent or unparseable, so callers fall back to the prose.
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
  const blockedBySection = sectionBody(text, "Blocked by") ?? "";
  const deps = readIssueDeps(path);
  const file = basename(path);
  const jsonBlockedBy = deps && Object.prototype.hasOwnProperty.call(deps, file) ? deps[file] : undefined;
  const blockedBy = jsonBlockedBy ?? resolveBlockedBy(blockedBySection, path);
  const criteria = criteriaSection(text);
  return {
    path,
    file,
    slug: issueSlug(path),
    number: issueNumber(path),
    title: titleMatch ? titleMatch[1].trim() : issueSlug(path),
    status: statusMatch ? statusMatch[1] : "",
    blockedBy,
    criteria,
    sourceGuarded: isSourceGuarded(text),
    hasProgress: sectionBody(text, "Progress") !== null,
    hasBlocked: sectionBody(text, "Blocked") !== null,
    text,
  };
}

/** Every issue of one feature, in every state; a file in `done/` is `done` whatever its text says. */
export function listFeatureIssues(mainRoot, { featureSlug } = {}) {
  const dir = join(mainRoot, ".scratch", featureSlug, "issues");
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

/** Every feature: each `.scratch/<slug>/` with an `issues/` subdirectory, sorted by slug. */
export function listFeatures(mainRoot) {
  const scratch = join(mainRoot, ".scratch");
  if (!existsSync(scratch)) return [];
  const out = [];
  for (const entry of readdirSync(scratch, { withFileTypes: true })) {
    if (!entry.isDirectory() || !existsSync(join(scratch, entry.name, "issues"))) continue;
    const open = listOpenIssueFiles(mainRoot, { featureSlug: entry.name });
    const ready = open.filter((p) => parseIssue(p).status === READY_STATUS).length;
    out.push({ slug: entry.name, state: open.length ? "open" : "closed", ready });
  }
  return out.sort((a, b) => (a.slug < b.slug ? -1 : a.slug > b.slug ? 1 : 0));
}

/** The feature's `issues-deps.json` when `to-issues` wrote one, else null. */
export function featureDepsFile(mainRoot, { featureSlug } = {}) {
  const path = join(mainRoot, ".scratch", featureSlug, "issues", "issues-deps.json");
  return existsSync(path) ? path : null;
}

export function doneFiles(issuePath) {
  const done = join(dirname(dirname(issuePath)), "done");
  return existsSync(done) ? new Set(readdirSync(done)) : new Set();
}

export function blockers(issue, done = doneFiles(issue.path)) {
  return issue.blockedBy.filter((f) => !done.has(f));
}

/**
 * Ready and unblocked, in filename order. `includeBlocked` keeps the ready issues still waiting
 * on a blocker: preflight probes their `## Requires` before any dispatch.
 */
export function selectDispatchable(mainRoot, { status = READY_STATUS, featureSlug = null, includeBlocked = false } = {}) {
  const issues = listOpenIssueFiles(mainRoot, { featureSlug }).map((p) => parseIssue(p));
  const ready = issues.filter((i) => i.status === status);
  return ready
    .map((i) => ({ ...i, blockers: blockers(i) }))
    .filter((i) => includeBlocked || i.blockers.length === 0);
}

export function writeIssueSection(path, heading, body, { append = false } = {}) {
  const text = readFileSync(path, "utf8");
  const next = append ? appendToSection(text, heading, body) : spliceSection(text, heading, body);
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
 * The absolute issue path a CLI ref names, or null unless it sits under the main root's `.scratch/`
 * with symlinks resolved. A relative ref resolves against `cwd` when that names a file, else the
 * main root: a worker in a worktree names `.scratch/…` paths that live only in the main checkout.
 */
export function validateRef(mainRoot, ref, { cwd = process.cwd() } = {}) {
  if (!ref) return null;
  const candidates = isAbsolute(ref) ? [ref] : [resolve(cwd, ref), resolve(mainRoot, ref)];
  const path = candidates.find((c) => existsSync(c)) ?? candidates.at(-1);
  const scratch = realpathAsFarAsExists(resolve(mainRoot, ".scratch"));
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

/** The feature's PRD, `.scratch/<slug>/PRD.md`, or null when there is none. */
export function readPrd(mainRoot, { featureSlug } = {}) {
  const path = join(mainRoot, ".scratch", featureSlug, "PRD.md");
  return existsSync(path) ? readFileSync(path, "utf8") : null;
}

/** The file `known` writes for one issue: the issue file itself, under its own name (the lint ref). */
export function knownFile(issue) {
  return { name: issue.file, text: issue.text };
}

function stateFiles(mainRoot, featureSlug, state) {
  const d = join(mainRoot, ".scratch", featureSlug, "issues", state);
  return existsSync(d) ? readdirSync(d).filter((f) => f.endsWith(".md")).sort() : [];
}

/**
 * `publish-issues`' re-run rule: a feature with done issues is not re-published over (exit 4), and
 * open issues are only overwritten with `--replace` (exit 5), never one a draft's `## Blocked by`
 * names, which would leave that draft blocked for good (exit 1). Null when publishing may go ahead.
 */
export function publishGuard(mainRoot, { featureSlug, replace = false, blockers = [] } = {}) {
  const issues = `.scratch/${featureSlug}/issues`;
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

/** `publish-issues`' local side: drafts numbered from one past the feature's highest issue number. */
export function beginPublish(mainRoot, { featureSlug, drafts, replace = false } = {}) {
  const issues = join(mainRoot, ".scratch", featureSlug, "issues");
  const openDir = join(issues, "open");
  const existing = [...stateFiles(mainRoot, featureSlug, "open"), ...stateFiles(mainRoot, featureSlug, "done")];
  const base = Math.max(0, ...existing.map((f) => Number(issueNumber(f) ?? 0)));
  const ordered = [...drafts].sort((a, b) => a.localeCompare(b, "en", { numeric: true }));
  const width = Math.max(2, String(base + ordered.length).length);
  const names = new Map(ordered.map((f, i) => [f, `${String(base + i + 1).padStart(width, "0")}-${f.replace(/^[0-9]+-/, "")}`]));
  if (replace) for (const f of stateFiles(mainRoot, featureSlug, "open")) rmSync(join(openDir, f));
  mkdirSync(openDir, { recursive: true });
  return {
    create(draft) {
      const name = names.get(draft.file);
      const path = join(openDir, name);
      writeFileSync(path, draft.text);
      return { ref: path, blockerRef: name };
    },
    finish({ deps }) {
      writeFileSync(join(issues, "issues-deps.json"), `${JSON.stringify(deps, null, 2)}\n`);
    },
  };
}

/** Write the feature's PRD to `.scratch/<slug>/PRD.md` (the title is the body's own heading); returns that path. */
export function publishPrd(mainRoot, { featureSlug, body } = {}) {
  const path = join(mainRoot, ".scratch", featureSlug, "PRD.md");
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

/** Rewrite a single-slice source issue in place with its `Status:` set; null when there is no file. */
export function rewriteIssue(mainRoot, path, { body, status } = {}) {
  if (!existsSync(path) || !statSync(path).isFile()) return null;
  writeFileSync(path, withStatus(body, status));
  return true;
}

/** Every criterion in the file at `path` ticked; the count, or null when there is no such file. */
export function tickIssue(mainRoot, path) {
  if (!existsSync(path) || !statSync(path).isFile()) return null;
  const { text, ticked } = tickCriteria(readFileSync(path, "utf8"));
  if (ticked) writeFileSync(path, text);
  return ticked;
}

/** `## <heading>` written into the file at `path`, replacing one already there; null when there is no such file. */
export function writeSection(mainRoot, path, { heading, body } = {}) {
  if (!existsSync(path) || !statSync(path).isFile()) return null;
  writeIssueSection(path, heading, body);
  return true;
}

/** What `mark-done` closes at `path`: its name, its sprint dir, and whether it is already done or missing. */
export function doneTarget(mainRoot, path) {
  const name = basename(path);
  const stateDir = dirname(path);
  const doneDir = join(dirname(stateDir), "done");
  const sprintDir = dirname(dirname(stateDir));
  if (basename(stateDir) === "done" && existsSync(path)) return { name, sprintDir, alreadyDone: `${name} already closed (${path})`, donePath: path };
  if (!existsSync(path)) {
    const done = join(doneDir, name);
    return existsSync(done) ? { name, sprintDir, alreadyDone: `${name} already closed (${done})`, donePath: done } : { name, sprintDir, missing: true };
  }
  return { name, sprintDir };
}

/** A file already in done/ (moved by hand, or a re-run): its `Status:` made `done` in place, nothing else touched. */
export function reconcileDone(mainRoot, donePath) {
  const text = readFileSync(donePath, "utf8");
  const next = text.replace(/^Status: *.*$/gm, "Status: done");
  if (next !== text) writeFileSync(donePath, next);
}

export function readIssueBody(mainRoot, path) {
  return readFileSync(path, "utf8");
}

/** Close the issue file: every `Status:` line becomes `Status: done`, then it moves to the sibling `done/`. */
export function markDone(mainRoot, path) {
  const doneDir = join(dirname(dirname(path)), "done");
  const dest = join(doneDir, basename(path));
  writeFileSync(path, readFileSync(path, "utf8").replace(/^Status: *.*$/gm, "Status: done"));
  mkdirSync(doneDir, { recursive: true });
  renameSync(path, dest);
  return `DONE: ${basename(path)} → ${dest}`;
}
