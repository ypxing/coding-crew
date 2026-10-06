/**
 * pi adapter: `pi -p --mode json`. pi has no built-in subagent tool, so a dispatch is a separate
 * process with the role's protocol as `--append-system-prompt`. The event stream is pi's
 * docs/json.md.
 */
import { safePreview } from "./common.mjs";

/** `$ <command>` for bash, a path for read/write/edit; null for any other tool (a JSON preview instead). */
function summarize(tool, args) {
  if (tool === "bash" && typeof args?.command === "string" && args.command) return `$ ${args.command}`;
  if (["read", "write", "edit"].includes(tool)) {
    const path = args?.path ?? args?.file_path;
    if (typeof path === "string" && path) return path;
  }
  return null;
}

export default {
  cmd: "pi",
  defaultParallel: 3,
  defaultModel: undefined,
  coAuthor: "Co-authored-by: pi <noreply@earendil.works>",
  requiredFlags: ["--mode", "--append-system-prompt"],

  /** The prompt is pi's positional argument; the role's protocol goes in as `--append-system-prompt`. */
  build({ model, policy, protocol, prompt, label }) {
    const args = ["-p", "-n", label, "--mode", "json"];
    if (model && model !== "inherit") args.push("--model", model);
    if (policy) args.push(...this.policyArgs(policy));
    if (protocol) args.push("--append-system-prompt", protocol);
    args.push(prompt);
    return { args };
  },

  // pi names an allowlist; it ignores tool names it does not know, so these are pi's own.
  policyArgs: ({ readOnly }) => ["--tools", readOnly ? "read,bash" : "read,bash,edit,write"],

  traceLine(evt, agent) {
    if (evt.type === "tool_execution_start") {
      const tool = evt.toolName ?? "?";
      return `[TOOL] agent=${agent} tool=${tool} ${summarize(tool, evt.args) ?? `args=${safePreview(evt.args)}`}`;
    }
    if (evt.type === "tool_execution_end" && evt.isError === true) return `[TOOL-ERROR] agent=${agent} tool=${evt.toolName ?? "?"}`;
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
    return (last?.message?.content ?? []).filter((b) => b?.type === "text").map((b) => b.text).join("");
  },
};
