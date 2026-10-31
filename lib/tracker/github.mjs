/**
 * github.mjs — the GitHub Issues tracker backend, shelling out to `gh` with argv arrays.
 * `exec` is injectable so tests stub `gh` without touching PATH. A feature is one root issue whose
 * body carries a column-0 `Feature: <slug>` line, plus that root's sub-issues: reading one is a
 * paginated scan for the root (once per process) and one paginated sub-issues read, never a call
 * per issue.
 */

import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { unlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { sectionBody, tickCriteria } from "./body-format.mjs";
import { trustChecker } from "./trust.mjs";

export const READY_STATUS = "ready-for-agent";

/** "Done" short of shipped: implemented and merged into the feature branch, closed only by the
 * `Closes #n` in the feature's PR once that merges. An open issue carrying it reads as `done`. */
export const AWAITING_MERGE_LABEL = "awaiting-merge";

/** Added by a person to an issue that needs a human; the issue keeps `ready-for-agent`, but
 * selectDispatchable skips it until a person removes this. */
export const BLOCKED_LABEL = "blocked";

/** POSIX single-quoting. */
function shQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

/** Real `gh`: argv array, no shell. A thrown non-zero exit returns the same shape as a clean one. */
function shellOut(cmd, args) {
  // Test/CI seam: a bash script stands in for `gh`. Run through bash
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
    // stderr piped, not inherited: an expected failure (a 404 read) is no noise, and every error raised quotes it.
    const stdout = execFileSync(cmd, args, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024, stdio: ["ignore", "pipe", "pipe"], ...(env ? { env } : {}) });
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

export const gh = retryTransient(shellOut);

/** The 4 pre-created triage labels. `done` is `awaiting-merge` or the closed state, and
 * `wontfix` a close-state, so neither is a triage label (see statusOf). */
const TRIAGE_LABELS = ["needs-triage", "needs-info", "ready-for-agent", "ready-for-human"];

/** Every status label, `blocked` and `needs-info` too: a person applies those in GitHub's UI, which offers only existing labels. */
const STATUS_LABELS = [...TRIAGE_LABELS, AWAITING_MERGE_LABEL, BLOCKED_LABEL];
const DESCRIPTIONS = { [AWAITING_MERGE_LABEL]: "Implemented on a feature branch; closes when its PR merges" };
/** Without --color gh picks a random one. */
const COLORS = {
  "needs-triage": "d4c5f9",
  "needs-info": "fbca04",
  "ready-for-agent": "0e8a16",
  "ready-for-human": "1d76db",
  [AWAITING_MERGE_LABEL]: "c2e0c6",
  [BLOCKED_LABEL]: "b60205",
};
const labelsMade = new WeakSet();

/** `--label`/`--add-label` fail on a label the repo lacks: create the status labels once per `exec` (one CLI invocation).
 * No --force, so a label that already exists keeps the colour and description a team gave it. */
function ensureStatusLabels(exec) {
  if (labelsMade.has(exec)) return;
  for (const name of STATUS_LABELS) {
    const desc = DESCRIPTIONS[name] ? ["--description", DESCRIPTIONS[name]] : [];
    const r = exec("gh", ["label", "create", name, "--color", COLORS[name], ...desc]);
    if (r.code !== 0 && !/already exists/i.test(`${r.stderr}${r.stdout}`)) {
      throw new Error(`ERROR: gh label create ${name} failed (exit ${r.code}):\n${r.stderr || r.stdout}`);
    }
  }
  labelsMade.add(exec);
}

/** GitHub has no filename to derive a slug from, so the title is the source. */
function titleSlug(title) {
  return title
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

/** Blocker numbers in a `## Blocked by` section: `Issue NN` / `Issue #NN` entries and bare refs, in order.
 * A PR or pull-request mention is prose, not a blocker. */
function blockerNumbers(section) {
  const prose = section.replace(/(^|[^a-z0-9])(?:pr|pull(?:\s+request)?)\s*#[0-9]+/gi, "$1");
  return [...prose.matchAll(/(?:\bissue[\s-]*#?|#)0*([0-9]+)\b/gi)].map((m) => Number(m[1]));
}

/** A label's name: `gh --json labels` gives objects, a test fixture may give plain strings. */
const labelName = (l) => (typeof l === "string" ? l : l.name);

/** `wontfix` is an issue closed as not planned, `done` any other closed issue or an open one labelled
 * `awaiting-merge`; other open issues take their status from their triage label, or "" when none (as
 * local's untriaged issues). */
function statusOf({ state, state_reason, labels = [] }) {
  if (String(state).toUpperCase() === "CLOSED") return state_reason === "not_planned" ? "wontfix" : "done";
  const names = new Set((labels ?? []).map(labelName));
  if (names.has(AWAITING_MERGE_LABEL)) return "done";
  return TRIAGE_LABELS.find((name) => names.has(name)) ?? "";
}

/** The feature's PRD: an issue of the feature by title convention, not a work issue (to-prd). */
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
    labels: (json.labels ?? []).map(labelName),
    text,
  };
}

/** `gh api` resolves the placeholders from the git remote, as every `gh issue ...` call here does. */
const API = "repos/{owner}/{repo}";

/** A slug on a body's column-0 `Feature: <slug>` line: written by this backend only, on a root. */
const MARKER = /^Feature:[ \t]*([A-Za-z0-9][A-Za-z0-9._-]*)[ \t]*$/m;
const MARKER_LINES = /^Feature:[ \t]*[A-Za-z0-9][A-Za-z0-9._-]*[ \t]*(?:\r?\n|$)/gm;

/** The feature slug a root issue's body names, or null when it names none. */
export function featureMarker(body) {
  return MARKER.exec(body ?? "")?.[1] ?? null;
}

/** `body` as a root's: one `Feature: <featureSlug>` line, then the body. */
function withMarker(body, featureSlug) {
  return `Feature: ${featureSlug}\n\n${withoutMarker(body).replace(/^(?:[ \t]*\r?\n)+/, "")}`;
}

/** `body` with no `Feature:` line: a sub-issue carrying one would read as a second root. */
function withoutMarker(body) {
  return (body ?? "").replace(MARKER_LINES, "");
}

/** Every element of a paginated REST list; `--slurp` prints the pages as one JSON array. */
function apiList(path, { exec }) {
  const r = exec("gh", ["api", path, "--paginate", "--slurp"]);
  if (r.code !== 0) throw new Error(`gh api ${path} failed (exit ${r.code}): ${r.stderr || r.stdout}`);
  return r.stdout?.trim() ? JSON.parse(r.stdout).flat() : [];
}

/**
 * Issues and PRs in `state` (`open`|`all`), from the REST list. It lags a create by seconds (see
 * findRoot), but less than `gh issue list --search`'s index, and a PR's number still bounds the scan.
 */
function scanIssues(state, { exec }) {
  return apiList(`${API}/issues?state=${state}&per_page=100`, { exec });
}

const isIssue = (i) => !i.pull_request;

/** Issue or PR `number` as REST JSON; `{ gone: true }` when it was deleted (410), null when no such number (404). */
function readNumber(number, { exec }) {
  const r = exec("gh", ["api", `${API}/issues/${number}`]);
  if (r.code !== 0) {
    if (/HTTP 410/.test(r.stderr ?? "")) return { gone: true };
    if (/HTTP 404/.test(r.stderr ?? "")) return null;
    throw new Error(`gh api ${API}/issues/${number} failed (exit ${r.code}): ${r.stderr || r.stdout}`);
  }
  return JSON.parse(r.stdout || "{}");
}

/** The list lags by seconds, so only a few numbers can be past its newest; a cap, not a 404, ends the read. */
const MAX_UNLISTED = 20;

/** Every issue numbered past `newest`, read one by one up to the first number not taken. */
function issuesAfter(newest, { exec }) {
  const found = [];
  for (let n = newest + 1; n <= newest + MAX_UNLISTED; n++) {
    const issue = readNumber(n, { exec });
    if (issue === null) return found;
    if (!issue.gone && isIssue(issue)) found.push(issue);
  }
  return found;
}

const isOpen = (issue) => String(issue.state).toUpperCase() === "OPEN";

function ambiguousRoots(featureSlug, roots) {
  const refs = roots.map((r) => `#${r.number}`).sort().join(", ");
  return new Error(`feature ${featureSlug} has ${roots.length} root issues carrying 'Feature: ${featureSlug}': ${refs} — keep the line on one of them`);
}

/** Root numbers by slug, per `exec` (one GitHub): a caller may read its feature more than once,
 * and a scan costs a page per 100 of the repo's issues. Nothing outlives the process. */
const rootsSeen = new WeakMap();

/** Issue `number` (REST JSON) while it still carries `featureSlug`'s marker, else null. */
function stillRoot(number, featureSlug, { exec }) {
  const issue = readNumber(number, { exec });
  return issue && featureMarker(issue.body) === featureSlug ? issue : null;
}

/**
 * The feature's root issue (REST JSON), or null when no issue carries its marker. An open root
 * wins over closed ones; two open, or no open and two closed, is an error naming them. Scans
 * once per process: later calls re-read the root found, scanning again only once it loses its line.
 * The list lags a create by seconds, so when it shows no open root the issues past its newest are
 * read by number: `publish-issues` right after `publish-prd` must find the root just made.
 */
function findRoot(featureSlug, { exec }) {
  if (!rootsSeen.has(exec)) rootsSeen.set(exec, new Map());
  const seen = rootsSeen.get(exec);
  const known = seen.has(featureSlug) ? stillRoot(seen.get(featureSlug), featureSlug, { exec }) : null;
  if (known) return known;
  const marked = (list) => list.filter((i) => isIssue(i) && featureMarker(i.body) === featureSlug);
  let roots = marked(scanIssues("open", { exec }));
  if (roots.length === 0) {
    const all = scanIssues("all", { exec });
    const found = marked([...all, ...issuesAfter(Math.max(0, ...all.map((i) => i.number)), { exec })]);
    roots = found.some(isOpen) ? found.filter(isOpen) : found;
  }
  if (roots.length > 1) throw ambiguousRoots(featureSlug, roots);
  if (roots[0]) seen.set(featureSlug, roots[0].number);
  return roots[0] ?? null;
}

/** `root` and its sub-issues (one level), open and closed, as REST JSON. */
function rootAndSubIssues(root, { exec }) {
  return [root, ...apiList(`${API}/issues/${root.number}/sub_issues?per_page=100`, { exec })];
}

/** The feature's issues as REST JSON — none for a slug with no root. */
function featureIssuesJson(featureSlug, { exec }) {
  const root = findRoot(featureSlug, { exec });
  return root ? rootAndSubIssues(root, { exec }) : [];
}

/** Every issue of the feature, open and closed (a closed blocker is resolved). */
export function listFeatureIssues(mainRoot, { featureSlug, exec = gh } = {}) {
  return featureIssuesJson(featureSlug, { exec }).map(parseIssue);
}

/** Ready and unblocked: a blocker resolves once `done` or closed as `wontfix`, in this feature or not. */
export function selectDispatchable(mainRoot, { featureSlug, exec = gh } = {}) {
  return dispatchable(listFeatureIssues(mainRoot, { featureSlug, exec }), { exec });
}

/** The sub-issue list is link order, not number order: `next` takes the lowest number. */
export const sortDispatchable = (issues) => [...issues].sort((a, b) => a.number - b.number);

/** The CLI ref for `issue`: its number. */
export const issueRef = (mainRoot, issue) => String(issue.number);

/** `selectDispatchable`'s rule over one feature's parsed issues, so `listFeatures` counts the same set.
 * A blocker outside the feature is read by number; a missing or deleted one never resolves. */
function dispatchable(issues, { exec }) {
  const statusByNumber = new Map(issues.map((i) => [i.number, i.status]));
  const statusOfBlocker = (n) => {
    if (statusByNumber.has(n)) return statusByNumber.get(n);
    const issue = readNumber(n, { exec });
    return issue && !issue.gone ? statusOf(issue) : "";
  };
  const ready = issues.filter((i) => i.status === READY_STATUS && !i.labels.includes(BLOCKED_LABEL));
  return ready
    .map((i) => ({ ...i, blockers: i.blockedBy.filter((n) => !["done", "wontfix"].includes(statusOfBlocker(n))) }))
    .filter((i) => i.blockers.length === 0);
}

/**
 * Every feature, one per slug a root issue names, sorted: `open` while the root or a sub-issue is
 * open, and the count of issues among them dispatch would start now. A slug on more than one root
 * warns and counts them all as one feature, rather than failing every other slug. A closed root whose
 * `sub_issues_summary` shows every sub-issue closed is settled without reading them.
 */
export function listFeatures(mainRoot, { exec = gh, warn = (m) => process.stderr.write(`${m}\n`) } = {}) {
  const rootsBySlug = new Map();
  for (const issue of scanIssues("all", { exec }).filter(isIssue)) {
    const slug = featureMarker(issue.body);
    if (slug) rootsBySlug.set(slug, [...(rootsBySlug.get(slug) ?? []), issue]);
  }
  return [...rootsBySlug.keys()].sort().map((slug) => {
    const all = rootsBySlug.get(slug);
    const open = all.filter(isOpen);
    const roots = open.length ? open : all;
    if (roots.length > 1) warn(`WARNING: ${ambiguousRoots(slug, roots).message}`);
    const settled = (r) => !isOpen(r) && r.sub_issues_summary && r.sub_issues_summary.completed >= r.sub_issues_summary.total;
    if (roots.every(settled)) return { slug, state: "closed", ready: 0 };
    const members = new Map(roots.flatMap((r) => rootAndSubIssues(r, { exec })).map((i) => [i.number, i]));
    const live = [...members.values()].some(isOpen);
    return { slug, state: live ? "open" : "closed", ready: dispatchable([...members.values()].map(parseIssue), { exec }).length };
  });
}

/**
 * Create an issue in the feature, returning `{number, url}`. With no root yet (`parent` null) it
 * becomes the root, marker added; otherwise a sub-issue of `parent`, any marker dropped.
 */
export function createIssue({ title, body, labels = [], featureSlug }, { mainRoot, exec = gh, parent } = {}) {
  const text = parent === null ? withMarker(body, featureSlug) : withoutMarker(body);
  if ([].concat(labels).some(Boolean)) ensureStatusLabels(exec);
  const result = withBodyFile(text, (bodyFile) => {
    const args = ["issue", "create", "--title", title, "--body-file", bodyFile];
    for (const label of [].concat(labels).filter(Boolean)) args.push("--label", label);
    if (parent !== null) args.push("--parent", String(parent));
    return exec("gh", args);
  });
  if (result.code !== 0) {
    throw new Error(`gh issue create failed (exit ${result.code}): ${result.stderr || result.stdout}`);
  }
  const url = result.stdout.trim();
  const match = /\/(\d+)\s*$/.exec(url);
  const number = match ? Number(match[1]) : null;
  if (number !== null) linkBlockers(number, { mainRoot, exec, body: text });
  return { number, url };
}

/**
 * Mirror `body`'s `## Blocked by` as issue `number`'s native `blocked_by` links. Best-effort: dispatch
 * reads only the body prose, so a failed link warns and never throws. Returns the count linked.
 */
export function linkBlockers(number, { mainRoot, exec = gh, body, warn = (m) => process.stderr.write(`${m}\n`) } = {}) {
  try {
    const blockers = blockerNumbers(sectionBody(body, "Blocked by") ?? "");
    let linked = 0;
    for (const blocker of blockers) {
      const idr = exec("gh", ["api", `${API}/issues/${blocker}`, "--jq", ".id"]);
      const id = String(idr.stdout ?? "").trim();
      if (idr.code !== 0 || !/^\d+$/.test(id)) {
        warn(`link-blockers: #${number}: blocker #${blocker} not found: ${idr.stderr || idr.stdout}`);
        continue;
      }
      const r = exec("gh", ["api", "-X", "POST", `${API}/issues/${number}/dependencies/blocked_by`, "-F", `issue_id=${id}`]);
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
 * The feature PR's `Closes #n` lines: every open `awaiting-merge` issue of the feature, plus its
 * open `PRD:` issue (and the PRD's `Origin:` issues) once no open work issue is left. A PR that
 * ships nothing closes nothing.
 */
export function closingRefs(mainRoot, { featureSlug, exec = gh } = {}) {
  const raw = featureIssuesJson(featureSlug, { exec }).filter(isOpen);
  const awaiting = (i) => (i.labels || []).some((l) => labelName(l) === AWAITING_MERGE_LABEL);
  const prds = raw.filter(isPrdIssue);
  const work = raw.filter((i) => !prds.includes(i));
  const ships = work.filter(awaiting);
  const prdCloses = ships.length > 0 && ships.length === work.length ? prds : [];
  const nums = new Set([...ships, ...prdCloses].map((i) => i.number));
  // A PRD's `Origin: #n[, #n…]` line (column 0, one line) names the issues it was written from.
  for (const prd of prdCloses) {
    const origin = /^Origin:[ \t]*(.*)$/m.exec(prd.body || "");
    for (const m of origin?.[1].matchAll(/#(\d+)/g) ?? []) nums.add(Number(m[1]));
  }
  return [...nums].sort((a, b) => a - b).map((n) => `Closes #${n}`);
}

/** A ref the CLI may pass to `gh`: an issue number, all digits — anything else is a usage error. */
export function validateRef(mainRoot, ref) {
  return /^[0-9]+$/.test(String(ref)) ? String(ref) : null;
}

/** `gh` reports an issue number with no issue behind it this way; anything else is a failure. */
const NOT_FOUND = /could not resolve to an? (?:issue|pullrequest|pull request)/i;

/** `{title, body, comments?, omitted?}` for issue `number`, or null when it does not exist; `comments` are trusted authors' only. */
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
    const all = (json.comments ?? []).map((c) => ({ id: c.id ?? "", author: c.author?.login ?? "", out: { author: c.author?.login ?? "", createdAt: c.createdAt ?? "", body: c.body ?? "" } }));
    const trusted = trustChecker({ exec, mainRoot })(all);
    out.comments = all.filter((c) => trusted.has(c)).map((c) => c.out);
    const dropped = all.filter((c) => !trusted.has(c));
    if (dropped.length) out.omitted = { count: dropped.length, authors: [...new Set(dropped.map((c) => c.author))] };
  }
  return out;
}

/** Issue `number`'s status (statusOf), or null when it does not exist. gh names the REST `state_reason` stateReason. */
export function issueStatus(mainRoot, number, { exec = gh } = {}) {
  const r = exec("gh", ["issue", "view", String(number), "--json", "state,stateReason,labels"]);
  if (r.code !== 0) {
    if (NOT_FOUND.test(r.stderr ?? "")) return null;
    throw new Error(`gh issue view failed (exit ${r.code}): ${r.stderr || r.stdout}`);
  }
  const json = JSON.parse(r.stdout || "{}");
  return statusOf({ ...json, state_reason: String(json.stateReason ?? "").toLowerCase() });
}

/** The feature's PRD body, headed by an HTML comment naming its number and title; null when none. */
export function readPrd(mainRoot, { featureSlug, exec = gh } = {}) {
  const prd = listFeatureIssues(mainRoot, { featureSlug, exec }).find(isPrdIssue);
  return prd ? `<!-- PRD issue #${prd.number}: ${prd.title} -->\n${prd.text}\n` : null;
}

/** The file `known` writes for one issue: named `<n>-<slug>.md`, `# <title>` then the body. */
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

/**
 * `publish-issues`' github side: the first issue of a slug with no root becomes the root, every
 * later one its sub-issue. Issues only accumulate, so there is no re-run guard.
 */
export function beginPublish(mainRoot, { featureSlug, exec = gh } = {}) {
  let parent;
  return {
    create(draft) {
      parent ??= findRoot(featureSlug, { exec })?.number ?? null;
      const { number } = createIssue(
        { title: draft.title, body: draftBody(draft.text), labels: [draft.status], featureSlug },
        { mainRoot, exec, parent },
      );
      if (number === null) throw new Error(`gh issue create printed no issue URL for ${draft.file}`);
      parent ??= number;
      return { ref: String(number), blockerRef: `Issue #${number}` };
    },
  };
}

/**
 * Update the feature's `PRD:` issue or create one: as the root when the slug has none, else under
 * the root. An edit keeps the root's marker. Returns the issue number.
 */
export function publishPrd(mainRoot, { featureSlug, title, body, exec = gh } = {}) {
  const root = findRoot(featureSlug, { exec });
  const existing = root ? rootAndSubIssues(root, { exec }).find(isPrdIssue) : null;
  if (!existing) {
    const { number } = createIssue({ title: `PRD: ${title}`, body, featureSlug }, { mainRoot, exec, parent: root?.number ?? null });
    if (number === null) throw new Error("gh issue create printed no issue URL for the PRD");
    return String(number);
  }
  const text = existing.number === root.number ? withMarker(body, featureSlug) : withoutMarker(body);
  const r = withBodyFile(text, (f) => exec("gh", ["issue", "edit", String(existing.number), "--body-file", f]));
  if (r.code !== 0) throw new Error(`gh issue edit failed (exit ${r.code}): ${r.stderr || r.stdout}`);
  return String(existing.number);
}

/** Issue `number`'s parent issue (REST JSON), or null when it has none (the API answers 404). */
function parentOf(number, { exec }) {
  const r = exec("gh", ["api", `${API}/issues/${number}/parent`]);
  if (r.code !== 0) {
    if (/HTTP 404|Not Found/i.test(r.stderr ?? "")) return null;
    throw new Error(`gh api ${API}/issues/${number}/parent failed (exit ${r.code}): ${r.stderr || r.stdout}`);
  }
  const parent = JSON.parse(r.stdout || "{}");
  return parent.number ? parent : null;
}

/**
 * Rewrite a single-slice source issue's body (a `Source:` line kept), set `status` as its only
 * triage label and file it in the feature: as its root when the slug has none, else under the
 * root. Never moves an issue out of another feature; a new root keeps a parent that is no root. `--remove-label` fails on a label the issue
 * lacks, so only carried ones are named. Null when the issue does not exist.
 */
export function rewriteIssue(mainRoot, number, { body, status, featureSlug, exec = gh } = {}) {
  const read = exec("gh", ["issue", "view", String(number), "--json", "labels,body"]);
  if (read.code !== 0) {
    if (notFound(read)) return null;
    throw new Error(`gh issue view failed (exit ${read.code}): ${read.stderr || read.stdout}`);
  }
  const current = JSON.parse(read.stdout || "{}");
  const own = featureMarker(current.body);
  if (own && own !== featureSlug) {
    throw new Error(`rewrite: issue #${number} is the root of feature ${own} (its 'Feature: ${own}' line) — not filing it under ${featureSlug}`);
  }
  const carried = new Set((current.labels ?? []).map(labelName));
  const remove = TRIAGE_LABELS.filter((name) => name !== status && carried.has(name))
    .flatMap((name) => ["--remove-label", name]);

  const root = findRoot(featureSlug, { exec });
  const isRoot = !root || root.number === Number(number);
  const parent = root?.number === Number(number) ? null : parentOf(number, { exec });
  // A new root stays under a parent that is no feature's root: making it the root moves nothing.
  const keepsParent = !root && parent && !featureMarker(parent.body);
  if (parent && parent.number !== root?.number && !keepsParent) {
    throw new Error(`rewrite: issue #${number} is already a sub-issue of #${parent.number}, not of feature ${featureSlug}'s root — not moving it`);
  }
  const text = isRoot ? withMarker(draftBody(body), featureSlug) : withoutMarker(draftBody(body));
  const move = isRoot || parent?.number === root.number ? [] : ["--parent", String(root.number)];
  ensureStatusLabels(exec);
  const r = withBodyFile(text, (f) =>
    exec("gh", ["issue", "edit", String(number), "--body-file", f, ...remove, "--add-label", status, ...move]),
  );
  if (r.code !== 0) {
    if (notFound(r)) return null;
    throw new Error(`gh issue edit failed (exit ${r.code}): ${r.stderr || r.stdout}`);
  }
  return true;
}

/** Every criterion of issue `number`'s live body ticked; the count, or null when gh knows no such issue. */
export function tickIssue(mainRoot, number, { exec = gh } = {}) {
  const r = exec("gh", ["issue", "view", String(number), "--json", "body", "--jq", ".body"]);
  if (r.code !== 0) {
    if (NOT_FOUND.test(r.stderr ?? "")) return null;
    throw new Error(`gh issue view failed (exit ${r.code}): ${r.stderr || r.stdout}`);
  }
  const { text, ticked } = tickCriteria(r.stdout ?? "");
  if (!ticked) return 0;
  const edit = withBodyFile(text, (f) => exec("gh", ["issue", "edit", String(number), "--body-file", f]));
  if (edit.code !== 0) throw new Error(`gh issue edit failed (exit ${edit.code}): ${edit.stderr || edit.stdout}`);
  return ticked;
}

/** `## <heading>` as a new comment on issue `number`, never a body edit: the body stays whoever wrote it's. */
export function writeSection(mainRoot, number, { heading, body, exec = gh } = {}) {
  const r = exec("gh", ["issue", "comment", String(number), "--body", `## ${heading}\n\n${body}`]);
  if (r.code !== 0) throw new Error(`gh issue comment failed (exit ${r.code}): ${r.stderr || r.stdout}`);
  return true;
}

/** What `mark-done` closes: a github issue has no file, so only its name. */
export function doneTarget(mainRoot, number) {
  return { name: `issue #${number}` };
}

/** Issue `number`'s body, fetched live — never a copy the caller may hold — for `mark-done`'s criteria guard. */
export function readIssueBody(mainRoot, number, { exec = gh } = {}) {
  const r = exec("gh", ["issue", "view", String(number), "--json", "body", "--jq", ".body"]);
  if (r.code !== 0) throw new Error(`ERROR: gh issue view failed for #${number}:\n${r.stderr || r.stdout}`);
  return r.stdout ?? "";
}

/**
 * Mark issue `number` done, not closed: the work is only on a branch, and the PR's `Closes #n`
 * closes it. `--remove-label` fails on one the issue lacks, so only the ready labels it carries are named.
 */
export function markDone(mainRoot, number, { exec = gh } = {}) {
  ensureStatusLabels(exec);
  const read = exec("gh", ["issue", "view", String(number), "--json", "labels"]);
  if (read.code !== 0) throw new Error(`ERROR: gh issue view failed for #${number}:\n${read.stderr || read.stdout}`);
  const carried = new Set((JSON.parse(read.stdout || "{}").labels ?? []).map(labelName));
  const remove = ["ready-for-agent", "ready-for-human"].filter((l) => carried.has(l)).flatMap((l) => ["--remove-label", l]);
  const edit = exec("gh", ["issue", "edit", String(number), "--add-label", AWAITING_MERGE_LABEL, ...remove]);
  if (edit.code !== 0) throw new Error(`ERROR: gh issue edit failed for #${number}:\n${edit.stderr || edit.stdout}`);
  return `DONE: issue #${number} labelled ${AWAITING_MERGE_LABEL} — put 'Closes #${number}' in the PR body so merging it closes the issue`;
}

/**
 * Undo markDone: `awaiting-merge` swapped back for `ready-for-agent`, and an issue its merged PR closed reopened
 * first. `--remove-label` fails on a label the issue lacks, so it is named only when carried. Null when the issue
 * does not exist.
 */
export function reopenIssue(mainRoot, number, { exec = gh } = {}) {
  const read = exec("gh", ["issue", "view", String(number), "--json", "state,labels"]);
  if (read.code !== 0) {
    if (notFound(read)) return null;
    throw new Error(`gh issue view failed (exit ${read.code}): ${read.stderr || read.stdout}`);
  }
  const issue = JSON.parse(read.stdout || "{}");
  if (!isOpen(issue)) {
    const r = exec("gh", ["issue", "reopen", String(number)]);
    if (r.code !== 0) throw new Error(`gh issue reopen failed (exit ${r.code}): ${r.stderr || r.stdout}`);
  }
  const carried = (issue.labels ?? []).some((l) => labelName(l) === AWAITING_MERGE_LABEL);
  const remove = carried ? ["--remove-label", AWAITING_MERGE_LABEL] : [];
  ensureStatusLabels(exec);
  const edit = exec("gh", ["issue", "edit", String(number), "--add-label", READY_STATUS, ...remove]);
  if (edit.code !== 0) throw new Error(`gh issue edit failed (exit ${edit.code}): ${edit.stderr || edit.stdout}`);
  return `REOPENED: issue #${number} labelled ${READY_STATUS}`;
}
