/**
 * claude adapter: `claude -p --output-format stream-json --verbose`. Today's argv, trace parsing
 * and the cost/session/resume/budget behaviour, moved out of dispatch.mjs.
 */
import { EMPTY_RESULT_META, formatArgs, lastEvent, safePreview } from "./common.mjs";
import { ROLE_ARGS } from "./role-args.mjs";

/** One assistant event's whole token usage: prompt, cache and output. */
function usageTokens(u) {
  return (u.input_tokens ?? 0) + (u.cache_read_input_tokens ?? 0) + (u.cache_creation_input_tokens ?? 0) + (u.output_tokens ?? 0);
}

export default {
  cmd: "claude",
  defaultParallel: 3,
  defaultModel: "sonnet",
  // The CLI takes the system prompt from a file, and the prompt as its positional argument.
  promptVia: "argv",
  // Flags the dispatch argv relies on for a full-permission headless run; `doctor` checks `--help` lists them.
  requiredFlags: ["--permission-mode", "--output-format", "--append-system-prompt-file", "--add-dir"],

  /**
   * bypassPermissions removes the *prompt*, not an allowlist. stream-json requires --verbose, or
   * claude refuses to start. `protocolFile` is the rendered role protocol (none for a plain role).
   * The prompt sits right after `-p`: `--add-dir` and `--disallowedTools` are variadic and would
   * swallow a prompt that followed them.
   */
  argv({ mainRoot, model, role, protocolFile, prompt }) {
    const args = ["-p", prompt, "--permission-mode", "bypassPermissions", "--add-dir", mainRoot];
    if (protocolFile) args.push("--append-system-prompt-file", protocolFile);
    args.push("--output-format", "stream-json", "--verbose");
    if (model) args.push("--model", model);
    args.push(...this.roleArgs(role));
    return args;
  },

  roleArgs: (role) => ROLE_ARGS.claude[role] ?? [],
  // A fix round continuing the coder's own earlier session.
  resume: (id) => ["--resume", id],
  // claude ends the session with `subtype: error_max_budget_usd` (exit 1, no result).
  budget: (usd) => ["--max-budget-usd", String(usd)],

  // Session ids cleared so a child launched from inside a Claude Code session starts its own
  // instead of attaching to the parent's hook chain, which can mutate or swallow the prompt.
  // Auto-memory off: every dispatch is unattended, and the memory dir is shared across every
  // worktree, so a note one wrote would reach every later session unreviewed.
  env: { CLAUDE_CODE_SESSION_ID: "", CLAUDE_CODE_CHILD_SESSION: "", CLAUDE_CODE_DISABLE_AUTO_MEMORY: "1" },

  traceLine(evt, agent) {
    if (evt.type === "assistant") {
      for (const block of evt.message?.content ?? []) {
        if (block.type === "tool_use") return `[TOOL] agent=${agent} tool=${block.name} ${formatArgs(block.input)}`;
      }
    }
    if (evt.type === "user") {
      for (const block of evt.message?.content ?? []) {
        if (block.type === "tool_result" && block.is_error) {
          return `[TOOL-ERROR] agent=${agent} tool_use_id=${block.tool_use_id ?? "?"}`;
        }
      }
    }
    // A run that dies on an API error (auth, quota) says so only here.
    if (evt.type === "result" && evt.is_error) return `[AGENT-ERROR] agent=${agent} error=${safePreview(evt.result)}`;
    return null;
  },

  /** The terminal `result` line's `.result`; "" when absent (an empty report is a handled state). */
  finalText: (lines) => lastEvent(lines, "result")?.result ?? "",

  /**
   * Cost, error and timing from claude's `result` events. A session can emit several (a worker that
   * used background tasks gets one per wake-up): turns and agent time are summed, cost (cumulative)
   * is the last one's. A stream with no `result` (killed on timeout) is cost-unknown, with what it
   * spent read off its assistant events. `contextTokens` is the last assistant turn's prompt size.
   */
  resultMeta(lines) {
    let contextTokens = null;
    let tokens = 0;
    let assistantTurns = 0;
    let parsed = 0;
    const seenMessages = new Set();
    const results = [];
    for (const line of lines) {
      let evt;
      try {
        evt = JSON.parse(line);
      } catch {
        continue; // skip an unparseable line
      }
      parsed++;
      if (evt?.type === "result") {
        results.push(evt);
      } else if (evt?.type === "assistant") {
        // One message streams as several events (one per content block) sharing an id and usage.
        const id = evt.message?.id;
        if (id != null) {
          if (seenMessages.has(id)) continue;
          seenMessages.add(id);
        }
        assistantTurns++;
        const u = evt.message?.usage;
        if (u) {
          tokens += usageTokens(u);
          contextTokens = (u.input_tokens ?? 0) + (u.cache_read_input_tokens ?? 0) + (u.cache_creation_input_tokens ?? 0);
        }
      }
    }
    if (results.length) {
      const last = results[results.length - 1];
      const sum = (key) => (results.some((e) => e[key] != null) ? results.reduce((n, e) => n + (e[key] ?? 0), 0) : null);
      return {
        isError: last.is_error ?? null,
        subtype: last.subtype ?? null,
        costUsd: last.total_cost_usd ?? null,
        durationMs: sum("duration_ms"),
        numTurns: sum("num_turns"),
        permissionDenials: last.permission_denials ?? [],
        sessionId: last.session_id ?? null,
        contextTokens,
        costUnknown: false,
        tokens: null,
      };
    }
    if (!parsed) return EMPTY_RESULT_META;
    return { ...EMPTY_RESULT_META, numTurns: assistantTurns, contextTokens, costUnknown: true, tokens };
  },
};
