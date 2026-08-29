/**
 * tracker.mjs — the local markdown issue tracker, as code.
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
 */

import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";

export const READY_STATUS = "ready-for-agent";
export const PARKED_STATUS = "deferred-findings";

/** Filename minus leading digits and extension. Mirrors receipts.sh issue_slug_of(). */
export function issueSlug(file) {
  return basename(file).replace(/\.md$/, "").replace(/^[0-9]+[-_]?/, "");
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
 * Extract one `## <heading>` section's body. Stops at the next heading of the
 * same or higher level, so a `### Sub` inside the section is kept.
 */
export function sectionBody(text, heading) {
  const lines = text.split("\n");
  const want = heading.trim().toLowerCase();
  let start = -1;
  let level = 0;
  for (let i = 0; i < lines.length; i++) {
    const m = /^(#{1,6})\s+(.*?)\s*$/.exec(lines[i]);
    if (m && m[2].toLowerCase() === want) {
      start = i + 1;
      level = m[1].length;
      break;
    }
  }
  if (start === -1) return null;
  const body = [];
  for (let i = start; i < lines.length; i++) {
    const m = /^(#{1,6})\s+/.exec(lines[i]);
    if (m && m[1].length <= level) break;
    body.push(lines[i]);
  }
  return body.join("\n").replace(/^\n+|\n+$/g, "");
}

/**
 * Replace a section's body, or append the section when absent. Never adds a
 * second heading with the same name — the failure the prose kept warning about.
 */
export function spliceSection(text, heading, body) {
  const lines = text.split("\n");
  const want = heading.trim().toLowerCase();
  let start = -1;
  let level = 2;
  for (let i = 0; i < lines.length; i++) {
    const m = /^(#{1,6})\s+(.*?)\s*$/.exec(lines[i]);
    if (m && m[2].toLowerCase() === want) {
      start = i;
      level = m[1].length;
      break;
    }
  }
  const block = `${"#".repeat(level)} ${heading}\n\n${body.replace(/\s+$/, "")}`;
  if (start === -1) {
    const sep = text.endsWith("\n") ? "\n" : "\n\n";
    return `${text}${sep}${block}\n`;
  }
  let end = lines.length;
  for (let i = start + 1; i < lines.length; i++) {
    const m = /^(#{1,6})\s+/.exec(lines[i]);
    if (m && m[1].length <= level) {
      end = i;
      break;
    }
  }
  const rebuilt = [...lines.slice(0, start), ...block.split("\n"), "", ...lines.slice(end)];
  return rebuilt.join("\n").replace(/\n{3,}/g, "\n\n");
}

/** Append a line inside a section, creating the heading only if absent. */
export function appendToSection(text, heading, line) {
  const existing = sectionBody(text, heading);
  const body = existing ? `${existing}\n${line}` : line;
  return spliceSection(text, heading, body);
}

export function parseIssue(path, text = readFileSync(path, "utf8")) {
  const statusMatch = /^\s*(?:[-*]\s*)?(?:\*\*)?Status(?:\*\*)?:\s*(?:`)?([a-z-]+)/im.exec(text);
  const titleMatch = /^#\s+(.*)$/m.exec(text);
  const blockedBySection = sectionBody(text, "Blocked by") ?? "";
  const blockedBy = [...blockedBySection.matchAll(/([0-9A-Za-z][\w.-]*\.md)/g)].map((m) => m[1]);
  const criteria =
    sectionBody(text, "Acceptance criteria") ?? sectionBody(text, "Acceptance Criteria") ?? "";
  return {
    path,
    file: basename(path),
    slug: issueSlug(path),
    title: titleMatch ? titleMatch[1].trim() : issueSlug(path),
    status: statusMatch ? statusMatch[1] : "",
    blockedBy,
    criteria,
    // A `Source:` line marks a fix issue promoted from review findings. It is the
    // depth bound: findings raised against it are never promoted again.
    sourceGuarded: /^\s*(?:\*\*)?Source(?:\*\*)?:/im.test(text),
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
