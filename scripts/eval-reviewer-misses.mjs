#!/usr/bin/env node
// eval-reviewer-misses.mjs — replay eval: does the reviewer protocol now report the bugs a review
// once missed?
//
// Why this exists: PR #208 shipped two bugs that a reviewer reading only the diff could not see,
// both in unchanged code the change affected. Whether a protocol or PRD edit makes a reviewer look
// there needs a replay: run each case's review at a base ref and at the head, several times, then
// have a judge check every output blind against the case's expected misses. Maintainer-only; ships
// to no consumer. Costs real API money (each run's cost is printed), so it is run by hand after
// editing orchestrator/roles/reviewer.md, never in CI.
//
// Usage: node scripts/eval-reviewer-misses.mjs [--base <git ref>] [--head <git ref>|worktree]
//          [--case <name>]... [--runs N] [--model opus] [--judge-model opus] [--parallel 4]
//          [--max-areas 3] [--dry-run]
//
// Each ref builds its prompts from its OWN files (build-prompts.mjs runs inside that ref's checkout):
// reviewPrompt / featureReviewPrompt, the feature-areas pure functions, and the rendered
// orchestrator/roles/reviewer.md. The reviewer then runs against the case's tree (a detached
// worktree at the case's head_sha) with file-writing tools disallowed, so its report is read from
// its final message. A `feature` case replays the planner split, then one reviewer per area.
//
// Cases live in scripts/eval-reviewer-misses/cases/*.md: front matter (mode: feature|branch,
// base_sha, head_sha, slug), free text, then `## PRD` (a frozen copy), `## Expected misses`
// (`- <id>: <defect>`), `## Reference judgement`, and for `branch` cases `## Issue`,
// `## Implements`, `## Acceptance criteria`. A SHA that does not resolve names the case and skips
// only it (exit 1). Results land in .scratch/eval-reviewer-misses/<timestamp>/ (summary.md,
// results.json, every prompt and output). A reviewer or judge CLI failure is a failed run, never
// "not caught".

import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { LIMIT_RE, pool, runClaude, shuffleLabels } from "./eval-design-skills.mjs";

const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8" }).trim();
const HERE = path.join(ROOT, "scripts", "eval-reviewer-misses");

const EVAL_NOTE = (prdPath) =>
  "EVAL MODE (non-interactive): you cannot write files. Where the protocol says to write the report " +
  "file, print that JSON object in a fenced ```json block as the last thing in your final message. " +
  `Modify nothing. The PRD is at ${prdPath}.`;

function parseArgs(argv) {
  const o = { base: "main", head: "worktree", cases: [], runs: 2, model: "opus", judgeModel: "opus",
    parallel: 4, maxAreas: 3, dryRun: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i], v = () => {
      if (i + 1 >= argv.length) throw new Error(`${a} needs a value`);
      return argv[++i];
    };
    switch (a) {
      case "--base": o.base = v(); break;
      case "--head": o.head = v(); break;
      case "--case": o.cases.push(v()); break;
      case "--runs": o.runs = Number(v()); break;
      case "--model": o.model = v(); break;
      case "--judge-model": o.judgeModel = v(); break;
      case "--parallel": o.parallel = Number(v()); break;
      case "--max-areas": o.maxAreas = Number(v()); break;
      case "--dry-run": o.dryRun = true; break;
      default: throw new Error(`unknown argument: ${a}`);
    }
  }
  if (!(o.runs >= 1) || !(o.parallel >= 1) || !(o.maxAreas >= 1)) throw new Error("--runs, --parallel and --max-areas must be >= 1");
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
  const parts = m[2].split(/^## /m);
  const intro = parts[0].trim();
  for (const part of parts.slice(1)) {
    const nl = part.indexOf("\n");
    sections[part.slice(0, nl).trim()] = part.slice(nl + 1).trim();
  }
  for (const k of ["mode", "base_sha", "head_sha", "slug"]) if (!meta[k]) throw new Error(`${name}: front matter needs ${k}`);
  if (!["feature", "branch"].includes(meta.mode)) throw new Error(`${name}: unknown mode ${meta.mode}`);
  const misses = (sections["Expected misses"] ?? "").split("\n")
    .map((l) => /^\s*-\s+([\w-]+):\s*(.+)$/.exec(l)).filter(Boolean).map((x) => ({ id: x[1], text: x[2] }));
  if (!misses.length || !sections["Reference judgement"] || !sections.PRD) {
    throw new Error(`${name}: needs ## PRD, ## Expected misses and ## Reference judgement`);
  }
  if (meta.mode === "branch" && !sections["Acceptance criteria"]) throw new Error(`${name}: a branch case needs ## Acceptance criteria`);
  return { name, ...meta, intro, prd: sections.PRD, misses, reference: sections["Reference judgement"],
    issue: sections.Issue ?? name, implements: sections.Implements ?? "", criteria: sections["Acceptance criteria"] ?? "" };
}

const git = (args, cwd = ROOT) => spawnSync("git", args, { cwd, encoding: "utf8" });
const resolveSha = (sha) => {
  const r = git(["rev-parse", "--verify", "-q", `${sha}^{commit}`]);
  return r.status === 0 ? r.stdout.trim() : null;
};

// Blind: outputs get shuffled letter labels; the judge never sees which ref wrote what.
export function judgePrompt(rubric, c, labelled) {
  return [rubric, "", "## Case", c.intro, "",
    "## Expected misses", ...c.misses.map((x) => `- ${x.id}: ${x.text}`), "",
    "## Reference judgement (from the maintainer)", c.reference, "",
    "## Outputs",
    ...labelled.map(({ label, text }) => `### Output ${label}\n${text}\n`),
    "Reply with ONLY a JSON array, one object per output: " +
      `{"label": "A", "caught": {${c.misses.map((x) => `"${x.id}": true|false`).join(", ")}}, "distinct": <N>, "note": "<one sentence>"}`,
    "distinct = the number of distinct defects the output's findings name: findings naming the same defect " +
      "(in different areas, or at neighbouring lines) count once.",
  ].join("\n");
}

export function parseJudge(text) {
  const s = text.indexOf("["), e = text.lastIndexOf("]");
  if (s < 0 || e < s) throw new Error("judge reply has no JSON array");
  return JSON.parse(text.slice(s, e + 1));
}

/** Findings reported in one reviewer output: the `findings` of its last fenced json block that has them; null when none parses. */
export function countFindings(text) {
  const blocks = [...String(text).matchAll(/```(?:json)?[ \t]*\n([\s\S]*?)\n[ \t]*```/g)];
  for (let i = blocks.length - 1; i >= 0; i--) {
    try {
      const v = JSON.parse(blocks[i][1]);
      if (Array.isArray(v?.findings)) return v.findings.length;
    } catch { /* previous block */ }
  }
  return null;
}

const mean = (xs) => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : null);
const fmt = (n) => (n === null ? "n/a" : n.toFixed(1));

/** Per case: mean raw and distinct findings per ref, plus head/base distinct ratio and the max(2x, +2) noise-bound verdict. */
export function aggregate(rows, cases) {
  const out = {};
  for (const c of cases) {
    const entry = {};
    for (const v of ["base", "head"]) {
      const rs = rows.filter((r) => r.case === c.name && r.version === v);
      if (!rs.length) continue;
      entry[v] = {
        meanFindings: mean(rs.map((r) => r.findings).filter((n) => typeof n === "number")),
        meanDistinct: mean(rs.map((r) => r.distinct).filter((n) => typeof n === "number")),
      };
    }
    const base = entry.base?.meanDistinct, head = entry.head?.meanDistinct;
    entry.ratio = base && head != null ? head / base : null;
    entry.withinBound = base != null && head != null ? head <= Math.max(2 * base, base + 2) : null;
    out[c.name] = entry;
  }
  return out;
}

export function summarize(rows, cases) {
  const lines = ["| case | version | runs ok | caught (per expected miss) | mean findings (raw) | mean findings (distinct) | cost |", "|---|---|---|---|---|---|---|"];
  const means = {};
  for (const c of cases) {
    for (const v of ["base", "head"]) {
      const rs = rows.filter((r) => r.case === c.name && r.version === v);
      if (!rs.length) continue;
      const judged = rs.filter((r) => r.caught);
      const caught = c.misses.map((x) => `${x.id} ${judged.filter((r) => r.caught[x.id]).length}/${judged.length}`).join("; ");
      const m = mean(rs.map((r) => r.findings).filter((n) => typeof n === "number"));
      const d = mean(rs.map((r) => r.distinct).filter((n) => typeof n === "number"));
      (means[c.name] ??= {})[v] = d;
      lines.push(`| ${c.name} | ${v} | ${rs.filter((r) => r.ok).length}/${rs.length} | ${caught} | ${fmt(m)} | ${fmt(d)} | $${rs.reduce((a, r) => a + (r.cost || 0), 0).toFixed(2)} |`);
    }
  }
  lines.push("", "Mean distinct findings, head / base: " + cases.map((c) => {
    const { base, head } = means[c.name] ?? {};
    const ratio = base && head != null ? (head / base).toFixed(2) + "x" : "n/a";
    const within = base != null && head != null ? (head <= Math.max(2 * base, base + 2) ? "within" : "over") : "n/a";
    return `${c.name} ${ratio} (${within} max(2x, +2))`;
  }).join("; "));
  return lines.join("\n");
}

function buildPrompts(tree, input) {
  const r = spawnSync("node", [path.join(HERE, "build-prompts.mjs"), tree], { input: JSON.stringify(input), encoding: "utf8", maxBuffer: 1 << 28 });
  if (r.status !== 0) throw new Error(`build-prompts failed in ${tree}: ${(r.stderr || r.stdout).trim().split("\n").slice(-3).join(" | ")}`);
  return JSON.parse(r.stdout);
}

async function main() {
  const o = parseArgs(process.argv.slice(2));
  const rubric = fs.readFileSync(path.join(HERE, "rubric.md"), "utf8");
  let cases = fs.readdirSync(path.join(HERE, "cases")).filter((f) => f.endsWith(".md")).sort()
    .map((f) => parseCase(f.replace(/\.md$/, ""), fs.readFileSync(path.join(HERE, "cases", f), "utf8")));
  if (o.cases.length) cases = cases.filter((c) => o.cases.includes(c.name));
  if (!cases.length) throw new Error("no cases match");

  const unresolved = [];
  cases = cases.filter((c) => {
    const base = resolveSha(c.base_sha), head = resolveSha(c.head_sha);
    if (base && head) { c.base = base; c.tip = head; return true; }
    const bad = [!base && c.base_sha, !head && c.head_sha].filter(Boolean).join(", ");
    console.error(`UNRESOLVED ${c.name}: ${bad} does not resolve (reachable through ${c.via ?? "the case's branch"}; fetch it)`);
    unresolved.push(c.name);
    return false;
  });
  if (process.exitCode === undefined && unresolved.length) process.exitCode = 1;

  const versions = { base: o.base, head: o.head };
  console.log(`cases: ${cases.map((c) => c.name).join(", ") || "(none)"}; ${o.runs} run(s) each on base=${o.base} head=${o.head}`);
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const outDir = path.join(ROOT, ".scratch", "eval-reviewer-misses", stamp);
  fs.mkdirSync(outDir, { recursive: true });

  const trees = new Map(); // dir → removable
  const addTree = (name, ref) => {
    const dir = path.join(outDir, name);
    execFileSync("git", ["worktree", "add", "-q", "--detach", dir, ref], { cwd: ROOT });
    trees.set(dir, true);
    return dir;
  };
  try {
    const refTree = {};
    for (const [v, ref] of Object.entries(versions)) refTree[v] = ref === "worktree" ? ROOT : addTree(`ref-${v}`, ref);
    const caseTree = {};
    const input = (c, v, extra = {}) => ({ mode: c.mode, base: c.base, tip: c.tip, branch: c.tip, slug: c.slug, issue: c.issue,
      criteria: c.criteria, implements: c.implements, prdText: c.prd, reportPath: "(print it in your final message)", max: o.maxAreas, ...extra });
    const prompt = (c, name, body, role) => `${role}\n\n=== THIS DISPATCH ===\n\n${body}\n\n${EVAL_NOTE(path.join(caseTree[c.name] ?? "<case tree>", ".scratch", c.slug, "PRD.md"))}\n`;

    if (!o.dryRun) {
      for (const c of cases) {
        caseTree[c.name] = addTree(`tree-${c.name}`, c.tip);
        const prd = path.join(caseTree[c.name], ".scratch", c.slug, "PRD.md");
        fs.mkdirSync(path.dirname(prd), { recursive: true });
        fs.writeFileSync(prd, c.prd + "\n");
      }
    }

    if (o.dryRun) {
      for (const c of cases) {
        console.log(`  ${c.name}`);
        for (const v of Object.keys(versions)) {
          const b = buildPrompts(refTree[v], input(c, v));
          if (b.planner) fs.writeFileSync(path.join(outDir, `${c.name}-${v}.planner.prompt.md`), b.planner);
          for (const r of b.reviews) fs.writeFileSync(path.join(outDir, `${c.name}-${v}.${r.name}.prompt.md`), prompt(c, r.name, r.prompt, b.role));
        }
      }
      console.log(`\nDry run: prompts written to ${path.relative(ROOT, outDir)}/ (a feature case shows its whole-feature fallback area; no planner ran). No model was called.`);
      return;
    }

    const plan = cases.flatMap((c) => Object.keys(versions).flatMap((v) => Array.from({ length: o.runs }, (_, i) => ({ c, v, i: i + 1 }))));
    console.log(`${plan.length} reviewer runs on ${o.model}, ${cases.length} judge calls on ${o.judgeModel}`);
    const stop = { hit: false, why: "" };
    const note = (r) => { if (!r.ok && LIMIT_RE.test(`${r.text}\n${r.err}`) && !stop.hit) { stop.hit = true; stop.why = (r.text || r.err).trim().split("\n")[0]; } };
    const claude = (model, turns, inputText, cwd, extraDeny = "") => runClaude(["-p", "--model", model, "--output-format", "json",
      "--max-turns", String(turns), "--disallowedTools", `${extraDeny}Edit,Write,NotebookEdit,Agent`], inputText, cwd);

    const runs = await pool(plan.map(({ c, v, i }) => async () => {
      const id = `${c.name}-${v}-${i}`;
      let cost = 0, failure = null, areas = null;
      let b = buildPrompts(refTree[v], input(c, v));
      if (c.mode === "feature") {
        fs.writeFileSync(path.join(outDir, `${id}.planner.prompt.md`), b.planner);
        const p = await claude(o.model, 1, b.planner, outDir, "Bash,Read,Grep,Glob,");
        cost += p.cost; note(p);
        fs.writeFileSync(path.join(outDir, `${id}.planner.out.md`), p.ok ? p.text : `PLANNER FAILED: ${p.err}\n${p.text}`);
        if (p.ok) {
          const m = [...p.text.matchAll(/```(?:json)?[ \t]*\n([\s\S]*?)\n[ \t]*```/g)].at(-1);
          try { areas = JSON.parse(m[1]).areas; } catch { /* whole-feature fallback */ }
        }
        if (areas) b = buildPrompts(refTree[v], input(c, v, { areas }));
      }
      const outs = await Promise.all(b.reviews.map(async (r) => {
        const text = prompt(c, r.name, r.prompt, b.role);
        fs.writeFileSync(path.join(outDir, `${id}.${r.name}.prompt.md`), text);
        const res = await claude(o.model, 40, text, caseTree[c.name]);
        cost += res.cost; note(res);
        fs.writeFileSync(path.join(outDir, `${id}.${r.name}.out.md`), res.ok ? res.text : `RUN FAILED: ${res.err}\n${res.text}`);
        if (!res.ok) failure ??= (res.err || res.text).trim().split("\n")[0];
        return res.text;
      }));
      const ok = !failure;
      const counts = outs.map(countFindings);
      const findings = ok && counts.every((n) => n !== null) ? counts.reduce((a, n) => a + n, 0) : null;
      console.log(`  ${id}: ${stop.hit && !ok ? "LIMIT" : ok ? "ok" : "FAILED"} ${b.reviews.length} area(s) $${cost.toFixed(2)}`);
      return { case: c.name, version: v, run: i, ok, failure, areas: b.reviews.length, text: outs.join("\n\n--- next area ---\n\n"), findings, cost };
    }), o.parallel, stop);
    if (stop.hit) {
      console.error(`\nSTOPPED: "${stop.why}". ${runs.filter((r) => r?.ok).length} of ${plan.length} runs finished; nothing was judged. ` +
        `Outputs so far: ${path.relative(ROOT, outDir)}/. Re-run once the limit resets.`);
      process.exitCode = 3;
      return;
    }

    const rows = [];
    for (const c of cases) {
      const mine = runs.filter((r) => r.case === c.name);
      const good = mine.filter((r) => r.ok);
      const verdicts = new Map();
      const labelOf = new Map(); // "<version>#<run>" → the judge's letter
      let judgeCost = 0, judgeOk = true;
      if (good.length) {
        const labelled = shuffleLabels(good);
        const jp = judgePrompt(rubric, c, labelled);
        fs.writeFileSync(path.join(outDir, `${c.name}.judge.prompt.md`), jp);
        const j = await claude(o.judgeModel, 1, jp, ROOT, "Bash,Read,Grep,Glob,");
        judgeCost = j.cost; judgeOk = j.ok;
        fs.writeFileSync(path.join(outDir, `${c.name}.judge.out.md`), j.ok ? j.text : `JUDGE FAILED: ${j.err}\n${j.text}`);
        if (!j.ok && LIMIT_RE.test(`${j.text}\n${j.err}`)) {
          console.error(`\nSTOPPED while judging ${c.name}: "${(j.text || j.err).trim().split("\n")[0]}". Outputs kept in ${path.relative(ROOT, outDir)}/.`);
          process.exitCode = 3;
          return;
        }
        try { for (const vd of parseJudge(j.text)) verdicts.set(vd.label, vd); } catch (e) { judgeOk = false; console.error(`judge failed for ${c.name}: ${e.message}`); }
        for (const l of labelled) labelOf.set(`${l.version}#${l.run}`, l.label);
      }
      for (const r of mine) {
        const vd = r.ok && judgeOk ? verdicts.get(labelOf.get(`${r.version}#${r.run}`)) : null;
        const caught = vd ? Object.fromEntries(c.misses.map((x) => [x.id, vd.caught?.[x.id] === true])) : null;
        const distinct = Number.isFinite(vd?.distinct) ? vd.distinct : null;
        rows.push({ case: c.name, version: r.version, run: r.run, ok: r.ok && !!caught, failure: r.failure ?? (r.ok && !caught ? "judge gave no verdict" : null),
          areas: r.areas, findings: r.findings, distinct, caught, note: vd?.note ?? null, cost: r.cost });
      }
      if (rows.length) rows.at(-1).cost += judgeCost;
    }
    const total = rows.reduce((a, r) => a + (r.cost || 0), 0);
    const summary = `${summarize(rows, cases)}\n\nTotal cost: $${total.toFixed(2)} (judge included). Base \`${o.base}\`, head \`${o.head}\`, ${o.runs} run(s) each. Reviewers on ${o.model}, judge on ${o.judgeModel}.\n\n## Runs\n` +
      rows.map((r) => `- ${r.case} ${r.version} #${r.run}: ` + (r.caught
        ? `${Object.entries(r.caught).map(([k, v]) => `${k} ${v ? "caught" : "not caught"}`).join(", ")}; ${r.findings ?? "n/a"} finding(s), ${r.distinct ?? "n/a"} distinct${r.areas > 1 ? ` over ${r.areas} areas` : ""} — ${r.note ?? ""}`
        : `FAILED (${r.failure})`)).join("\n") + "\n";
    fs.writeFileSync(path.join(outDir, "summary.md"), summary);
    fs.writeFileSync(path.join(outDir, "results.json"), JSON.stringify({ base: o.base, head: o.head, runs: o.runs, model: o.model, judgeModel: o.judgeModel, means: aggregate(rows, cases), rows }, null, 2));
    if (rows.some((r) => !r.ok)) process.exitCode ||= 1;
    console.log(`\n${summary}\nResults: ${path.relative(ROOT, outDir)}/`);
  } finally {
    for (const dir of trees.keys()) {
      try { execFileSync("git", ["worktree", "remove", "--force", dir], { cwd: ROOT }); } catch { /* best effort */ }
    }
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((e) => { console.error(`eval-reviewer-misses: ${e.message}`); process.exit(2); });
}
