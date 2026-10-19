#!/usr/bin/env node
// eval-reviewer-misses.mjs — replay eval: does crew-review report bugs in unchanged code a change
// affected? Base and head review each case; a judge checks outputs blind. Maintainer-only, costs API money.
// Usage: node scripts/eval-reviewer-misses.mjs [--base <git ref>] [--head <git ref>|worktree]
//   [--case <name>]... [--runs N] [--model opus] [--effort <level>] [--no-subagents]
//   [--judge-model opus] [--parallel 4] [--dry-run] [--resume <out dir>]
// Each ref builds its prompts from its own files; a reviewer or judge CLI failure is a failed run, and so is
// a reviewer that changed its worktree (each run has its own, detached at the case's tip).

import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { LIMIT_RE, parseJudge, pool, runClaude, shuffleLabels } from "./eval-design-skills.mjs";

const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8" }).trim();
const HERE = path.join(ROOT, "scripts", "eval-reviewer-misses");
// No claude.ai connectors or bundled skills: the reviewer sees only the repo and its prompt.
const HEADLESS_SETTINGS = JSON.stringify({ disableClaudeAiConnectors: true, disableBundledSkills: true });

const EVAL_NOTE = (prdPath) =>
  "EVAL MODE (non-interactive): write nothing in the repo; scratch files outside it are fine. Where the " +
  "protocol says to write the report file, print that JSON object in a fenced ```json block as the last " +
  `thing in your final message. The PRD is at ${prdPath}.`;

function parseArgs(argv) {
  const o = { base: "main", head: "worktree", cases: [], runs: 2, model: "opus", judgeModel: "opus",
    effort: null, subagents: true, parallel: 4, dryRun: false, resume: null };
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
      case "--effort": o.effort = v(); break;
      case "--no-subagents": o.subagents = false; break;
      case "--judge-model": o.judgeModel = v(); break;
      case "--parallel": o.parallel = Number(v()); break;
      case "--dry-run": o.dryRun = true; break;
      case "--resume": o.resume = path.resolve(v()); break;
      default: throw new Error(`unknown argument: ${a}`);
    }
  }
  if (!(o.runs >= 1) || !(o.parallel >= 1)) throw new Error("--runs and --parallel must be >= 1");
  if (o.effort !== null && !["low", "medium", "high", "xhigh", "max"].includes(o.effort)) throw new Error("--effort must be low, medium, high, xhigh or max");
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
  // A clean case (no known defect) says so, so a case that forgot its misses still fails here.
  const clean = meta.clean === "true";
  if ((!misses.length && !clean) || !sections["Reference judgement"] || !sections.PRD) {
    throw new Error(`${name}: needs ## PRD, ## Expected misses and ## Reference judgement`);
  }
  if (meta.mode === "branch" && !sections["Acceptance criteria"]) throw new Error(`${name}: a branch case needs ## Acceptance criteria`);
  const notes = (sections.Notes ?? "").split("\n")
    .map((l) => /^\s*-\s+`([^`]+)`\s+—\s+(.+)$/.exec(l)).filter(Boolean).map((x) => ({ location: x[1], concern: x[2] }));
  return { name, ...meta, clean, intro, prd: sections.PRD, misses, notes, reference: sections["Reference judgement"],
    issue: sections.Issue ?? name, criteria: sections["Acceptance criteria"] ?? "" };
}

const git = (args, cwd = ROOT) => spawnSync("git", args, { cwd, encoding: "utf8" });
const treeStatus = (dir) => git(["status", "--porcelain", "--untracked-files=all"], dir).stdout;

/** How a reviewer changed its worktree since `before` (its status once set up), or null when it did not. */
function treeChange(dir, tip, before) {
  const head = git(["rev-parse", "HEAD"], dir).stdout.trim();
  if (head !== tip) return `changed its worktree: HEAD moved from ${tip.slice(0, 12)} to ${head.slice(0, 12) || "nothing"}`;
  const now = treeStatus(dir);
  if (now === before) return null;
  const was = new Set(before.split("\n"));
  const diff = now.split("\n").filter((l) => l && !was.has(l));
  return `changed its worktree: ${diff.slice(0, 3).join("; ") || "files it found are gone"}`;
}
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
      "(at neighbouring lines) count once.",
  ].join("\n");
}

export { parseJudge };

/** One reviewer output's report findings: the `findings` of its last fenced json block that has them; null when none parses. */
function reportFindings(text) {
  const blocks = [...String(text).matchAll(/```(?:json)?[ \t]*\n([\s\S]*?)\n[ \t]*```/g)];
  for (let i = blocks.length - 1; i >= 0; i--) {
    try {
      const v = JSON.parse(blocks[i][1]);
      if (Array.isArray(v?.findings)) return v.findings;
    } catch { /* previous block */ }
  }
  return null;
}

export const countFindings = (text) => reportFindings(text)?.length ?? null;
/** CRITICAL and HIGH findings in one reviewer output's report; null when none parses. */
export const countSevere = (text) => reportFindings(text)?.filter((f) => ["CRITICAL", "HIGH"].includes(f?.severity)).length ?? null;

const mean = (xs) => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : null);
const fmt = (n) => (n === null ? "n/a" : n.toFixed(1));

/** head / base as text: a base mean of 0 is an increase (or no change), not a missing mean. */
export function formatRatio(base, head) {
  if (base == null || head == null) return "n/a";
  if (base === 0) return head > 0 ? `inf (base 0, head ${fmt(head)})` : "n/a (base 0, head 0)";
  return (head / base).toFixed(2) + "x";
}

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
        ...(c.clean ? { meanCritHigh: mean(rs.map((r) => r.critHigh).filter((n) => typeof n === "number")) } : {}),
      };
    }
    const base = entry.base?.meanDistinct, head = entry.head?.meanDistinct;
    entry.ratio = base && head != null ? head / base : null; // base 0 stays null in JSON; summary.md carries the text
    entry.withinBound = base != null && head != null ? head <= Math.max(2 * base, base + 2) : null;
    out[c.name] = entry;
  }
  return out;
}

export function summarize(rows, cases) {
  const changed = ["base", "head"].map((v) => {
    const rs = rows.filter((r) => r.version === v);
    return `${v} ${rs.filter((r) => r.treeChanged).length}/${rs.length}`;
  }).join(", ");
  const lines = ["| case | version | runs ok | caught (per expected miss) | mean findings (raw) | mean findings (distinct) | mean CRITICAL+HIGH | cost |", "|---|---|---|---|---|---|---|---|"];
  const means = {};
  for (const c of cases) {
    for (const v of ["base", "head"]) {
      const rs = rows.filter((r) => r.case === c.name && r.version === v);
      if (!rs.length) continue;
      const judged = rs.filter((r) => r.caught);
      const caught = c.misses.map((x) => `${x.id} ${judged.filter((r) => r.caught[x.id]).length}/${judged.length}`).join("; ");
      const m = mean(rs.map((r) => r.findings).filter((n) => typeof n === "number"));
      const d = mean(rs.map((r) => r.distinct).filter((n) => typeof n === "number"));
      // Only a clean case has no defect to tell a false CRITICAL or HIGH finding from a real one.
      const severe = c.clean ? fmt(mean(rs.map((r) => r.critHigh).filter((n) => typeof n === "number"))) : "-";
      (means[c.name] ??= {})[v] = d;
      lines.push(`| ${c.name} | ${v} | ${rs.filter((r) => r.ok).length}/${rs.length} | ${caught || "none (clean case)"} | ${fmt(m)} | ${fmt(d)} | ${severe} | $${rs.reduce((a, r) => a + (r.cost || 0), 0).toFixed(2)} |`);
    }
  }
  lines.push("", "Mean distinct findings, head / base: " + cases.map((c) => {
    const { base, head } = means[c.name] ?? {};
    const ratio = formatRatio(base, head);
    const within = base != null && head != null ? (head <= Math.max(2 * base, base + 2) ? "within" : "over") : "n/a";
    return `${c.name} ${ratio} (${within} max(2x, +2))`;
  }).join("; "));
  lines.push("", `Runs that changed their worktree: ${changed}.`);
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
  const outDir = o.resume ?? path.join(ROOT, ".coding-crew", "scratch", "eval-reviewer-misses", stamp);
  if (o.resume && !fs.existsSync(outDir)) throw new Error(`--resume: ${outDir} does not exist`);
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
    for (const [v, ref] of Object.entries(versions)) {
      refTree[v] = ref === "worktree" ? ROOT : addTree(`ref-${v}`, ref);
      if (!fs.existsSync(path.join(refTree[v], "skills", "crew-review", "SKILL.md"))) {
        throw new Error(`--${v} ${ref} has no skills/crew-review/SKILL.md: the ref predates crew-review; pick a later one`);
      }
    }
    // The case's PRD as a file: in the run's own tree when a reviewer runs there, beside the prompts on a dry run.
    const writePrd = (c, file) => {
      fs.mkdirSync(path.dirname(file), { recursive: true });
      fs.writeFileSync(file, c.prd + "\n");
    };
    const input = (c, prdPath) => ({ mode: c.mode, base: c.base, tip: c.tip, branch: c.tip, slug: c.slug, issue: c.issue,
      criteria: c.criteria, notes: c.notes, prdPath, prdText: c.prd, reportPath: "(print it in your final message)" });
    const prompt = (body, role, prdPath) => `${role ? `${role}\n\n=== THIS DISPATCH ===\n\n` : ""}${body}\n\n${EVAL_NOTE(prdPath)}\n`;

    if (o.dryRun) {
      for (const c of cases) {
        console.log(`  ${c.name}`);
        const prdPath = path.join(outDir, `${c.name}.PRD.md`);
        writePrd(c, prdPath);
        for (const v of Object.keys(versions)) {
          const b = buildPrompts(refTree[v], input(c, prdPath));
          for (const r of b.reviews) fs.writeFileSync(path.join(outDir, `${c.name}-${v}.${r.name}.prompt.md`), prompt(r.prompt, b.role, prdPath));
        }
      }
      console.log(`\nDry run: prompts written to ${path.relative(ROOT, outDir)}/. No model was called.`);
      return;
    }

    const plan = cases.flatMap((c) => Object.keys(versions).flatMap((v) => Array.from({ length: o.runs }, (_, i) => ({ c, v, i: i + 1 }))));
    console.log(`${plan.length} reviewer runs on ${o.model}, ${cases.length} judge calls on ${o.judgeModel}`);
    const stop = { hit: false, why: "" };
    const note = (r) => { if (!r.ok && LIMIT_RE.test(`${r.text}\n${r.err}`) && !stop.hit) { stop.hit = true; stop.why = (r.text || r.err).trim().split("\n")[0]; } };
    const claude = (model, turns, inputText, cwd, flags) => runClaude(["-p", "--model", model,
      "--output-format", "json", "--max-turns", String(turns), ...flags], inputText, cwd);
    // The reviewer has production's powers: any shell command without a prompt, as the Actions reviewer runs;
    // subagents unless --no-subagents. `--tools` is variadic: it goes last.
    const reviewerFlags = ["--settings", HEADLESS_SETTINGS, "--permission-mode", "bypassPermissions",
      ...(o.effort ? ["--effort", o.effort] : []), "--tools", "Bash", "Read", ...(o.subagents ? ["Agent"] : []), "ToolSearch"];

    const runs = await pool(plan.map(({ c, v, i }) => async () => {
      const id = `${c.name}-${v}-${i}`;
      let cost = 0, failure = null, reused = false;
      // Its own tree, set up only when a reviewer runs in it (not for outputs --resume reuses).
      const tree = path.join(outDir, `tree-${id}`), prdPath = path.join(tree, ".scratch", c.slug, "PRD.md");
      let before = null;
      const written = [];
      const b = buildPrompts(refTree[v], input(c, prdPath));
      const outs = await Promise.all(b.reviews.map(async (r) => {
        const text = prompt(r.prompt, b.role, prdPath);
        const outFile = path.join(outDir, `${id}.${r.name}.out.md`);
        const prior = o.resume && fs.existsSync(outFile) ? fs.readFileSync(outFile, "utf8") : null;
        if (prior !== null && !prior.startsWith("RUN FAILED")) { reused = true; return prior; }
        if (before === null) { addTree(`tree-${id}`, c.tip); writePrd(c, prdPath); before = treeStatus(tree); }
        fs.writeFileSync(path.join(outDir, `${id}.${r.name}.prompt.md`), text);
        const res = await claude(o.model, 80, text, tree, reviewerFlags);
        cost += res.cost; note(res);
        fs.writeFileSync(outFile, res.ok ? res.text : `RUN FAILED: ${res.err}\n${res.text}`);
        written.push({ outFile, res });
        if (!res.ok) failure ??= (res.err || res.text).trim().split("\n")[0];
        return res.text;
      }));
      // A reviewer that changed its tree failed, whatever it printed: RUN FAILED, so --resume retries it.
      const change = before === null ? null : treeChange(tree, c.tip, before);
      if (change) {
        failure = change;
        for (const { outFile, res } of written) fs.writeFileSync(outFile, `RUN FAILED: ${change}\n${res.text}`);
      }
      const ok = !failure;
      const counts = outs.map(countFindings);
      const findings = ok && counts.every((n) => n !== null) ? counts.reduce((a, n) => a + n, 0) : null;
      const severe = c.clean ? outs.map(countSevere) : [];
      const critHigh = ok && c.clean && severe.every((n) => n !== null) ? severe.reduce((a, n) => a + n, 0) : null;
      console.log(`  ${id}: ${stop.hit && !ok ? "LIMIT" : change ? "CHANGED TREE" : !ok ? "FAILED" : reused ? "reused" : "ok"} $${cost.toFixed(2)}`);
      return { case: c.name, version: v, run: i, ok, failure, treeChanged: !!change, text: outs.join("\n\n"), findings, critHigh, cost };
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
        const j = await claude(o.judgeModel, 1, jp, ROOT, ["--disallowedTools", "Bash,Read,Grep,Glob,Edit,Write,NotebookEdit,Agent"]);
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
          treeChanged: r.treeChanged, findings: r.findings, critHigh: r.critHigh, distinct, caught, note: vd?.note ?? null, cost: r.cost });
      }
      if (rows.length) rows.at(-1).cost += judgeCost;
    }
    const total = rows.reduce((a, r) => a + (r.cost || 0), 0);
    const summary = `${summarize(rows, cases)}\n\nTotal cost: $${total.toFixed(2)} (judge included). Base \`${o.base}\`, head \`${o.head}\`, ${o.runs} run(s) each. Reviewers on ${o.model} (effort ${o.effort ?? "default"}, sub-agents ${o.subagents ? "allowed" : "denied"}), judge on ${o.judgeModel}.\n\n## Runs\n` +
      rows.map((r) => `- ${r.case} ${r.version} #${r.run}: ` + (r.caught
        ? `${Object.entries(r.caught).map(([k, v]) => `${k} ${v ? "caught" : "not caught"}`).join(", ")}; ${r.findings ?? "n/a"} finding(s), ${r.distinct ?? "n/a"} distinct — ${r.note ?? ""}`
        : `FAILED (${r.failure})`)).join("\n") + "\n";
    fs.writeFileSync(path.join(outDir, "summary.md"), summary);
    fs.writeFileSync(path.join(outDir, "results.json"), JSON.stringify({ base: o.base, head: o.head, runs: o.runs, model: o.model, effort: o.effort, subagents: o.subagents, judgeModel: o.judgeModel, means: aggregate(rows, cases), rows }, null, 2));
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
