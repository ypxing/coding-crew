#!/usr/bin/env node
// field-review.mjs — run two crew-review versions on the same range of another project, blind, and keep
// what a maintainer needs to compare them: both reports, cost and time, and a verdict sheet. Maintainer-only,
// costs API money (two reviewer runs).
// Usage: node scripts/field-review.mjs <project path> [--range <base>..<head>] [--spec <file>]
//   [--skill-base <ref>] [--skill-head <ref>|worktree] [--model opus] [--out <dir>] [--dry-run]
// --range defaults to the merge-base of the project's HEAD with origin/<default branch>, to HEAD.
// --skill-base defaults to main and --skill-head to this checkout: the coding-crew versions whose
// skills/crew-review/SKILL.md each reviewer follows. Nothing is installed into the project; each reviewer
// gets its own detached worktree of it, removed afterwards.
// Writes <out>/<project>/<date>-<head8>/: meta.json, A.out.md and B.out.md (labels shuffled), key.json
// (which label is which version: open it after verdicts.md), verdicts.md and misses.md to fill in.

import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { runClaude, shuffleLabels } from "./eval-design-skills.mjs";

const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8" }).trim();
const HEADLESS_SETTINGS = JSON.stringify({ disableClaudeAiConnectors: true, disableBundledSkills: true });
const MANIFESTS = ["package.json", "pyproject.toml", "requirements.txt", "go.mod", "Cargo.toml", "Gemfile",
  "pom.xml", "build.gradle", "build.gradle.kts", "composer.json", "mix.exs", "Package.swift", "CMakeLists.txt"];

function parseArgs(argv) {
  const o = { project: null, range: null, spec: null, skillBase: "main", skillHead: "worktree", model: "opus",
    out: path.join(os.homedir(), "crew-review-field"), dryRun: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i], v = () => {
      if (i + 1 >= argv.length) throw new Error(`${a} needs a value`);
      return argv[++i];
    };
    switch (a) {
      case "--range": o.range = v(); break;
      case "--spec": o.spec = path.resolve(v()); break;
      case "--skill-base": o.skillBase = v(); break;
      case "--skill-head": o.skillHead = v(); break;
      case "--model": o.model = v(); break;
      case "--out": o.out = path.resolve(v()); break;
      case "--dry-run": o.dryRun = true; break;
      default:
        if (a.startsWith("--") || o.project) throw new Error(`unknown argument: ${a}`);
        o.project = path.resolve(a);
    }
  }
  if (!o.project) throw new Error("usage: field-review.mjs <project path> [--range <base>..<head>] [--spec <file>]");
  if (o.spec && !fs.existsSync(o.spec)) throw new Error(`--spec ${o.spec} does not exist`);
  return o;
}

const git = (args, cwd) => {
  const r = spawnSync("git", args, { cwd, encoding: "utf8" });
  if (r.status !== 0) throw new Error(`git ${args.join(" ")} (in ${cwd}): ${r.stderr.trim()}`);
  return r.stdout.trim();
};
const treeStatus = (dir) => git(["status", "--porcelain", "--untracked-files=all"], dir);

function resolveRange(project, range) {
  if (range) {
    const m = /^(.+?)\.\.(.+)$/.exec(range);
    if (!m) throw new Error(`--range must be <base>..<head>, got ${range}`);
    return { base: git(["rev-parse", "--verify", `${m[1]}^{commit}`], project), head: git(["rev-parse", "--verify", `${m[2]}^{commit}`], project) };
  }
  const def = git(["rev-parse", "--abbrev-ref", "origin/HEAD"], project);
  return { base: git(["merge-base", "HEAD", def], project), head: git(["rev-parse", "HEAD"], project) };
}

/** The project's ecosystems and size, from its root manifests and tracked files at the head. */
function projectType(project, head) {
  const files = git(["ls-tree", "-r", "--name-only", head], project).split("\n").filter(Boolean);
  return { manifests: MANIFESTS.filter((m) => files.includes(m)), trackedFiles: files.length,
    hasTests: files.some((f) => /(^|\/)(tests?|spec|__tests__)\/|[._-](test|spec)\.[a-z]+$/i.test(f)) };
}

function reviewPrompt(skill, base, spec) {
  const against = spec ? `against the spec in ${spec}` : "with no spec (skip question 1)";
  return `Review branch HEAD, base ${base} (the change is \`git diff ${base}..HEAD\`), ${against}, following the ` +
    `Review section of ${skill}. You are the reviewer: answer its three questions yourself.\n\n` +
    "FIELD MODE (non-interactive): write nothing in the repo; scratch files outside it are fine. Where the " +
    "protocol says to write the report file, print that JSON object in a fenced ```json block as the last " +
    "thing in your final message.\n";
}

/** The `findings` of the last fenced json block that has them; null when none parses. */
export function reportFindings(text) {
  const blocks = [...String(text).matchAll(/```(?:json)?[ \t]*\n([\s\S]*?)\n[ \t]*```/g)];
  for (let i = blocks.length - 1; i >= 0; i--) {
    try {
      const v = JSON.parse(blocks[i][1]);
      if (Array.isArray(v?.findings)) return v.findings;
    } catch { /* previous block */ }
  }
  return null;
}

export function verdictSheet(labelled) {
  const lines = ["# Verdicts", "",
    "Mark each finding `real` (a defect worth fixing), `false` (not a defect) or `nit` (true, not worth a finding).",
    "Open key.json only once every line is marked.", ""];
  for (const { label, text, failure } of labelled) {
    lines.push(`## ${label}`, "");
    const findings = failure ? null : reportFindings(text);
    if (failure) lines.push(`Run failed: ${failure}`);
    else if (findings === null) lines.push(`No report parsed; read ${label}.out.md.`);
    else if (!findings.length) lines.push("No findings.");
    else for (const f of findings) lines.push(`- verdict: ___ — ${f.severity ?? "?"} \`${f.location ?? "?"}\` — ${f.issue ?? ""}`);
    lines.push("");
  }
  return lines.join("\n");
}

const MISSES = `# Misses

A defect in this range the reviews missed, found later: one line each, so it can become an eval case.

<!-- - \`<file:line>\` — what broke — <fix sha> -->
`;

async function main() {
  const o = parseArgs(process.argv.slice(2));
  const project = git(["rev-parse", "--show-toplevel"], o.project);
  const { base, head } = resolveRange(project, o.range);
  const name = path.basename(project);
  const outDir = path.join(o.out, name, `${new Date().toISOString().slice(0, 10)}-${head.slice(0, 8)}`);
  if (fs.existsSync(outDir)) throw new Error(`${outDir} already exists: move it aside or pass --out`);

  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "field-review-"));
  const trees = []; // [repo, dir] to remove
  const addTree = (repo, dir, ref) => { git(["worktree", "add", "-q", "--detach", dir, ref], repo); trees.push([repo, dir]); return dir; };
  try {
    const versions = [["base", o.skillBase], ["head", o.skillHead]].map(([version, ref]) => {
      const tree = ref === "worktree" ? ROOT : addTree(ROOT, path.join(scratch, `skill-${version}`), ref);
      const skill = path.join(tree, "skills", "crew-review", "SKILL.md");
      if (!fs.existsSync(skill)) throw new Error(`--skill-${version} ${ref} has no skills/crew-review/SKILL.md`);
      return { version, ref, sha: git(["rev-parse", "HEAD"], tree), dirty: ref === "worktree" && treeStatus(tree) !== "", skill };
    });
    fs.mkdirSync(outDir, { recursive: true });
    const spec = o.spec ? path.join(outDir, `spec${path.extname(o.spec) || ".md"}`) : null;
    if (spec) fs.copyFileSync(o.spec, spec);
    let remote = null;
    try { remote = git(["remote", "get-url", "origin"], project); } catch { /* no origin */ }
    const meta = { project: name, path: project, remote, base, head, spec: o.spec, model: o.model,
      date: new Date().toISOString(), type: projectType(project, head),
      skills: versions.map(({ version, ref, sha, dirty }) => ({ version, ref, sha, dirty })) };

    if (o.dryRun) {
      for (const v of versions) fs.writeFileSync(path.join(outDir, `${v.version}.prompt.md`), reviewPrompt(v.skill, base, spec));
      fs.writeFileSync(path.join(outDir, "meta.json"), JSON.stringify(meta, null, 2) + "\n");
      console.log(`Dry run: prompts and meta.json written to ${outDir}. No model was called.`);
      return;
    }

    const flags = ["-p", "--model", o.model, "--output-format", "json", "--max-turns", "80", "--settings", HEADLESS_SETTINGS,
      "--permission-mode", "bypassPermissions", "--tools", "Bash", "Read", "Agent", "ToolSearch"];
    console.log(`${name} ${base.slice(0, 8)}..${head.slice(0, 8)}: two reviewers on ${o.model} (${versions.map((v) => `${v.version}=${v.ref}`).join(", ")})`);
    const runs = await Promise.all(versions.map(async (v) => {
      const tree = addTree(project, path.join(scratch, `project-${v.version}`), head);
      const before = treeStatus(tree);
      const started = Date.now();
      const r = await runClaude(flags, reviewPrompt(v.skill, base, spec), tree);
      const seconds = Math.round((Date.now() - started) / 1000);
      const moved = git(["rev-parse", "HEAD"], tree) !== head, dirtied = treeStatus(tree) !== before;
      const failure = !r.ok ? (r.err || r.text).trim().split("\n")[0]
        : moved || dirtied ? "changed its worktree" : null;
      console.log(`  ${v.version}: ${failure ? `FAILED (${failure})` : "ok"} $${r.cost.toFixed(2)} ${seconds}s`);
      return { version: v.version, text: r.text, failure, cost: r.cost, seconds };
    }));

    const labelled = shuffleLabels(runs);
    for (const l of labelled) fs.writeFileSync(path.join(outDir, `${l.label}.out.md`), l.failure ? `RUN FAILED: ${l.failure}\n${l.text}` : l.text);
    meta.runs = labelled.map(({ label, failure, cost, seconds, text }) => ({ label, ok: !failure, cost, seconds, findings: reportFindings(text)?.length ?? null }));
    fs.writeFileSync(path.join(outDir, "meta.json"), JSON.stringify(meta, null, 2) + "\n");
    fs.writeFileSync(path.join(outDir, "key.json"), JSON.stringify(Object.fromEntries(labelled.map((l) => [l.label, l.version])), null, 2) + "\n");
    fs.writeFileSync(path.join(outDir, "verdicts.md"), verdictSheet(labelled));
    fs.writeFileSync(path.join(outDir, "misses.md"), MISSES);
    if (runs.some((r) => r.failure)) process.exitCode = 1;
    console.log(`\nWritten to ${outDir}: fill in verdicts.md (then open key.json), and misses.md when a missed bug turns up.`);
  } finally {
    for (const [repo, dir] of trees.reverse()) {
      try { execFileSync("git", ["worktree", "remove", "--force", dir], { cwd: repo, stdio: "ignore" }); } catch { /* best effort */ }
    }
    fs.rmSync(scratch, { recursive: true, force: true });
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((e) => { console.error(`field-review: ${e.message}`); process.exit(2); });
}
