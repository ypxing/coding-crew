#!/usr/bin/env node
/**
 * fake-github.mjs — a stateful stand-in for the `gh` calls tracker/github.mjs and the crew-afk
 * scripts make, so a test sees a feature as GitHub does: a root issue and its sub-issues.
 *   in-process: `fakeGithub(issues, {fail})` is an `exec` for github.mjs (`.calls`, `.issues`)
 *   as a script: `node fake-github.mjs <issues.json> <gh argv…>` reads and rewrites issues.json,
 *   for a `gh` stub on PATH.
 * An issue is `{number, title, body, state: OPEN|CLOSED, labels: [{name}], parent?, pull_request?}`.
 * REST lists page like the API (`per_page`, default 30): one page unless `--paginate`, the pages
 * as one array only with `--slurp`. Any milestone call, and `gh issue list`, fails.
 */

import { readFileSync, realpathSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const API = "repos/{owner}/{repo}/";

/** One issue for a fixture; `body` may be omitted. */
export function ghIssue(number, { title = `Issue ${number}`, body = "", state = "OPEN", labels = [], parent, pr = false } = {}) {
  return {
    number,
    title,
    body,
    state,
    labels: labels.map((name) => ({ name })),
    ...(parent === undefined ? {} : { parent }),
    ...(pr ? { pull_request: { url: `https://api.github.com/repos/o/r/pulls/${number}` } } : {}),
  };
}

/** A feature: `root` carries `Feature: <slug>`, every other issue is its sub-issue. */
export function ghFeature(slug, root, ...subs) {
  return [
    { ...root, body: `Feature: ${slug}\n\n${root.body ?? ""}` },
    ...subs.map((s) => ({ ...s, parent: root.number })),
  ];
}

/** `i` as the REST API prints it; `issues` gives the counts in its `sub_issues_summary`. */
const rest = (i, issues = []) => {
  const subs = issues.filter((s) => s.parent === i.number);
  const completed = subs.filter((s) => String(s.state).toUpperCase() === "CLOSED").length;
  return {
    id: i.number * 1000,
    number: i.number,
    title: i.title,
    body: i.body ?? "",
    state: String(i.state).toLowerCase(),
    labels: i.labels ?? [],
    ...(i.pull_request
      ? { pull_request: i.pull_request }
      : { sub_issues_summary: { total: subs.length, completed, percent_completed: subs.length ? Math.floor((100 * completed) / subs.length) : 0 } }),
  };
};

const ok = (stdout = "") => ({ code: 0, stdout, stderr: "" });
const fail = (stderr, code = 1) => ({ code, stdout: "", stderr: `${stderr}\n` });
const notFound = (n) => fail(`GraphQL: Could not resolve to an issue or pull request with the number of ${n}. (repository.issue)`);

function flag(args, name) {
  const i = args.indexOf(name);
  return i === -1 ? undefined : args[i + 1];
}
const flags = (args, name) => args.flatMap((a, i) => (a === name ? [args[i + 1]] : []));

/** `list` as the REST API pages it, then as `gh api` prints the pages. */
function paged(list, query, args) {
  const per = Math.min(Number(query.get("per_page") ?? 30), 100);
  const pages = [];
  for (let i = 0; i < list.length || pages.length === 0; i += per) pages.push(list.slice(i, i + per));
  if (!args.includes("--paginate")) return ok(JSON.stringify(pages[0]));
  if (args.includes("--slurp")) return ok(JSON.stringify(pages));
  return ok(pages.map((p) => JSON.stringify(p)).join(""));
}

/** A `gh api` call. */
function api(issues, args, { lagged }) {
  const path = args.slice(1).find((a, i) => !a.startsWith("-") && !["-X", "--method", "-f", "-F", "--jq", "-q", "--input"].includes(args[i]));
  const method = String(flag(args, "-X") ?? flag(args, "--method") ?? "GET").toUpperCase();
  if (!path?.startsWith(API)) return fail(`fake gh: unexpected api path: ${path}`);
  const [route, qs = ""] = path.slice(API.length).split("?");
  const query = new URLSearchParams(qs);
  const visible = issues.filter((i) => !lagged(i));

  if (route === "issues" && method === "GET") {
    const state = query.get("state") ?? "open";
    const list = visible
      .filter((i) => state === "all" || String(i.state).toLowerCase() === state)
      .sort((a, b) => b.number - a.number)
      .map((i) => rest(i, issues));
    return paged(list, query, args);
  }
  let m = /^issues\/(\d+)\/sub_issues$/.exec(route);
  if (m && method === "GET") {
    const list = visible.filter((i) => i.parent === Number(m[1])).sort((a, b) => a.number - b.number).map((i) => rest(i, issues));
    return paged(list, query, args);
  }
  m = /^issues\/(\d+)\/parent$/.exec(route);
  if (m) {
    const child = issues.find((i) => i.number === Number(m[1]));
    const parent = child && issues.find((i) => i.number === child.parent);
    return parent ? ok(JSON.stringify(rest(parent, issues))) : fail("gh: Not Found (HTTP 404)");
  }
  m = /^issues\/(\d+)$/.exec(route);
  if (m) {
    const issue = issues.find((i) => i.number === Number(m[1]));
    if (!issue) return fail("gh: Not Found (HTTP 404)");
    return ok(args.includes("--jq") ? `${issue.number * 1000}\n` : JSON.stringify(rest(issue, issues)));
  }
  if (/^issues\/\d+\/dependencies\/blocked_by$/.test(route)) return ok("{}");
  return fail(`fake gh: unexpected api call: ${args.join(" ")}`);
}

/** `gh issue view N --json f[,f…] [--jq|-q expr]`. */
function view(issue, args) {
  const jq = flag(args, "--jq") ?? flag(args, "-q");
  const names = (issue.labels ?? []).map((l) => l.name);
  if (jq === ".body" || jq === '.body // ""') return ok(`${issue.body ?? ""}\n`);
  if (jq === ".labels[].name") return ok(names.map((n) => `${n}\n`).join(""));
  if (jq === ".state") return ok(`${issue.state}\n`);
  if (jq) return fail(`fake gh: unsupported --jq ${jq}`);
  const fields = (flag(args, "--json") ?? "").split(",").filter(Boolean);
  const all = { ...issue, comments: issue.comments ?? [] };
  return ok(JSON.stringify(Object.fromEntries(fields.map((f) => [f, all[f]]))));
}

/** Handle one `gh` argv against `issues` (mutated in place). */
export function handle(issues, args, { lagged = () => false } = {}) {
  if (args.some((a) => /milestone/i.test(a))) return fail(`fake gh: milestones are gone: ${args.join(" ")}`);
  const [group, sub] = args;
  if (group === "api") return api(issues, args, { lagged });
  if (group === "label" && sub === "create") return ok();
  if (group !== "issue") return fail(`fake gh: unexpected call: ${args.join(" ")}`);
  if (sub === "list") return fail("fake gh: gh issue list is not how a feature is read");
  if (sub === "create") {
    const parent = flag(args, "--parent");
    if (parent !== undefined && !issues.some((i) => i.number === Number(parent))) return notFound(parent);
    const number = Math.max(0, ...issues.map((i) => i.number)) + 1;
    issues.push({
      number,
      title: flag(args, "--title"),
      body: readFileSync(flag(args, "--body-file"), "utf8"),
      state: "OPEN",
      labels: flags(args, "--label").map((name) => ({ name })),
      ...(parent === undefined ? {} : { parent: Number(parent) }),
    });
    return ok(`https://github.com/o/r/issues/${number}\n`);
  }
  const issue = issues.find((i) => i.number === Number(args[2]));
  if (!issue) return notFound(args[2]);
  switch (sub) {
    case "view":
      return view(issue, args);
    case "edit": {
      const bodyFile = flag(args, "--body-file");
      if (bodyFile !== undefined) issue.body = readFileSync(bodyFile, "utf8");
      const parent = flag(args, "--parent");
      if (parent !== undefined) {
        if (!issues.some((i) => i.number === Number(parent))) return notFound(parent);
        issue.parent = Number(parent);
      }
      const names = new Set((issue.labels ?? []).map((l) => l.name));
      for (const l of flags(args, "--remove-label")) names.delete(l);
      for (const l of flags(args, "--add-label")) names.add(l);
      issue.labels = [...names].map((name) => ({ name }));
      return ok(`https://github.com/o/r/issues/${issue.number}\n`);
    }
    case "close":
      issue.state = "CLOSED";
      return ok();
    case "reopen":
      issue.state = "OPEN";
      return ok();
    case "comment":
    case "pin":
      return ok();
    default:
      return fail(`fake gh: unexpected call: ${args.join(" ")}`);
  }
}

/**
 * An in-process `exec`: `fail` maps an argv prefix ("api repos/…") to the `{code, stderr}` it returns.
 * `lagCreates` hides every issue it creates from list reads, as GitHub's lists lag a create by seconds.
 */
export function fakeGithub(issues = [], { fail: failures = {}, lagCreates = false } = {}) {
  const calls = [];
  const created = new Set();
  const lagged = (i) => lagCreates && created.has(i.number);
  const exec = (cmd, args) => {
    calls.push([cmd, ...args]);
    const key = Object.keys(failures).find((k) => args.join(" ").startsWith(k));
    if (key) return { code: failures[key].code ?? 1, stdout: "", stderr: failures[key].stderr ?? "" };
    const r = handle(exec.issues, args, { lagged });
    if (args[0] === "issue" && args[1] === "create" && r.code === 0) created.add(Math.max(...exec.issues.map((i) => i.number)));
    return r;
  };
  exec.issues = issues.map((i) => ({ ...i }));
  exec.calls = calls;
  return exec;
}

function invokedDirectly() {
  try {
    return Boolean(process.argv[1]) && realpathSync(fileURLToPath(import.meta.url)) === realpathSync(process.argv[1]);
  } catch {
    return false;
  }
}

// GH_LIST_LAG_MS=N hides the newest issue a create made from list reads for N ms, as GitHub's lags.
if (invokedDirectly()) {
  const [file, ...args] = process.argv.slice(2);
  const issues = JSON.parse(readFileSync(file, "utf8"));
  const lagFile = `${file}.lag`;
  let lag = null;
  try {
    lag = JSON.parse(readFileSync(lagFile, "utf8"));
  } catch {
  }
  const lagged = (i) => Boolean(lag && Date.now() < lag.until && i.number === lag.number);
  const r = handle(issues, args, { lagged });
  writeFileSync(file, JSON.stringify(issues));
  const ms = Number(process.env.GH_LIST_LAG_MS || 0);
  if (ms && args[0] === "issue" && args[1] === "create" && r.code === 0) {
    writeFileSync(lagFile, JSON.stringify({ number: Math.max(...issues.map((i) => i.number)), until: Date.now() + ms }));
  }
  process.stdout.write(r.stdout);
  process.stderr.write(r.stderr);
  process.exitCode = r.code;
}
