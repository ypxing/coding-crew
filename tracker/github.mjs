/**
 * github.mjs — the GitHub Issues tracker backend, shelling out to `gh` with argv arrays.
 * `exec` is injectable so tests stub `gh` without touching PATH. `listFeatureIssues` makes one
 * `gh issue list` call per invocation, never one per issue.
 */

import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

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

/** POSIX single-quoting, kept local so the tracker does not depend on pane-host. */
function shQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

/** Real `gh`: argv array, no shell. A thrown non-zero exit returns the same shape as a clean one. */
function shellOut(cmd, args) {
  // Test/CI seam, like CREW_FAKE_DISPATCH: a bash script stands in for `gh`. Run through bash
  // explicitly — on Windows execFileSync never reads a shebang and refuses a .cmd, so a stub
  // found by PATH alone loses to the real gh.exe.
  const fake = cmd === "gh" ? process.env.CREW_FAKE_GH : "";
  let env;
  if (fake) {
    // One quoted `-c` string, not argv: on Windows the MSYS runtime re-parses the command line
    // before bash starts and can drop an unquoted brace pair (`{owner}` -> `owner`).
    // MSYS2_ARG_CONV_EXCL="*" turns off its argument conversion for this child.
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

/** A `gh` failure on the network or GitHub's side, not in the request itself: worth another try. */
const TRANSIENT = /\bEOF\b|connection reset|connection refused|no such host|timeout|timed out|HTTP 5\d\d|secondary rate limit/i;
/** Failed before the request left this machine, so even a write cannot have been applied. */
const UNSENT = /dial tcp|no such host|connection refused|TLS handshake timeout/i;
const RETRY_DELAYS_MS = [1000, 2000, 4000];

/** A call whose retry could create a second issue, comment or resource (`gh api` posts once given a field). */
function createsSomething(args) {
  const [group, sub] = args;
  if (group === "issue") return sub === "create" || sub === "comment";
  if (group !== "api") return false;
  const m = args.findIndex((a) => a === "-X" || a === "--method");
  if (m !== -1) return String(args[m + 1]).toUpperCase() === "POST";
  return args.some((a) => ["-f", "-F", "--field", "--raw-field", "--input"].includes(a));
}

function sleepSync(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

/**
 * `exec` with a transient failure retried after each of `delays`; the last result is returned as is.
 * A write is retried only when the failure happened before it was sent.
 */
export function retryTransient(exec, { delays = RETRY_DELAYS_MS, sleep = sleepSync, warn = (m) => process.stderr.write(`${m}\n`) } = {}) {
  return (cmd, args) => {
    let r = exec(cmd, args);
    for (const [i, ms] of delays.entries()) {
      const stderr = r.stderr ?? "";
      if (r.code === 0 || !TRANSIENT.test(stderr)) return r;
      if (createsSomething(args) && !UNSENT.test(stderr)) return r;
      warn(`gh ${args.slice(0, 2).join(" ")}: transient failure, retry ${i + 1}/${delays.length} in ${ms / 1000}s: ${stderr.trim().split("\n")[0]}`);
      sleep(ms);
      r = exec(cmd, args);
    }
    return r;
  };
}

const gh = retryTransient(shellOut);

/** The 4 pre-created triage labels. `done` is `awaiting-merge` or the closed state, and
 * `wontfix` a close-state, so neither is a triage label (see statusOf). */
const TRIAGE_LABELS = ["needs-triage", "needs-info", "ready-for-agent", "ready-for-human"];

/** GitHub has no filename to derive a slug from, so the title is the source. */
function titleSlug(title) {
  return title
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

/** Blocker numbers in a `## Blocked by` section: `Issue NN` / `Issue #NN` entries and bare refs, in order.
 * A PR or pull-request mention is prose, not a blocker (lint-issues.sh strips the same). */
function blockerNumbers(section) {
  const prose = section.replace(/(^|[^a-z0-9])(?:pr|pull(?:\s+request)?)\s*#[0-9]+/gi, "$1");
  return [...prose.matchAll(/(?:\bissue[\s-]*#?|#)0*([0-9]+)\b/gi)].map((m) => Number(m[1]));
}

/** `done` is a closed issue or an open one labelled `awaiting-merge`; other open issues take
 * their status from their triage label, or "" when none (as local's untriaged issues). */
function statusOf({ state, labels = [] }) {
  if (String(state).toUpperCase() === "CLOSED") return "done";
  const names = new Set((labels ?? []).map((l) => (typeof l === "string" ? l : l.name)));
  if (names.has(AWAITING_MERGE_LABEL)) return "done";
  return TRIAGE_LABELS.find((name) => names.has(name)) ?? "";
}

/** The feature's PRD: a milestone issue by title convention, not a work issue (to-prd). */
export const isPrdIssue = (issue) => /^PRD:/.test(issue.title ?? "");

/** Same shape as local.mjs's `parseIssue`; `blockedBy` holds bare issue numbers. */
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

/** Every issue in the milestone, open and closed (a closed blocker is resolved), in one call. */
export function listFeatureIssues(mainRoot, { featureSlug, exec = gh } = {}) {
  const args = ["issue", "list", "--milestone", featureSlug, "--state", "all", "--json", "number,title,body,labels,state"];

  const r = exec("gh", args);
  if (r.code !== 0) {
    // gh reports a milestone not created yet as an unresolvable filter: an empty sprint.
    if (/milestone/i.test(r.stderr ?? "")) return [];
    throw new Error(`gh issue list failed (exit ${r.code}): ${r.stderr || r.stdout}`);
  }

  const raw = r.stdout && r.stdout.trim() ? JSON.parse(r.stdout) : [];
  return raw.map(parseIssue);
}

/** GitHub has no `issues-deps.json`: `## Blocked by` prose (mirrored as native links) is the map. */
export const featureDepsFile = () => null;

/** Ready and unblocked: a blocker resolves once `done`; one absent from this milestone still blocks. */
export function selectDispatchable(mainRoot, { status = READY_STATUS, featureSlug, exec, includeBlocked = false } = {}) {
  const issues = listFeatureIssues(mainRoot, { featureSlug, exec });
  const statusByNumber = new Map(issues.map((i) => [i.number, i.status]));
  // `blocked` is a human's to remove, so it also keeps the issue out of `includeBlocked` (plan/preflight).
  const ready = issues.filter((i) => i.status === status && !i.labels.includes(BLOCKED_LABEL));
  return ready
    .map((i) => ({ ...i, blockers: i.blockedBy.filter((n) => statusByNumber.get(n) !== "done") }))
    .filter((i) => includeBlocked || i.blockers.length === 0);
}

/** `gh api` resolves the placeholders from the git remote, as every `gh issue ...` call here does. */
const MILESTONES_PATH = "repos/{owner}/{repo}/milestones";

/**
 * Ensure a milestone named `featureSlug` exists, list-first so repeat calls create nothing.
 * The list paginates and includes closed milestones: a missed one reads as missing and its
 * create 422s on the taken title. A closed match is reopened.
 */
function ensureMilestone(featureSlug, { exec }) {
  const list = exec("gh", ["api", `${MILESTONES_PATH}?state=all`, "--paginate", "--jq", ".[] | [.number, .state, .title] | @tsv"]);
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
    const reopened = exec("gh", ["api", "-X", "PATCH", `${MILESTONES_PATH}/${number}`, "-f", "state=open"]);
    if (reopened.code !== 0) {
      throw new Error(`gh api milestone reopen failed (exit ${reopened.code}): ${reopened.stderr || reopened.stdout}`);
    }
    return;
  }

  const created = exec("gh", ["api", MILESTONES_PATH, "-f", `title=${featureSlug}`]);
  if (created.code !== 0) {
    throw new Error(`gh api milestone create failed (exit ${created.code}): ${created.stderr || created.stdout}`);
  }
}

/** Every feature, one per milestone (a closed one is still a taken slug), sorted by title. */
export function listFeatures(mainRoot, { exec = gh } = {}) {
  const fail = (r) => new Error((r.stderr || r.stdout || `gh exited ${r.code}`).replace(/\n$/, ""));
  const milestones = exec("gh", ["api", `${MILESTONES_PATH}?state=all`, "--paginate", "--jq", ".[] | [.number, .state, .title] | @tsv"]);
  if (milestones.code !== 0) throw fail(milestones);
  const issues = exec("gh", ["issue", "list", "--label", READY_STATUS, "--state", "open", "--limit", "1000", "--json", "milestone"]);
  if (issues.code !== 0) throw fail(issues);
  const ready = new Map();
  for (const issue of issues.stdout?.trim() ? JSON.parse(issues.stdout) : []) {
    const title = issue.milestone?.title;
    if (title) ready.set(title, (ready.get(title) ?? 0) + 1);
  }
  return (milestones.stdout || "")
    .split("\n")
    .filter(Boolean)
    .map((line) => line.split("\t"))
    .map(([, state, title]) => ({ slug: title, state, ready: ready.get(title) ?? 0 }))
    .sort((a, b) => (a.slug < b.slug ? -1 : a.slug > b.slug ? 1 : 0));
}

/** Create an issue in the feature's milestone, `body` unmodified. Returns `{number, url}`. */
export function createIssue({ title, body, labels = [], featureSlug }, { mainRoot, exec = gh } = {}) {
  ensureMilestone(featureSlug, { exec });

  const bodyFile = join(tmpdir(), `crew-github-issue-${randomUUID()}.md`);
  writeFileSync(bodyFile, body);
  try {
    const args = ["issue", "create", "--title", title, "--body-file", bodyFile];
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
    }
  }
}

/**
 * Mirror `## Blocked by` as native `blocked_by` links. Best-effort: dispatch reads only the
 * body prose, so a failed link warns and never throws. Returns the count linked.
 */
export function linkBlockers(number, { mainRoot, exec = gh, body, warn = (m) => process.stderr.write(`${m}\n`) } = {}) {
  try {
    const apiBase = "repos/{owner}/{repo}";
    let text = body;
    if (text === undefined) {
      const view = exec("gh", ["issue", "view", String(number), "--json", "body", "-q", ".body"]);
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
 * The feature PR's `Closes #n` lines: every open `awaiting-merge` issue in the milestone, plus
 * its open `PRD:` issue once no open work issue is left (as `close-shipped.sh`). A PR that
 * ships nothing closes nothing.
 */
export function closingRefs(mainRoot, { featureSlug, exec = gh } = {}) {
  const args = ["issue", "list", "--milestone", featureSlug, "--state", "open", "--limit", "500", "--json", "number,title,labels"];
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
    const v = exec("gh", ["issue", "view", String(prd.number), "--json", "body"]);
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

/** Post `body` as a new comment under `## <heading>`, never an in-place edit. */
export function writeProgress(issue, body, { heading = "Progress", mainRoot, exec = gh } = {}) {
  const commentBody = `## ${heading}\n\n${body}`;

  const result = exec("gh", ["issue", "comment", String(issue.number), "--body", commentBody]);
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

/** `{title, body, comments?}` for issue `number`, or null when it does not exist. */
export function fetchIssue(mainRoot, number, { comments = false, exec = gh } = {}) {
  const fields = comments ? "title,body,comments" : "title,body";
  const r = exec("gh", ["issue", "view", String(number), "--json", fields]);
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

/** The milestone's PRD body, headed by an HTML comment naming its number and title; null when none. */
export function readPrd(mainRoot, { featureSlug, exec = gh } = {}) {
  const prd = listFeatureIssues(mainRoot, { featureSlug, exec }).find(isPrdIssue);
  return prd ? `<!-- PRD issue #${prd.number}: ${prd.title} -->\n${prd.text}\n` : null;
}

/** The file `known` writes for one issue: named `<n>-<slug>.md` (the lint ref), `# <title>` then the body. */
export function knownFile(issue) {
  return { name: `${issue.number}-${issue.slug}.md`, text: `# ${issue.title}\n\n${issue.text.replace(/\n*$/, "\n")}` };
}

/** The `## Blocked by` ref for a `known` file's name, `<n>-<slug>.md` → `Issue #<n>`; null for any other name. */
export function knownBlockerRef(name) {
  const n = /^([0-9]+)-[A-Za-z0-9][\w.-]*\.md$/.exec(name)?.[1];
  return n ? `Issue #${Number(n)}` : null;
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

/** `publish-issues`' github side. A milestone only accumulates, so there is no re-run guard. */
export function beginPublish(mainRoot, { featureSlug, exec = gh } = {}) {
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
 * Update the milestone's `PRD:` issue or create one, then pin it best-effort — GitHub caps
 * pinned issues at 3 a repo. Returns the issue number.
 */
export function publishPrd(mainRoot, { featureSlug, title, body, exec = gh, warn = (m) => process.stderr.write(`${m}\n`) } = {}) {
  const existing = listFeatureIssues(mainRoot, { featureSlug, exec }).find(isPrdIssue);
  let number;
  if (existing) {
    number = existing.number;
    const r = withBodyFile(body, (f) => exec("gh", ["issue", "edit", String(number), "--body-file", f]));
    if (r.code !== 0) throw new Error(`gh issue edit failed (exit ${r.code}): ${r.stderr || r.stdout}`);
  } else {
    number = createIssue({ title: `PRD: ${title}`, body, featureSlug }, { mainRoot, exec }).number;
    if (number === null) throw new Error("gh issue create printed no issue URL for the PRD");
  }
  const pin = exec("gh", ["issue", "pin", String(number)]);
  if (pin.code !== 0) warn(`WARNING: could not pin PRD issue #${number} (exit ${pin.code}): ${pin.stderr || pin.stdout}`);
  return String(number);
}

/**
 * Rewrite a single-slice source issue's body (a `Source:` line kept), set `status` as its only
 * triage label and move it into the feature's milestone. `--remove-label` fails on a label the
 * issue lacks, so only carried ones are named. Null when the issue does not exist.
 */
export function rewriteIssue(mainRoot, number, { body, status, featureSlug, exec = gh } = {}) {
  const read = exec("gh", ["issue", "view", String(number), "--json", "labels", "--jq", ".labels[].name"]);
  if (read.code !== 0) {
    if (notFound(read)) return null;
    throw new Error(`gh issue view failed (exit ${read.code}): ${read.stderr || read.stdout}`);
  }
  const carried = new Set((read.stdout ?? "").split("\n").map((l) => l.trim()).filter(Boolean));
  const remove = TRIAGE_LABELS.filter((name) => name !== status && carried.has(name))
    .flatMap((name) => ["--remove-label", name]);
  ensureMilestone(featureSlug, { exec });
  const r = withBodyFile(draftBody(body), (f) =>
    exec("gh", ["issue", "edit", String(number), "--body-file", f, ...remove, "--add-label", status, "--milestone", featureSlug]),
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
export function readIssueBody(mainRoot, number, { exec = gh } = {}) {
  const r = exec("gh", ["issue", "view", String(number), "--json", "body", "--jq", ".body"]);
  if (r.code !== 0) throw new Error(`ERROR: gh issue view failed for #${number}:\n${r.stderr || r.stdout}`);
  return r.stdout ?? "";
}

/**
 * Mark issue `number` done, not closed: the work is only on a branch, and the PR's `Closes #n`
 * closes it. `--add-label`/`--remove-label` fail on a label the repo lacks, so each is created
 * first; `ready-for-human` without `--force`, keeping the project's colour.
 */
export function markDone(mainRoot, number, { exec = gh, warn = (m) => process.stderr.write(`${m}\n`) } = {}) {
  const awaiting = exec("gh", ["label", "create", AWAITING_MERGE_LABEL, "--force",
    "--description", "Implemented on a feature branch; closes when its PR merges"]);
  if (awaiting.code !== 0) throw new Error(`ERROR: gh label create ${AWAITING_MERGE_LABEL} failed:\n${awaiting.stderr || awaiting.stdout}`);
  const remove = ["--remove-label", "ready-for-agent"];
  const human = exec("gh", ["label", "create", "ready-for-human", "--description", "Requires human implementation"]);
  if (human.code === 0 || /already exists/.test(`${human.stderr}${human.stdout}`)) remove.push("--remove-label", "ready-for-human");
  else warn(`WARNING: gh label create ready-for-human failed; leaving it alone: ${human.stderr || human.stdout}`);
  // A display label never fails a close: without it created the edit just leaves it alone.
  const inProgress = exec("gh", ["label", "create", "in-progress", "--force",
    "--description", "A crew-afk run is working this issue (display only)"]);
  if (inProgress.code === 0) remove.push("--remove-label", "in-progress");
  else warn(`WARNING: gh label create in-progress failed; leaving it alone: ${inProgress.stderr || inProgress.stdout}`);
  const edit = exec("gh", ["issue", "edit", String(number), "--add-label", AWAITING_MERGE_LABEL, ...remove]);
  if (edit.code !== 0) throw new Error(`ERROR: gh issue edit failed for #${number}:\n${edit.stderr || edit.stdout}`);
  return `DONE: issue #${number} labelled ${AWAITING_MERGE_LABEL} — put 'Closes #${number}' in the PR body so merging it closes the issue`;
}

/** An argv mistake in a subcommand below: the tracker CLI exits 2 for it, not 1. */
function usage(message) {
  return Object.assign(new Error(message), { usage: true });
}

/**
 * `create-issue --title T --body-file F --feature-slug S [--label L]… [--main-root DIR]`, so
 * `promote-findings.sh` never hand-rolls a second milestone bootstrap. Prints the issue URL.
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
