
/** Says how much it cut, so truncation is never mistaken for the whole value. */
export function safePreview(value, max = 200) {
  let text;
  try {
    text = JSON.stringify(value ?? {});
  } catch {
    text = "{}";
  }
  return text.length > max ? `${text.slice(0, max)}…(+${text.length - max} chars)` : text;
}

/** `{ kind, tool?, command?, path?, args?, id?, detail? }`; absent fields are left out, not undefined. */
export function normalized(kind, fields = {}) {
  const evt = { kind };
  for (const [k, v] of Object.entries(fields)) if (v != null) evt[k] = v;
  return evt;
}

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

/** Linux caps each argv string (MAX_ARG_STRLEN) and Windows the whole command line: fail, never truncate. */
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
