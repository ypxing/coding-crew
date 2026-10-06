/**
 * copilot adapter: `copilot -p <prompt> --output-format json`. The CLI allows the prompt only as
 * the `-p` argument, so it is the one platform whose prompt must go via argv.
 */
import { formatArgs, lastEvent, safePreview } from "./common.mjs";

export default {
  cmd: "copilot",
  defaultParallel: 2,
  defaultModel: undefined,
  coAuthor: "Co-authored-by: GitHub Copilot <noreply@github.com>",
  requiredFlags: ["--allow-all-tools", "--output-format", "--add-dir"],

  /**
   * --allow-all-tools removes the confirmation prompt. --add-dir: the worker reads the issue and
   * writes its report under .scratch/ in the main checkout, outside its worktree cwd. copilot has
   * no system-prompt flag, so the role's protocol is prepended to the prompt. The json schema is
   * copilot-sdk's session-events.d.ts.
   */
  build({ cwd, mainRoot, model, policy, protocol, prompt }) {
    const text = protocol ? `${protocol}\n\n---\n\n${prompt}` : prompt;
    const args = ["-p", text, "-C", cwd, "--add-dir", mainRoot, "--allow-all-tools", "--no-color", "--output-format", "json"];
    if (model) args.push("--model", model);
    if (policy) args.push(...this.policyArgs(policy));
    return { args };
  },

  policyArgs: ({ readOnly }) => (readOnly ? ["--deny-tool", "write"] : []),

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
