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
[[ -f "$PROMPT_FILE" ]] || die "prompt file does not exist: $PROMPT_FILE"

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

ARGS=(exec --cd "$DIR" --sandbox "$SANDBOX")
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
  cat "$PROMPT_FILE"
} > "$COMBINED"

if [[ -n "$LOG" ]]; then
  mkdir -p "$(dirname "$LOG")"
  echo "[$(date -u +%H:%M:%SZ)] [DISPATCH] agent=$AGENT dir=$DIR model=${EFFECTIVE_MODEL:-inherit} sandbox=$SANDBOX" >> "$LOG"
fi

# MAIN_ROOT is exported so the agent's own environment setup can read it. The agent
# runs with the worktree as its working root, which its PROJECT_ROOT check expects.
MAIN_ROOT="$MAIN_ROOT" CREW_ORCHESTRATED=1 codex "${ARGS[@]}" - < "$COMBINED" 2>>"${LOG:-/dev/null}"
status=$?

if [[ -n "$LOG" ]]; then
  echo "[$(date -u +%H:%M:%SZ)] [DISPATCH-END] agent=$AGENT exit=$status" >> "$LOG"
fi

exit "$status"
