/**
 * github.mjs — the GitHub Issues tracker backend.
 *
 * Backed by the `gh` CLI via `execFile`-style argv shelling-out (no shell string, no REST
 * client dependency) — the same argv-array pattern `dispatch.mjs`'s `effects.exec` uses.
 * `exec` is an injectable `(cmd, args) => {code, stdout, stderr}` so tests stub `gh`
 * without touching `PATH`; it defaults to a real `execFileSync`-backed shell-out.
 *
 * Read path (issue 04): `listOpen` is the one place a network round trip happens for
 * dispatchability: exactly one `gh issue list` call per invocation, `--state all` and
 * parsed client-side, never a call per issue — the N+1 this design exists to avoid (see
 * `.scratch/github-issue-tracker/PRD.md`). `parseIssue` stays pure and I/O-free over one
 * already-fetched issue's JSON, sharing the markdown-body parsing in `./body-format.mjs`
 * with the local backend so both backends' output shape is identical without duplicating
 * the parsing.
 *
 * Write path (issue 05): `createIssue`, `markDone`, `writeProgress`. `createIssue` lazily
 * bootstraps the feature's milestone (list-first, idempotent) and passes the caller's
 * `body` through to `gh issue create --body-file` unmodified — the producer side of the
 * `## Blocked by`/`Source:` prose flow issues 07/08 write and issue 04's `parseIssue` reads
 * back. `markDone` re-fetches the issue body live before checking criteria, mirroring
 * `scripts/tracker/mark-issue-done.sh`'s github branch (never trusting a cached
 * `issue.text` a caller might be holding from an earlier `listOpen`). `writeProgress`
 * always posts a new `gh issue comment` — a GitHub comment thread is a timeline, not an
 * in-place-edited section, so every call is a new comment, deliberately, including for a
 * `## Blocked` write (there is no `blocked` label anywhere in this module).
 */

import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { readTrackerConfig } from "../tracker-config.mjs";
import {
  criteriaSection,
  extractBlockedByNumbers,
  isSourceGuarded,
  sectionBody,
  uncheckedCriteria,
} from "./body-format.mjs";

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
/** The feature's PRD: a milestone issue by title convention, not a work issue (to-prd). */
export const isPrdIssue = (issue) => /^PRD:/.test(issue.title ?? "");

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

/** `repos/{owner}/{repo}/milestones` when `repo` is unset, letting `gh` resolve the
 * placeholder from the git remote (this `gh` version's `api` subcommand has no `--repo`
 * flag); the literal `owner/name` path otherwise, so a `readTrackerConfig` override is
 * honored the same way it is for every `gh issue ...` call in this module. */
function milestonesPath(repo) {
  return repo ? `repos/${repo}/milestones` : "repos/{owner}/{repo}/milestones";
}

/**
 * Ensure a milestone named `featureSlug` exists, list-first so a second call for the
 * same slug makes no create request — idempotent, as `createIssue` needs since it calls
 * this on every publish, not just the feature's first.
 */
function ensureMilestone(featureSlug, { repo, exec }) {
  const path = milestonesPath(repo);
  const list = exec("gh", ["api", path]);
  if (list.code !== 0) {
    throw new Error(`gh api milestones list failed (exit ${list.code}): ${list.stderr || list.stdout}`);
  }
  const milestones = list.stdout && list.stdout.trim() ? JSON.parse(list.stdout) : [];
  if (milestones.some((m) => m.title === featureSlug)) return;

  const created = exec("gh", ["api", path, "-f", `title=${featureSlug}`]);
  if (created.code !== 0) {
    throw new Error(`gh api milestone create failed (exit ${created.code}): ${created.stderr || created.stdout}`);
  }
}

/**
 * Create a work (or PRD) issue in the feature's milestone, bootstrapping the milestone
 * first. `body` is written through unmodified via a throwaway `--body-file` — this
 * function does not add or strip `## Blocked by`/`Source:` prose; that is the caller's
 * (issues 07/08's) job. Returns `{number, url}` parsed from `gh issue create`'s printed
 * URL, so a caller citing this issue as a blocker (issue 06's `to-issues` flow) has the
 * number without a second fetch.
 */
export function createIssue({ title, body, labels = [], featureSlug }, { mainRoot, exec = shellOut } = {}) {
  const { repo } = readTrackerConfig(mainRoot);
  ensureMilestone(featureSlug, { repo, exec });

  const bodyFile = join(tmpdir(), `crew-github-issue-${randomUUID()}.md`);
  writeFileSync(bodyFile, body);
  try {
    const args = ["issue", "create"];
    if (repo) args.push("--repo", repo);
    args.push("--title", title, "--body-file", bodyFile);
    for (const label of [].concat(labels).filter(Boolean)) args.push("--label", label);
    args.push("--milestone", featureSlug);

    const result = exec("gh", args);
    if (result.code !== 0) {
      throw new Error(`gh issue create failed (exit ${result.code}): ${result.stderr || result.stdout}`);
    }
    const url = result.stdout.trim();
    const match = /\/(\d+)\s*$/.exec(url);
    return { number: match ? Number(match[1]) : null, url };
  } finally {
    try {
      unlinkSync(bodyFile);
    } catch {
      // best-effort cleanup of a throwaway temp file — nothing depends on it surviving.
    }
  }
}

/**
 * Close an issue as done — `gh issue close --reason completed`, no label added or
 * removed (the closed state itself is "done"; see the PRD's Labels decision). Before
 * closing, re-fetches the issue body live (`gh issue view --json body`) and checks
 * criteria against *that* fetch, never against `issue.text`/any other field the caller
 * might be holding from an earlier `listOpen` — a human may have edited the issue since.
 * Refuses (throws, without closing) while any criterion is still unchecked.
 */
export function markDone(issue, { mainRoot, exec = shellOut } = {}) {
  const { repo } = readTrackerConfig(mainRoot);
  const repoArgs = repo ? ["--repo", repo] : [];

  const view = exec("gh", ["issue", "view", String(issue.number), ...repoArgs, "--json", "body", "--jq", ".body"]);
  if (view.code !== 0) {
    throw new Error(`gh issue view failed (exit ${view.code}): ${view.stderr || view.stdout}`);
  }
  const freshBody = view.stdout.replace(/\n$/, "");

  const unchecked = uncheckedCriteria(freshBody);
  if (unchecked.length > 0) {
    throw new Error(`markDone: issue #${issue.number} still has unchecked criteria:\n${unchecked.join("\n")}`);
  }

  const close = exec("gh", ["issue", "close", String(issue.number), ...repoArgs, "--reason", "completed"]);
  if (close.code !== 0) {
    throw new Error(`gh issue close failed (exit ${close.code}): ${close.stderr || close.stdout}`);
  }
  return close;
}

/**
 * Post `body` as a new `gh issue comment` under `## <heading>` — never an in-place edit
 * of an existing comment or the issue body; local's `{append}` splice/append distinction
 * (see `local.mjs`'s `writeIssueSection`) does not apply here. `heading` is typically
 * `"Progress"` or `"Blocked"`; a `## Blocked` write is not special-cased — it is this
 * same comment path, and there is no `blocked` label anywhere in this module.
 */
export function writeProgress(issue, body, { heading = "Progress", mainRoot, exec = shellOut } = {}) {
  const { repo } = readTrackerConfig(mainRoot);
  const repoArgs = repo ? ["--repo", repo] : [];
  const commentBody = `## ${heading}\n\n${body}`;

  const result = exec("gh", ["issue", "comment", String(issue.number), ...repoArgs, "--body", commentBody]);
  if (result.code !== 0) {
    throw new Error(`gh issue comment failed (exit ${result.code}): ${result.stderr || result.stdout}`);
  }
  return result;
}

/**
 * CLI entry point — the shape `promote-findings.sh`'s `_defer_github` shells out to
 * (`node github.mjs create-issue --title ... --body-file ... --feature-slug ...
 * [--label ...] [--main-root ...]`), the same "bash calls a small Node CLI" pattern
 * `review-rollup.mjs` already established for `promote-findings.sh`'s `remind`. Without
 * this, the bash script would have to hand-roll its own `gh issue create` + milestone
 * bootstrap — a second implementation of `createIssue` that can (and did) drift from this
 * one. Prints the created issue's URL to stdout, matching `gh issue create`'s own stdout,
 * so callers see the exact same value either way.
 */
function cliCreateIssue(argv) {
  const opts = { labels: [] };
  for (let i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case "--title":
        opts.title = argv[++i];
        break;
      case "--body-file":
        opts.bodyFile = argv[++i];
        break;
      case "--feature-slug":
        opts.featureSlug = argv[++i];
        break;
      case "--label":
        opts.labels.push(argv[++i]);
        break;
      case "--main-root":
        opts.mainRoot = argv[++i];
        break;
      default:
        throw new Error(`create-issue: unknown argument: ${argv[i]}`);
    }
  }
  if (!opts.title || !opts.bodyFile || !opts.featureSlug) {
    throw new Error("create-issue requires --title, --body-file, and --feature-slug");
  }
  const body = readFileSync(opts.bodyFile, "utf8");
  const { url } = createIssue(
    { title: opts.title, body, labels: opts.labels, featureSlug: opts.featureSlug },
    { mainRoot: opts.mainRoot ?? process.cwd() },
  );
  process.stdout.write(`${url}\n`);
}

/**
 * `prd --feature-slug <slug> [--main-root <dir>]` — print the milestone's PRD issue body, for
 * prd-audit.sh, which has no local PRD.md under github. Exit 3 when the milestone has none.
 */
function cliPrd(argv) {
  const opts = {};
  for (let i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case "--feature-slug":
        opts.featureSlug = argv[++i];
        break;
      case "--main-root":
        opts.mainRoot = argv[++i];
        break;
      default:
        throw new Error(`prd: unknown argument: ${argv[i]}`);
    }
  }
  if (!opts.featureSlug) throw new Error("prd requires --feature-slug");
  const prd = listOpen(opts.mainRoot ?? process.cwd(), { featureSlug: opts.featureSlug }).find(isPrdIssue);
  if (!prd) {
    process.exitCode = 3;
    return;
  }
  process.stdout.write(`<!-- PRD issue #${prd.number}: ${prd.title} -->\n${prd.text}\n`);
}

function cliMain(argv) {
  const [command, ...rest] = argv;
  if (command === "create-issue") return cliCreateIssue(rest);
  if (command === "prd") return cliPrd(rest);
  throw new Error(`unknown command: ${command}`);
}

const isMain = process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1];
if (isMain) {
  try {
    cliMain(process.argv.slice(2));
  } catch (err) {
    process.stderr.write(`${err.message}\n`);
    process.exitCode = 1;
  }
}
