/**
 * commands.mjs — the sprint's one-time command discovery.
 *
 * Finds the local dev-loop test/lint/typecheck commands once, before any worktree exists,
 * the same shape coverage-validation.sh's step already uses: a bash script decides whether a
 * model call is needed and builds the prompt (discover-commands.sh), an agent-less
 * dispatchPlain() call answers it, and a second bash script (write-commands-cache.sh) turns
 * the answer into .scratch/commands.json. verify-worktree.sh and solve-issue then read that
 * cache instead of guessing from CLAUDE.md/Makefile with a fragile regex.
 *
 * Advisory, like ensure-deps.sh: any failure here is logged and never thrown — a missing or
 * stale cache just means the checks fall back to the pre-existing heuristic chain, exactly the
 * behaviour every repo already had before this step existed. --dry-run costs zero tokens: the
 * discovery script itself is read-only and safe to run for its "would (not) run" message, but
 * the model dispatch and the cache write are skipped outright.
 */

import { join } from "node:path";
import { dispatchPlain } from "./dispatch.mjs";

export async function discoverCommands(effects, { platform, model, timeoutMs, log = () => {} }) {
  // Read-only — safe (and informative) to actually run under --dry-run/plan, unlike the
  // model dispatch and cache write below.
  const d = effects.bash("discover-commands.sh", [], { mutating: false });
  if (d.stdout.trim()) log(d.stdout.trim());

  // A non-zero exit here (a candidate file vanishing mid-read, an unreadable manifest, …)
  // must not fall through to dispatching stderr's leftovers or a half-built prompt as if it
  // were discover-commands.sh's real output — that is how this step used to fail silently:
  // no cache, no error anyone could see short of re-running by hand.
  if (d.code !== 0) {
    log(`Command discovery: discover-commands.sh failed (exit ${d.code}) — ${(d.stderr || d.stdout).trim() || "no output"}`);
    return;
  }

  // Only discover-commands.sh's own *first line* ever says "skipped" — its skip paths echo
  // that single line and exit immediately, before printing a prompt. Testing the regex
  // against the whole of d.stdout (as this used to do) matches the word "skipped" anywhere
  // in the prompt it goes on to build, including inside a quoted CLAUDE.md/AGENTS.md's own
  // prose ("...because I skipped this; don't repeat the mistake." is a real line seen in the
  // wild) — silently discarding a fully-built prompt and never calling the model, with
  // nothing logged to explain why, because the short-circuit fires before any of the
  // branches below that do log.
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
      // Distinguishes this agent-less dispatch from coverage validation's under the
      // CREW_FAKE_DISPATCH test seam — see fake-dispatch.sh's "commands-discovery" branch.
      fakeAgent: "commands-discovery",
    });
  } catch (e) {
    log(`Command discovery: dispatch failed (${e.message}) — falling back to per-check discovery.`);
    return;
  }

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
