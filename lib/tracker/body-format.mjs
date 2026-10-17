
/** body-format.mjs — markdown-body parsing shared by every backend's `parseIssue`. */

/** The code fence open after `line`, given the one open before it: "" when none (``` / ~~~, closed by the same mark). */
function fenceAfter(fence, line) {
  if (fence) {
    const c = /^ {0,3}(`{3,}|~{3,})\s*$/.exec(line);
    return c && c[1][0] === fence[0] && c[1].length >= fence.length ? "" : fence;
  }
  const m = /^ {0,3}(`{3,}|~{3,})/.exec(line);
  return m ? m[1] : "";
}

/** One `## <heading>` section's body, up to the next heading of the same or higher level; fenced lines are never headings. */
export function sectionBody(text, heading) {
  const lines = text.split("\n");
  const want = heading.trim().toLowerCase();
  let start = -1;
  let level = 0;
  let fence = "";
  for (let i = 0; i < lines.length; i++) {
    fence = fenceAfter(fence, lines[i]);
    if (fence || /^ {0,3}(`{3,}|~{3,})/.test(lines[i])) continue;
    const m = /^(#{1,6})\s+(.*?)\s*$/.exec(lines[i]);
    if (m && m[2].toLowerCase() === want) {
      start = i + 1;
      level = m[1].length;
      break;
    }
  }
  if (start === -1) return null;
  const body = [];
  fence = "";
  for (let i = start; i < lines.length; i++) {
    const inFence = fence !== "";
    fence = fenceAfter(fence, lines[i]);
    const m = !inFence && !fence ? /^(#{1,6})\s+/.exec(lines[i]) : null;
    if (m && m[1].length <= level) break;
    body.push(lines[i]);
  }
  return body.join("\n").replace(/^\n+|\n+$/g, "");
}

/** Replace a section's body, or append the section when absent; never a second heading of the same name. */
export function spliceSection(text, heading, body) {
  const lines = text.split("\n");
  const want = heading.trim().toLowerCase();
  let start = -1;
  let level = 2;
  let fence = "";
  for (let i = 0; i < lines.length; i++) {
    fence = fenceAfter(fence, lines[i]);
    if (fence || /^ {0,3}(`{3,}|~{3,})/.test(lines[i])) continue;
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
  fence = "";
  for (let i = start + 1; i < lines.length; i++) {
    const inFence = fence !== "";
    fence = fenceAfter(fence, lines[i]);
    const m = !inFence && !fence ? /^(#{1,6})\s+/.exec(lines[i]) : null;
    if (m && m[1].length <= level) {
      end = i;
      break;
    }
  }
  const rebuilt = [...lines.slice(0, start), ...block.split("\n"), "", ...lines.slice(end)];
  return rebuilt.join("\n").replace(/\n{3,}/g, "\n\n");
}

/**
 * Whether `text` has its own `## Acceptance criteria` heading, outside a fence. `## Cross-cutting
 * Requirements` does not count: it carries the PRD's rules, not the issue's criteria.
 */
export function hasCriteriaSection(text) {
  return sectionBody(text, "Acceptance criteria") !== null || sectionBody(text, "Acceptance Criteria") !== null;
}

/** An `## Acceptance criteria` / `## Cross-cutting Requirements` heading: what `mark-done`'s criteria guard scopes to. */
const CRITERIA_HEADING_RE = /^#{1,6}\s+(?:Acceptance Criteria|Cross-cutting Requirements)\s*$/i;

/** Every still-unchecked `- [ ]` line under either criteria heading in `text`. */
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

/** `text` with every `- [ ]` under either criteria heading ticked, and how many were: what `cli.mjs tick` writes. */
export function tickCriteria(text) {
  let inside = false;
  let ticked = 0;
  const lines = String(text).split("\n").map((line) => {
    if (/^#{1,6}\s+/.test(line)) {
      inside = CRITERIA_HEADING_RE.test(line);
      return line;
    }
    if (!inside || !/^\s*[-*]\s*\[\s\]/.test(line)) return line;
    ticked += 1;
    return line.replace(/\[\s\]/, "[x]");
  });
  return { text: lines.join("\n"), ticked };
}
