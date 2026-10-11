/** pi adapter: `pi -p --mode json`, the role's protocol as `--append-system-prompt`. */
import { normalized, safePreview, str } from "./common.mjs";

const FILE_TOOLS = ["read", "write", "edit"];

const textOf = (message) => (message?.content ?? []).filter((b) => b?.type === "text").map((b) => b.text).join("");

export default {
  cmd: "pi",
  defaultParallel: 3,
  defaultModel: undefined,
  coAuthor: "Co-authored-by: pi <noreply@earendil.works>",
  requiredFlags: ["--mode", "--append-system-prompt"],

  build({ model, policy, protocol, prompt, label }) {
    const args = ["-p", "-n", label, "--mode", "json"];
    if (model && model !== "inherit") args.push("--model", model);
    if (policy) args.push(...this.policyArgs(policy));
    if (protocol) args.push("--append-system-prompt", protocol);
    args.push(prompt);
    return { args };
  },

  interactive({ model, protocol, policy }) {
    const argv = ["pi"];
    if (model && model !== "inherit") argv.push("--model", model);
    if (policy) argv.push(...this.policyArgs(policy));
    argv.push(protocol);
    return argv;
  },

  // pi ignores tool names it does not know, so the allowlist uses pi's own.
  policyArgs: ({ readOnly, effort }) => [...(effort ? ["--thinking", effort] : []), "--tools", readOnly ? "read,bash" : "read,bash,edit,write"],

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
