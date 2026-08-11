#!/usr/bin/env bash
# dispatch-agent.sh — run a crew agent as an isolated pi subprocess.
#
# pi has no built-in subagent tool, so a "subagent" here is a separate `pi -p`
# process: fresh context window, its own tool loop, its own working directory.
# The agent definition (.pi/agents/<name>.md) supplies the system prompt, tool
# allowlist, and default model; this script wires them onto the pi CLI.
#
# Usage:
#   dispatch-agent.sh --agent crew-coder --dir <worktree> --prompt-file <file> \
#                     [--log <file>] [--model <alias|inherit>] [--out <file>]
#
# Exit code is pi's exit code. The agent's final message goes to stdout and, when
# --out is given, to that file as well.
set -uo pipefail

AGENT=""
DIR=""
PROMPT_FILE=""
LOG=""
MODEL=""
OUT=""

die() { echo "dispatch-agent: $*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent) AGENT="${2:-}"; shift 2 ;;
    --dir) DIR="${2:-}"; shift 2 ;;
    --prompt-file) PROMPT_FILE="${2:-}"; shift 2 ;;
    --log) LOG="${2:-}"; shift 2 ;;
    --model) MODEL="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$AGENT" ]] || die "--agent is required"
[[ -n "$DIR" ]] || die "--dir is required"
[[ -n "$PROMPT_FILE" ]] || die "--prompt-file is required"
[[ -d "$DIR" ]] || die "working directory does not exist: $DIR"
[[ -f "$PROMPT_FILE" ]] || die "prompt file does not exist: $PROMPT_FILE"
command -v pi >/dev/null 2>&1 || die "pi CLI not found on PATH"

MAIN_ROOT="${MAIN_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# Agent definitions: project-level first, then user-level.
AGENT_FILE=""
for candidate in \
  "$MAIN_ROOT/.pi/agents/$AGENT.md" \
  "$HOME/.pi/agent/agents/$AGENT.md" \
  "$HOME/.pi/agents/$AGENT.md"; do
  if [[ -f "$candidate" ]]; then AGENT_FILE="$candidate"; break; fi
done
[[ -n "$AGENT_FILE" ]] || die "agent definition not found for '$AGENT' (looked in .pi/agents and ~/.pi/agent/agents)"

# Split the agent file into frontmatter and body without needing yq/python.
frontmatter_value() {
  local key="$1"
  awk -v key="$key" '
    NR == 1 && $0 == "---" { inside = 1; next }
    inside && $0 == "---" { exit }
    inside {
      if (index($0, key ":") == 1) {
        value = substr($0, length(key) + 2)
        gsub(/^[ \t]+|[ \t]+$/, "", value)
        print value
        exit
      }
    }
  ' "$AGENT_FILE"
}

SYSTEM_PROMPT=$(awk '
  NR == 1 && $0 == "---" { inside = 1; next }
  NR == 1 { body = 1 }
  inside && $0 == "---" { inside = 0; body = 1; next }
  body { print }
' "$AGENT_FILE")
# Regex match, not ${v//[[:space:]]/}: pattern substitution over a multi-KB string is
# O(n^2) in bash 3.2 (macOS system bash), which cost ~40s of dead CPU per dispatch.
[[ "$SYSTEM_PROMPT" =~ [^[:space:]] ]] || die "agent definition has an empty body: $AGENT_FILE"

AGENT_TOOLS=$(frontmatter_value tools)
AGENT_MODEL=$(frontmatter_value model)

# Preflight the allowlist. pi silently ignores names it does not recognise, so a tool
# list copied from another platform's agent file (Claude's Grep/Glob/LS, for example)
# degrades quietly into a smaller-than-intended toolset. Warn loudly instead.
PI_KNOWN_TOOLS="read bash edit write web_search fetch_content get_search_content source_check mcp mcpScript"
if [[ -n "$AGENT_TOOLS" ]]; then
  for _t in $(printf '%s' "$AGENT_TOOLS" | tr -d '[]"' | tr ',' ' '); do
    case " $PI_KNOWN_TOOLS " in
      *" $_t "*) ;;
      *) echo "dispatch-agent: warning: '$_t' is unknown to the pi CLI (not a pi tool) — check tools: in $AGENT_FILE" >&2 ;;
    esac
  done
fi

# --model inherit means "whatever the orchestrator session uses" — pass nothing.
EFFECTIVE_MODEL=""
if [[ -n "$MODEL" && "$MODEL" != "inherit" ]]; then
  EFFECTIVE_MODEL="$MODEL"
elif [[ -z "$MODEL" ]]; then
  EFFECTIVE_MODEL="$AGENT_MODEL"
fi

PROMPT_LABEL=$(basename "$PROMPT_FILE" .md)
PROMPT_LABEL="${PROMPT_LABEL%.prompt}"
ARGS=(-p -n "$AGENT: $PROMPT_LABEL")
[[ -n "$EFFECTIVE_MODEL" ]] && ARGS+=(--model "$EFFECTIVE_MODEL")
if [[ -n "$AGENT_TOOLS" ]]; then
  # tools: read, bash, edit  ->  read,bash,edit
  ARGS+=(--tools "$(printf '%s' "$AGENT_TOOLS" | tr -d '[]"' | tr -d ' ')")
fi
ARGS+=(--append-system-prompt "$SYSTEM_PROMPT")

if [[ -n "$LOG" ]]; then
  mkdir -p "$(dirname "$LOG")"
  echo "[$(date -u +%H:%M:%SZ)] [DISPATCH] agent=$AGENT dir=$DIR model=${EFFECTIVE_MODEL:-inherit}" >> "$LOG"
fi

# MAIN_ROOT is exported so the agent's own environment setup can read it. The agent
# runs with the worktree as cwd, which is what its PROJECT_ROOT check expects.
if [[ -n "$OUT" ]]; then
  mkdir -p "$(dirname "$OUT")"
  (cd "$DIR" && MAIN_ROOT="$MAIN_ROOT" CREW_ORCHESTRATED=1 pi "${ARGS[@]}" "$(cat "$PROMPT_FILE")") 2>>"${LOG:-/dev/null}" | tee "$OUT"
  status=${PIPESTATUS[0]}
else
  (cd "$DIR" && MAIN_ROOT="$MAIN_ROOT" CREW_ORCHESTRATED=1 pi "${ARGS[@]}" "$(cat "$PROMPT_FILE")") 2>>"${LOG:-/dev/null}"
  status=$?
fi

if [[ -n "$LOG" ]]; then
  echo "[$(date -u +%H:%M:%SZ)] [DISPATCH-END] agent=$AGENT exit=$status" >> "$LOG"
fi

exit "$status"
