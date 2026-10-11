/** codex adapter: `codex exec --json`, with the protocol prepended to a prompt read from stdin. */
import { spawnSync } from "node:child_process";
import { mkdirSync, realpathSync } from "node:fs";
import { dirname, isAbsolute } from "node:path";
import { normalized, safePreview, str } from "./common.mjs";

/** Made absolute against `dir` if git gave a relative path. */
function gitPath(dir, flag) {
  const r = spawnSync("git", ["rev-parse", "--path-format=absolute", flag], { cwd: dir, encoding: "utf8" });
  const p = r.status === 0 ? r.stdout.trim() : "";
  if (!p) return "";
  return isAbsolute(p) || /^[A-Za-z]:/.test(p) ? p : `${dir}/${p}`;
}

/** A plain role (no protocol, so no policy) only reads. */
function sandboxFor(policy) {
  return !policy || policy.readOnly ? "read-only" : "workspace-write";
}

/**
 * Network on (dep-install), the git dirs writable (a linked worktree's index lives in the main
 * repo's git dir), the main checkout added (.scratch holds traces, prompts and reports).
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

const toolOf = (item) => (item?.type === "command_execution" ? "shell" : (item?.type ?? "?"));

export default {
  cmd: "codex",
  defaultParallel: 3,
  defaultModel: undefined,
  coAuthor: "Co-authored-by: Codex <noreply@openai.com>",
  helpArgs: ["exec", "--help"],
  requiredFlags: ["--sandbox", "--json", "--cd"],

  /**
   * A read-only role must still write its result file, which codex's read-only sandbox forbids: it
   * runs workspace-write with that file's directory as its one writable root. codex has no
   * system-prompt flag, so stdin (`-`) carries protocol then task, with no argv size limit.
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

  // The sandbox is set by build().
  policyArgs: ({ effort }) => (effort ? ["-c", `model_reasoning_effort="${effort}"`] : []),

  /** Approval prompts stay on for the human in the pane. */
  interactive({ cwd, mainRoot, model, protocol, policy }) {
    const sandbox = sandboxFor(policy);
    const argv = ["codex", "--cd", cwd, "--sandbox", sandbox];
    if (sandbox === "workspace-write") argv.push(...workspaceWriteArgs(cwd, mainRoot));
    if (model && model !== "inherit") argv.push("--model", model);
    if (policy) argv.push(...this.policyArgs(policy));
    argv.push(protocol);
    return argv;
  },

  /** `turn.failed` / `error` stay tool-errors, not agent-errors: codex also sends `error` for a stream it retries. */
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
