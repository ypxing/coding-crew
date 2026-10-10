/**
 * copilot adapter: `copilot -p <prompt> --output-format json`. The CLI allows the prompt only as
 * the `-p` argument, so it is the one platform whose prompt must go via argv.
 */
import { lastEvent, normalized, safePreview, str } from "./common.mjs";

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

  /** `-i`: copilot's interactive mode, which runs the protocol as its first prompt. */
  interactive({ mainRoot, model, protocol, policy }) {
    const argv = ["copilot", "-i", protocol, "--add-dir", mainRoot];
    if (model && model !== "inherit") argv.push("--model", model);
    if (policy) argv.push(...this.policyArgs(policy));
    return argv;
  },

  /** The role's reasoning effort; read-only denies the write tool. */
  policyArgs: ({ readOnly, effort }) => [...(effort ? ["--reasoning-effort", effort] : []), ...(readOnly ? ["--deny-tool", "write"] : [])],

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
