/**
 * report.mjs — parse each role's `*.report.json` sidecar, never the captured text; a missing or
 * invalid one fails closed (`blocked` / `unmet` / `fixable`). Also the schema pre-filter.
 */

import { readFileSync } from "node:fs";

export const CHECK_CATEGORIES = ["test", "lint", "typecheck"];
const STATUSES = new Set(["complete", "partial", "blocked"]);

function normaliseCheck(value) {
  if (value == null) return "not_run";
  const v = String(value).trim().toLowerCase();
  if (/(^|\b)deferred\b/.test(v)) return "deferred";
  if (/(^|\b)(pass|passed|passing|ok|green|success)\b/.test(v)) return "pass";
  if (/(^|\b)(fail|failed|failing|red|error)\b/.test(v)) return "fail";
  if (/(^|\b)(not_run|not run|none|n\/a|na|skipped|missing|absent)\b/.test(v)) return "not_run";
  return "not_run";
}

/** Every fenced json block in `text` with `requiredField`, parsed as JSON so pane-transcript indentation does not matter. */
export function allFencedJson(text, requiredField) {
  const re = /[ \t]*```(?:json)?[ \t]*\n([\s\S]*?)\n[ \t]*```/g;
  const out = [];
  let m;
  while ((m = re.exec(text)) !== null) {
    const body = m[1].trim();
    if (!body.startsWith("{")) continue;
    try {
      const parsed = JSON.parse(body);
      if (parsed && typeof parsed === "object" && parsed[requiredField]) out.push(parsed);
    } catch {
      /* not the block we want */
    }
  }
  return out;
}

// The coder's own evidence rides to triage verbatim, so its size is capped here, once. The tail
// is kept: a failing command's own error is almost always at the end.
export const EVIDENCE_OUTPUT_MAX = 4096;

/** `environment` | `code` | null — what a coder that stopped says stopped it. A claim, not a verdict. */
function coderCause(value) {
  const v = String(value ?? "").trim().toLowerCase();
  return v === "environment" || v === "code" ? v : null;
}

/** The one command a coder says shows why it stopped, or null: a claim triage weighs against the diff. */
function coderEvidence(obj) {
  if (!obj || typeof obj !== "object" || Array.isArray(obj)) return null;
  const command = typeof obj.command === "string" ? obj.command.trim() : "";
  const output = obj.output == null ? "" : String(obj.output);
  if (!command && !output.trim()) return null;
  const n = Number(obj.exit);
  const exit = obj.exit != null && String(obj.exit).trim() !== "" && Number.isInteger(n) ? n : null;
  const truncated = output.length > EVIDENCE_OUTPUT_MAX;
  return { command, exit, output: truncated ? output.slice(-EVIDENCE_OUTPUT_MAX) : output, truncated };
}

function fromStructured(raw, obj) {
  const checks = {};
  // Further dev-commands.json checks (coverage, integration) ride beside the base three, so the
  // pre-filter can stop on a failure the coder admitted; verify-worktree.sh runs them anyway.
  for (const c of CHECK_CATEGORIES) checks[c] = normaliseCheck(obj.checks?.[c]);
  for (const [k, v] of Object.entries(obj.checks && typeof obj.checks === "object" ? obj.checks : {})) {
    const c = k.trim().toLowerCase();
    if (/^[a-z][a-z0-9_]*$/.test(c) && !CHECK_CATEGORIES.includes(c)) checks[c] = normaliseCheck(v);
  }
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
    cause: coderCause(obj.cause),
    evidence: coderEvidence(obj.evidence),
    raw,
  };
}

/** Every missing-or-invalid-sidecar case, in fromStructured's shape so a caller never branches on which. */
function missingReport(raw, unparseable) {
  return {
    parsedFrom: "missing",
    status: "blocked",
    checks: Object.fromEntries(CHECK_CATEGORIES.map((c) => [c, "not_run"])),
    branch: null,
    workingDirectory: null,
    progress: null,
    notes: null,
    criteria: [],
    cause: null,
    evidence: null,
    unparseable,
    raw,
  };
}

/** `text` is kept only as `raw`, for a human reading a blocked report; never parsed. */
export function parseWorkerReport(text, sidecar = null) {
  const raw = text ?? "";
  if (sidecar && STATUSES.has(String(sidecar.status).toLowerCase())) return fromStructured(raw, sidecar);
  return missingReport(
    raw,
    sidecar
      ? "the worker's report.json has no valid status field"
      : "no report.json — the worker never wrote its result file",
  );
}

/**
 * Same policy as verify-worktree.sh, so the two gates cannot disagree: lint/typecheck `not_run` is
 * only a coverage gap, since many repos have neither.
 */
export function applySchemaPrefilter(report) {
  const failed = Object.keys(report.checks).filter((c) => report.checks[c] === "fail");
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
 * verify-worktree.sh's `verify.json`, the reviewer's check evidence (it cannot run commands). A
 * missing record is every base check `not_run`; `missing` maps a check to its uninstalled command.
 */
export function readVerifyRecord(file) {
  const checks = Object.fromEntries(CHECK_CATEGORIES.map((c) => [c, "not_run"]));
  const logs = {};
  const missing = {};
  let rec = null;
  try {
    rec = JSON.parse(readFileSync(file, "utf8"));
  } catch {
    return { checks, logs, missing, notConfigured: [] };
  }
  for (const c of Array.isArray(rec?.checks) ? rec.checks : []) {
    if (!c || typeof c.category !== "string") continue;
    checks[c.category] = normaliseCheck(c.result);
    if (typeof c.log === "string" && c.log) logs[c.category] = c.log;
    if (typeof c.missing === "string" && c.missing) missing[c.category] = c.missing;
  }
  const notConfigured = Array.isArray(rec?.not_configured) ? rec.not_configured.filter((c) => typeof c === "string") : [];
  return { checks, logs, missing, notConfigured };
}

/** ensure-deps.sh's `DEPS:` line, or "" when there is none (a dry run produces no output). */
export function depsLine(stdout) {
  const m = /^DEPS:.*$/m.exec(stdout ?? "");
  return m ? m[0].trim() : "";
}

/**
 * check-requires.sh's failures: `Map<file, [{ command, status, output }]>`. A `REQUIRE: fail <file>
 * <cmd>` line is matched against `files`, not split on a space, since either may contain one.
 */
export function parseRequiresFailures(stdout, files) {
  const byFile = new Map();
  const known = [...files].sort((a, b) => b.length - a.length);
  let current = null;
  for (const line of String(stdout ?? "").split("\n")) {
    if (line.startsWith("REQUIRE: ")) {
      current = null;
      const rest = line.slice("REQUIRE: fail ".length);
      if (!line.startsWith("REQUIRE: fail ")) continue;
      const file = known.find((f) => rest.startsWith(`${f} `));
      if (!file) continue;
      current = { command: rest.slice(file.length + 1), status: "", output: [] };
      if (!byFile.has(file)) byFile.set(file, []);
      byFile.get(file).push(current);
    } else if (current && line.startsWith("  | ")) {
      current.output.push(line.slice(4));
    } else if (current && line.startsWith("  ")) {
      current.status = line.trim();
    }
  }
  for (const list of byFile.values()) for (const f of list) f.output = f.output.join("\n");
  return byFile;
}

const SEVERITIES = ["CRITICAL", "HIGH", "MEDIUM", "LOW"];
export const SEVERITY_RANK = Object.fromEntries(SEVERITIES.map((s, i) => [s, i]));
const VERDICTS = new Set(["all-met", "unmet", "not_run"]);
/** Findings triage's answer per finding (the shared rubric: skills/_shared/fragments/findings-rubric.md). */
export const FINDING_VERDICTS = ["actionable", "debatable", "dismiss"];

function findingsFromStructured(list) {
  if (!Array.isArray(list)) return [];
  return list
    .filter((f) => f && SEVERITIES.includes(String(f.severity).toUpperCase()))
    .map((f) => ({
      severity: String(f.severity).toUpperCase(),
      location: f.location ? String(f.location).trim() : "",
      issue: f.issue ? String(f.issue).trim() : "",
      criterion: f.criterion ? String(f.criterion).trim() : "",
      explicit: true,
      // Set by carryFindings: raised by an earlier review of the branch, not repeated by the latest.
      ...(f.carried === true ? { carried: true } : {}),
      // Set on a feature-review finding the promotion cap left report-only: no fix issue covers it.
      ...(f.report_only === true ? { report_only: true } : {}),
      ...(FINDING_VERDICTS.includes(String(f.verdict).toLowerCase())
        ? { verdict: String(f.verdict).toLowerCase(), rationale: f.rationale ? String(f.rationale).trim() : "" }
        : {}),
      ...(Number.isInteger(f.duplicate_of) && f.duplicate_of >= 0 ? { duplicate_of: f.duplicate_of } : {}),
    }));
}

/** A note field still holding the protocol's `<path>:<line>` / `<input or state → bad outcome>` template text. */
const NOTE_PLACEHOLDER = /^\s*<[^<>]*>(:<[^<>]*>)?\s*$/;

/** The reviewer's notes — suspected defects outside the criteria — that are `{location, concern}` of two strings; anything else is dropped. */
function notesFromStructured(notes) {
  if (!Array.isArray(notes)) return [];
  return notes
    .filter((n) => n && typeof n.location === "string" && typeof n.concern === "string")
    .filter((n) => !NOTE_PLACEHOLDER.test(n.location) && !NOTE_PLACEHOLDER.test(n.concern))
    .map((n) => ({ location: n.location, concern: n.concern }));
}

/** One branch's structured verdict: the one parser crew-summary.sh and promote-findings.sh reach through review-rollup.mjs. */
function reviewFromStructured(raw, obj) {
  return {
    ok: true,
    parsedFrom: "json",
    branch: obj.branch ? String(obj.branch) : null,
    slug: obj.slug ? String(obj.slug) : null,
    verdict: VERDICTS.has(String(obj.verdict).toLowerCase()) ? String(obj.verdict).toLowerCase() : "unmet",
    detail: obj.detail ? String(obj.detail).trim() : "",
    // Only `environment` means anything: an unmet criterion whose precondition the run's
    // environment did not provide. Anything else, or absent, is the code's to fix.
    cause: String(obj.cause ?? "").trim().toLowerCase() === "environment" ? "environment" : null,
    findings: findingsFromStructured(obj.findings),
    criteriaOnly: obj.criteria_only === true,
    notes: notesFromStructured(obj.notes),
    reviewedSha: obj.reviewed_sha ? String(obj.reviewed_sha) : null,
    raw,
  };
}

/** Reviewer output for one branch, from the `review.report.json` sidecar alone. */
export function parseReviewReport(text, sidecar = null) {
  const raw = text ?? "";
  if (sidecar && VERDICTS.has(String(sidecar.verdict).toLowerCase())) return reviewFromStructured(raw, sidecar);
  return {
    ok: false,
    parsedFrom: "missing",
    verdict: "unmet",
    detail: sidecar
      ? "the reviewer's report.json has no valid verdict field"
      : "no report.json — the reviewer never wrote its verdict file",
    findings: [],
    raw,
  };
}

/** The aggregate review file folded to one record per branch, later block wins (a retry overrides a `not_run` stub). */
export function parseReviewAggregate(text) {
  const order = [];
  const byBranch = new Map();
  for (const rec of parseReviewBlocks(text)) {
    const key = rec.branch ?? `#${order.length}`;
    if (!byBranch.has(key)) order.push(key);
    byBranch.set(key, foldReview(byBranch.get(key), rec));
  }
  return order.map((key) => byBranch.get(key));
}

/** Every review block in `text`, in file order and unfolded (parseReviewAggregate folds them). */
export function parseReviewBlocks(text) {
  const raw = text ?? "";
  return allFencedJson(raw, "verdict").map((obj) => reviewFromStructured(raw, obj));
}

/**
 * The one fold step: `rec` replaces `prev`, except a `not_run` block says nothing about the code and
 * a `criteria_only` block (a per-branch review) nothing about findings, so the earlier findings stay,
 * marked carried. A `not_run` block also keeps the earlier notes with the sha they were written for.
 */
export function foldReview(prev, rec) {
  if (!prev) return rec;
  const kept = rec.verdict === "not_run" ? { notes: prev.notes ?? [], reviewedSha: prev.reviewedSha ?? null } : {};
  if ((rec.verdict !== "not_run" && !rec.criteriaOnly) || !prev.findings?.length) return { ...rec, ...kept };
  return { ...rec, ...kept, findings: prev.findings.map((f) => ({ ...f, carried: true })) };
}

/** What makes two findings the same: severity, path (line dropped), whitespace-normalised case-folded issue (the criterion when a finding has none). */
export function findingKey(f) {
  const path = String(f.location ?? "").trim().replace(/(?::\d+(?:-\d+)?|#L\d+(?:-L?\d+)?)$/, "");
  const issue = String(f.issue || f.criterion || "").replace(/\s+/g, " ").trim().toLowerCase();
  return `${f.severity}\u0000${path}\u0000${issue}`;
}

/**
 * `latestFindings`, then each earlier finding the latest does not repeat, marked `carried`. A carried
 * finding drops its triage verdict unless `keepVerdicts` (the feature review's promotion used them).
 */
export function carryFindings(earlierRecords, latestFindings, { keepVerdicts = false } = {}) {
  const seen = new Set(latestFindings.map(findingKey));
  const carried = [];
  for (const rec of earlierRecords) {
    for (const f of rec.findings ?? []) {
      const key = findingKey(f);
      if (seen.has(key)) continue;
      seen.add(key);
      const { verdict, rationale, ...rest } = keepVerdicts ? { ...f } : f;
      carried.push({ ...(keepVerdicts ? f : rest), carried: true });
    }
  }
  return [...latestFindings, ...carried];
}

/** Findings at `level` ("critical" | "high" | "medium" | "none", afk.fixFindings) or more severe. */
export function findingsAtOrAbove(findings, level) {
  const cut = SEVERITIES.indexOf(String(level).toUpperCase());
  if (cut < 0) return [];
  return findings.filter((f) => {
    const i = SEVERITIES.indexOf(f.severity);
    return i >= 0 && i <= cut;
  });
}

/** The severities `level` promotes, as `defer` records them: "CRITICAL, HIGH" for `high`. */
export function severityNames(level) {
  return [...new Set(findingsAtOrAbove(SEVERITIES.map((severity) => ({ severity })), level).map((f) => f.severity))].join(", ");
}

/** What a sprint promotes under `level`: "actionable", or the severities ("CRITICAL, HIGH"); the one such table. */
export function promoteSeverities(level) {
  return level === "actionable" ? "actionable" : severityNames(level);
}

function triageFromStructured(raw, obj) {
  return {
    ok: true,
    parsedFrom: "json",
    fixable: String(obj.fixable).toLowerCase() !== "no",
    category: obj.category ? String(obj.category).trim() : "unspecified",
    detail: obj.detail ? String(obj.detail).trim() : "",
    raw,
  };
}

/** Fails closed toward `fixable`: a missing verdict must not strand an issue a retry could still fix. */
export function parseTriageReport(text, sidecar = null) {
  const raw = text ?? "";
  if (sidecar && sidecar.fixable != null) return triageFromStructured(raw, sidecar);
  return {
    ok: false,
    fixable: true,
    category: "",
    detail: sidecar
      ? "the triage report.json has no valid fixable field"
      : "no report.json — triage never wrote its verdict file",
    raw,
  };
}

/** A flag a model wrote as a boolean, or as the word. */
const isYes = (v) => v === true || ["true", "yes"].includes(String(v).trim().toLowerCase());

/**
 * All-or-nothing: a missing, unknown or duplicate entry makes the whole answer `ok: false`, and the
 * caller falls back to the severity rule rather than promote on a half-read verdict.
 */
export function parseFindingsTriage(sidecar, count) {
  if (!sidecar) return { ok: false, detail: "no report.json — triage never wrote its verdict file" };
  if (!Array.isArray(sidecar.findings)) return { ok: false, detail: "the triage report.json has no findings array" };
  const verdicts = new Array(count).fill(null);
  for (const e of sidecar.findings) {
    const i = Number(e?.index);
    const verdict = String(e?.verdict ?? "").toLowerCase();
    if (!Number.isInteger(i) || i < 0 || i >= count) return { ok: false, detail: `the triage report.json names finding ${JSON.stringify(e?.index)}, outside 0..${count - 1}` };
    if (!FINDING_VERDICTS.includes(verdict)) return { ok: false, detail: `the triage report.json gives finding ${i} the verdict ${JSON.stringify(e?.verdict)}` };
    if (verdicts[i]) return { ok: false, detail: `the triage report.json judges finding ${i} twice` };
    const dup = e.duplicate_of;
    const hasDup = dup !== undefined && dup !== null;
    if (hasDup && (!Number.isInteger(dup) || dup < 0 || dup >= count)) return { ok: false, detail: `the triage report.json gives finding ${i} a duplicate_of ${JSON.stringify(dup)}, outside 0..${count - 1}` };
    if (hasDup && dup === i) return { ok: false, detail: `the triage report.json makes finding ${i} a duplicate of itself` };
    verdicts[i] = {
      verdict,
      rationale: e.rationale ? String(e.rationale).trim() : "",
      adr: isYes(e.adr),
      protected: isYes(e.protected),
      ...(hasDup ? { duplicate_of: dup } : {}),
    };
  }
  const missing = verdicts.findIndex((v) => !v);
  if (missing >= 0) return { ok: false, detail: `the triage report.json leaves finding ${missing} unjudged` };
  const chained = verdicts.findIndex((v) => v.duplicate_of !== undefined && verdicts[v.duplicate_of].duplicate_of !== undefined);
  if (chained >= 0) return { ok: false, detail: `the triage report.json makes finding ${chained} a duplicate of finding ${verdicts[chained].duplicate_of}, which is itself a duplicate` };
  return { ok: true, verdicts };
}

/**
 * Paths no unattended fix may touch: the shared rubric's list, enforced in code so a triage verdict
 * of Actionable cannot send a coder at them.
 */
const PROTECTED_PATH = [
  /(^|\/)\.github\/(workflows|actions)\//,
  /(^|\/)\.gitlab-ci\.ya?ml$/,
  /(^|\/)Jenkinsfile/,
  /(^|\/)\.circleci\//,
  /(^|\/)azure-pipelines\.ya?ml$/,
  /(^|\/)\.env(\.|$)/,
  /(^|\/)(auth|authn|authz|authentication|authorization|oauth|security|secrets?|credentials?)([\/._-]|$)/i,
  /(^|\/)(deploy|deployment|deployments)([\/._-]|$)/i,
  /(^|\/)(Dockerfile|docker-compose[^/]*\.ya?ml)$/,
  /(^|\/)(terraform|k8s|helm)\//,
];

/** The file part of a finding's `location` ("src/a.ts:12" → "src/a.ts"). */
function locationPath(location) {
  return String(location ?? "").trim().replace(/:\d+(-\d+)?(:\d+)?$/, "").replace(/^\.\//, "");
}

/** Whether a finding's only basis is the design standard: crew-reviewer starts its `issue` so. */
function isDesignOnly(finding) {
  return String(finding.issue ?? "").trim().startsWith("Design standard (criterion");
}

export function touchesProtectedPath(location) {
  const path = locationPath(location);
  return path !== "" && PROTECTED_PATH.some((re) => re.test(path));
}

/** Triage's verdicts, then the hard rules: an ADR conflict, a protected path or a design-only basis forces Debatable. */
export function applyFindingVerdicts(findings, verdicts) {
  return findings.map((f, i) => {
    const t = verdicts[i];
    let { verdict, rationale } = t;
    // Auto never dismisses: a doubted finding goes to the coder's premise check instead.
    if (verdict === "dismiss") {
      verdict = "actionable";
      rationale = `${rationale ? `${rationale} ` : ""}[remapped dismiss → actionable: auto triage does not dismiss]`;
    }
    const forced = [];
    if (t.adr) forced.push("contradicts a documented decision (ADR / CONTEXT.md)");
    if (t.protected || touchesProtectedPath(f.location)) forced.push("its fix touches a protected path (CI config, auth, deploy, .env)");
    if (isDesignOnly(f)) forced.push("its only basis is the design standard, which is advisory");
    if (forced.length && verdict !== "debatable") {
      verdict = "debatable";
      rationale = `${rationale ? `${rationale} ` : ""}[forced Debatable: ${forced.join("; ")}]`;
    }
    return { ...f, verdict, rationale, ...(t.duplicate_of !== undefined ? { duplicate_of: t.duplicate_of } : {}) };
  });
}


/** Folds `duplicate_of` findings into promotable targets; one whose target is not promotable stays, so the defect is not lost. */
export function foldDuplicates(judged, promotable) {
  const folded = new Map();
  judged.forEach((f, i) => {
    if (f.duplicate_of === undefined || !promotable.includes(judged[f.duplicate_of])) return;
    const t = folded.get(f.duplicate_of) ?? { ...judged[f.duplicate_of] };
    if (SEVERITY_RANK[f.severity] < SEVERITY_RANK[t.severity]) t.severity = f.severity;
    if (f.location && f.location !== t.location) {
      t.criterion = `${t.criterion} (also at ${f.location})`;
      t.location = t.location ? `${t.location}, ${f.location}` : f.location;
    }
    folded.set(f.duplicate_of, t);
  });
  const folds = (f) => f.duplicate_of !== undefined && promotable.includes(judged[f.duplicate_of]);
  return promotable.filter((f) => !folds(f)).map((f) => folded.get(judged.indexOf(f)) ?? f);
}

/** findingsFromStructured drops entries with no valid severity, so the sidecar's own list is walked in step. */
export function annotateFindings(sidecar, findings) {
  let k = 0;
  const annotated = (Array.isArray(sidecar.findings) ? sidecar.findings : []).map((f) => {
    if (!f || !SEVERITIES.includes(String(f.severity).toUpperCase())) return f;
    const v = findings[k++];
    return v ? { ...f, verdict: v.verdict, rationale: v.rationale, ...(v.duplicate_of !== undefined ? { duplicate_of: v.duplicate_of } : {}) } : f;
  });
  return { ...sidecar, findings: annotated };
}
