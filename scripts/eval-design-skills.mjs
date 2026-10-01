#!/usr/bin/env node
// eval-design-skills.mjs — behavioural A/B check for crew-grill / crew-brainstorm.
//
// Why this exists: these skills shape every PRD, and their tests can only grep that a rule's text
// is present. Whether a rule changes what the model *does* needs a replay: run each case against
// the skill at a base ref and at the head, several times, then have a judge score every output
// blind against a fixed rubric. Maintainer-only; ships to no consumer. Costs real API money — it
// prints each run's cost — so it is run by hand after editing a design skill, never in CI.
//
// Usage: node scripts/eval-design-skills.mjs [--skill crew-grill|crew-brainstorm|all]
//          [--base <git ref>] [--head <git ref>|worktree] [--case <name>]... [--runs N]
//          [--model sonnet] [--judge-model opus] [--parallel 4] [--dry-run]
//
// Cases live in scripts/eval-design-skills/cases/*.md: front matter (skill, stage, repo_ref), then
// `## Request`, optional `## Transcript` (stage: close), and `## Reference judgement`, which only
// the judge sees. A reference judgement is a set of claims about the repo at repo_ref: verify every
// fact in it against that commit before committing the case — the judge scores against it, so a
// wrong reference silently inverts the result. State facts that live outside git (a count in a
// gitignored dir, an open PR) in the Request, as the user would. Results land in .scratch/eval-design-skills/<timestamp>/ (summary.md,
// results.json, every prompt and output).

import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8" }).trim();
const HERE = path.join(ROOT, "scripts", "eval-design-skills");
const CLAUDE = process.env.CLAUDE_BIN || "claude";

const STAGE_INSTRUCTIONS = {
  round1:
    "EVAL MODE (non-interactive): do your research read-only, then output ONLY what you would send the user at your first decision point (for a grill: your first round; for a brainstorm: the approaches you would propose, stating as assumptions anything you would otherwise ask one question at a time). Then stop. No user will answer. Modify nothing.",
  close:
    "EVAL MODE (non-interactive): the frontier is empty. Output exactly what you would send the user to close Phase 1 (everything up to and including the 'Ready to write the PRD?' line). Then assume the user answered 'y' with no other change, and output ONLY the '## Decisions' and '## Out of Scope' sections the PRD would get. You may read the repo to check facts, but modify nothing.",
};

const METRICS = ["sized", "do_least", "overbuilt", "underbuilt", "false_cut", "chain_priced"];
// Higher is better for these; lower is better for the rest.
const GOOD_HIGH = new Set(["sized", "do_least", "chain_priced"]);

function parseArgs(argv) {
  const o = { skill: "all", base: "main", head: "worktree", cases: [], runs: 2, model: "sonnet",
    judgeModel: "opus", parallel: 4, dryRun: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i], v = () => {
      if (i + 1 >= argv.length) throw new Error(`${a} needs a value`);
      return argv[++i];
    };
    switch (a) {
      case "--skill": o.skill = v(); break;
      case "--base": o.base = v(); break;
      case "--head": o.head = v(); break;
      case "--case": o.cases.push(v()); break;
      case "--runs": o.runs = Number(v()); break;
      case "--model": o.model = v(); break;
      case "--judge-model": o.judgeModel = v(); break;
      case "--parallel": o.parallel = Number(v()); break;
      case "--dry-run": o.dryRun = true; break;
      default: throw new Error(`unknown argument: ${a}`);
    }
  }
  if (!(o.runs >= 1) || !(o.parallel >= 1)) throw new Error("--runs and --parallel must be >= 1");
  return o;
}

export function parseCase(name, text) {
  const m = text.match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/);
  if (!m) throw new Error(`${name}: missing front matter`);
  const meta = Object.fromEntries(m[1].split("\n").filter(Boolean).map((l) => {
    const i = l.indexOf(":");
    return [l.slice(0, i).trim(), l.slice(i + 1).trim()];
  }));
  const sections = {};
  for (const part of m[2].split(/^## /m).slice(1)) {
    const nl = part.indexOf("\n");
    sections[part.slice(0, nl).trim()] = part.slice(nl + 1).trim();
  }
  for (const k of ["skill", "stage", "repo_ref"]) if (!meta[k]) throw new Error(`${name}: front matter needs ${k}`);
  if (!STAGE_INSTRUCTIONS[meta.stage]) throw new Error(`${name}: unknown stage ${meta.stage}`);
  if (!sections.Request || !sections["Reference judgement"]) {
    throw new Error(`${name}: needs ## Request and ## Reference judgement`);
  }
  return { name, ...meta, request: sections.Request, transcript: sections.Transcript || "",
    reference: sections["Reference judgement"] };
}

function skillText(skill, ref) {
  const rel = `skills/${skill}/SKILL.md`;
  if (ref === "worktree") return fs.readFileSync(path.join(ROOT, rel), "utf8");
  return execFileSync("git", ["show", `${ref}:${rel}`], { cwd: ROOT, encoding: "utf8" });
}

export function subjectPrompt(skill, c) {
  return [skill, "", `ARGUMENTS: ${c.request}`, "",
    c.transcript ? `=== TRANSCRIPT SO FAR ===\n${c.transcript}\n` : "",
    STAGE_INSTRUCTIONS[c.stage]].join("\n");
}

// Blind: outputs get shuffled letter labels; the judge never sees which version wrote what.
export function judgePrompt(rubric, c, labelled) {
  return [rubric, "", "## Case request", c.request, "",
    c.transcript ? `## Transcript the outputs continue from\n${c.transcript}\n` : "",
    "## Reference judgement (from the maintainer)", c.reference, "",
    `## Outputs (stage: ${c.stage})`,
    ...labelled.map(({ label, text }) => `### Output ${label}\n${text}\n`),
    "Reply with ONLY a JSON array, one object per output: " +
      '{"label": "A", "scores": {' + METRICS.map((m) => `"${m}": 0|1|null`).join(", ") + '}, "note": "<one sentence>"}',
  ].join("\n");
}

export function shuffleLabels(items, rand = Math.random) {
  const a = items.slice();
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(rand() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a.map((it, i) => ({ ...it, label: String.fromCharCode(65 + i) }));
}

export function parseJudge(text) {
  const s = text.indexOf("["), e = text.lastIndexOf("]");
  if (s < 0 || e < s) throw new Error("judge reply has no JSON array");
  return JSON.parse(text.slice(s, e + 1));
}

export function summarize(rows) {
  // rows: [{case, version, scores, cost}] → per case×version: mean per metric (nulls skipped), n, cost.
  const groups = new Map();
  for (const r of rows) {
    const k = `${r.case}\t${r.version}`;
    if (!groups.has(k)) groups.set(k, []);
    groups.get(k).push(r);
  }
  const lines = ["| case | version | n | " + METRICS.join(" | ") + " | cost |",
    "|---|---|---|" + METRICS.map(() => "---").join("|") + "|---|"];
  for (const [k, rs] of groups) {
    const [c, v] = k.split("\t");
    const cells = METRICS.map((m) => {
      const vals = rs.map((r) => r.scores?.[m]).filter((x) => x === 0 || x === 1);
      return vals.length ? `${vals.reduce((a, b) => a + b, 0)}/${vals.length}` : "n/a";
    });
    const cost = rs.reduce((a, r) => a + (r.cost || 0), 0);
    lines.push(`| ${c} | ${v} | ${rs.length} | ${cells.join(" | ")} | $${cost.toFixed(2)} |`);
  }
  lines.push("", "Higher is better: " + [...GOOD_HIGH].join(", ") + ". Lower is better: " +
    METRICS.filter((m) => !GOOD_HIGH.has(m)).join(", ") + ". n/a = not applicable to that output.");
  return lines.join("\n");
}

function runClaude(args, input, cwd) {
  return new Promise((resolve) => {
    const p = spawn(CLAUDE, args, { cwd, stdio: ["pipe", "pipe", "pipe"] });
    let out = "", err = "";
    p.stdout.on("data", (d) => (out += d));
    p.stderr.on("data", (d) => (err += d));
    p.on("close", (code) => {
      try {
        const j = JSON.parse(out);
        resolve({ ok: code === 0 && !j.is_error, text: j.result ?? "", cost: j.total_cost_usd ?? 0, err });
      } catch {
        resolve({ ok: false, text: out, cost: 0, err: err || `exit ${code}` });
      }
    });
    p.stdin.end(input);
  });
}

async function pool(tasks, n) {
  const results = [];
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(n, tasks.length) }, async () => {
    while (next < tasks.length) { const i = next++; results[i] = await tasks[i](); }
  }));
  return results;
}

async function main() {
  const o = parseArgs(process.argv.slice(2));
  const rubric = fs.readFileSync(path.join(HERE, "rubric.md"), "utf8");
  let cases = fs.readdirSync(path.join(HERE, "cases")).filter((f) => f.endsWith(".md")).sort()
    .map((f) => parseCase(f.replace(/\.md$/, ""), fs.readFileSync(path.join(HERE, "cases", f), "utf8")));
  if (o.skill !== "all") cases = cases.filter((c) => c.skill === o.skill);
  if (o.cases.length) cases = cases.filter((c) => o.cases.includes(c.name));
  if (!cases.length) throw new Error("no cases match");

  const versions = { base: o.base, head: o.head };
  const plan = cases.flatMap((c) => Object.keys(versions).flatMap((v) =>
    Array.from({ length: o.runs }, (_, i) => ({ c, v, i: i + 1 }))));
  console.log(`${plan.length} subject runs (${cases.length} cases × 2 versions × ${o.runs}) on ${o.model}, ` +
    `${cases.length} judge calls on ${o.judgeModel}; base=${o.base} head=${o.head}`);
  if (o.dryRun) { for (const p of plan) console.log(`  ${p.c.name} ${p.v} #${p.i}`); return; }

  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const outDir = path.join(ROOT, ".scratch", "eval-design-skills", stamp);
  fs.mkdirSync(outDir, { recursive: true });

  // One read-only worktree per repo_ref, so each case researches the repo as it was when written.
  const trees = new Map();
  for (const ref of new Set(cases.map((c) => c.repo_ref))) {
    const dir = path.join(outDir, `wt-${ref}`);
    execFileSync("git", ["worktree", "add", "-q", "--detach", dir, ref], { cwd: ROOT });
    trees.set(ref, dir);
  }
  const skills = {};
  for (const c of cases) for (const [v, ref] of Object.entries(versions)) skills[`${c.skill}@${v}`] ??= skillText(c.skill, ref);

  try {
    const runs = await pool(plan.map(({ c, v, i }) => async () => {
      const prompt = subjectPrompt(skills[`${c.skill}@${v}`], c);
      const id = `${c.name}-${v}-${i}`;
      fs.writeFileSync(path.join(outDir, `${id}.prompt.txt`), prompt);
      const r = await runClaude(["-p", "--model", o.model, "--output-format", "json", "--max-turns", "40",
        "--disallowedTools", "Edit,Write,NotebookEdit,Agent"], prompt, trees.get(c.repo_ref));
      fs.writeFileSync(path.join(outDir, `${id}.out.md`), r.ok ? r.text : `RUN FAILED: ${r.err}\n${r.text}`);
      console.log(`  ${id}: ${r.ok ? "ok" : "FAILED"} $${r.cost.toFixed(2)}`);
      return { case: c.name, version: v, run: i, ok: r.ok, text: r.text, cost: r.cost };
    }), o.parallel);

    const rows = [];
    for (const c of cases) {
      const mine = runs.filter((r) => r.case === c.name && r.ok);
      for (const r of runs.filter((r) => r.case === c.name && !r.ok)) rows.push({ ...r, scores: null });
      if (!mine.length) continue;
      const labelled = shuffleLabels(mine);
      const j = await runClaude(["-p", "--model", o.judgeModel, "--output-format", "json", "--max-turns", "1",
        "--disallowedTools", "Bash,Edit,Write,NotebookEdit,Agent,Read,Grep,Glob"],
        judgePrompt(rubric, c, labelled), ROOT);
      let verdicts = [];
      try { verdicts = parseJudge(j.text); } catch (e) { console.error(`judge failed for ${c.name}: ${e.message}`); }
      for (const l of labelled) {
        const vd = verdicts.find((x) => x.label === l.label);
        rows.push({ case: c.name, version: l.version, run: l.run, ok: true, cost: l.cost,
          scores: vd?.scores ?? null, note: vd?.note ?? "judge gave no verdict" });
      }
      rows.push({ case: c.name, version: "judge", run: 0, ok: j.ok, cost: j.cost, scores: null });
    }

    const scored = rows.filter((r) => r.version !== "judge");
    const total = rows.reduce((a, r) => a + (r.cost || 0), 0);
    const summary = `${summarize(scored)}\n\nTotal cost: $${total.toFixed(2)} (judge included)\n\n## Notes\n` +
      scored.map((r) => `- ${r.case} ${r.version} #${r.run}: ${r.ok ? r.note : "run failed"}`).join("\n") + "\n";
    fs.writeFileSync(path.join(outDir, "summary.md"), summary);
    fs.writeFileSync(path.join(outDir, "results.json"), JSON.stringify(rows.map(({ text, ...r }) => r), null, 2));
    console.log(`\n${summary}\nResults: ${path.relative(ROOT, outDir)}/`);
  } finally {
    for (const dir of trees.values()) {
      try { execFileSync("git", ["worktree", "remove", "--force", dir], { cwd: ROOT }); } catch { /* best effort */ }
    }
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((e) => { console.error(`eval-design-skills: ${e.message}`); process.exit(2); });
}
