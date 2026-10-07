/**
 * local.mjs — the local markdown issue tracker backend.
 *
 * Owns every mechanical fact the orchestrator prompt used to read by hand: which
 * issues exist, which are ready, which are blocked by an issue that is not in
 * done/ yet, what an issue's slug and branch are, and how to splice a
 * `## Progress` / `## Blocked` section without ever creating a second one.
 *
 * Slug derivation is deliberately identical to `issue_slug_of()` in receipts.sh
 * (basename, minus .md, minus leading digits): that shared derivation is what
 * ties an acceptance-criteria receipt to one specific issue rather than to
 * whichever branch was verified last.
 *
 * Text-parsing that is identical across backends (section extraction, the criteria
 * lookup, the `Source:` guard, the numeric half of `## Blocked by` resolution) lives in
 * `./body-format.mjs`, not here — this file keeps only what is genuinely file-specific:
 * filenames, the `Status:` line, and directory scans.
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

/** The filename's leading digits (`NN-<slug>.md` — see docs/issue-tracker.md), or null when absent. */
export function issueNumber(file) {
  return /^([0-9]+)/.exec(basename(file))?.[1] ?? null;
}

export function branchFor(featureSlug, slug) {
  return `crew/${featureSlug}/${slug}`;
}

/**
 * Every open issue file, sorted. Across every feature dir under .scratch/ by default,
 * or under a single `.scratch/<featureSlug>/` when one is given.
 *
 * A sprint is scoped to exactly one feature — one FEATURE_SLUG, one feature branch, one
 * `sprint.env` (see session-init.sh, sprint.mjs) — so a live sprint's dispatch loop must
 * always pass its own `sprint.featureSlug` here. Without it, a `ready-for-agent` issue
 * that merely happens to sit in a *different* `.scratch/<other-feature>/issues/open/`
 * gets dispatched, merged onto, and closed against the running sprint's feature branch —
 * real work landing on the wrong feature. The unscoped, all-features scan stays the
 * default only for callers with no sprint yet to scope to (e.g. a first `plan` survey).
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
 * Resolve a `## Blocked by` section's entries to sibling issue filenames.
 * Accepts literal `NN-slug.md` filenames as well as `Issue NN` references —
 * the latter is how the dependency often actually gets written, and the
 * leading number is the only stable link back to the real file.
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

/** Path to the machine-readable dependency map, a sibling of open/ and done/. */
export function issueDepsPath(issuePath) {
  return join(dirname(dirname(issuePath)), "issues-deps.json");
}

/**
 * `issues-deps.json`, if `to-issues` wrote one: `{ "02-second.md": ["01-first.md"] }`.
 * The exact source of truth `## Blocked by` prose can't guarantee, since prose has more
 * shapes than any parser enumerates. Returns null when absent or unparseable, so callers
 * fall back to the markdown heuristic.
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

/**
 * Every issue of one feature, in every state, as `parseIssue` entries: `issues/open/` files with
 * their own `Status:`, then `issues/done/` files, whose status is `done` whatever their text says —
 * the directory is the state. The same entry shape (`slug`, `number`, `title`, `status`, `text`, …)
 * as github's `listFeatureIssues`, plus the `path`/`file` only a file has.
 */
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

/** The feature's `issues-deps.json` when `to-issues` wrote one, else null. */
export function featureDepsFile(mainRoot, { featureSlug } = {}) {
  const path = join(mainRoot, ".scratch", featureSlug, "issues", "issues-deps.json");
  return existsSync(path) ? path : null;
}

/** Files present in the sibling done/ dir of an issue's open/ dir. */
export function doneFiles(issuePath) {
  const done = join(dirname(dirname(issuePath)), "done");
  return existsSync(done) ? new Set(readdirSync(done)) : new Set();
}

export function blockers(issue, done = doneFiles(issue.path)) {
  return issue.blockedBy.filter((f) => !done.has(f));
}

/**
 * Ready and unblocked, in filename order. Everything else is skipped.
 *
 * `featureSlug` is forwarded to `listOpenIssueFiles` unchanged — see its docstring for
 * why a running sprint must always pass its own slug here. `includeBlocked` keeps the ready
 * issues still waiting on a blocker: preflight probes their `## Requires` before any dispatch.
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
 * The absolute issue path a CLI ref names, or null when it is not one this backend may read: a
 * path that, symlinks resolved, sits under the main root's `.scratch/`. A relative ref resolves
 * against `cwd` when that names an existing file, else against the main root (a worker in a
 * worktree names `.scratch/…` paths, which live only in the main checkout). Stats, never reads.
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

/**
 * `{title, body}` for the issue file at `path` (already through `validateRef`), or null when there
 * is none. The body is the file minus its `# <title>` line; a file with no such line keeps all of
 * it and takes its slug as the title, as `parseIssue` does. Comments are already in the file.
 */
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

/** The `.md` files in a feature's `issues/<state>/`, sorted. */
function stateFiles(mainRoot, featureSlug, state) {
  const d = join(mainRoot, ".scratch", featureSlug, "issues", state);
  return existsSync(d) ? readdirSync(d).filter((f) => f.endsWith(".md")).sort() : [];
}

/**
 * `publish-issues`' re-run rule: a feature with done issues is not re-published over (exit 4 —
 * reconcile by hand), and open issues are only overwritten with `--replace` (exit 5). Null when
 * publishing may go ahead.
 */
export function publishGuard(mainRoot, { featureSlug, replace = false } = {}) {
  const issues = `.scratch/${featureSlug}/issues`;
  if (stateFiles(mainRoot, featureSlug, "done").length) {
    return {
      code: 4,
      message: `publish-issues: ${issues}/done/ has issues — some are already completed. Reconcile by hand (delete or archive ${issues}/) before re-running.`,
    };
  }
  const open = stateFiles(mainRoot, featureSlug, "open");
  if (open.length && !replace) {
    return {
      code: 5,
      message: `publish-issues: ${issues}/open/ already has issues, which publishing would overwrite: ${open.join(", ")}. Pass --replace to overwrite them.`,
    };
  }
  return null;
}

/**
 * `publish-issues`' local side: each draft is written as-is (its `## Blocked by` already rewritten
 * to final filenames) to `issues/open/NN-<slug>.md`, numbered from one past the feature's highest
 * existing issue number in draft order; `--replace` first removes the open issues; `finish` writes
 * `issues-deps.json` naming the final filenames.
 */
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

/**
 * Rewrite a single-slice source issue in place: the file at `path` becomes `body` with its
 * `Status:` set to `status`; everything else, a `Source:` line included, stays as written.
 * Null when there is no such file.
 */
export function rewriteIssue(mainRoot, path, { body, status } = {}) {
  if (!existsSync(path) || !statSync(path).isFile()) return null;
  writeFileSync(path, withStatus(body, status));
  return true;
}

/**
 * What `mark-done` closes at `path`: its name, its sprint dir (`.scratch/<slug>`, where the
 * `.orchestrated` marker lives), and whether it is already in `done/` (`alreadyDone`, a message)
 * or exists nowhere (`missing`).
 */
export function doneTarget(mainRoot, path) {
  const name = basename(path);
  const stateDir = dirname(path);
  const doneDir = join(dirname(stateDir), "done");
  const sprintDir = dirname(dirname(stateDir));
  if (basename(stateDir) === "done" && existsSync(path)) return { name, sprintDir, alreadyDone: `${name} already closed (${path})` };
  if (!existsSync(path)) {
    const done = join(doneDir, name);
    return existsSync(done) ? { name, sprintDir, alreadyDone: `${name} already closed (${done})` } : { name, sprintDir, missing: true };
  }
  return { name, sprintDir };
}

/** The issue file's text, read now, for `mark-done`'s criteria guard. */
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
