/** copilot adapter: `copilot -p <prompt> --output-format json`; the CLI takes the prompt only via argv. */
import { lastEvent, normalized, safePreview, str } from "./common.mjs";

export default {
  cmd: "copilot",
  defaultParallel: 2,
  defaultModel: undefined,
  coAuthor: "Co-authored-by: GitHub Copilot <noreply@github.com>",
  requiredFlags: ["--allow-all-tools", "--output-format", "--add-dir"],

  /**
   * --add-dir: the worker writes its report under .scratch/ in the main checkout, outside its cwd.
   * copilot has no system-prompt flag, so the protocol is prepended to the prompt.
   */
  build({ cwd, mainRoot, model, policy, protocol, prompt }) {
    const text = protocol ? `${protocol}\n\n---\n\n${prompt}` : prompt;
    const args = ["-p", text, "-C", cwd, "--add-dir", mainRoot, "--allow-all-tools", "--no-color", "--output-format", "json"];
    if (model) args.push("--model", model);
    if (policy) args.push(...this.policyArgs(policy));
    return { args };
  },

  /** Permission prompts stay on for the human in the pane. */
  interactive({ mainRoot, model, protocol, policy }) {
    const argv = ["copilot", "-i", protocol, "--add-dir", mainRoot];
    if (model && model !== "inherit") argv.push("--model", model);
    if (policy) argv.push(...this.policyArgs(policy));
    return argv;
  },

  policyArgs: ({ readOnly, effort }) => [...(effort ? ["--reasoning-effort", effort] : []), ...(readOnly ? ["--deny-tool", "write"] : [])],

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

  /** copilot has no terminal event. */
  finalText: (lines) => lastEvent(lines, "assistant.message")?.data?.content ?? "",
};
