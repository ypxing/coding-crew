/**
 * github.mjs — the GitHub Issues tracker backend. Read path only (issue 04); the write
 * path (`writeProgress`, `markDone`, `createIssue`, milestone/label bootstrap) is added on
 * top of this same module by issue 05.
 *
 * Backed by the `gh` CLI via `execFile`-style argv shelling-out (no shell string, no REST
 * client dependency) — the same argv-array pattern `dispatch.mjs`'s `effects.exec` uses.
 * `exec` is an injectable `(cmd, args) => {code, stdout, stderr}` so tests stub `gh`
 * without touching `PATH`; it defaults to a real `execFileSync`-backed shell-out.
 *
 * `listOpen` is the one place a network round trip happens: exactly one `gh issue list`
 * call per invocation, `--state all` and parsed client-side, never a call per issue — the
 * N+1 this design exists to avoid (see `.scratch/github-issue-tracker/PRD.md`).
 * `parseIssue` stays pure and I/O-free over one already-fetched issue's JSON, sharing the
 * markdown-body parsing in `./body-format.mjs` with the local backend so both backends'
 * output shape is identical without duplicating the parsing.
 */

import { execFileSync } from "node:child_process";

import { readTrackerConfig } from "../tracker-config.mjs";
import { criteriaSection, extractBlockedByNumbers, isSourceGuarded, sectionBody } from "./body-format.mjs";

export const READY_STATUS = "ready-for-agent";

/** Real `gh` invocation: argv array, no shell. Normalizes a thrown non-zero exit the same
 * shape as a clean one, so callers only ever branch on `.code`. */
function shellOut(cmd, args) {
  try {
    const stdout = execFileSync(cmd, args, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
    return { code: 0, stdout, stderr: "" };
  } catch (err) {
    return {
      code: typeof err.status === "number" ? err.status : 1,
      stdout: err.stdout ?? "",
      stderr: err.stderr ?? String(err.message ?? err),
    };
  }
}

/** Only the 4 pre-created triage labels are real GitHub labels (see PRD Labels decision);
 * `done`/`wontfix` are close-states, not labels, and are resolved from `state` instead. */
const TRIAGE_LABELS = ["needs-triage", "needs-info", "ready-for-agent", "ready-for-human"];

/** Deterministic kebab-case slug derived from an issue title — GitHub has no filename to
 * derive one from, and nothing here needs caching (see PRD's Slug/branch mapping decision). */
function titleSlug(title) {
  return title
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

/** `done` is GitHub's native closed state, not a label; open issues take their status from
 * whichever triage label is present, or "" when none is (matches local's untriaged issues). */
function statusOf({ state, labels = [] }) {
  if (String(state).toUpperCase() === "CLOSED") return "done";
  const names = new Set((labels ?? []).map((l) => (typeof l === "string" ? l : l.name)));
  return TRIAGE_LABELS.find((name) => names.has(name)) ?? "";
}

/**
 * A pure, no-I/O transform over one already-fetched `gh issue list --json ...` entry.
 * Produces the exact same shape as `local.mjs`'s `parseIssue`; `blockedBy`/`criteria`/
 * `sourceGuarded` are computed by calling into `body-format.mjs` on the issue body, not
 * reimplemented. Unlike local, a matched `## Blocked by` number *is* the blocker's ref
 * already — no filename lookup — so `blockedBy` holds bare issue numbers.
 */
export function parseIssue(json) {
  const text = json.body ?? "";
  const blockedBySection = sectionBody(text, "Blocked by") ?? "";
  const blockedBy = extractBlockedByNumbers(blockedBySection).map(Number);
  return {
    ref: json.number,
    slug: titleSlug(json.title ?? ""),
    number: json.number,
    title: json.title ?? "",
    status: statusOf(json),
    blockedBy,
    criteria: criteriaSection(text),
    sourceGuarded: isSourceGuarded(text),
    hasProgress: sectionBody(text, "Progress") !== null,
    hasBlocked: sectionBody(text, "Blocked") !== null,
    text,
  };
}

/**
 * Every issue in the feature's milestone, `--state all` (open and closed — closed states
 * are how a blocker resolves), fetched and parsed via exactly one `gh issue list` call.
 * `--repo` is passed only when `readTrackerConfig` names one; omitted, `gh` infers it from
 * the git remote. A milestone that does not exist yet is an empty sprint, not an error.
 */
export function listOpen(mainRoot, { featureSlug, exec = shellOut } = {}) {
  const { repo } = readTrackerConfig(mainRoot);
  const args = ["issue", "list"];
  if (repo) args.push("--repo", repo);
  args.push("--milestone", featureSlug, "--state", "all", "--json", "number,title,body,labels,state");

  const r = exec("gh", args);
  if (r.code !== 0) {
    // A milestone not created yet (nothing has written to this feature's tracker) is a
    // valid empty sprint, not a failure — `gh` reports it as an unresolvable filter.
    if (/milestone/i.test(r.stderr ?? "")) return [];
    throw new Error(`gh issue list failed (exit ${r.code}): ${r.stderr || r.stdout}`);
  }

  const raw = r.stdout && r.stdout.trim() ? JSON.parse(r.stdout) : [];
  return raw.map(parseIssue);
}

/**
 * Ready and unblocked. One `listOpen` fetch (all states) builds an in-memory
 * `number → status` map reused to resolve every candidate's blockers — mirrors how local's
 * `doneFiles()` is one directory read reused across every issue in the same call. A blocker
 * counts as resolved once its own status is `done` (closed); anything else, including a
 * blocker number absent from this milestone entirely, still blocks.
 */
export function selectDispatchable(mainRoot, { status = READY_STATUS, featureSlug, exec } = {}) {
  const issues = listOpen(mainRoot, { featureSlug, exec });
  const statusByNumber = new Map(issues.map((i) => [i.number, i.status]));
  const ready = issues.filter((i) => i.status === status);
  return ready
    .map((i) => ({ ...i, blockers: i.blockedBy.filter((n) => statusByNumber.get(n) !== "done") }))
    .filter((i) => i.blockers.length === 0);
}
