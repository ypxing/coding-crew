/**
 * pi adapter: `pi -p --mode json`. pi has no built-in subagent tool, so a dispatch is a separate
 * process with the role's protocol as `--append-system-prompt`. The event stream is pi's
 * docs/json.md.
 */
import { normalized, safePreview, str } from "./common.mjs";
import { ROLE_ARGS } from "./role-args.mjs";

const FILE_TOOLS = ["read", "write", "edit"];

/** An assistant message's text blocks, joined; "" when none. */
const textOf = (message) => (message?.content ?? []).filter((b) => b?.type === "text").map((b) => b.text).join("");

export default {
  cmd: "pi",
  defaultParallel: 3,
  defaultModel: undefined,
  promptVia: "argv",
  requiredFlags: ["--mode", "--append-system-prompt"],

  /** The prompt is pi's positional argument; `protocol` is the role's rendered protocol (none for a plain role). */
  argv({ model, role, protocol, prompt, label }) {
    const args = ["-p", "-n", label, "--mode", "json"];
    if (model && model !== "inherit") args.push("--model", model);
    args.push(...this.roleArgs(role));
    if (protocol) args.push("--append-system-prompt", protocol);
    args.push(prompt);
    return args;
  },

  roleArgs: (role) => ROLE_ARGS.pi[role] ?? [],

  /**
   * A tool start (bash's command, read/write/edit's path), a failed tool, or an assistant
   * `message_end`: its text, or the error it stopped on.
   */
  normalize(evt) {
    if (evt.type === "tool_execution_start") {
      const tool = evt.toolName ?? "?";
      return normalized("tool", {
        tool,
        command: tool === "bash" ? str(evt.args?.command, true) : undefined,
        path: FILE_TOOLS.includes(tool) ? str(evt.args?.path ?? evt.args?.file_path, true) : undefined,
        args: evt.args,
        id: str(evt.toolCallId),
      });
    }
    if (evt.type === "tool_execution_end" && evt.isError === true) return normalized("tool-error", { tool: evt.toolName ?? "?", id: str(evt.toolCallId) });
    if (evt.type === "message_end" && evt.message?.role === "assistant") {
      if (evt.message.stopReason === "error") return normalized("agent-error", { detail: `error=${safePreview(evt.message.errorMessage)}` });
      const text = textOf(evt.message);
      return text ? normalized("text", { detail: text }) : null;
    }
    return null;
  },

  /** The last assistant `message_end`'s text blocks, joined; "" when none. */
  finalText(lines) {
    let last = null;
    for (const line of lines) {
      try {
        const evt = JSON.parse(line);
        if (evt.type === "message_end" && evt.message?.role === "assistant") last = evt;
      } catch {
        /* skip an unparseable line */
      }
    }
    return textOf(last?.message);
  },
};
