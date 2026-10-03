/** Helpers shared by the adapters: trace-line formatting and the empty result-meta shape. */

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
 * `$ <command>` for a shell call, a bare path for a file tool; null for any other shape,
 * which formatArgs renders as a capped JSON preview instead.
 */
function summarizeArgs(args) {
  if (!args || typeof args !== "object") return null;
  if (typeof args.command === "string") return `$ ${args.command}`;
  const path = args.file_path ?? args.path;
  return typeof path === "string" ? path : null;
}

export function formatArgs(args) {
  return summarizeArgs(args) ?? `args=${safePreview(args)}`;
}

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
 * Argv strings are capped per string (Linux MAX_ARG_STRLEN, 128 KiB). A prompt that has to travel
 * as one fails the dispatch with this message rather than being cut.
 */
export const ARGV_PROMPT_LIMIT_BYTES = 128 * 1024;

export function assertArgvPromptFits(prompt, cli) {
  const bytes = Buffer.byteLength(prompt, "utf8");
  if (bytes > ARGV_PROMPT_LIMIT_BYTES) {
    throw new Error(
      `prompt is ${bytes} bytes, over the ${ARGV_PROMPT_LIMIT_BYTES}-byte (128 KiB) argv size limit; ${cli} takes it as a command-line argument, so it cannot be sent without truncating`,
    );
  }
}
