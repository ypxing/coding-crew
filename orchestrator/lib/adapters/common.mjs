/** Helpers shared by the adapters: the normalized-event shape, a capped preview, and the empty result-meta shape. */

/** A capped JSON preview that says how much it cut, so truncation is never mistaken for the whole value. */
export function safePreview(value, max = 200) {
  let text;
  try {
    text = JSON.stringify(value ?? {});
  } catch {
    text = "{}";
  }
  return text.length > max ? `${text.slice(0, max)}…(+${text.length - max} chars)` : text;
}

/**
 * A normalized event (PRD D12): `{ kind, tool?, command?, path?, args?, id?, detail? }`, each
 * adapter's `normalize(evt)` result. `kind` is "tool" | "tool-error" | "agent-error" | "text";
 * `detail` is the trace text after the tool for an error, the assistant's text for "text".
 * Absent fields are left out, not set to undefined.
 */
export function normalized(kind, fields = {}) {
  const evt = { kind };
  for (const [k, v] of Object.entries(fields)) if (v != null) evt[k] = v;
  return evt;
}

/** `value` when it is a string, else undefined; `nonEmpty` also drops "". */
export const str = (value, nonEmpty = false) => (typeof value === "string" && (!nonEmpty || value) ? value : undefined);

export const EMPTY_RESULT_META = {
  isError: null,
  subtype: null,
  costUsd: null,
  durationMs: null,
  numTurns: null,
  permissionDenials: [],
  sessionId: null,
  contextTokens: null,
  costUnknown: false,
  tokens: null,
};

/** Last parsed event of `type` among JSONL `lines`, scanning from the end; null when none parses. */
export function lastEvent(lines, type) {
  for (let i = lines.length - 1; i >= 0; i--) {
    try {
      const evt = JSON.parse(lines[i]);
      if (evt.type === type) return evt;
    } catch {
      /* skip an unparseable line */
    }
  }
  return null;
}

/**
 * Argv strings are capped per string (Linux MAX_ARG_STRLEN, 128 KiB), and Windows caps the whole
 * command line (32,767 characters). A prompt that has to travel in argv fails the dispatch with
 * this message rather than being cut.
 */
export const ARGV_PROMPT_LIMIT_BYTES = 128 * 1024;
const WINDOWS_COMMAND_LINE_CHARS = 32767;

export function assertArgvFits(args, cli, platform = process.platform) {
  for (const a of args) {
    const bytes = Buffer.byteLength(a, "utf8");
    if (bytes > ARGV_PROMPT_LIMIT_BYTES) {
      throw new Error(
        `prompt is ${bytes} bytes, over the ${ARGV_PROMPT_LIMIT_BYTES}-byte (128 KiB) argv size limit; ${cli} takes it as a command-line argument, so it cannot be sent without truncating`,
      );
    }
  }
  const chars = [cli, ...args].reduce((n, a) => n + a.length + 1, 0);
  if (platform === "win32" && chars > WINDOWS_COMMAND_LINE_CHARS) {
    throw new Error(
      `the ${cli} command line is ${chars} characters, over Windows' ${WINDOWS_COMMAND_LINE_CHARS}-character limit; the prompt cannot be sent without truncating`,
    );
  }
}
