/**
 * report.mjs — parse what the models return, and apply the schema pre-filter.
 *
 * The worker's report is the only channel between a worker's context window and
 * the pipeline, so it is parsed strictly and *pessimistically*: an unparseable
 * report is `blocked`, never a silent `complete`. A structured block is preferred
 * (```json fence, or a <slug>.report.json sidecar); the markdown headings stay
 * supported so an older crew-coder still works.
 *
 * The reviewer's report carries two things the pipeline gates on: the `AC:`
 * verdict line and the findings list. Both fail closed — a missing verdict is
 * `unmet`, an unreadable report is a review that did not happen.
 */

export const CHECK_CATEGORIES = ["test", "lint", "typecheck"];
const STATUSES = new Set(["complete", "partial", "blocked"]);

function normaliseCheck(value) {
  if (value == null) return "not_run";
  const v = String(value).trim().toLowerCase();
  if (/(^|\b)(pass|passed|passing|ok|green|success)\b/.test(v)) return "pass";
  if (/(^|\b)(fail|failed|failing|red|error)\b/.test(v)) return "fail";
  if (/(^|\b)(not_run|not run|none|n\/a|na|skipped|missing|absent)\b/.test(v)) return "not_run";
  return "not_run";
}

function fencedJson(text) {
  const re = /```(?:json)?\s*\n([\s\S]*?)\n```/g;
  let m;
  while ((m = re.exec(text)) !== null) {
    const body = m[1].trim();
    if (!body.startsWith("{")) continue;
    try {
      const parsed = JSON.parse(body);
      if (parsed && typeof parsed === "object" && parsed.status) return parsed;
    } catch {
      /* not the block we want */
    }
  }
  return null;
}

function fromStructured(raw, obj) {
  const checks = {};
  for (const c of CHECK_CATEGORIES) checks[c] = normaliseCheck(obj.checks?.[c]);
  return {
    parsedFrom: "json",
    status: STATUSES.has(String(obj.status).toLowerCase())
      ? String(obj.status).toLowerCase()
      : "blocked",
    checks,
    branch: obj.branch ?? null,
    workingDirectory: obj.working_directory ?? obj.workingDirectory ?? null,
    progress: obj.progress ?? null,
    notes: obj.notes ?? null,
    criteria: Array.isArray(obj.criteria) ? obj.criteria : [],
    raw,
  };
}

function fromMarkdown(raw) {
  const status = /^\s*(?:\*\*)?Status(?:\*\*)?:\s*(?:`)?(complete|partial|blocked)/im.exec(raw);
  const checks = {};
  for (const c of CHECK_CATEGORIES) {
    // "test: pass", "| tests | fail |", "- Typecheck — not_run"
    const re = new RegExp(`${c}s?\\b[^\\n|]*[:|\\-—]\\s*\`?(\\w[\\w /]*)`, "i");
    const m = re.exec(raw);
    checks[c] = m ? normaliseCheck(m[1]) : "not_run";
  }
  const wd = /(?:working[_ ]directory|worktree)\s*[:=]\s*(\S+)/i.exec(raw);
  const branch = /^\s*(?:\*\*)?Branch(?:\*\*)?:\s*(\S+)/im.exec(raw);
  return {
    parsedFrom: "markdown",
    status: status ? status[1].toLowerCase() : null,
    checks,
    branch: branch ? branch[1] : null,
    workingDirectory: wd ? wd[1] : null,
    progress: null,
    notes: null,
    criteria: [],
    raw,
  };
}

/**
 * @param {string|null} text  the worker's final message
 * @param {object|null} sidecar  parsed <slug>.report.json, when the worker wrote one
 */
export function parseWorkerReport(text, sidecar = null) {
  const raw = text ?? "";
  if (sidecar && sidecar.status) return fromStructured(raw, sidecar);
  const json = fencedJson(raw);
  if (json) return fromStructured(raw, json);
  if (!raw.trim()) {
    return {
      parsedFrom: "empty",
      status: "blocked",
      checks: Object.fromEntries(CHECK_CATEGORIES.map((c) => [c, "not_run"])),
      branch: null,
      workingDirectory: null,
      progress: null,
      notes: null,
      criteria: [],
      unparseable: "empty report — the worker died before reporting",
      raw,
    };
  }
  const md = fromMarkdown(raw);
  if (!md.status) {
    return { ...md, status: "blocked", unparseable: "no Status: line in the worker report" };
  }
  return md;
}

/**
 * The schema pre-filter, identical in policy to verify-worktree.sh so the two
 * gates cannot disagree: a failing check or an un-run test demotes `complete`,
 * while lint/typecheck `not_run` is a recorded coverage gap, not a demotion —
 * many repos legitimately have neither, and demoting there stalls every sprint.
 */
export function applySchemaPrefilter(report) {
  const failed = CHECK_CATEGORIES.filter((c) => report.checks[c] === "fail");
  const gaps = ["lint", "typecheck"].filter((c) => report.checks[c] === "not_run");
  let status = report.status;
  let reason = report.unparseable ?? null;

  if (status === "complete") {
    if (failed.length) {
      status = "partial";
      reason = `reported checks failed: ${failed.join(", ")}`;
    } else if (report.checks.test === "not_run") {
      status = "partial";
      reason = "tests not run — nothing was verified";
    }
  }
  return { status, demoted: status !== report.status, reason, coverageGaps: gaps };
}

/**
 * verify-worktree.sh's own output, read back as the check evidence the reviewer is given.
 *
 * The reviewer cannot run commands, so a criterion phrased "…and the tests pass" is
 * unprovable from a diff and reads as `unmet` — which stalled every sprint whose issues
 * were written that way. The pipeline has already run those checks in the branch's
 * worktree and gated the merge on the result; passing that result on is what makes the
 * criteria check answerable without weakening it. `not_run` is never evidence.
 */
export function parseVerifyChecks(stdout) {
  const checks = { test: "not_run", lint: "not_run", typecheck: "not_run" };
  for (const m of (stdout ?? "").matchAll(/^\s*(TEST|LINT|TYPECHECK):\s*(pass|fail|not_run)\b/gim)) {
    checks[m[1].toLowerCase()] = m[2].toLowerCase();
  }
  return checks;
}

const SEVERITIES = ["CRITICAL", "HIGH", "MEDIUM", "LOW"];

/**
 * Reviewer output. `AC:` is read, never inferred. Findings come from explicit
 * `FINDING: SEV | file:line | criterion` lines when present, otherwise from
 * `[SEV]` headings, so the reviewer can be upgraded independently.
 */
export function parseReviewReport(text) {
  const raw = text ?? "";
  if (!raw.trim()) {
    return { ok: false, verdict: "unmet", detail: "empty review report", findings: [], raw };
  }
  if (/^\s*SKIPPED:/im.test(raw)) {
    const m = /^\s*SKIPPED:\s*(.*)$/im.exec(raw);
    return { ok: false, verdict: "unmet", detail: `skipped — ${m[1].trim()}`, findings: [], raw };
  }
  const ac = /^\s*AC:\s*(all-met|unmet)\s*(?:—|--|-)?\s*(.*)$/im.exec(raw);
  const findings = [];
  const explicit = [...raw.matchAll(/^\s*FINDING:\s*(\w+)\s*\|\s*([^|\n]*)\|\s*(.+)$/gim)];
  for (const m of explicit) {
    const severity = m[1].toUpperCase();
    if (!SEVERITIES.includes(severity)) continue;
    findings.push({ severity, location: m[2].trim(), criterion: m[3].trim(), explicit: true });
  }
  if (!explicit.length) {
    for (const m of raw.matchAll(/\[(CRITICAL|HIGH|MEDIUM|LOW)\]\s*(.*)$/gim)) {
      findings.push({
        severity: m[1].toUpperCase(),
        location: "",
        criterion: m[2].trim(),
        explicit: false,
      });
    }
  }
  if (!ac) {
    return { ok: true, verdict: "unmet", detail: "no verdict line", findings, raw };
  }
  return {
    ok: true,
    verdict: ac[1].toLowerCase(),
    detail: (ac[2] || "").trim(),
    findings,
    raw,
  };
}

export function findingsAtOrAbove(findings, threshold /* "critical" | "critical-high" */) {
  const allowed = threshold === "critical-high" ? ["CRITICAL", "HIGH"] : ["CRITICAL"];
  return findings.filter((f) => allowed.includes(f.severity));
}
