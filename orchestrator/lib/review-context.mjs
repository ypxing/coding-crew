/**
 * review-context.mjs — the reviewer's stack checklists, resolved once per sprint.
 *
 * `review-context.sh` names the STACK and the reference files that apply to the repo; that answer
 * does not change between reviews of one sprint, so it runs once and its result is inlined in
 * every review prompt. When the script is missing or fails, every file in the assets'
 * `references/` is used instead (the protocol's own fallback), and the prompt says so.
 */

import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const cache = new WeakMap();

function readRefs(paths) {
  return paths.flatMap((path) => {
    try {
      return [{ path, text: readFileSync(path, "utf8") }];
    } catch {
      return [];
    }
  });
}

/** Pure: resolve the context for `assets` (the reviewer's asset dir) against `root`. */
export function resolveReviewContext(effects, assets, root) {
  const script = join(assets, "scripts", "review-context.sh");
  const refDir = join(assets, "references");
  const all = () =>
    existsSync(refDir)
      ? readRefs(readdirSync(refDir).filter((f) => f.endsWith(".md")).sort().map((f) => join(refDir, f)))
      : [];
  const fallback = (why) => ({
    stack: null,
    files: all(),
    note: `review-context.sh ${why}; every checklist in ${refDir} is included instead.`,
  });
  if (!existsSync(script)) return fallback("is missing");
  const r = effects.exec("bash", [script, "--root", root], { mutating: false });
  if (r.code !== 0 || r.error) return fallback(`failed (exit ${r.code})`);
  const stack = /^STACK: (.*)$/m.exec(r.stdout)?.[1]?.trim() ?? null;
  const paths = [...r.stdout.matchAll(/^REFERENCE: (.+)$/gm)].map((m) => m[1].trim()).filter((p) => p !== "none");
  if (stack === null) return fallback("printed no STACK line");
  return { stack, files: readRefs(paths), note: "" };
}

/** Once per sprint: the first review runs the script, later ones reuse the result. */
export function sprintReviewContext(sprint, effects, assets, root) {
  if (!cache.has(sprint)) cache.set(sprint, resolveReviewContext(effects, assets, root));
  return cache.get(sprint);
}

/** Prompt text for a context; empty when there is none. */
export function renderReviewContext(ctx) {
  if (!ctx) return [];
  const out = ["Review context (provided — do not run review-context.sh, do not fetch the references):"];
  if (ctx.note) out.push(ctx.note);
  out.push(ctx.stack ? `STACK: ${ctx.stack}` : "STACK: unknown");
  for (const f of ctx.files) out.push("", `Checklist ${f.path}:`, "---", f.text.trim(), "---");
  out.push("");
  return out;
}
