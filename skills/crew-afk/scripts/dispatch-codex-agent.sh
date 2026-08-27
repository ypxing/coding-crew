#!/usr/bin/env bash
# dispatch-codex-agent.sh — run a crew agent as an isolated `codex exec` subprocess.
#
# Codex spawns its own subagents internally, but the orchestrator needs a worker
# pinned to a specific git worktree with a report written to a known file, so a
# "subagent" here is a separate `codex exec` process: fresh context window, its own
# tool loop, its own working root (-C <worktree>).
#
# The agent definition (.codex/agents/<name>.toml — the same file Codex reads for
# custom agents) supplies developer_instructions, model, and reasoning effort. This
# script prepends developer_instructions to the prompt and wires the rest onto the
# codex CLI.
#
# Usage:
#   dispatch-codex-agent.sh --agent crew-coder --dir <worktree> --prompt-file <file> \
#                           [--log <file>] [--model <name|inherit>] [--out <file>] \
#                           [--sandbox <mode>]
#
# Exit code is codex's exit code. The agent's final message goes to --out (via
# `codex exec -o`) and to stdout.
#
# Visibility: the run goes through `codex exec --json`, which streams thread/turn/item
# events (item.started/item.completed, covering command_execution, file_change,
# mcp_tool_call, …) as NDJSON as they happen, instead of staying silent until the whole
# turn is done. trace_event reads that stream one line at a time and appends a
# `[TOOL]`/`[TOOL-ERROR]` line to --log as each item starts or a command exits non-zero,
# so `tail -f` on the sprint's trace log shows what a worker is doing *while* it runs.
# --output-last-message is untouched by --json — codex still writes the final message
# to --out itself — so no text extraction is needed here the way pi's dispatcher needs
# one; only the tracing is new. The full event stream is kept next to --out, as
# `<out>.events.jsonl`, for post-hoc debugging.
set -uo pipefail

AGENT=""
DIR=""
PROMPT_FILE=""
LOG=""
MODEL=""
OUT=""
SANDBOX="${CREW_CODEX_SANDBOX:-workspace-write}"

die() { echo "dispatch-codex-agent: $*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent) AGENT="${2:-}"; shift 2 ;;
    --dir) DIR="${2:-}"; shift 2 ;;
    --prompt-file) PROMPT_FILE="${2:-}"; shift 2 ;;
    --log) LOG="${2:-}"; shift 2 ;;
    --model) MODEL="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --sandbox) SANDBOX="${2:-}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$AGENT" ]] || die "--agent is required"
[[ -n "$DIR" ]] || die "--dir is required"
[[ -n "$PROMPT_FILE" ]] || die "--prompt-file is required"
[[ -d "$DIR" ]] || die "working directory does not exist: $DIR"
# Read the prompt now, immediately next to the existence check, not many lines later at
# COMBINED-build time (agent-file parsing, sandbox/model resolution, --add-dir wiring all
# used to sit in between). That gap let the file disappear before its contents were ever
# actually read — silently: the `cat` that filled COMBINED had no `|| die` of its own, so
# a missing prompt file did not fail the dispatch at all, it just ran codex with the task
# section blank. See dispatch-agent.sh's identical fix for the pi platform.
#
# A [[ -f ]] test and a `cat` are still two separate syscalls in two separate processes,
# not one atomic read — on a slow/virtualized/shared-mount filesystem (bind mounts, VM
# shared folders, network filesystems) a file a sibling process just wrote can briefly
# 404 for a freshly spawned `cat` even microseconds after `[[ -f ]]` found it. A short,
# bounded retry (5 attempts, 40ms apart — a fifth of a second, worst case) absorbs that
# class of transient miss without masking a prompt file that genuinely never existed,
# which still fails just as hard, only slightly later.
PROMPT_TEXT=""
PROMPT_READ_OK=0
for _prompt_attempt in 1 2 3 4 5; do
  if [[ -f "$PROMPT_FILE" ]] && PROMPT_TEXT=$(cat "$PROMPT_FILE" 2>/dev/null); then
    PROMPT_READ_OK=1
    break
  fi
  sleep 0.04
done
[[ "$PROMPT_READ_OK" -eq 1 ]] || die "failed to read prompt file: $PROMPT_FILE"
[[ -n "$PROMPT_TEXT" ]] || die "prompt file is empty: $PROMPT_FILE"

MAIN_ROOT="${MAIN_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# Agent definitions: project-level first, then user-level.
AGENT_FILE=""
for candidate in \
  "$MAIN_ROOT/.codex/agents/$AGENT.toml" \
  "$HOME/.codex/agents/$AGENT.toml"; do
  if [[ -f "$candidate" ]]; then AGENT_FILE="$candidate"; break; fi
done
[[ -n "$AGENT_FILE" ]] || die "agent definition not found for '$AGENT' (looked in .codex/agents and ~/.codex/agents)"

command -v codex >/dev/null 2>&1 || die "codex CLI not found on PATH (crew-afk requires the local Codex CLI; hosted Codex in ChatGPT / Codex cloud is not supported)"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH (required to read codex's --json event stream)"

# Scalar TOML value:  key = "value"
toml_scalar() {
  local key="$1"
  awk -v key="$key" '
    $0 ~ "^[ \t]*" key "[ \t]*=" {
      sub(/^[^=]*=[ \t]*/, "", $0)
      gsub(/^["'"'"']|["'"'"'][ \t]*$/, "", $0)
      print
      exit
    }
  ' "$AGENT_FILE"
}

# Multi-line literal TOML value:  key = '''\n...\n'''
toml_multiline() {
  local key="$1"
  awk -v key="$key" '
    !inside && $0 ~ "^[ \t]*" key "[ \t]*=[ \t]*'"'''"'[ \t]*$" { inside = 1; next }
    inside && $0 ~ "^[ \t]*'"'''"'[ \t]*$" { exit }
    inside { print }
  ' "$AGENT_FILE"
}

INSTRUCTIONS=$(toml_multiline developer_instructions)
# Regex match, not ${v//[[:space:]]/}: pattern substitution over a multi-KB string is
# O(n^2) in bash 3.2 (macOS system bash), which cost ~40s of dead CPU per dispatch.
[[ "$INSTRUCTIONS" =~ [^[:space:]] ]] || die "agent definition has empty developer_instructions: $AGENT_FILE"

AGENT_MODEL=$(toml_scalar model)
AGENT_EFFORT=$(toml_scalar model_reasoning_effort)
AGENT_SANDBOX=$(toml_scalar sandbox_mode)
[[ -n "$AGENT_SANDBOX" ]] && SANDBOX="$AGENT_SANDBOX"

# --model inherit means "whatever the orchestrator session uses" — pass nothing.
EFFECTIVE_MODEL=""
if [[ -n "$MODEL" && "$MODEL" != "inherit" ]]; then
  EFFECTIVE_MODEL="$MODEL"
elif [[ -z "$MODEL" ]]; then
  EFFECTIVE_MODEL="$AGENT_MODEL"
fi

ARGS=(exec --cd "$DIR" --sandbox "$SANDBOX" --json)
# Workers install dependencies and fetch packages; a sandboxed workspace blocks
# network by default, which would fail every dep-install step.
[[ "$SANDBOX" == "workspace-write" ]] && ARGS+=(-c sandbox_workspace_write.network_access=true)
# A linked worktree's index lives in the *main* repo's git dir
# (`<main>/.git/worktrees/<name>/index.lock`), and codex's workspace-write sandbox keeps
# `.git` read-only even when the enclosing directory is passed with --add-dir. Without
# naming the git dir as an explicit writable root, a worker can edit files but never stage
# or commit them: observed as `fatal: Unable to create '…/index.lock': Operation not
# permitted`, which the pipeline correctly reads as `blocked` — every codex sprint stalls.
if [[ "$SANDBOX" == "workspace-write" ]]; then
  GIT_COMMON_DIR=$(cd "$DIR" && git rev-parse --git-common-dir 2>/dev/null || true)
  case "$GIT_COMMON_DIR" in
    "") ;;
    /*) ;;
    *) GIT_COMMON_DIR="$DIR/$GIT_COMMON_DIR" ;;
  esac
  [[ -n "$GIT_COMMON_DIR" ]] &&
    ARGS+=(-c "sandbox_workspace_write.writable_roots=[\"$GIT_COMMON_DIR\"]")
fi
# Traces, prompts, and reports live under $MAIN_ROOT/.scratch, outside the worktree.
[[ "$MAIN_ROOT" != "$DIR" ]] && ARGS+=(--add-dir "$MAIN_ROOT")
[[ -n "$EFFECTIVE_MODEL" ]] && ARGS+=(--model "$EFFECTIVE_MODEL")
[[ -n "$AGENT_EFFORT" ]] && ARGS+=(-c "model_reasoning_effort=\"$AGENT_EFFORT\"")
if [[ -n "$OUT" ]]; then
  mkdir -p "$(dirname "$OUT")"
  ARGS+=(--output-last-message "$OUT")
fi

# Codex exec has no --append-system-prompt equivalent, so the agent definition is
# prepended to the task prompt as a delimited instruction block.
COMBINED=$(mktemp)
trap 'rm -f "$COMBINED"' EXIT
{
  printf '%s\n' "$INSTRUCTIONS"
  printf '\n---\n\n# Task\n\n'
  printf '%s\n' "$PROMPT_TEXT"
} > "$COMBINED"

if [[ -n "$LOG" ]]; then
  mkdir -p "$(dirname "$LOG")"
  echo "[$(date -u +%H:%M:%SZ)] [DISPATCH] agent=$AGENT dir=$DIR model=${EFFECTIVE_MODEL:-inherit} sandbox=$SANDBOX" >> "$LOG"
fi

# Every raw event line, kept for anyone who needs more than the one-line trace below.
EVENTS_FILE=""
if [[ -n "$OUT" ]]; then
  EVENTS_FILE="$OUT.events.jsonl"
  mkdir -p "$(dirname "$EVENTS_FILE")"
  : > "$EVENTS_FILE"
fi

# agent_message/reasoning items are the narrative text — already in the final report —
# so only the item types that are actual tool calls get a line here. A line this does
# not recognise (a bad JSON line from a non-JSON tool stub, a future item type) is
# silently skipped: trace output is observability, it must never be why a dispatch fails.
trace_event() {
  local line="$1" type
  type=$(printf '%s' "$line" | jq -r '.type // empty' 2>/dev/null) || return 0
  case "$type" in
    item.started)
      local itemtype msg
      itemtype=$(printf '%s' "$line" | jq -r '.item.type // "?"' 2>/dev/null)
      case "$itemtype" in
        agent_message|reasoning) return 0 ;;
      esac
      msg="[TOOL] agent=$AGENT item=$itemtype"
      [[ -n "$LOG" ]] && printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$msg" >> "$LOG"
      echo "$msg" >&2
      ;;
    item.completed)
      local itemtype exitcode msg
      itemtype=$(printf '%s' "$line" | jq -r '.item.type // "?"' 2>/dev/null)
      exitcode=$(printf '%s' "$line" | jq -r '.item.exit_code // empty' 2>/dev/null)
      [[ -n "$exitcode" && "$exitcode" != "0" ]] || return 0
      msg="[TOOL-ERROR] agent=$AGENT item=$itemtype exit=$exitcode"
      [[ -n "$LOG" ]] && printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$msg" >> "$LOG"
      echo "$msg" >&2
      ;;
    turn.failed|error)
      local msg="[TOOL-ERROR] agent=$AGENT $type"
      [[ -n "$LOG" ]] && printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$msg" >> "$LOG"
      echo "$msg" >&2
      ;;
  esac
}

# Reads codex's NDJSON stream one line at a time, so trace_event's [TOOL] lines land in
# --log while the worker is still running. Forwards every line back to its own stdout
# unchanged, so a human running this by hand still sees the raw stream live.
stream_events() {
  local line
  while IFS= read -r line; do
    [[ -n "$EVENTS_FILE" ]] && printf '%s\n' "$line" >> "$EVENTS_FILE"
    trace_event "$line"
    printf '%s\n' "$line"
  done
}

# MAIN_ROOT is exported so the agent's own environment setup can read it. The agent
# runs with the worktree as its working root, which its PROJECT_ROOT check expects.
MAIN_ROOT="$MAIN_ROOT" CREW_ORCHESTRATED=1 codex "${ARGS[@]}" - < "$COMBINED" 2>>"${LOG:-/dev/null}" | stream_events
status=${PIPESTATUS[0]}

if [[ -n "$LOG" ]]; then
  echo "[$(date -u +%H:%M:%SZ)] [DISPATCH-END] agent=$AGENT exit=$status" >> "$LOG"
fi

exit "$status"
