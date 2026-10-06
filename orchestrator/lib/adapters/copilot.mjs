/**
 * copilot adapter: `copilot -p <prompt> --output-format json`. The CLI allows the prompt only as
 * the `-p` argument, so it is the one platform whose prompt must go via argv.
 */
import { lastEvent, normalized, safePreview, str } from "./common.mjs";
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

  /** A tool start, a failed tool, a `session.error`, or an `assistant.message`'s text. */
  normalize(evt) {
    const d = evt.data ?? {};
    if (evt.type === "tool.execution_start") {
      const args = d.arguments;
      return normalized("tool", {
        tool: d.toolName ?? "?",
        command: str(args?.command),
        path: str(args?.file_path ?? args?.path),
        args,
        id: str(d.toolCallId),
      });
    }
    if (evt.type === "tool.execution_complete" && d.success === false) {
      return normalized("tool-error", { id: str(d.toolCallId), detail: `toolCallId=${d.toolCallId ?? "?"} error=${safePreview(d.error?.message)}` });
    }
    if (evt.type === "session.error") return normalized("agent-error", { detail: `type=${d.errorType ?? "?"} error=${safePreview(d.message)}` });
    if (evt.type === "assistant.message" && str(d.content, true)) return normalized("text", { detail: d.content });
    return null;
  },

  /** The last `assistant.message` (copilot has no terminal event); "" when none. */
  finalText: (lines) => lastEvent(lines, "assistant.message")?.data?.content ?? "",
};
