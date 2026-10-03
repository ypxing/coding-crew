/**
 * deviation.mjs — a coder that ran the whole test suite itself.
 *
 * Under CREW_DEFER_FULL_CHECKS=1 the full suite is the verify gate's; a coder runs only the
 * tests it touched (`run-checks.sh --targeted`). Its tool calls are in the dispatch's
 * `<outFile>.events.jsonl`: a command that contains the `dev-commands.json` `test` command
 * verbatim (and is not run-checks.sh) is the suite run in full. Recorded and named in the
 * summary; never fails the issue.
 */

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

/** Every `command` string in an event, whatever the runtime's tool-call shape. */
function commandsIn(node, out = []) {
  if (Array.isArray(node)) node.forEach((n) => commandsIn(n, out));
  else if (node && typeof node === "object") {
    for (const [k, v] of Object.entries(node)) {
      if (k === "command" && typeof v === "string") out.push(v);
      else commandsIn(v, out);
    }
  }
  return out;
}

/** The cached `test` command, or null (absent file, `null`, unreadable). */
export function cachedTestCommand(mainRoot) {
  try {
    const cache = JSON.parse(readFileSync(join(mainRoot, ".coding-crew", "dev-commands.json"), "utf8"));
    return typeof cache.test === "string" && cache.test.trim() ? cache.test.trim() : null;
  } catch {
    return null;
  }
}

/** Commands in an events file that ran `testCommand` in full; [] when none or unreadable. */
export function fullSuiteRuns(eventsFile, testCommand) {
  if (!testCommand || !existsSync(eventsFile)) return [];
  const runs = [];
  for (const line of readFileSync(eventsFile, "utf8").split("\n")) {
    if (!line.includes("command")) continue;
    let evt;
    try {
      evt = JSON.parse(line);
    } catch {
      continue;
    }
    for (const cmd of commandsIn(evt)) {
      if (cmd.includes(testCommand) && !cmd.includes("run-checks.sh")) runs.push(cmd);
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
