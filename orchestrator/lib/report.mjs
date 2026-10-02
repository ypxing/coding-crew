/**
 * report.mjs — parse what the models return, and apply the schema pre-filter.
 *
 * One file, one schema, one parser, fail closed: every role (coder/triage/review) writes
 * its result to a `report.json` (or `triage.report.json` / `review.report.json`) sidecar
 * in the issue's own dispatch subdirectory as its own last action, and that file
 * is the *only* thing read here — never the dispatch's captured text. There is no fallback
 * to a fenced ```json block in the final message or to markdown headings; a missing or
 * invalid sidecar is read as the failure state (`blocked` / `unmet` / `fixable`, per role),
 * deterministically, the same way for every platform.
 *
 * The reviewer's report carries two things the pipeline gates on: the `AC:`-equivalent
 * `verdict` field and the findings list. Both fail closed — a missing or unreadable sidecar
 * is `unmet`, a review that did not happen.
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

/**
 * Every fenced ```json block in `text` whose parsed object has `requiredField` set,
 * in document order. JSON's own grammar treats whitespace between tokens as
 * insignificant, so this is immune to the indentation a herdr-captured pane transcript
 * sometimes adds — unlike a line-anchored regex or awk pattern, which is not.
 *
 * Callers: parsePrdAudit (one audit report), and parseReviewAggregate: the round-aggregate file is a
 * concatenation of several dispatches' sidecar contents (see pipeline/review.mjs's runReview),
 * appended as fenced json blocks so a later retry's block can be told apart from an
 * earlier one for the same branch. Per-dispatch parsing (parseWorkerReport,
 * parseReviewReport, parseTriageReport) reads the sidecar object directly and never
 * scans text for a fence.
 */
function allFencedJson(text, requiredField) {
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

/**
 * `{ command, exit, output, truncated }` — the one command a coder ran that shows why it
 * stopped, or null when it gave none. Only ever read as the coder's claim: triage weighs it
 * against the diff.
 */
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
  // Any further dev-commands.json check the coder ran (coverage, integration) rides in `checks`
  // beside the base three, so the pre-filter can stop on a failure the coder already admitted,
  // before any gate runs. verify-worktree.sh runs every cached check itself either way.
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

/**
 * The one blocked shape every missing-or-invalid-sidecar case collapses to — same fields as
 * fromStructured's success shape, so a caller never has to branch on which one it got before
 * reading `status`/`checks`/`criteria`.
 */
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

/**
 * @param {string|null} text  the worker's captured dispatch text — kept only as `raw` for a
 *   human reading a blocked report; never parsed
 * @param {object|null} sidecar  parsed report.json, when the worker wrote one
 */
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
 * The schema pre-filter, identical in policy to verify-worktree.sh so the two
 * gates cannot disagree: a failing check or an un-run test demotes `complete`,
 * while lint/typecheck `not_run` is a recorded coverage gap, not a demotion —
 * many repos legitimately have neither, and demoting there stalls every sprint.
 * A further check the coder did not run is left to verify-worktree.sh, which runs it anyway.
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
 * verify-worktree.sh's own record (`verify.json`, in the issue's dispatch subdirectory), read back as the check evidence the
 * reviewer is given.
 *
 * The reviewer cannot run commands, so a criterion phrased "…and the tests pass" is
 * unprovable from a diff and reads as `unmet` — which stalled every sprint whose issues
 * were written that way. The pipeline has already run those checks in the branch's
 * worktree and gated the merge on the result; passing that result on is what makes the
 * criteria check answerable without weakening it. `not_run` is never evidence, and a
 * missing or unreadable record is every base check `not_run`.
 *
 * `logs` maps each check to its full-output file, so a reviewer can read a figure (a coverage
 * percentage) pass/fail cannot carry; `notConfigured` names the cached checks set to `null`,
 * which the gate never runs, so a criterion resting on one visibly has no evidence; `missing`
 * maps each check that failed on a command not installed (exit 127) to that command.
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

/**
 * ensure-deps.sh's single `DEPS:` line, or "" when there is none (a dry run records the
 * command and produces no output).
 *
 * Extracting the line is all this does; pipeline.mjs stops an issue on a per-issue
 * `DEPS: failed`, main.mjs stops the run on a sprint-level `DEPS: docker-failed`, and nothing
 * else in the line changes a round's status.
 */
export function depsLine(stdout) {
  const m = /^DEPS:.*$/m.exec(stdout ?? "");
  return m ? m[0].trim() : "";
}

/**
 * check-requires.sh's failures, per issue file: `Map<file, [{ command, status, output }]>`.
 * `files` are the paths it was given — a `REQUIRE: fail <file> <cmd>` line is matched on them,
 * not split on a space, since a path or a command may contain one. `status` is its `exit N` /
 * `timed out after Ns` line; `output` the `| `-prefixed tail below it.
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
const VERDICTS = new Set(["all-met", "unmet", "not_run"]);
/** Findings triage's answer per finding (the shared rubric: skills/_shared/fragments/common/findings-rubric.md). */
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
      // Written beside the finding once findings triage has judged it (annotateFindings below).
      ...(FINDING_VERDICTS.includes(String(f.verdict).toLowerCase())
        ? { verdict: String(f.verdict).toLowerCase(), rationale: f.rationale ? String(f.rationale).trim() : "" }
        : {}),
    }));
}

/**
 * One branch's structured verdict, out of a fenced ```json block: `{branch, slug,
 * verdict, detail, cause, findings}`. Both `code_review_summary()` and `promote-findings.sh
 * remind` used to re-derive this from the same raw text with their own line-anchored
 * awk, and drifted out of sync — this is the one parser both now call through instead
 * (see orchestrator/review-rollup.mjs).
 */
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
    raw,
  };
}

/**
 * Reviewer output for one branch. The `review.report.json` sidecar (see
 * parseWorkerReport's own sidecar policy) is the only thing read — never the captured text.
 *
 * @param {string|null} text  the reviewer's captured dispatch text — kept only as `raw`
 * @param {object|null} sidecar  parsed review.report.json, when the reviewer wrote one
 */
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

/**
 * The aggregate `reviews/sprint-review-*.md` file(s): several dispatches' raw text,
 * appended in creation order across rounds and retries. Folds to one record per
 * branch, later block wins — a retry's real verdict overrides an earlier `not_run`
 * stub for the same branch, the same fold semantics `code_review_summary()`'s awk used
 * to implement by hand. This is the one place that fold happens now; `crew-summary.sh`
 * and `promote-findings.sh remind` both read its output (see
 * orchestrator/review-rollup.mjs) instead of re-parsing the file themselves.
 */
export function parseReviewAggregate(text) {
  const raw = text ?? "";
  const order = [];
  const byBranch = new Map();
  for (const obj of allFencedJson(raw, "verdict")) {
    const rec = reviewFromStructured(raw, obj);
    const key = rec.branch ?? `#${order.length}`;
    if (!byBranch.has(key)) order.push(key);
    byBranch.set(key, rec);
  }
  return order.map((key) => byBranch.get(key));
}

const SEVERITY_ORDER = ["CRITICAL", "HIGH", "MEDIUM", "LOW"];

/** Findings at `level` ("critical" | "high" | "medium" | "none", afk.fixFindings) or more severe. */
export function findingsAtOrAbove(findings, level) {
  const cut = SEVERITY_ORDER.indexOf(String(level).toUpperCase());
  if (cut < 0) return [];
  return findings.filter((f) => {
    const i = SEVERITY_ORDER.indexOf(f.severity);
    return i >= 0 && i <= cut;
  });
}

/** The severities `level` promotes, as `defer` records them: "CRITICAL, HIGH" for `high`. */
export function severityNames(level) {
  return [...new Set(findingsAtOrAbove(SEVERITY_ORDER.map((severity) => ({ severity })), level).map((f) => f.severity))].join(", ");
}

/**
 * One triage sidecar or fenced-json object, normalised — shared by the sidecar branch and
 * the in-text fenced-json branch below so the two can never drift on field handling.
 */
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

/**
 * Triage report. Dispatched only after verify-worktree.sh already failed, to answer one
 * question independently of the coder that wrote the branch (the same reason review is
 * independent of the coder, not a self-grade): is this failure fixable by writing more
 * code on this branch, or is it an environment/infrastructure problem no amount of
 * recoding touches? Fails closed toward `fixable` — an unparseable or missing verdict
 * must not silently strand an issue that a normal retry could still fix.
 *
 * The `triage.report.json` sidecar (see parseWorkerReport's own sidecar policy) is
 * the only thing read — never the captured text.
 *
 * @param {string|null} text  the triage agent's captured dispatch text — kept only as `raw`
 * @param {object|null} sidecar  parsed triage.report.json, when it wrote one
 */
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
 * Findings triage (crew-triage's findings mode): `{"findings": [{index, verdict, rationale, adr?,
 * protected?}]}` — one entry per finding, `index` the 0-based position in the prompt's list. Only
 * the sidecar is read. All-or-nothing: a missing, unknown or duplicate entry makes the whole
 * answer `ok: false` — the caller falls back to the severity rule, as it does for no sidecar at
 * all, rather than promoting on a half-read verdict.
 *
 * @param {object|null} sidecar  parsed findings-triage.report.json
 * @param {number} count  how many findings were sent
 * @returns {{ok: true, verdicts: {verdict, rationale, adr, protected}[]} | {ok: false, detail: string}}
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
    verdicts[i] = {
      verdict,
      rationale: e.rationale ? String(e.rationale).trim() : "",
      adr: isYes(e.adr),
      protected: isYes(e.protected),
    };
  }
  const missing = verdicts.findIndex((v) => !v);
  if (missing >= 0) return { ok: false, detail: `the triage report.json leaves finding ${missing} unjudged` };
  return { ok: true, verdicts };
}

/**
 * Paths no unattended fix may touch: CI config, auth, deploy, secrets. The same list the shared
 * rubric gives crew-triage and /crew-address-findings; here it is enforced in code, so a triage
 * verdict of Actionable cannot send a coder at them.
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

/** Whether a finding's `location` names a protected path. */
export function touchesProtectedPath(location) {
  const path = locationPath(location);
  return path !== "" && PROTECTED_PATH.some((re) => re.test(path));
}

/**
 * Findings with triage's verdicts applied, the hard rules last: a finding that contradicts an
 * ADR / CONTEXT.md (triage's `adr` flag), or whose fix touches a protected path (triage's
 * `protected` flag, or the finding's own location), is Debatable whatever triage said.
 * Returns the findings with `verdict` and `rationale` written beside them.
 */
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
    if (forced.length && verdict !== "debatable") {
      verdict = "debatable";
      rationale = `${rationale ? `${rationale} ` : ""}[forced Debatable: ${forced.join("; ")}]`;
    }
    return { ...f, verdict, rationale };
  });
}

/**
 * The review's sidecar object with each finding's verdict and rationale written beside it, in
 * the order the sidecar lists them. `findings` is the normalised, verdict-bearing list from
 * applyFindingVerdicts, in the same order findingsFromStructured produced it (it drops entries
 * with no valid severity, so the sidecar's own list is walked in step).
 */
export function annotateFindings(sidecar, findings) {
  let k = 0;
  const annotated = (Array.isArray(sidecar.findings) ? sidecar.findings : []).map((f) => {
    if (!f || !SEVERITIES.includes(String(f.severity).toUpperCase())) return f;
    const v = findings[k++];
    return v ? { ...f, verdict: v.verdict, rationale: v.rationale } : f;
  });
  return { ...sidecar, findings: annotated };
}

/**
 * The PRD audit's closing fenced json (prd-audit.sh's prompt): `{covered, partial, missing:
 * [{requirement, detail}], superseded: [{requirement, by}]}`. The last such block wins, as the
 * prose above it may quote one. No block is `ok: false` — nothing is queued from prose. A
 * requirement listed as both missing and superseded is superseded: a later decision replaced it,
 * and queuing it would send a coder to build what was decided against.
 */
export function parsePrdAudit(text) {
  const last = allFencedJson(text ?? "", "missing").at(-1);
  if (!last || !Array.isArray(last.missing)) return { ok: false, missing: [], superseded: [] };
  const entries = (list, field) =>
    (Array.isArray(list) ? list : [])
      .map((m) => (typeof m === "string" ? { requirement: m } : m))
      .filter((m) => m && typeof m.requirement === "string" && m.requirement.trim())
      .map((m) => ({ requirement: m.requirement.trim(), [field]: typeof m[field] === "string" ? m[field].trim() : "" }));
  const superseded = entries(last.superseded, "by");
  const replaced = new Set(superseded.map((m) => m.requirement));
  const missing = entries(last.missing, "detail").filter((m) => !replaced.has(m.requirement));
  return { ok: true, missing, superseded };
}
