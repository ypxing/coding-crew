/**
 * The feature review's areas: a whole-feature review is split by a planner into up to `maxParallel`
 * areas, each read end to end by its own reviewer. The planner is one plain dispatch (like the PRD
 * audit) on the reviewer's binding; its answer is validated against the diff and the PRD, and any
 * failure to plan gives one area over the whole diff with every decision.
 */

import { join } from "node:path";

import { dispatchPlain } from "../dispatch.mjs";
import { implementedIds, loadPrdDecisions } from "../prd-decisions.mjs";
import { getTracker } from "../tracker.mjs";
import { FEATURE_REVIEW } from "../prompts.mjs";
import { readOnlyDispatch, roleBinding } from "./shared.mjs";

export const FEATURE_PLAN = `${FEATURE_REVIEW}-plan`;

// Paths verbatim (core.quotePath=false, -z) and no rename detection: an area's diff is limited to these
// paths, so an escaped name would match nothing, and a renamed file's old path must be listed for its
// deletion to be seen.
const DIFF = ["-c", "core.quotePath=false", "diff", "--no-renames"];
const stdoutOf = (r) => (r.code === 0 ? r.stdout : "");
const names = (r) => stdoutOf(r).split("\0").filter(Boolean);

/** Pure: the last fenced json block of the planner's answer, parsed; null when there is none. */
export function parsePlannerAnswer(text) {
  const blocks = [...String(text ?? "").matchAll(/```(?:json)?[ \t]*\n([\s\S]*?)\n[ \t]*```/g)];
  for (let i = blocks.length - 1; i >= 0; i--) {
    try {
      const v = JSON.parse(blocks[i][1]);
      if (v && typeof v === "object") return v;
    } catch {
      /* try the previous block */
    }
  }
  return null;
}

const size = (a) => a.files.length;

/**
 * Pure: the planner's `areas` made safe to dispatch. Paths not in the diff and IDs not in the PRD
 * are dropped, an area left with no file goes, more than `max` areas are merged down (the two
 * smallest first), and a changed file no area holds joins the smallest one. A PRD decision no area
 * holds then goes to the area holding the most files of the `issues` (`mergedIssues`) implementing
 * it — the earlier area on a tie — else to the smallest area, so every decision is judged somewhere.
 * Empty when nothing valid remains.
 */
export function normalizeAreas(raw, { diffFiles, decisionIds, max, issues = [] }) {
  const inDiff = new Set(diffFiles);
  const inPrd = new Set(decisionIds);
  const strings = (v) => (Array.isArray(v) ? v.filter((x) => typeof x === "string").map((x) => x.trim()) : []);
  let areas = (Array.isArray(raw) ? raw : [])
    .filter((a) => a && typeof a === "object")
    .map((a, i) => ({
      name: typeof a.name === "string" && a.name.trim() ? a.name.trim() : `area ${i + 1}`,
      files: [...new Set(strings(a.files).filter((f) => inDiff.has(f)))],
      decisions: [...new Set(strings(a.decisions).filter((d) => inPrd.has(d)))],
    }))
    .filter((a) => a.files.length);
  if (!areas.length) return [];
  while (areas.length > Math.max(1, max)) {
    areas.sort((x, y) => size(x) - size(y));
    const [a, b, ...rest] = areas;
    areas = [
      {
        name: `${a.name} + ${b.name}`,
        files: [...new Set([...a.files, ...b.files])],
        decisions: [...new Set([...a.decisions, ...b.decisions])],
      },
      ...rest,
    ];
  }
  const covered = new Set(areas.flatMap((a) => a.files));
  const left = diffFiles.filter((f) => !covered.has(f));
  if (left.length) {
    const smallest = areas.reduce((m, a) => (size(a) < size(m) ? a : m));
    smallest.files = [...smallest.files, ...left];
  }
  const held = new Set(areas.flatMap((a) => a.decisions));
  for (const id of decisionIds.filter((d) => !held.has(d))) {
    const files = new Set(issues.filter((i) => i.ids?.includes(id)).flatMap((i) => i.files ?? []));
    const counts = areas.map((a) => a.files.filter((f) => files.has(f)).length);
    const best = counts.indexOf(Math.max(...counts));
    const home = counts[best] > 0 ? areas[best] : areas.reduce((m, a) => (size(a) < size(m) ? a : m));
    home.decisions = [...home.decisions, id];
  }
  return areas;
}

/** The one area a failed or empty plan falls back to; `whole`, so its diff needs no pathspec. */
export function wholeFeatureArea(diffFiles, decisionIds) {
  return { name: "whole feature", files: [...diffFiles], decisions: [...decisionIds], whole: true };
}

/**
 * Pure: featureReviewPrompt's `area`, `decisions` and `otherAreas` for one of `areas`, `decisions`
 * the PRD's `ID → line` map. An area gets its own decision lines and every other area's as
 * reference; an increment has no area (`null`), so it gets every line.
 */
export function areaReviewArgs(areas, area, decisions) {
  const linesOf = (a) => a.decisions.map((id) => decisions.get(id)).filter(Boolean);
  return {
    area,
    decisions: area ? linesOf(area) : [...decisions.values()],
    otherAreas: areas.filter((o) => o && o !== area).map((o) => ({ name: o.name, files: o.files, decisions: linesOf(o) })),
  };
}

/** Pure: what the planner is told. */
export function plannerPrompt({ featureBranch, base, max, stat, issues, decisions }) {
  return [
    `Feature review planning: split the review of ${featureBranch} (diff ${base}..${featureBranch}) into at most ${max} areas.`,
    "Each area is read end to end by one reviewer, who judges whether the PRD decisions you give it hold in the merged code.",
    "Group files that work together (one flow, one module and its callers) and give each area the decisions that touch it.",
    "You may only read this prompt: answer from it, run nothing.",
    "",
    "Diff stat:",
    "```",
    stat.trimEnd(),
    "```",
    "",
    "Merged issues (files changed, PRD decision IDs each implements):",
    ...(issues.length
      ? issues.map((i) => `- ${i.branch}: files ${i.files.join(", ") || "(none)"}; implements ${i.ids.join(", ") || "(none named)"}`)
      : ["- (none found in the history)"]),
    "",
    "PRD decisions:",
    ...(decisions.size ? [...decisions.values()] : ["(none — the PRD has no decision lines)"]),
    "",
    `Answer with one fenced json block: {"areas": [{"name": "<short>", "files": ["<path from the diff stat>"], "decisions": ["<ID such as D3>"]}]}`,
    `At most ${max} areas; every changed file should sit in some area; use only the paths and IDs above.`,
  ].join("\n");
}

/** `{branch, files, ids}` for each issue branch merged into the feature in `base..tip`; `ids` from `idsFor(branch)`. */
export function mergedIssues(ctx, { base, tip, idsFor = () => [] }) {
  const { effects } = ctx;
  const log = effects.gitRead(["log", "--first-parent", "--merges", "--reverse", "--format=%H%x09%s", `${base}..${tip}`]);
  if (log.code !== 0) return [];
  const out = [];
  for (const line of log.stdout.split("\n").filter(Boolean)) {
    const [sha, subject = ""] = line.split("\t");
    const branch = /^Merge branch '(crew\/[^']+)'/.exec(subject)?.[1];
    if (!branch) continue;
    out.push({ branch, files: names(effects.gitRead([...DIFF, "--name-only", "-z", `${sha}^1`, sha])), ids: idsFor(branch) });
  }
  return out;
}

/**
 * `branch → ## Implements IDs`, from one listing of the feature's issues in every state (a merged
 * issue is `done`: in done/, `awaiting-merge` or closed). A branch's stem is the issue's slug
 * (local: `crew/<feature>/<slug>`) or `<number>-<slug>` (github), matched by slug first, then by
 * the stem's leading number. A failed listing warns and every branch reads as implementing none.
 */
export function implementsLookup(ctx, tracker) {
  const { effects, sprint } = ctx;
  let issues;
  return (branch) => {
    if (!issues) {
      issues = [];
      try {
        issues = tracker.listFeatureIssues(effects.mainRoot, { featureSlug: sprint.featureSlug });
      } catch (e) {
        ctx.log(`FEATURE-REVIEW: could not list the feature's issues for their ## Implements IDs — ${e.message}`, "warn");
      }
    }
    const stem = branch.split("/").pop();
    const n = /^(\d+)-/.exec(stem)?.[1];
    const issue =
      issues.find((i) => i.slug === stem || `${i.number}-${i.slug}` === stem) ??
      (n === undefined ? undefined : issues.find((i) => i.number != null && Number(i.number) === Number(n)));
    return issue ? implementedIds(issue.text ?? "") : [];
  };
}

/**
 * Plan the areas of a whole-feature review: `{ areas, why? }` with at least one area. `why` is set
 * when the planner could not be used and the one-area fallback applies.
 */
export async function planAreas(ctx, { base, tip, dir }) {
  const { sprint, effects, options } = ctx;
  const max = Math.max(1, options.parallel ?? 1);
  const diffFiles = names(effects.gitRead([...DIFF, "--name-only", "-z", `${base}..${tip}`]));
  const decisions = loadPrdDecisions(ctx);
  const ids = [...decisions.keys()];
  const fallback = (why) => {
    ctx.log(`FEATURE-REVIEW: planner fallback — ${why}; one area over the whole diff`, "warn");
    return { areas: [wholeFeatureArea(diffFiles, ids)], why };
  };

  const issues = mergedIssues(ctx, { base, tip, idsFor: implementsLookup(ctx, ctx.tracker ?? (await getTracker(effects.mainRoot))) });
  const prompt = plannerPrompt({
    featureBranch: sprint.featureBranch,
    base,
    max,
    // Off a tty git fits the stat to 80 columns and shortens long paths to `.../name`, which the planner
    // must answer with verbatim: give it room for every path in full.
    stat: stdoutOf(effects.gitRead([...DIFF, "--stat=1000", "--stat-name-width=1000", `${base}..${tip}`])),
    issues,
    decisions,
  });
  const planner = roleBinding(ctx, "reviewer");
  ctx.log(`[STEP] step=feature-plan model=${planner.model ?? "inherit"} runtime=${planner.runtime}`);
  const guarded = await readOnlyDispatch(ctx, { label: "feature-plan" }, () =>
    dispatchPlain(effects, planner.runtime, {
      prompt,
      cwd: effects.mainRoot,
      mainRoot: effects.mainRoot,
      model: planner.model,
      outFile: join(dir, "planner.md"),
      timeoutMs: options.timeoutMs.reviewer,
      maxBudgetUsd: planner.maxBudgetUsd,
      fakeAgent: "feature-planner",
      logFile: sprint.traceLog,
    }),
  );
  const r = guarded.result;
  if (r && !r.dryRun) sprint.recordDispatchCost(r, { slug: FEATURE_PLAN, role: "reviewer", attempt: 1 });
  if (guarded.violation) return fallback(`the planner ${guarded.violation}`);
  if (!r || r.dryRun) return fallback("the planner did not run");
  if (r.timedOut) return fallback("the planner timed out");
  if (r.code !== 0) return fallback(`the planner exited ${r.code}`);
  const answer = parsePlannerAnswer(r.text);
  if (!answer) return fallback("the planner's answer has no fenced json block");
  const areas = normalizeAreas(answer.areas, { diffFiles, decisionIds: ids, max, issues });
  if (!areas.length) return fallback("the planner returned no usable area");
  // One area holds every changed file (uncovered ones join it), so its diff needs no pathspec.
  if (areas.length === 1) areas[0].whole = true;
  ctx.log(`FEATURE-REVIEW: planner: ${areas.length} area(s) — ${areas.map((a) => `${a.name} (${a.files.length} file(s), ${a.decisions.length} decision(s))`).join("; ")}`);
  return { areas };
}
