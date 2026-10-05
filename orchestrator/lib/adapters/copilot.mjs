/**
 * copilot adapter: `copilot -p <prompt> --output-format json`. The CLI allows the prompt only as
 * the `-p` argument, so it is the one platform whose prompt must go via argv.
 */
import { formatArgs, lastEvent, safePreview } from "./common.mjs";
import { ROLE_ARGS } from "./role-args.mjs";

export default {
  cmd: "copilot",
  defaultParallel: 2,
  defaultModel: undefined,
  promptVia: "argv",
  // No system-prompt flag: the protocol is prepended to the prompt.
  protocolVia: "prompt",
  requiredFlags: ["--allow-all-tools", "--output-format", "--add-dir"],

  /**
   * --allow-all-tools removes the confirmation prompt. --add-dir: the worker reads the issue and
   * writes its report under .scratch/ in the main checkout, outside its worktree cwd. `prompt` is
   * the full text (role protocol prepended: copilot has no system-prompt file). The json schema is
   * copilot-sdk's session-events.d.ts.
   */
  argv({ cwd, mainRoot, model, role, prompt }) {
    const args = ["-p", prompt, "-C", cwd, "--add-dir", mainRoot, "--allow-all-tools", "--no-color", "--output-format", "json"];
    if (model) args.push("--model", model);
    args.push(...this.roleArgs(role));
    return args;
  },

  roleArgs: (role) => ROLE_ARGS.copilot[role] ?? [],

  traceLine(evt, agent) {
    if (evt.type === "tool.execution_start") {
      return `[TOOL] agent=${agent} tool=${evt.data?.toolName ?? "?"} ${formatArgs(evt.data?.arguments)}`;
    }
    if (evt.type === "tool.execution_complete" && evt.data?.success === false) {
      return `[TOOL-ERROR] agent=${agent} toolCallId=${evt.data?.toolCallId ?? "?"} error=${safePreview(evt.data?.error?.message)}`;
    }
    if (evt.type === "session.error") {
      return `[AGENT-ERROR] agent=${agent} type=${evt.data?.errorType ?? "?"} error=${safePreview(evt.data?.message)}`;
    }
    return null;
  },

  /** The last `assistant.message` (copilot has no terminal event); "" when none. */
  finalText: (lines) => lastEvent(lines, "assistant.message")?.data?.content ?? "",
};
