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
 * back. Marking an issue done is `markDone`'s alone, reached through `tracker/cli.mjs mark-done`
 * (mark-issue-done.sh and close-issue.sh call it), so there is one implementation of the label
 * swap. `writeProgress`
 * always posts a new `gh issue comment` — a GitHub comment thread is a timeline, not an
 * in-place-edited section, so every call is a new comment, deliberately, including for a
 * `## Blocked` write (there is no `blocked` label anywhere in this module).
 */

import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

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

/** A ref the CLI may pass to `gh`: an issue number, all digits — anything else is a usage error. */
export function validateRef(mainRoot, ref) {
  return /^[0-9]+$/.test(String(ref)) ? String(ref) : null;
}

/** `gh` reports an issue number with no issue behind it this way; anything else is a failure. */
const NOT_FOUND = /could not resolve to an? (?:issue|pullrequest|pull request)/i;

/**
 * `{title, body, comments?}` for issue `number`, or null when it does not exist. One `gh issue
 * view`; `comments` (with `{author, createdAt, body}` each) only when asked for.
 */
export function fetchIssue(mainRoot, number, { comments = false, exec = shellOut } = {}) {
  const { repo } = readTrackerConfig(mainRoot);
  const fields = comments ? "title,body,comments" : "title,body";
  const r = exec("gh", ["issue", "view", String(number), ...(repo ? ["--repo", repo] : []), "--json", fields]);
  if (r.code !== 0) {
    if (NOT_FOUND.test(r.stderr ?? "")) return null;
    throw new Error(`gh issue view failed (exit ${r.code}): ${r.stderr || r.stdout}`);
  }
  const json = JSON.parse(r.stdout || "{}");
  const out = { title: json.title ?? "", body: json.body ?? "" };
  if (comments) {
    out.comments = (json.comments ?? []).map((c) => ({ author: c.author?.login ?? "", createdAt: c.createdAt ?? "", body: c.body ?? "" }));
  }
  return out;
}

/**
 * The milestone's PRD issue body, headed by an HTML comment naming its number and title (prd.mjs
 * saves it as `prd-issue.md`, so the saved copy still says which issue it came from); null when
 * the milestone has none.
 */
export function readPrd(mainRoot, { featureSlug, exec = shellOut } = {}) {
  const prd = listFeatureIssues(mainRoot, { featureSlug, exec }).find(isPrdIssue);
  return prd ? `<!-- PRD issue #${prd.number}: ${prd.title} -->\n${prd.text}\n` : null;
}

/** The file `known` writes for one issue: named `<n>-<slug>.md` (the lint ref), `# <title>` then the body. */
export function knownFile(issue) {
  return { name: `${issue.number}-${issue.slug}.md`, text: `# ${issue.title}\n\n${issue.text.replace(/\n*$/, "\n")}` };
}

/** `gh issue edit`/`view` stderr naming an issue that does not exist. */
function notFound(r) {
  return NOT_FOUND.test(r.stderr ?? "");
}

/** Runs `fn(path)` with `text` in a throwaway `--body-file`, removed afterwards. */
function withBodyFile(text, fn) {
  const bodyFile = join(tmpdir(), `crew-github-issue-${randomUUID()}.md`);
  writeFileSync(bodyFile, text);
  try {
    return fn(bodyFile);
  } finally {
    try {
      unlinkSync(bodyFile);
    } catch {
      // best-effort cleanup of a throwaway temp file — nothing depends on it surviving.
    }
  }
}

/** A draft's body as an issue body: its `# <title>` and `Status:` lines become the title and label. */
function draftBody(text) {
  return text
    .replace(/^#[ \t]+.*(?:\r?\n|$)/m, "")
    .replace(/^Status:.*(?:\r?\n|$)/m, "")
    .replace(/^(?:[ \t]*\r?\n)+/, "");
}

/**
 * `publish-issues`' github side: each draft becomes an issue through `createIssue` (milestone
 * ensured, blockers linked), titled by its `# <title>` line and labelled by its `Status:`. A
 * milestone only accumulates, so there is no re-run guard: github never refuses with 4 or 5.
 */
export function beginPublish(mainRoot, { featureSlug, exec = shellOut } = {}) {
  return {
    create(draft) {
      const { number } = createIssue(
        { title: draft.title, body: draftBody(draft.text), labels: [draft.status], featureSlug },
        { mainRoot, exec },
      );
      if (number === null) throw new Error(`gh issue create printed no issue URL for ${draft.file}`);
      return { ref: String(number), blockerRef: `Issue #${number}` };
    },
  };
}

/**
 * The feature's PRD issue: the milestone's existing `PRD:` issue gets `body`, else `PRD: <title>`
 * is created in it. Then a best-effort pin — GitHub caps pinned issues at 3 a repo, so a failed
 * pin only warns. Returns the issue number.
 */
export function publishPrd(mainRoot, { featureSlug, title, body, exec = shellOut, warn = (m) => process.stderr.write(`${m}\n`) } = {}) {
  const { repo } = readTrackerConfig(mainRoot);
  const repoArgs = repo ? ["--repo", repo] : [];
  const existing = listFeatureIssues(mainRoot, { featureSlug, exec }).find(isPrdIssue);
  let number;
  if (existing) {
    number = existing.number;
    const r = withBodyFile(body, (f) => exec("gh", ["issue", "edit", String(number), ...repoArgs, "--body-file", f]));
    if (r.code !== 0) throw new Error(`gh issue edit failed (exit ${r.code}): ${r.stderr || r.stdout}`);
  } else {
    number = createIssue({ title: `PRD: ${title}`, body, featureSlug }, { mainRoot, exec }).number;
    if (number === null) throw new Error("gh issue create printed no issue URL for the PRD");
  }
  const pin = exec("gh", ["issue", "pin", String(number), ...repoArgs]);
  if (pin.code !== 0) warn(`WARNING: could not pin PRD issue #${number} (exit ${pin.code}): ${pin.stderr || pin.stdout}`);
  return String(number);
}

/**
 * Rewrite a single-slice source issue: `body` — a draft's `# <title>` and `Status:` lines taken
 * off, as `publish-issues` does — replaces its body (a `Source:` line kept), `needs-triage` comes off, `status` goes on, and it moves into the feature's milestone,
 * created — or reopened when closed — first. Null when the issue does not exist.
 */
export function rewriteIssue(mainRoot, number, { body, status, featureSlug, exec = shellOut } = {}) {
  const { repo } = readTrackerConfig(mainRoot);
  ensureMilestone(featureSlug, { repo, exec });
  const r = withBodyFile(draftBody(body), (f) =>
    exec("gh", [
      "issue", "edit", String(number), ...(repo ? ["--repo", repo] : []),
      "--body-file", f, "--remove-label", "needs-triage", "--add-label", status, "--milestone", featureSlug,
    ]),
  );
  if (r.code !== 0) {
    if (notFound(r)) return null;
    throw new Error(`gh issue edit failed (exit ${r.code}): ${r.stderr || r.stdout}`);
  }
  return true;
}

/** What `mark-done` closes: a github issue has no file, so no sprint dir of its own (the CLI falls back to the env). */
export function doneTarget(mainRoot, number) {
  return { name: `issue #${number}`, sprintDir: null };
}

/** Issue `number`'s body, fetched live — never a copy the caller may hold — for `mark-done`'s criteria guard. */
export function readIssueBody(mainRoot, number, { exec = shellOut } = {}) {
  const { repo } = readTrackerConfig(mainRoot);
  const r = exec("gh", ["issue", "view", String(number), ...(repo ? ["--repo", repo] : []), "--json", "body", "--jq", ".body"]);
  if (r.code !== 0) throw new Error(`ERROR: gh issue view failed for #${number}:\n${r.stderr || r.stdout}`);
  return r.stdout ?? "";
}

/**
 * Mark issue `number` done — not closed: the work is only on a branch. `awaiting-merge` (read as
 * done) replaces `ready-for-agent`, and the PR's `Closes #n` closes the issue when it merges.
 * crew-afk's display label `in-progress` and a person's `ready-for-human` come off in the same
 * edit. Each label is created first, idempotently: `--add-label`/`--remove-label` fail on a label
 * the repo lacks. `ready-for-human` is the project's own (configure-tracker made it), so it is
 * created without `--force`, keeping its colour, and gh's "already exists" refusal counts as made.
 */
export function markDone(mainRoot, number, { exec = shellOut, warn = (m) => process.stderr.write(`${m}\n`) } = {}) {
  const { repo } = readTrackerConfig(mainRoot);
  const repoArgs = repo ? ["--repo", repo] : [];
  const awaiting = exec("gh", ["label", "create", AWAITING_MERGE_LABEL, ...repoArgs, "--force",
    "--description", "Implemented on a feature branch; closes when its PR merges"]);
  if (awaiting.code !== 0) throw new Error(`ERROR: gh label create ${AWAITING_MERGE_LABEL} failed:\n${awaiting.stderr || awaiting.stdout}`);
  const remove = ["--remove-label", "ready-for-agent"];
  const human = exec("gh", ["label", "create", "ready-for-human", ...repoArgs, "--description", "Requires human implementation"]);
  if (human.code === 0 || /already exists/.test(`${human.stderr}${human.stdout}`)) remove.push("--remove-label", "ready-for-human");
  else warn(`WARNING: gh label create ready-for-human failed; leaving it alone: ${human.stderr || human.stdout}`);
  // A display label never fails a close: without it created the edit just leaves it alone.
  const inProgress = exec("gh", ["label", "create", "in-progress", ...repoArgs, "--force",
    "--description", "A crew-afk run is working this issue (display only)"]);
  if (inProgress.code === 0) remove.push("--remove-label", "in-progress");
  else warn(`WARNING: gh label create in-progress failed; leaving it alone: ${inProgress.stderr || inProgress.stdout}`);
  const edit = exec("gh", ["issue", "edit", String(number), ...repoArgs, "--add-label", AWAITING_MERGE_LABEL, ...remove]);
  if (edit.code !== 0) throw new Error(`ERROR: gh issue edit failed for #${number}:\n${edit.stderr || edit.stdout}`);
  return `DONE: issue #${number} labelled ${AWAITING_MERGE_LABEL} — put 'Closes #${number}' in the PR body so merging it closes the issue`;
}

/** An argv mistake in a subcommand below: the tracker CLI exits 2 for it, not 1. */
function usage(message) {
  return Object.assign(new Error(message), { usage: true });
}

/**
 * `create-issue --title T --body-file F --feature-slug S [--label L]… [--main-root DIR]` — the
 * shape `promote-findings.sh`'s `_defer_github` calls through `tracker/cli.mjs`, so the bash
 * script never hand-rolls a second `gh issue create` + milestone bootstrap that can drift from
 * `createIssue` (it did). Prints the created issue's URL, as `gh issue create` does.
 */
function cliCreateIssue(argv, { exec, out }) {
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
        throw usage(`create-issue: unknown argument: ${argv[i]}`);
    }
  }
  if (!opts.title || !opts.bodyFile || !opts.featureSlug) {
    throw usage("create-issue requires --title, --body-file, and --feature-slug");
  }
  const body = readFileSync(opts.bodyFile, "utf8");
  const { url } = createIssue(
    { title: opts.title, body, labels: opts.labels, featureSlug: opts.featureSlug },
    { mainRoot: opts.mainRoot ?? process.cwd(), exec },
  );
  out(`${url}\n`);
}

/** `link-blockers --issue <n> [--main-root <dir>]` — always exits 0; failures warn on stderr. */
function cliLinkBlockers(argv, { exec, err }) {
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
        throw usage(`link-blockers: unknown argument: ${argv[i]}`);
    }
  }
  if (!opts.issue) throw usage("link-blockers requires --issue");
  linkBlockers(opts.issue, { mainRoot: opts.mainRoot ?? process.cwd(), exec, warn: (m) => err(`${m}\n`) });
}

/** This backend's own `tracker/cli.mjs` ops, beyond the ones every backend has. */
export const cliOps = {
  "create-issue": cliCreateIssue,
  "link-blockers": cliLinkBlockers,
};
