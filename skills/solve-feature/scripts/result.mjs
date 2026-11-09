#!/usr/bin/env node
// result.mjs --logs <dir> --slug <feature> --cli <tracker cli.mjs> --default <branch> --publish yes|no [--pr <n|local>] — writes
// <dir>/result.json (result.schema.json beside SKILL.md) from the run's files and git. It reads what the script and
// its subagents wrote, splitting prose only into lines; any error exits non-zero, leaving the earlier file untouched.
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync, renameSync, writeFileSync } from "node:fs";
import { basename, join } from "node:path";

const args = {};
for (let i = 2; i < process.argv.length; i += 2) args[process.argv[i].replace(/^--/, "")] = process.argv[i + 1] ?? "";
const LOGS = args.logs;

const run = (cmd, argv) => spawnSync(cmd, argv, { encoding: "utf8" });
const git = (...argv) => {
  const r = run("git", argv);
  if (r.status !== 0) throw new Error(`git ${argv.join(" ")} failed: ${r.stderr.trim()}`);
  return r.stdout;
};
const at = (name) => join(LOGS, name);
const text = (name) => (existsSync(at(name)) ? readFileSync(at(name), "utf8").replace(/\r/g, "") : null);
const lines = (name) => (text(name) ?? "").split("\n").map((l) => l.trimEnd()).filter((l) => l.trim() !== "");

// run-checks.sh's `<key>: pass|fail…` verdicts; a second pass's verdict replaces the first's.
function checkResults(name) {
  const results = new Map();
  for (const l of lines(name)) {
    const m = /^([a-z][A-Za-z0-9_.-]*): (pass|fail\b.*)$/.exec(l);
    if (m) results.set(m[1], m[2]);
  }
  return [...results].map(([key, result]) => ({ key, result }));
}

// preflight.sh's ISSUE_SLUG: the ref's basename without .md. A spec section's id is that slug, or it followed by
// `-<title slug>`; an exact match wins.
const slugOf = (ref) => basename(ref).replace(/\.md$/, "");
const pick = (id, candidates, slug) =>
  candidates.find((c) => slug(c) === id) ?? candidates.find((c) => id.startsWith(`${slug(c)}-`));

const outcome = (text("outcome") ?? "").split("\n")[0];
const branch = git("branch", "--show-current").trim();
const head = git("rev-parse", "HEAD").trim();
const result = { outcome, branch, head };

const files = readdirSync(LOGS);
const roundRe = /^pr-(\d+|local)\.r(\d+)\.review\.json$/;
const pr = /^\d+$/.test(args.pr ?? "") ? args.pr : "";
if (args.publish === "yes" && pr) result.pr = Number(pr);
if (args.publish === "no") {
  const body = text(`local-pr-${branch.replace(/\//g, "_")}.md`);
  if (body !== null) {
    const [first, ...rest] = body.split("\n");
    if (rest[0] === "") rest.shift();
    result.pr_title = first.replace(/^# /, "");
    result.pr_body = rest.join("\n");
  }
}

// The branch's own commits: first-parent, so what a merge of the default branch brought in is not counted.
const base = [`origin/${args.default}`, args.default].find((r) => run("git", ["rev-parse", "-q", "--verify", `${r}^{commit}`]).status === 0);
const subjects = git("log", "--first-parent", "--reverse", "--format=%s", "HEAD", ...(base ? ["--not", base] : []))
  .split("\n")
  .filter(Boolean);
const prefixes = [...new Set(subjects.map((s) => /^\[([^\]]+)\]/.exec(s)?.[1]).filter(Boolean))];
// The refs next handed out: one <ref, / → _>.ref file each. The directory is shared by every feature, and a local
// tracker's ref is a path `…/<feature slug>/issues/…` whose basename another feature's issue can share: those go.
const refs = files
  .filter((f) => f.endsWith(".ref"))
  .map((f) => readFileSync(at(f), "utf8").split("\n")[0])
  .filter((r) => r && (/\/([^/]+)\/issues\//.exec(r)?.[1] ?? args.slug) === args.slug);

const issues = [];
for (const l of lines("spec.md")) {
  const m = /^### (\S+) — (.*)$/.exec(l);
  if (!m) continue;
  const [, id, title] = m;
  const ref = pick(id, refs, slugOf);
  const slug = ref ? slugOf(ref) : pick(id, prefixes, (p) => p);
  // An issue no next in this checkout handed out (an earlier runner's) is tried by its id, then the id's first
  // `-` part, the ref of a tracker that names sections `<number>-<title slug>`; a ref the tracker rejects is unknown.
  let status = "unknown";
  for (const target of new Set([ref, slug, id, id.split("-")[0]].filter(Boolean))) {
    const r = run("node", [args.cli, "status", target]);
    if (r.status !== 0) continue;
    status = r.stdout.trim() === "done" ? "done" : "not done";
    break;
  }
  const rs = (ref ?? slug ?? id).replace(/\//g, "_");
  const commits = slug ? subjects.filter((s) => s.startsWith(`[${slug}]`)) : [];
  const checksHead = text(`${rs}.checks.head`);
  const checks = checksHead === null ? null : { commit: checksHead.split("\n")[0], results: checkResults(`${rs}.checks.log`) };
  issues.push({ ref: id, title, status, commits, checks, red: lines(`${rs}.red.md`) });
}
result.issues = issues;

const red = issues.flatMap((i) => i.red);
// Exact strings only: a test carries the red line that starts with it and the ` — ` before the failing line.
const redFor = (test) => red.find((r) => r.startsWith(`${test} — `)) ?? null;

const kept = files
  .map((f) => roundRe.exec(f))
  .filter((m) => m && (!pr || m[1] === pr || m[1] === "local"))
  .map((m) => ({ stem: `pr-${m[1]}.r${m[2]}`, k: Number(m[2]) }))
  .sort((a, b) => a.k - b.k);
const rounds = kept.map(({ stem }) => ({ review: `${stem}.review.json`, unfixed: `${stem}.unfixed.md`, stem }));
// A live report a stopped fix never moved is the last round.
const live = files.find((f) => /^pr-(\d+|local)\.review\.json$/.test(f) && (!pr || f === `pr-${pr}.review.json` || f === "pr-local.review.json"));
if (live) rounds.push({ review: live, unfixed: live.replace(/\.review\.json$/, ".unfixed.md"), stem: null });

// A reviewer's report is read leniently: one off the expected shape (the stops reviewed and fix make for it, too)
// renders as a round with that field empty, never as no result.json.
const list = (x) => (Array.isArray(x) ? x : []);
const readReport = (name) => {
  try {
    const report = JSON.parse(text(name));
    return report && typeof report === "object" && !Array.isArray(report) ? report : {};
  } catch {
    return {};
  }
};

result.rounds = rounds.map((r, i) => {
  const report = readReport(r.review);
  const criteria = list(report.criteria).map((c) => ({
    issue: String(c?.issue ?? ""),
    text: String(c?.text ?? ""),
    met: c?.met === true,
    tests: list(c?.tests).map((t) => ({ test: String(t), red: redFor(String(t)) })),
  }));
  const cited = new Set(criteria.flatMap((c) => c.tests.map((t) => t.red)).filter(Boolean));
  const fix = r.stem && text(`${r.stem}.fix`) !== null ? JSON.parse(text(`${r.stem}.fix`)) : null;
  return {
    spec: String(report.spec ?? ""),
    gaps: list(report.gaps).map(String),
    findings: list(report.findings).filter((f) => f && typeof f === "object" && !Array.isArray(f)),
    criteria,
    unfixed: lines(r.unfixed),
    unmatched_red: red.filter((l) => !cited.has(l)),
    fixer_changed_code: fix ? fix.fixer_changed_code === true : null,
    checks: fix ? checkResults(`${r.stem}.checks.log`) : null,
    checks_commit: fix ? String(fix.checks_commit) : null,
    re_reviewed: i < rounds.length - 1,
  };
});

writeFileSync(at("result.json.tmp"), `${JSON.stringify(result, null, 2)}\n`);
renameSync(at("result.json.tmp"), at("result.json"));
