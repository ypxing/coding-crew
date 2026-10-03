/**
 * pi adapter: `pi -p --mode json`. pi has no built-in subagent tool, so a dispatch is a separate
 * process with the role's protocol as `--append-system-prompt`. The event stream is pi's
 * docs/json.md.
 */
import { safePreview } from "./common.mjs";
import { ROLE_ARGS } from "./role-args.mjs";

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
