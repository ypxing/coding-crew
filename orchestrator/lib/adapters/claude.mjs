/** claude adapter: `claude -p --output-format stream-json --verbose`. */
import { EMPTY_RESULT_META, lastEvent, normalized, safePreview, str } from "./common.mjs";

function usageTokens(u) {
  return (u.input_tokens ?? 0) + (u.cache_read_input_tokens ?? 0) + (u.cache_creation_input_tokens ?? 0) + (u.output_tokens ?? 0);
}

export default {
  cmd: "claude",
  defaultParallel: 3,
  defaultModel: "sonnet",
  coAuthor: "Co-authored-by: Claude Code <claude@anthropic.com>",
  // Cost arrives in the final `result` event: a dispatch killed before it has an unknown cost.
  reportsCost: true,
  // `doctor` checks `--help` lists these.
  requiredFlags: ["--permission-mode", "--output-format", "--append-system-prompt-file", "--add-dir"],
  // A reviewer/triage tier below the coder's is warned about.
  modelTiers: { haiku: 0, sonnet: 1, opus: 2 },
  // An alias maps through the child CLI's own env, which every dispatch inherits.
  modelAliasEnv: {
    haiku: "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    sonnet: "ANTHROPIC_DEFAULT_SONNET_MODEL",
    opus: "ANTHROPIC_DEFAULT_OPUS_MODEL",
  },

  /**
   * bypassPermissions removes the *prompt*, not an allowlist. stream-json requires --verbose. The
   * prompt goes right after `-p`: `--add-dir` and `--disallowedTools` are variadic and would swallow it.
   */
  build({ mainRoot, model, policy, protocolFile, prompt }) {
    const args = ["-p", prompt, "--permission-mode", "bypassPermissions", "--add-dir", mainRoot];
    if (protocolFile) args.push("--append-system-prompt-file", protocolFile);
    args.push("--output-format", "stream-json", "--verbose");
    if (model) args.push("--model", model);
    if (policy) args.push(...this.policyArgs(policy));
    return { args };
  },

  /** Prompt first, for the same variadic flags; permission prompts stay on for the human in the pane. */
  interactive({ mainRoot, model, protocol, policy }) {
    const argv = ["claude", protocol, "--add-dir", mainRoot];
    if (model && model !== "inherit") argv.push("--model", model);
    if (policy) argv.push(...this.policyArgs(policy));
    return argv;
  },

  policyArgs({ readOnly, subagents, effort }) {
    const denied = [...(readOnly ? ["Edit", "Write", "NotebookEdit"] : []), ...(subagents ? [] : ["Agent"])];
    return [...(effort ? ["--effort", effort] : []), ...(denied.length ? ["--disallowedTools", ...denied] : [])];
  },

  resume: (id) => ["--resume", id],
  // claude ends the session with `subtype: error_max_budget_usd` (exit 1, no result).
  budget: (usd) => ["--max-budget-usd", String(usd)],

  // Session ids cleared so a child of a Claude Code session doesn't attach to the parent's hook
  // chain, which can mutate or swallow the prompt. Auto-memory off: the memory dir is shared across
  // worktrees, so an unattended note would reach every later session unreviewed.
  env: { CLAUDE_CODE_SESSION_ID: "", CLAUDE_CODE_CHILD_SESSION: "", CLAUDE_CODE_DISABLE_AUTO_MEMORY: "1" },

  liveText: true,

  normalize(evt) {
    const blocks = Array.isArray(evt.message?.content) ? evt.message.content : [];
    if (evt.type === "assistant") {
      const uses = blocks.filter((b) => b?.type === "tool_use").map((use) =>
        normalized("tool", {
          tool: use.name,
          command: str(use.input?.command),
          path: str(use.input?.file_path ?? use.input?.path),
          args: use.input,
          id: str(use.id),
        }),
      );
      if (uses.length) return uses.length === 1 ? uses[0] : uses;
      const text = blocks.filter((b) => b?.type === "text" && typeof b.text === "string" && b.text.trim()).map((b) => b.text.trim());
      return text.length ? normalized("text", { detail: text.join("\n") }) : null;
    }
    if (evt.type === "user") {
      const failed = blocks.find((b) => b?.type === "tool_result" && b.is_error);
      if (failed) return normalized("tool-error", { id: str(failed.tool_use_id), detail: `tool_use_id=${failed.tool_use_id ?? "?"}` });
    }
    // A run that dies on an API error (auth, quota) says so only here.
    if (evt.type === "result" && evt.is_error) return normalized("agent-error", { detail: `error=${safePreview(evt.result)}` });
    return null;
  },

  /** "" when absent: an empty report is a handled state. */
  finalText: (lines) => lastEvent(lines, "result")?.result ?? "",

  /**
   * A session can emit several `result` events (one per background-task wake-up): turns and time are
   * summed, cost (cumulative) is the last one's. No `result` (killed on timeout) is cost-unknown.
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
        // One message streams as several events sharing an id and usage.
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
