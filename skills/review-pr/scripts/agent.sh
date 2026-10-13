#!/usr/bin/env bash
# agent.sh — sourced: the one owner of the coding-agent axis (claude, copilot, pi, codex)
# for review-pr and solve-feature. Every decision that varies by agent — its name, argv, prompt form,
# stdin, model default and log shape — lives in a `case "$agent"` here; the callers hold no agent name
# but the one they pass through.
#   agent_known <agent>                                    exit 0 for an agent in AGENT_NAMES, else 1
#   agent_cmd <role:coder|reviewer> <agent> <model> <budget> <prompt> [<tag>]
#                                                          sets the array AGENT_ARGV and AGENT_STDIN_FILE;
#                                                          <tag> is the run's artifact prefix under
#                                                          .solve-feature/, which the caller has created
#                                                          and ignored (codex's prompt file is written as
#                                                          <tag>.<role>.codex-prompt.md there);
#                                                          returns 1 on an unknown agent or role (one stderr line)
#   agent_coder_prompt <agent> <ref>                       prints the coder's prompt
#   agent_model <agent> <role> [<default>]                 prints .coding-crew/config.json's
#                                                          afk.models.<agent>.<role>, else the default
#   agent_log_tail <agent> <log>                           prints the agent's final text from its JSON log
#                                                          (at most 20 lines), else the log's raw last 20 lines
# The caller runs `timeout <min>m "${AGENT_ARGV[@]}" <"$AGENT_STDIN_FILE"`. Budget is a claude-only knob.
# The pi and codex flags and log shapes are copied from orchestrator/lib/adapters/{pi,codex}.mjs, not
# imported: those adapters are shaped and versioned for crew-afk.

AGENT_ARGV=()
AGENT_STDIN_FILE=/dev/null

AGENT_NAMES=(claude copilot pi codex)

agent_known() {
  local a; for a in "${AGENT_NAMES[@]}"; do [ "$a" = "$1" ] && return 0; done; return 1
}

# The built-in defaults; a caller passing none to agent_model gets these. pi and codex have none: the
# CLI's own model runs when the config sets none.
agent_default_model() {
  case "$1:$2" in claude:coder) echo sonnet ;; claude:reviewer) echo opus ;; *) echo "" ;; esac
}

agent_model() {
  local agent="$1" role="$2" default="${3-}" cfg m
  [ -n "$default" ] || default=$(agent_default_model "$agent" "$role")
  cfg="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.coding-crew/config.json"
  m=$(jq -r --arg a "$agent" --arg r "$role" '.afk.models[$a][$r] // empty' "$cfg" 2>/dev/null || true)
  echo "${m:-$default}"
}

agent_coder_prompt() {
  case "$1" in
    claude) echo "/solve-issue $2" ;;
    # Names the skill in prose; whether these CLIs treat a leading /name as a skill call is unverified,
    # and the sentence works wherever the skill is installed.
    copilot|pi|codex) echo "Use the solve-issue skill on $2." ;;
    *) echo "agent.sh: unknown agent: $1" >&2; return 1 ;;
  esac
}

agent_cmd() {
  local role="$1" agent="$2" model="$3" budget="$4" prompt="$5" tag="${6-}" repo common
  case "$role" in coder|reviewer) ;; *) echo "agent.sh: unknown role: $role" >&2; return 1 ;; esac
  AGENT_STDIN_FILE=/dev/null
  case "$agent" in
    claude)
      [ -n "$model" ] || model=$(agent_default_model claude "$role")
      # Unattended `claude -p` denies what it would prompt for, and an allow-list, `auto` mode and the
      # sandbox refuse solve-issue's compound commands: bypass. The reviewer stays read-only by --tools.
      AGENT_ARGV=(claude -p "$prompt" --output-format json --max-budget-usd "$budget" --model "$model" --permission-mode bypassPermissions)
      [ "$role" != reviewer ] || AGENT_ARGV+=(--tools Bash Read ToolSearch --settings '{"disableClaudeAiConnectors":true,"disableBundledSkills":true}')
      ;;
    copilot)
      AGENT_ARGV=(copilot -p "$prompt" --allow-all-tools --no-color --output-format json)
      [ -z "$model" ] || AGENT_ARGV+=(--model "$model")
      [ "$role" != reviewer ] || AGENT_ARGV+=(--deny-tool write)
      ;;
    pi)
      AGENT_ARGV=(pi -p --mode json)
      [ -z "$model" ] || AGENT_ARGV+=(--model "$model")
      if [ "$role" = reviewer ]; then AGENT_ARGV+=(--tools read,bash); else AGENT_ARGV+=(--tools read,bash,edit,write); fi
      AGENT_ARGV+=("$prompt")
      ;;
    codex)
      # codex has no prompt flag: the prompt goes on stdin from a file, which also leaves it inspectable
      # beside the run's other .solve-feature/ artifacts, keyed like them so runs do not overwrite each other's.
      repo="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
      AGENT_STDIN_FILE="$repo/.solve-feature/${tag:+$tag.}$role.codex-prompt.md"
      if [ "$role" = reviewer ]; then
        # codex's read-only sandbox cannot write the report: workspace-write with .solve-feature as the
        # one writable root keeps the tree read-only; review-pr's HEAD/tree assertion is the second check.
        AGENT_ARGV=(codex exec --cd "$repo/.solve-feature" --sandbox workspace-write -c sandbox_workspace_write.exclude_slash_tmp=true -c sandbox_workspace_write.exclude_tmpdir_env_var=true --json)
        prompt="Your shell starts in $repo/.solve-feature, the only writable directory, where your report goes. The repository is $repo: run your commands there (cd $repo && ...)."$'\n\n'"$prompt"
      else
        AGENT_ARGV=(codex exec --cd "$repo" --sandbox workspace-write -c sandbox_workspace_write.network_access=true)
        # The sandbox keeps the top-level .git of every writable root read-only, so the git dir is a root of
        # its own or the coder cannot commit; in a linked worktree that is the main repo's git dir, which
        # holds the worktree's index too. The main checkout is added where the local tracker's close writes,
        # by the tracker's own rule (tracker/cli.mjs defaultMainRoot): a common dir named .git, outside the repo.
        common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
        [ -z "$common" ] || AGENT_ARGV+=(-c "sandbox_workspace_write.writable_roots=$(jq -cn --arg p "$common" '[$p]')")
        [ "$(basename "$common")" != .git ] || [ "$(dirname "$common")" = "$repo" ] || AGENT_ARGV+=(--add-dir "$(dirname "$common")")
        AGENT_ARGV+=(--json)
      fi
      [ -z "$model" ] || AGENT_ARGV+=(--model "$model")
      AGENT_ARGV+=(-)
      printf '%s\n' "$prompt" >"$AGENT_STDIN_FILE"
      ;;
    *) echo "agent.sh: unknown agent: $agent" >&2; return 1 ;;
  esac
}

agent_log_tail() {
  local agent="$1" log="$2" t=""
  case "$agent" in
    claude) t=$(jq -rR 'fromjson? | objects | .result // empty' "$log" 2>/dev/null | tail -n 20 || true) ;;
    copilot) t=$(jq -cR 'fromjson? | objects | select(.type == "assistant.message") | .data.content // empty' "$log" 2>/dev/null | tail -n 1 | jq -r '.' 2>/dev/null | tail -n 20 || true) ;;
    pi) t=$(jq -cR 'fromjson? | objects | select(.type == "message_end" and .message.role == "assistant") | [.message.content[]? | select(.type == "text") | .text // empty] | join("")' "$log" 2>/dev/null | tail -n 1 | jq -r '.' 2>/dev/null | tail -n 20 || true) ;;
    codex) t=$(jq -cR 'fromjson? | objects | select(.type == "item.completed" and .item.type == "agent_message") | .item.text // empty' "$log" 2>/dev/null | tail -n 1 | jq -r '.' 2>/dev/null | tail -n 20 || true) ;;
  esac
  printf '%s' "${t:-$(tail -n 20 "$log" 2>/dev/null)}"
}
