/**
 * github.mjs — the GitHub Issues tracker backend.
 *
 * Backed by the `gh` CLI via `execFile`-style argv shelling-out (no shell string, no REST
 * client dependency) — the same argv-array pattern `dispatch.mjs`'s `effects.exec` uses.
 * `exec` is an injectable `(cmd, args) => {code, stdout, stderr}` so tests stub `gh`
 * without touching `PATH`; it defaults to a real `execFileSync`-backed shell-out.
 *
 * Read path (issue 04): `listFeatureIssues` is the one place a network round trip happens for
 * dispatchability: exactly one `gh issue list` call per invocation, `--state all` and
 * parsed client-side, never a call per issue — the N+1 this design exists to avoid (see
 * `.scratch/github-issue-tracker/PRD.md`). `parseIssue` stays pure and I/O-free over one
 * already-fetched issue's JSON, sharing the markdown-body parsing in `./body-format.mjs`
 * with the local backend so both backends' output shape is identical without duplicating
 * the parsing.
 *
 * Write path (issue 05): `createIssue`, `writeProgress`. `createIssue` lazily
 * bootstraps the feature's milestone (list-first, idempotent) and passes the caller's
 * `body` through to `gh issue create --body-file` unmodified — the producer side of the
 * `## Blocked by`/`Source:` prose flow issues 07/08 write and issue 04's `parseIssue` reads
 * back. Marking an issue done is `scripts/tracker/mark-issue-done.sh`'s alone (close-issue.sh
 * calls it too), so there is one implementation of the label swap. `writeProgress`
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

import { readTrackerConfig } from "./tracker-config.mjs";
import {
  criteriaSection,
  isSourceGuarded,
  sectionBody,
} from "./body-format.mjs";

export const READY_STATUS = "ready-for-agent";

/** promote-findings.sh creates a fix issue `ready-for-agent` (no parked state to flush), and the
 * milestone listing lags the create, so the loop waits for it to appear. */
export const fixIssuesCreatedReady = true;

/** "Done" short of shipped: implemented and merged into the feature branch, closed only by the
 * `Closes #n` in the feature's PR once that merges. An open issue carrying it reads as `done`. */
export const AWAITING_MERGE_LABEL = "awaiting-merge";

/** Added by crew-afk (issue-labels.sh) when a run stops on an issue that needs a human; the
 * issue keeps `ready-for-agent`, but selectDispatchable skips it until a human removes this. */
export const BLOCKED_LABEL = "blocked";

/** POSIX single-quoting for the CREW_FAKE_GH command string below — same convention as
 * pane-host's shellQuote, kept local rather than imported so this tracker has no dependency
 * on the pane-host feature. */
function shQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

/** Real `gh` invocation: argv array, no shell. Normalizes a thrown non-zero exit the same
 * shape as a clean one, so callers only ever branch on `.code`. */
function shellOut(cmd, args) {
  // Test/CI seam, like CREW_FAKE_DISPATCH: a bash script stands in for `gh`. Run through bash
  // explicitly — on Windows execFileSync never reads a shebang and refuses a .cmd, so a stub
  // found by PATH alone loses to the real gh.exe.
  const fake = cmd === "gh" ? process.env.CREW_FAKE_GH : "";
  let env;
  if (fake) {
    // A single quoted `-c` string, not an argv array: `gh api`'s own `{owner}`/`{repo}`
    // placeholders (see milestonesPath below) are literal argv content that must survive
    // Windows' two-step translation into this MSYS-linked child — Node re-encodes the argv
    // array as one Win32 command-line string, then bash's MSYS runtime re-parses that string
    // into argv before bash itself starts, and that second parse has been observed to drop
    // an unquoted brace pair (`{owner}` -> `owner`) even though bash's own parser never would.
    // Quoting each word ourselves, and MSYS2_ARG_CONV_EXCL="*" turning off that runtime's own
    // argument conversion for this child, keeps the content intact end to end.
    cmd = "bash";
    args = ["-c", [shQuote(fake), ...args.map(shQuote)].join(" ")];
    env = { ...process.env, MSYS2_ARG_CONV_EXCL: "*" };
  }
  try {
    const stdout = execFileSync(cmd, args, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024, ...(env ? { env } : {}) });
    return { code: 0, stdout, stderr: "" };
  } catch (err) {
    return {
      code: typeof err.status === "number" ? err.status : 1,
      stdout: err.stdout ?? "",
      stderr: err.stderr ?? String(err.message ?? err),
    };
  }
}

/** The 4 pre-created triage labels. `done` is `awaiting-merge` or the closed state, and
 * `wontfix` a close-state, so neither is a triage label (see statusOf). */
const TRIAGE_LABELS = ["needs-triage", "needs-info", "ready-for-agent", "ready-for-human"];

/** Deterministic kebab-case slug derived from an issue title — GitHub has no filename to
 * derive one from, and nothing here needs caching (see PRD's Slug/branch mapping decision). */
function titleSlug(title) {
  return title
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

/** Blocker numbers in a `## Blocked by` section: `Issue NN` / `Issue #NN` entries and bare `#NN` refs, in order.
 * A `PR #NN` / `pull #NN` / `pull request #NN` mention is prose, not a blocker (lint-issues.sh strips the same). */
function blockerNumbers(section) {
  const prose = section.replace(/(^|[^a-z0-9])(?:pr|pull(?:\s+request)?)\s*#[0-9]+/gi, "$1");
  return [...prose.matchAll(/(?:\bissue[\s-]*#?|#)0*([0-9]+)\b/gi)].map((m) => Number(m[1]));
}

/** `done` is a closed issue or an open one labelled `awaiting-merge`; other open issues take
 * their status from whichever triage label is present, or "" when none is (matches local's
 * untriaged issues). */
function statusOf({ state, labels = [] }) {
  if (String(state).toUpperCase() === "CLOSED") return "done";
  const names = new Set((labels ?? []).map((l) => (typeof l === "string" ? l : l.name)));
  if (names.has(AWAITING_MERGE_LABEL)) return "done";
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
  const blockedBy = blockerNumbers(blockedBySection);
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
    labels: (json.labels ?? []).map((l) => (typeof l === "string" ? l : l.name)),
    text,
  };
}

/**
 * Every issue in the feature's milestone, `--state all` (open and closed — a closed or
 * `awaiting-merge` issue is how a blocker resolves), fetched and parsed via exactly one `gh issue list` call.
 * `--repo` is passed only when `readTrackerConfig` names one; omitted, `gh` infers it from
 * the git remote. A milestone that does not exist yet is an empty sprint, not an error.
 */
export function listFeatureIssues(mainRoot, { featureSlug, exec = shellOut } = {}) {
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

/** GitHub has no `issues-deps.json`: `## Blocked by` prose (mirrored as native links) is the map. */
export const featureDepsFile = () => null;

/**
 * Ready and unblocked. One `listFeatureIssues` fetch (all states) builds an in-memory
 * `number → status` map reused to resolve every candidate's blockers — mirrors how local's
 * `doneFiles()` is one directory read reused across every issue in the same call. A blocker
 * counts as resolved once its own status is `done` (closed); anything else, including a
 * blocker number absent from this milestone entirely, still blocks. `includeBlocked` keeps the
 * ready issues still waiting on one, as local's does.
 */
export function selectDispatchable(mainRoot, { status = READY_STATUS, featureSlug, exec, includeBlocked = false } = {}) {
  const issues = listFeatureIssues(mainRoot, { featureSlug, exec });
  const statusByNumber = new Map(issues.map((i) => [i.number, i.status]));
  // `blocked` is a human's to remove, so it also keeps the issue out of `includeBlocked` (plan/preflight).
  const ready = issues.filter((i) => i.status === status && !i.labels.includes(BLOCKED_LABEL));
  return ready
    .map((i) => ({ ...i, blockers: i.blockedBy.filter((n) => statusByNumber.get(n) !== "done") }))
    .filter((i) => includeBlocked || i.blockers.length === 0);
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
 * this on every publish, not just the feature's first. The list paginates (30 per page) and
 * includes closed milestones: either one missed reads as missing, and its create 422s on the
 * taken title. A closed match is reopened, so a finished feature's milestone can be closed.
 */
function ensureMilestone(featureSlug, { repo, exec }) {
  const path = milestonesPath(repo);
  const list = exec("gh", ["api", `${path}?state=all`, "--paginate", "--jq", ".[] | [.number, .state, .title] | @tsv"]);
  if (list.code !== 0) {
    throw new Error(`gh api milestones list failed (exit ${list.code}): ${list.stderr || list.stdout}`);
  }
  const match = (list.stdout || "")
    .split("\n")
    .map((line) => line.split("\t"))
    .find(([, , title]) => title === featureSlug);
  if (match) {
    const [number, state] = match;
    if (state === "open") return;
    const reopened = exec("gh", ["api", "-X", "PATCH", `${path}/${number}`, "-f", "state=open"]);
    if (reopened.code !== 0) {
      throw new Error(`gh api milestone reopen failed (exit ${reopened.code}): ${reopened.stderr || reopened.stdout}`);
    }
    return;
  }

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
    const number = match ? Number(match[1]) : null;
    if (number !== null) linkBlockers(number, { mainRoot, exec, body });
    return { number, url };
  } finally {
    try {
      unlinkSync(bodyFile);
    } catch {
      // best-effort cleanup of a throwaway temp file — nothing depends on it surviving.
    }
  }
}

/**
 * Mirror issue `number`'s `## Blocked by` numbers as native GitHub `blocked_by` relationships,
 * each by the blocker's numeric id. Best-effort and additive: dispatch still reads only the
 * body prose, so a failed or already-existing link warns on stderr (or is silent) and never
 * throws. An issue with no `## Blocked by` makes no dependency call. Returns the count linked.
 */
export function linkBlockers(number, { mainRoot, exec = shellOut, body, warn = (m) => process.stderr.write(`${m}\n`) } = {}) {
  try {
    const { repo } = readTrackerConfig(mainRoot ?? process.cwd());
    const repoArgs = repo ? ["--repo", repo] : [];
    const apiBase = repo ? `repos/${repo}` : "repos/{owner}/{repo}";
    let text = body;
    if (text === undefined) {
      const view = exec("gh", ["issue", "view", String(number), ...repoArgs, "--json", "body", "-q", ".body"]);
      if (view.code !== 0) {
        warn(`link-blockers: could not read #${number} (exit ${view.code}): ${view.stderr || view.stdout}`);
        return 0;
      }
      text = view.stdout ?? "";
    }
    const blockers = blockerNumbers(sectionBody(text, "Blocked by") ?? "");
    let linked = 0;
    for (const blocker of blockers) {
      const idr = exec("gh", ["api", `${apiBase}/issues/${blocker}`, "--jq", ".id"]);
      const id = String(idr.stdout ?? "").trim();
      if (idr.code !== 0 || !/^\d+$/.test(id)) {
        warn(`link-blockers: #${number}: blocker #${blocker} not found: ${idr.stderr || idr.stdout}`);
        continue;
      }
      const r = exec("gh", ["api", "-X", "POST", `${apiBase}/issues/${number}/dependencies/blocked_by`, "-F", `issue_id=${id}`]);
      if (r.code === 0) linked++;
      else if (/already|duplicate/i.test(`${r.stderr}${r.stdout}`)) continue;
      else warn(`link-blockers: #${number} blocked by #${blocker} failed (exit ${r.code}): ${r.stderr || r.stdout}`);
    }
    return linked;
  } catch (err) {
    warn(`link-blockers: #${number}: ${err.message}`);
    return 0;
  }
}

/**
 * The feature PR's closing lines, `Closes #n`: one per issue in the milestone still open and
 * labelled `awaiting-merge` — every issue a sprint of this feature merged, whichever run did —
 * plus the milestone's open `PRD: …` issue once no open work issue is left (the rule
 * `close-shipped.sh` applies), and only when something is awaiting merge: a PR that ships
 * nothing closes nothing. Merging the PR into the default branch closes them. Optional per
 * backend: a tracker without one has nothing for a PR to close.
 */
export function closingRefs(mainRoot, { featureSlug, exec = shellOut } = {}) {
  const { repo } = readTrackerConfig(mainRoot);
  const args = ["issue", "list"];
  if (repo) args.push("--repo", repo);
  args.push("--milestone", featureSlug, "--state", "open", "--limit", "500", "--json", "number,title,labels");
  const r = exec("gh", args);
  if (r.code !== 0) throw new Error(`gh issue list failed (exit ${r.code}): ${r.stderr || r.stdout}`);
  const raw = r.stdout && r.stdout.trim() ? JSON.parse(r.stdout) : [];
  const awaiting = (i) => (i.labels || []).some((l) => l.name === AWAITING_MERGE_LABEL);
  const prds = raw.filter((i) => /^PRD:/.test(i.title || ""));
  const work = raw.filter((i) => !prds.includes(i));
  const ships = work.filter(awaiting);
  const prdCloses = ships.length > 0 && ships.length === work.length ? prds : [];
  const origins = [];
  for (const prd of prdCloses) {
    const v = exec("gh", ["issue", "view", String(prd.number), ...(repo ? ["--repo", repo] : []), "--json", "body"]);
    if (v.code !== 0) throw new Error(`gh issue view failed (exit ${v.code}): ${v.stderr || v.stdout}`);
    let body = "";
    try { body = JSON.parse(v.stdout || "{}").body || ""; } catch { body = ""; }
    origins.push(...parseOrigins(body));
  }
  const nums = new Set([...ships, ...prdCloses].map((i) => i.number));
  for (const n of origins) nums.add(n);
  return [...nums].sort((a, b) => a - b).map((n) => `Closes #${n}`);
}

/** Issue numbers on a PRD body's `Origin: #n[, #n…]` line (column 0, one line). */
export function parseOrigins(body) {
  const m = /^Origin:[ \t]*(.*)$/m.exec(body || "");
  return m ? [...m[1].matchAll(/#(\d+)/g)].map((x) => Number(x[1])) : [];
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
 * prd.mjs, which has no local PRD.md under github. Exit 3 when the milestone has none.
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
  const prd = listFeatureIssues(opts.mainRoot ?? process.cwd(), { featureSlug: opts.featureSlug }).find(isPrdIssue);
  if (!prd) {
    process.exitCode = 3;
    return;
  }
  process.stdout.write(`<!-- PRD issue #${prd.number}: ${prd.title} -->\n${prd.text}\n`);
}

/** `link-blockers --issue <n> [--main-root <dir>]` — always exits 0; failures warn on stderr. */
function cliLinkBlockers(argv) {
  const opts = {};
  for (let i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case "--issue":
        opts.issue = argv[++i];
        break;
      case "--main-root":
        opts.mainRoot = argv[++i];
        break;
      default:
        throw new Error(`link-blockers: unknown argument: ${argv[i]}`);
    }
  }
  if (!opts.issue) throw new Error("link-blockers requires --issue");
  linkBlockers(opts.issue, { mainRoot: opts.mainRoot ?? process.cwd() });
}

function cliMain(argv) {
  const [command, ...rest] = argv;
  if (command === "link-blockers") return cliLinkBlockers(rest);
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
