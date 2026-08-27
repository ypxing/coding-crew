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
#
# Visibility: the run goes through `pi --mode json` (docs/json.md), which streams
# tool_execution_start/end and message events as NDJSON as they happen, instead of
# pi -p's default of printing nothing until the whole turn is done. trace_event reads
# that stream one line at a time and appends a `[TOOL]`/`[TOOL-ERROR]` line to --log as
# each tool call starts/fails, so `tail -f` on the sprint's trace log shows what a
# worker is doing *while* it runs, not just a `[DISPATCH]` line followed by silence
# until it exits or times out. The full event stream is also kept next to --out, as
# `<out>.events.jsonl`, for post-hoc debugging; only the final assistant text — the one
# thing report.mjs actually parses — is extracted into --out itself.
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
# Read the prompt now, not at invocation time. This used to be a plain [[ -f ]] preflight
# followed, many lines and several subprocesses later (agent-file parsing, tool-list
# validation, mkdir), by `pi ... "$(cat "$PROMPT_FILE")"` at the bottom of the script. That
# gap between "the file exists" and "the file is actually read" is a TOCTOU window: on a
# real sprint the file was gone by the time cat ran, cat failed, the command substitution
# silently produced an empty string, and pi was dispatched with essentially no prompt —
# exiting 0 having done nothing, which then read as an empty report rather than a dispatch
# failure. Reading into a variable right next to the existence check closes that window,
# and a failed or empty read now aborts the dispatch instead of silently degrading it.
[[ -f "$PROMPT_FILE" ]] || die "prompt file does not exist: $PROMPT_FILE"
PROMPT_TEXT=$(cat "$PROMPT_FILE") || die "failed to read prompt file: $PROMPT_FILE"
[[ -n "$PROMPT_TEXT" ]] || die "prompt file is empty: $PROMPT_FILE"
command -v pi >/dev/null 2>&1 || die "pi CLI not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH (required to read pi's --mode json event stream)"

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
ARGS=(-p -n "$AGENT: $PROMPT_LABEL" --mode json)
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

# Every raw event line, kept for anyone who needs more than the one-line trace below.
EVENTS_FILE=""
if [[ -n "$OUT" ]]; then
  EVENTS_FILE="$OUT.events.jsonl"
  mkdir -p "$(dirname "$EVENTS_FILE")"
  : > "$EVENTS_FILE"
fi

# One line per tool call, as it starts or fails — not per message delta, for the same
# reason crew-coder's own [START]/[DONE] trace is two lines and not one per tool call:
# a log line here costs a jq invocation, and a worker can make dozens of tool calls.
# A line unrecognised by these two cases (a bad JSON line, a future event type) is
# silently skipped rather than failing the dispatch — trace output is observability,
# it must never be why a worker's run comes back `blocked`.
trace_event() {
  local line="$1" type
  type=$(printf '%s' "$line" | jq -r '.type // empty' 2>/dev/null) || return 0
  case "$type" in
    tool_execution_start)
      local tool args msg
      tool=$(printf '%s' "$line" | jq -r '.toolName // "?"' 2>/dev/null)
      args=$(printf '%s' "$line" | jq -c '.args // {}' 2>/dev/null | cut -c1-200)
      msg="[TOOL] agent=$AGENT tool=$tool args=$args"
      [[ -n "$LOG" ]] && printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$msg" >> "$LOG"
      echo "$msg" >&2
      ;;
    tool_execution_end)
      local is_error tool msg
      is_error=$(printf '%s' "$line" | jq -r '.isError // false' 2>/dev/null)
      [[ "$is_error" == "true" ]] || return 0
      tool=$(printf '%s' "$line" | jq -r '.toolName // "?"' 2>/dev/null)
      msg="[TOOL-ERROR] agent=$AGENT tool=$tool"
      [[ -n "$LOG" ]] && printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$msg" >> "$LOG"
      echo "$msg" >&2
      ;;
  esac
}

# Reads pi's NDJSON stream one line at a time, so trace_event's [TOOL] lines land in
# --log while the worker is still running. Forwards every line back to its own stdout
# unchanged — dispatch.mjs never reads this script's stdout (capture is "file", per
# dispatch.mjs), but a human running this by hand still sees the raw stream live.
stream_events() {
  local line
  while IFS= read -r line; do
    [[ -n "$EVENTS_FILE" ]] && printf '%s\n' "$line" >> "$EVENTS_FILE"
    trace_event "$line"
    printf '%s\n' "$line"
  done
}

# MAIN_ROOT is exported so the agent's own environment setup can read it. The agent
# runs with the worktree as cwd, which is what its PROJECT_ROOT check expects.
(cd "$DIR" && MAIN_ROOT="$MAIN_ROOT" CREW_ORCHESTRATED=1 pi "${ARGS[@]}" "$PROMPT_TEXT") 2>>"${LOG:-/dev/null}" | stream_events
status=${PIPESTATUS[0]}

# report.mjs reads --out as the worker's final message text, not the event stream — pull
# the last assistant message_end back out of the recorded events, the same text pi -p
# would have printed on its own. An empty result (no assistant text at all) is a
# legitimate, already-handled report state — see report.mjs's "empty" parsedFrom — so it
# is never papered over with the raw JSONL.
if [[ -n "$OUT" ]]; then
  mkdir -p "$(dirname "$OUT")"
  jq -rs '
    [.[] | select(.type == "message_end") | select(.message.role == "assistant")] as $msgs
    | (($msgs[-1] // {}).message.content // [])
    | map(select(.type == "text") | .text) | join("")
  ' "$EVENTS_FILE" > "$OUT" 2>/dev/null || : > "$OUT"
fi

if [[ -n "$LOG" ]]; then
  echo "[$(date -u +%H:%M:%SZ)] [DISPATCH-END] agent=$AGENT exit=$status" >> "$LOG"
fi

exit "$status"
