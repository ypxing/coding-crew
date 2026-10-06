/**
 * codex adapter: `codex exec --json`. codex has no system-prompt flag, so the role's protocol is
 * prepended to the prompt, which codex reads from stdin (`-`): no argv size limit applies. The sandbox is per role, and the
 * writable roots a worktree's git needs are named explicitly.
 */
import { spawnSync } from "node:child_process";
import { mkdirSync, realpathSync } from "node:fs";
import { dirname, isAbsolute } from "node:path";
import { normalized, safePreview, str } from "./common.mjs";
import { CODEX_SANDBOX, ROLE_ARGS } from "./role-args.mjs";

/** `git rev-parse --path-format=absolute <flag>` in `dir`, or "" — made absolute against `dir` if git gave a relative one. */
function gitPath(dir, flag) {
  const r = spawnSync("git", ["rev-parse", "--path-format=absolute", flag], { cwd: dir, encoding: "utf8" });
  const p = r.status === 0 ? r.stdout.trim() : "";
  if (!p) return "";
  return isAbsolute(p) || /^[A-Za-z]:/.test(p) ? p : `${dir}/${p}`;
}

/** A role's sandbox; a plain role (no protocol: command finder, PR writer) only reads. */
function sandboxFor(role) {
  if (!role) return "read-only";
  return CODEX_SANDBOX[role] || process.env.CREW_CODEX_SANDBOX || "workspace-write";
}

/** A tool item's name: `shell` for a command, else codex's item type (file_change, mcp_tool_call, …). */
const toolOf = (item) => (item?.type === "command_execution" ? "shell" : (item?.type ?? "?"));

export default {
  cmd: "codex",
  defaultParallel: 3,
  defaultModel: undefined,
  promptVia: "stdin",
  // The flags live on the `exec` subcommand.
  helpArgs: ["exec", "--help"],
  requiredFlags: ["--sandbox", "--json", "--cd"],
  // `-o` writes the final message to the dispatch's outFile; the stream is the fallback.
  lastMessageFile: true,

  /**
   * A read-only role (reviewer, triage) must still write its result file, which codex's read-only
   * sandbox forbids: it runs workspace-write with the result file's directory as its one writable
   * root, and the prompt says where the repository is. Otherwise: network on (dep-install), the
   * git dirs writable (a linked worktree's index lives in the main repo's git dir), the main
   * checkout added (traces, prompts and reports live under .scratch).
   */
  argv({ cwd, mainRoot, model, role, outFile }) {
    let sandbox = sandboxFor(role);
    let resultDir = null;
    if (sandbox === "read-only" && outFile) {
      mkdirSync(dirname(outFile), { recursive: true });
      resultDir = realpathSync(dirname(outFile));
      sandbox = "workspace-write";
    }
    const args = ["exec", "--cd", resultDir ?? cwd, "--sandbox", sandbox, "--json"];
    if (resultDir) args.push("-c", "sandbox_workspace_write.exclude_slash_tmp=true", "-c", "sandbox_workspace_write.exclude_tmpdir_env_var=true");
    if (sandbox === "workspace-write" && !resultDir) {
      args.push("-c", "sandbox_workspace_write.network_access=true");
      const common = gitPath(cwd, "--git-common-dir");
      const own = gitPath(cwd, "--git-dir");
      if (common) {
        const roots = [common, ...(own && own !== common ? [own] : [])].map((p) => JSON.stringify(p));
        args.push("-c", `sandbox_workspace_write.writable_roots=[${roots.join(",")}]`);
      }
      if (mainRoot !== cwd) args.push("--add-dir", mainRoot);
    }
    if (model && model !== "inherit") args.push("--model", model);
    args.push(...this.roleArgs(role));
    if (outFile) args.push("--output-last-message", outFile);
    args.push("-");
    return args;
  },

  /** What codex reads on stdin: the protocol, then the task. */
  stdin({ cwd, role, protocol, prompt, outFile }) {
    const readOnly = sandboxFor(role) === "read-only" && outFile;
    const task = readOnly
      ? `Your shell starts in ${realpathSync(dirname(outFile))}, the only writable directory, where your result file goes. The repository is ${cwd}: run your commands there (\`cd ${cwd} && ...\`).\n\n${prompt}`
      : prompt;
    return protocol ? `${protocol}\n\n---\n\n# Task\n\n${task}` : task;
  },

  roleArgs: (role) => ROLE_ARGS.codex[role] ?? [],

  /**
   * An item's start (its command or path), a command that completed with a non-zero exit, a
   * completed `agent_message`'s text, or a `turn.failed` / `error`. One command is reported at
   * its start and its end under the same item id.
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
      return normalized("agent-error", { detail: `type=${evt.type}${message != null ? ` error=${safePreview(message)}` : ""}` });
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
