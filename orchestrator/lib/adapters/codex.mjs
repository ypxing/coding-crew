/**
 * codex adapter: `codex exec --json`. codex has no system-prompt flag, so the role's protocol is
 * prepended to the prompt, which codex reads from stdin (`-`): no argv size limit applies. The sandbox follows the role's
 * policy, and the writable roots a worktree's git needs are named explicitly.
 */
import { spawnSync } from "node:child_process";
import { mkdirSync, realpathSync } from "node:fs";
import { dirname, isAbsolute } from "node:path";
import { normalized, safePreview, str } from "./common.mjs";

/** `git rev-parse --path-format=absolute <flag>` in `dir`, or "" — made absolute against `dir` if git gave a relative one. */
function gitPath(dir, flag) {
  const r = spawnSync("git", ["rev-parse", "--path-format=absolute", flag], { cwd: dir, encoding: "utf8" });
  const p = r.status === 0 ? r.stdout.trim() : "";
  if (!p) return "";
  return isAbsolute(p) || /^[A-Za-z]:/.test(p) ? p : `${dir}/${p}`;
}

/** A role's sandbox; a plain role (no protocol, so no policy: command finder, PR writer) only reads. */
function sandboxFor(policy) {
  return !policy || policy.readOnly ? "read-only" : "workspace-write";
}

/**
 * What a workspace-write run needs beyond the sandbox itself: network on (dep-install), the git
 * dirs writable (a linked worktree's index lives in the main repo's git dir), the main checkout
 * added (traces, prompts and reports live under .scratch). Shared by build() and an unattended
 * interactive() run.
 */
function workspaceWriteArgs(cwd, mainRoot) {
  const args = ["-c", "sandbox_workspace_write.network_access=true"];
  const common = gitPath(cwd, "--git-common-dir");
  const own = gitPath(cwd, "--git-dir");
  if (common) {
    const roots = [common, ...(own && own !== common ? [own] : [])].map((p) => JSON.stringify(p));
    args.push("-c", `sandbox_workspace_write.writable_roots=[${roots.join(",")}]`);
  }
  if (mainRoot !== cwd) args.push("--add-dir", mainRoot);
  return args;
}

/** A tool item's name: `shell` for a command, else codex's item type (file_change, mcp_tool_call, …). */
const toolOf = (item) => (item?.type === "command_execution" ? "shell" : (item?.type ?? "?"));

export default {
  cmd: "codex",
  defaultParallel: 3,
  defaultModel: undefined,
  coAuthor: "Co-authored-by: Codex <noreply@openai.com>",
  // The flags live on the `exec` subcommand.
  helpArgs: ["exec", "--help"],
  requiredFlags: ["--sandbox", "--json", "--cd"],

  /**
   * A read-only role (reviewer, triage) must still write its result file, which codex's read-only
   * sandbox forbids: it runs workspace-write with the result file's directory as its one writable
   * root, and the prompt says where the repository is. Otherwise: network on (dep-install), the
   * git dirs writable (a linked worktree's index lives in the main repo's git dir), the main
   * checkout added (traces, prompts and reports live under .scratch). codex has no system-prompt
   * flag, so it reads the protocol, then the task, from stdin (`-`): no argv size limit applies.
   */
  build({ cwd, mainRoot, model, policy, protocol, prompt, outFile }) {
    let sandbox = sandboxFor(policy);
    let resultDir = null;
    if (sandbox === "read-only" && outFile) {
      mkdirSync(dirname(outFile), { recursive: true });
      resultDir = realpathSync(dirname(outFile));
      sandbox = "workspace-write";
    }
    const args = ["exec", "--cd", resultDir ?? cwd, "--sandbox", sandbox, "--json"];
    if (resultDir) args.push("-c", "sandbox_workspace_write.exclude_slash_tmp=true", "-c", "sandbox_workspace_write.exclude_tmpdir_env_var=true");
    if (sandbox === "workspace-write" && !resultDir) args.push(...workspaceWriteArgs(cwd, mainRoot));
    if (model && model !== "inherit") args.push("--model", model);
    if (policy) args.push(...this.policyArgs(policy));
    args.push("-");
    const task = resultDir
      ? `Your shell starts in ${resultDir}, the only writable directory, where your result file goes. The repository is ${cwd}: run your commands there (\`cd ${cwd} && ...\`).\n\n${prompt}`
      : prompt;
    return { args, input: protocol ? `${protocol}\n\n---\n\n# Task\n\n${task}` : task };
  },

  // The sandbox is set by build(); the flag here is the role's reasoning effort (none: codex's default).
  policyArgs: ({ effort }) => (effort ? ["-c", `model_reasoning_effort="${effort}"`] : []),

  /**
   * The TUI with the protocol as its initial prompt (the last argument), in the role's sandbox. An
   * `unattended` role that may write (a follow-up worker) gets build()'s network and git dirs, and
   * never asks for approval: nobody is at its terminal.
   */
  interactive({ cwd, mainRoot, model, protocol, policy }) {
    const sandbox = sandboxFor(policy);
    const argv = ["codex", "--cd", cwd, "--sandbox", sandbox];
    if (policy?.unattended && sandbox === "workspace-write") argv.push(...workspaceWriteArgs(cwd, mainRoot), "--ask-for-approval", "never");
    if (model && model !== "inherit") argv.push("--model", model);
    if (policy) argv.push(...this.policyArgs(policy));
    argv.push(protocol);
    return argv;
  },

  /**
   * An item's start (its command or path), a command that completed with a non-zero exit, a
   * completed `agent_message`'s text, or a `turn.failed` / `error` — a tool-error, not an
   * agent-error: codex also sends `error` for a stream it retries, so these stay warn-level
   * `[TOOL-ERROR]` lines as they always were. One command is reported at its start and its end
   * under the same item id.
   */
  normalize(evt) {
    const item = evt.item;
    if (evt.type === "item.started") {
      if (item?.type === "agent_message" || item?.type === "reasoning") return null;
      return normalized("tool", {
        tool: toolOf(item),
        command: item?.type === "command_execution" ? str(item.command, true) : undefined,
        path: item?.type === "file_change" ? str(item.path ?? item.file, true) : undefined,
        args: item,
        id: str(item?.id),
      });
    }
    if (evt.type === "item.completed") {
      if (item?.type === "agent_message") return str(item.text, true) ? normalized("text", { detail: item.text }) : null;
      const code = item?.exit_code;
      if (code == null || String(code) === "0") return null;
      return normalized("tool-error", { tool: toolOf(item), command: str(item?.command, true), id: str(item?.id), detail: `exit=${code}` });
    }
    if (evt.type === "turn.failed" || evt.type === "error") {
      const message = evt.error?.message ?? evt.message;
      return normalized("tool-error", { detail: `type=${evt.type}${message != null ? ` error=${safePreview(message)}` : ""}` });
    }
    return null;
  },

  /** The last completed `agent_message` item's text; "" when none. */
  finalText(lines) {
    let text = "";
    for (const line of lines) {
      try {
        const evt = JSON.parse(line);
        if (evt.type === "item.completed" && evt.item?.type === "agent_message" && typeof evt.item.text === "string") text = evt.item.text;
      } catch {
        /* skip an unparseable line */
      }
    }
    return text;
  },
};
