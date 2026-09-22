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

import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";

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
 * why a running sprint must always pass its own slug here.
 */
export function selectDispatchable(mainRoot, { status = READY_STATUS, featureSlug = null } = {}) {
  const issues = listOpenIssueFiles(mainRoot, { featureSlug }).map((p) => parseIssue(p));
  const ready = issues.filter((i) => i.status === status);
  return ready
    .map((i) => ({ ...i, blockers: blockers(i) }))
    .filter((i) => i.blockers.length === 0);
}

export function writeIssueSection(path, heading, body, { append = false } = {}) {
  const text = readFileSync(path, "utf8");
  const next = append ? appendToSection(text, heading, body) : spliceSection(text, heading, body);
  writeFileSync(path, next);
  return next;
}
