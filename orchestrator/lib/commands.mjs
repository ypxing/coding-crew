/**
 * commands.mjs — find the dev-loop test/lint/typecheck commands once per sprint and cache them in
 * .coding-crew/dev-commands.json. Advisory: a failure is logged, never thrown, and each check falls
 * back to its own discovery.
 */

import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { dispatchPlain } from "./dispatch.mjs";

export async function discoverCommands(effects, { platform, model, timeoutMs, maxBudgetUsd = null, log = () => {}, recordCost = () => {} }) {
  // Read-only, so it runs even under --dry-run.
  const d = effects.bash("discover-commands.sh", [], { mutating: false });
  const [head, ...prompt] = d.stdout.trim() ? d.stdout.trim().split("\n") : [];
  if (head) log(head);
  if (prompt.length && effects.dryRun) log(prompt.join("\n"), "debug");
  else if (prompt.length) {
    const promptFile = join(effects.mainRoot, ".scratch", "commands-prompt.md");
    mkdirSync(dirname(promptFile), { recursive: true });
    writeFileSync(promptFile, d.stdout);
    log("Command discovery: prompt kept at .scratch/commands-prompt.md", "debug");
  }

  // A failed script must not dispatch its leftovers or a half-built prompt as real output.
  if (d.code !== 0) {
    log(`Command discovery: discover-commands.sh failed (exit ${d.code}) — ${(d.stderr || d.stdout).trim() || "no output"}`);
    return;
  }

  // Only the first line can say "skipped": the prompt may quote that word from a CLAUDE.md.
  const firstLine = d.stdout.split("\n", 1)[0] ?? "";
  if (/^Command discovery: skipped/.test(firstLine) || effects.dryRun) return;

  const outFile = join(effects.mainRoot, ".scratch", "commands-response.md");
  let r;
  try {
    r = await dispatchPlain(effects, platform, {
      prompt: d.stdout,
      cwd: effects.mainRoot,
      mainRoot: effects.mainRoot,
      model,
      outFile,
      timeoutMs,
      maxBudgetUsd,
      // Selects fake-dispatch.sh's "commands-discovery" branch under CREW_FAKE_DISPATCH.
      fakeAgent: "commands-discovery",
    });
  } catch (e) {
    log(`Command discovery: dispatch failed (${e.message}) — falling back to per-check discovery.`);
    return;
  }
  // Spent whether or not the answer is usable.
  recordCost(r);

  if (r.code !== 0 || r.timedOut) {
    const detail = (r.stderr || r.text || "").trim();
    log(
      `Command discovery: model dispatch did not complete (${r.timedOut ? "timed out" : `exit ${r.code}`}) — falling back to per-check discovery.` +
        (detail ? ` Last output: ${detail.slice(-500)}` : ""),
    );
    return;
  }

  const w = effects.bash("write-commands-cache.sh", ["--response-file", outFile]);
  log((w.code === 0 ? w.stdout : `Command discovery: cache write failed — ${w.stderr || w.stdout}`).trim());
}
