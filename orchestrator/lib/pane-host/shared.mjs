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
