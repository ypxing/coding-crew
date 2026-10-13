#!/usr/bin/env bash
# agent.sh — sourced, no side effects: the one owner of the coding-agent axis (claude, copilot) for
# review-pr and solve-feature. Every decision that varies by agent lives in one `case "$agent"` here.
#   agent_cmd <role:coder|reviewer> <agent> <model> <budget> <prompt>  sets the array AGENT_ARGV; returns 1 on
#                                                                        an unknown agent or role (one stderr line)
#   agent_coder_prompt <agent> <ref>                                   prints the coder's prompt
#   agent_model <agent> <role> [<default>]                             prints .coding-crew/config.json's
#                                                                        afk.models.<agent>.<role>, else the default
# The caller wraps AGENT_ARGV in `timeout <min>m` and redirects </dev/null. Budget is a claude-only knob.

AGENT_ARGV=()

# The built-in defaults; a caller passing none to agent_model gets these.
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
    # Names the skill in prose; whether copilot treats a leading /name as a skill call is unverified.
    copilot) echo "Use the solve-issue skill on $2." ;;
    *) echo "agent.sh: unknown agent: $1" >&2; return 1 ;;
  esac
}

agent_cmd() {
  local role="$1" agent="$2" model="$3" budget="$4" prompt="$5"
  case "$role" in coder|reviewer) ;; *) echo "agent.sh: unknown role: $role" >&2; return 1 ;; esac
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
    *) echo "agent.sh: unknown agent: $agent" >&2; return 1 ;;
  esac
}
