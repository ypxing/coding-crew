/**
 * Helpers shared by the herdr and orca adapters. See index.mjs for what a pane host is.
 */

/**
 * Async spawn, never effects.exec: exec is spawnSync, and a blocking pane-host call would
 * stall every concurrent dispatch in the pool (loop.mjs) sharing this event loop.
 */
export async function paneHostExec(effects, args, timeoutMs) {
  return effects.spawnWithTimeout(effects.paneHost, args, { cwd: effects.mainRoot, timeoutMs });
}

/**
 * Both hosts print success as JSON on stdout, but an error can land on stderr instead —
 * so try both, in that order, or a failed call's detail is unreachable.
 */
export function paneHostJson(result) {
  for (const text of [result?.stdout, result?.stderr]) {
    if (!text) continue;
    try {
      return JSON.parse(text);
    } catch {
      /* try the next candidate */
    }
  }
  return null;
}

/** The feature slug tells concurrent runs apart; "crew-afk" when none resolved. */
export function paneWorkspaceLabel(featureSlug) {
  return featureSlug || "crew-afk";
}

/** POSIX single-quoting, for text orca types into a shell rather than passing as argv. */
export function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

export function failureDetail(result) {
  return (result.stderr || result.stdout || "").trim();
}

/**
 * One failed host call as text: `<what> exit=<code>` plus the host's own words, and a note when
 * the call was killed at its timeout (exit 124), whose output is usually empty.
 */
export function hostFailure(what, result, timeoutMs) {
  const detail = failureDetail(result);
  const timedOut = result.code === 124 ? ` (timed out${timeoutMs ? ` after ${timeoutMs / 1000}s` : ""})` : "";
  return `${what} exit=${result.code}${timedOut}${detail ? ` ${detail}` : ""}`;
}

/** A terminal line without the decoration a TUI puts around a message (`> `, `⏺ `, a box edge). */
const undecorated = (line) => line.replace(/^[\s⏺●•·*>❯│|-]+/, "").replace(/[\s│|]+$/, "");

/**
 * The part of an agent's terminal `text` after the last line that echoes `prompt` (its last
 * non-blank line, undecorated), or null when no line does. herdr has no message queue, so an
 * earlier turn's `QUESTION:` / `DONE:` line sits in the same text as this turn's: only what comes
 * after the prompt crew-afk sent can be this turn's.
 */
export function textAfterPrompt(text, prompt) {
  const anchor = String(prompt ?? "")
    .split("\n")
    .map(undecorated)
    .filter(Boolean)
    .at(-1);
  if (!anchor) return null;
  const lines = String(text ?? "").split("\n");
  const at = lines.findLastIndex((line) => undecorated(line) === anchor);
  return at === -1 ? null : lines.slice(at + 1).join("\n");
}

/** The last `QUESTION: …` or `DONE: …` line of an agent's terminal text (herdr has no message queue). */
export function lastMarkerLine(text) {
  const marks = String(text ?? "")
    .split("\n")
    .map((line) => /^[\s⏺●•·*>-]*(QUESTION|DONE):\s*(.*\S)\s*$/.exec(line))
    .filter(Boolean);
  const last = marks.at(-1);
  return last ? { kind: last[1] === "QUESTION" ? "question" : "done", text: last[2] } : null;
}
