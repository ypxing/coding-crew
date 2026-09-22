/**
 * body-format.mjs — the backend-agnostic markdown-body helpers.
 *
 * A GitHub issue body uses the exact same markdown conventions as a local issue file
 * (`## Acceptance criteria`, `## Blocked by`, `Source:`) minus the `Status:` line, which
 * becomes a label/close-state instead. So every backend's `parseIssue` can share one
 * text-parsing implementation, extracted here verbatim from the pre-split `tracker.mjs`
 * (no behavior change) rather than duplicated per backend.
 */

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

/** The `## Acceptance criteria` section body, tolerant of either heading case. */
export function criteriaSection(text) {
  return sectionBody(text, "Acceptance criteria") ?? sectionBody(text, "Acceptance Criteria") ?? "";
}

/**
 * A `Source:` line marks a fix issue promoted from review findings. It is the
 * depth bound: findings raised against it are never promoted again.
 */
export function isSourceGuarded(text) {
  return /^\s*(?:\*\*)?Source(?:\*\*)?:/im.test(text);
}

/** Matches an `## Acceptance criteria` / `## Cross-cutting Requirements` heading — the
 * same two headings `scripts/tracker/mark-issue-done.sh`'s awk guard scopes to on both
 * backends. */
const CRITERIA_HEADING_RE = /^#{1,6}\s+(?:Acceptance Criteria|Cross-cutting Requirements)\s*$/i;

/**
 * Every still-unchecked `- [ ]` line found under either criteria heading in `text` — the
 * same close-time guard `mark-issue-done.sh`'s awk runs for both backends, shared here so
 * a Node caller (`github.mjs`'s `markDone`) does not reimplement the scan a third time.
 */
export function uncheckedCriteria(text) {
  let inside = false;
  const unchecked = [];
  for (const line of text.split("\n")) {
    const heading = /^#{1,6}\s+/.test(line);
    if (heading) {
      inside = CRITERIA_HEADING_RE.test(line);
      continue;
    }
    if (inside && /^\s*[-*]\s*\[\s\]/.test(line)) unchecked.push(line);
  }
  return unchecked;
}

/**
 * The numeric-matching half of `resolveBlockedBy`: `## Blocked by` entries written as
 * `Issue NN` (optionally `Issue #NN`) rather than a literal filename. Returns the matched
 * numbers as strings, in encounter order, duplicates included — resolving a number to a
 * concrete backend ref (a sibling filename for local, a bare issue number for GitHub) is
 * backend-specific and stays with each backend's own `resolveBlockedBy`/blocker lookup.
 */
export function extractBlockedByNumbers(section) {
  return [...section.matchAll(/\bissue[\s-]*#?0*([0-9]+)\b/gi)].map((m) => m[1]);
}
