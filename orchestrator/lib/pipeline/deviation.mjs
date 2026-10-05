/**
 * deviation.mjs — a coder that ran the whole test suite itself.
 *
 * Under CREW_DEFER_FULL_CHECKS=1 the full suite is the verify gate's; a coder runs only the
 * tests it touched (`run-checks.sh --targeted`). Its tool calls are in the dispatch's
 * `<outFile>.events.jsonl`: a command that contains the `dev-commands.json` `test` command
 * verbatim with no test-file argument after it (and is not run-checks.sh) is the suite run in full. Recorded and named in the
 * summary; never fails the issue.
 */

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

/**
 * Every `command` string in an event, whatever the runtime's tool-call shape, with the id of the
 * tool call it belongs to (the nearest `id` / `toolCallId` / `tool_use_id` around it), or null.
 */
function commandsIn(node, out = [], id = null) {
  if (Array.isArray(node)) node.forEach((n) => commandsIn(n, out, id));
  else if (node && typeof node === "object") {
    const own = node.id ?? node.toolCallId ?? node.tool_use_id ?? id;
    for (const [k, v] of Object.entries(node)) {
      if (k === "command" && typeof v === "string") out.push({ cmd: v, id: own });
      else commandsIn(v, out, own);
    }
  }
  return out;
}

/** `VAR=value cmd …` → `cmd …`: an env prefix in the cached command is not how a coder types it. */
const withoutEnvPrefix = (cmd) => cmd.replace(/^(\s*[A-Za-z_][A-Za-z0-9_]*=\S*\s+)+/, "");

/** The cached `test` command, or null (absent file, `null`, unreadable). */
export function cachedTestCommand(mainRoot) {
  try {
    const cache = JSON.parse(readFileSync(join(mainRoot, ".coding-crew", "dev-commands.json"), "utf8"));
    return typeof cache.test === "string" && cache.test.trim() ? cache.test.trim() : null;
  } catch {
    return null;
  }
}

/**
 * True when `cmd` runs `testCommand` as the whole suite: the text after it, up to the next shell
 * separator, holds no argument that is not a flag, a flag's numeric value, or a redirection and
 * its target (`pytest tests/test_x.py` and
 * `npm test -- a.test.js` name test files, so they are targeted runs).
 */
function runsWholeSuite(cmd, testCommand) {
  let from = 0;
  for (;;) {
    const at = cmd.indexOf(testCommand, from);
    if (at < 0) return false;
    from = at + testCommand.length;
    // Whole words only: `make test` is not in `make test-unit` or `xmake test`. A subshell or a
    // quoted `bash -lc '…'` (codex's command form) bounds it too, and ends its arguments.
    if (/[^\s;&|('"]/.test(cmd[at - 1] ?? " ") || /[^\s;&|)<>'"]/.test(cmd[from] ?? " ")) continue;
    const rest = cmd.slice(from).split(/&&|\|\||[;|\n)'"]/)[0];
    const words = rest.split(/\s+/).filter(Boolean);
    // A bare redirection operator (`>`, `2>`, `&>`) takes the next word as its target; a bare
    // number is a flag's value (`-n 4`, `--maxWorkers 2`). Neither names a test file.
    const args = words.filter(
      (a, i) => a !== "--" && !/^(\d*|&)[<>]/.test(a) && !/^\d+$/.test(a) && !/^(\d*|&)[<>]+$/.test(words[i - 1] ?? ""),
    );
    if (!args.some((a) => !a.startsWith("-"))) return true;
  }
}

/** Commands in an events file that ran `testCommand` in full; [] when none or unreadable. */
export function fullSuiteRuns(eventsFile, testCommand) {
  if (!testCommand || !existsSync(eventsFile)) return [];
  const core = withoutEnvPrefix(testCommand);
  const runs = [];
  // One tool call can appear in several events (codex's item.started and item.completed).
  const seen = new Set();
  for (const line of readFileSync(eventsFile, "utf8").split("\n")) {
    if (!line.includes("command")) continue;
    let evt;
    try {
      evt = JSON.parse(line);
    } catch {
      continue;
    }
    for (const { cmd, id } of commandsIn(evt)) {
      if (id != null && seen.has(id)) continue;
      if (runsWholeSuite(cmd, core) && !cmd.includes("run-checks.sh")) {
        if (id != null) seen.add(id);
        runs.push(cmd);
      }
    }
  }
  return runs;
}

/**
 * Logs `[DEVIATION]` and records it for the summary when the coder's trace shows the full suite.
 * @returns {number} how many full-suite runs were seen
 */
export function flagFullSuiteRuns(ctx, { slug, attempt, outFile }) {
  const { sprint, effects } = ctx;
  const testCommand = cachedTestCommand(effects.mainRoot);
  const runs = fullSuiteRuns(`${outFile}.events.jsonl`, testCommand);
  if (!runs.length) return 0;
  const reason = `coder ran the full test suite ${runs.length}x (\`${testCommand}\`); the verify gate owns it`;
  ctx.log(`[DEVIATION] slug=${slug} round=${attempt} ${reason}`, "warn");
  sprint.deviation(slug, reason);
  return runs.length;
}
