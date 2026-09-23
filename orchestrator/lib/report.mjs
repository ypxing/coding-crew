/**
 * report.mjs — parse what the models return, and apply the schema pre-filter.
 *
 * One file, one schema, one parser, fail closed: every role (coder/triage/review) writes
 * its result to a `<slug>.<role>.report.json` sidecar as its own last action, and that file
 * is the *only* thing read here — never the dispatch's captured text. There is no fallback
 * to a fenced ```json block in the final message or to markdown headings; a missing or
 * invalid sidecar is read as the failure state (`blocked` / `unmet` / `fixable`, per role),
 * deterministically, the same way for every platform.
 *
 * The reviewer's report carries two things the pipeline gates on: the `AC:`-equivalent
 * `verdict` field and the findings list. Both fail closed — a missing or unreadable sidecar
 * is `unmet`, a review that did not happen.
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

/**
 * Every fenced ```json block in `text` whose parsed object has `requiredField` set,
 * in document order. JSON's own grammar treats whitespace between tokens as
 * insignificant, so this is immune to the indentation a herdr-captured pane transcript
 * sometimes adds — unlike a line-anchored regex or awk pattern, which is not.
 *
 * The only remaining caller is parseReviewAggregate: the round-aggregate file is a
 * concatenation of several dispatches' sidecar contents (see pipeline.mjs's runReview),
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
    unparseable,
    raw,
  };
}

/**
 * @param {string|null} text  the worker's captured dispatch text — kept only as `raw` for a
 *   human reading a blocked report; never parsed
 * @param {object|null} sidecar  parsed <slug>.report.json, when the worker wrote one
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

/**
 * ensure-deps.sh's single `DEPS:` line, or "" when there is none (a dry run records the
 * command and produces no output).
 *
 * Read and logged, never branched on: an install failure is diagnosed by the verify gate
 * that follows it, so a DEPS: outcome must not be able to demote an issue or change a
 * round's status. Extracting the line is all the orchestrator does with it.
 */
export function depsLine(stdout) {
  const m = /^DEPS:.*$/m.exec(stdout ?? "");
  return m ? m[0].trim() : "";
}

const SEVERITIES = ["CRITICAL", "HIGH", "MEDIUM", "LOW"];
const VERDICTS = new Set(["all-met", "unmet", "not_run"]);

function findingsFromStructured(list) {
  if (!Array.isArray(list)) return [];
  return list
    .filter((f) => f && SEVERITIES.includes(String(f.severity).toUpperCase()))
    .map((f) => ({
      severity: String(f.severity).toUpperCase(),
      location: f.location ? String(f.location).trim() : "",
      criterion: f.criterion ? String(f.criterion).trim() : "",
      explicit: true,
    }));
}

/**
 * One branch's structured verdict, out of a fenced ```json block: `{branch, slug,
 * verdict, detail, findings}`. Both `code_review_summary()` and `promote-findings.sh
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
    findings: findingsFromStructured(obj.findings),
    raw,
  };
}

/**
 * Reviewer output for one branch. The `<slug>.review.report.json` sidecar (see
 * parseWorkerReport's own sidecar policy) is the only thing read — never the captured text.
 *
 * @param {string|null} text  the reviewer's captured dispatch text — kept only as `raw`
 * @param {object|null} sidecar  parsed <slug>.review.report.json, when the reviewer wrote one
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

export function findingsAtOrAbove(findings, threshold /* "critical" | "critical-high" */) {
  const allowed = threshold === "critical-high" ? ["CRITICAL", "HIGH"] : ["CRITICAL"];
  return findings.filter((f) => allowed.includes(f.severity));
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
 * The `<slug>.triage.report.json` sidecar (see parseWorkerReport's own sidecar policy) is
 * the only thing read — never the captured text.
 *
 * @param {string|null} text  the triage agent's captured dispatch text — kept only as `raw`
 * @param {object|null} sidecar  parsed <slug>.triage.report.json, when it wrote one
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
