#!/usr/bin/env bash
set -euo pipefail

# state.sh — the sprint's bookkeeping, as a script instead of as prose.
#
# Every round the orchestrator has to remember which slugs completed, which branches
# were retained and why, which issues are blocked, and which categories had no
# discoverable check command. That list used to live in the prompt as a set of raw jq
# one-liners plus an instruction to "append to all_merged / all_partial / all_blocked",
# which meant a long sprint could silently lose an entry and then report a branch as
# cleaned up that was never deleted. It is all mechanical, so it lives here.
#
# Usage:
#   state.sh model <alias>
#   state.sh round <n> [--issues <count>]
#   state.sh complete --slug <slug> --branch <branch>
#   state.sh retain   --slug <slug> --branch <branch> --reason <reason>
#   state.sh blocked  --slug <slug> [--branch <branch>] [--reason <text>]
#   state.sh coverage-gap --slug <slug> --categories <lint,typecheck>
#   state.sh resume --slug <slug>
#   state.sh retention --slug <slug>
#   state.sh get <merged|retained|completed|partial|blocked|model|round|feature-slug|state-file>
#   state.sh show
#
# Common flags: [--feature-slug <slug>] [--state-file <path>]
#
# `retain` is the single entry point for every branch that must survive the sprint:
# partial work, a failed verification, unmet acceptance criteria, a failed merge, or a
# blocked issue. The reason string is what the summary prints, and `get retained` is what
# feeds cleanup-worktrees.sh --retain, so a branch recorded here cannot be deleted.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "state.sh: $1" >&2; exit 1; }

trace() { bash "$SCRIPT_DIR/trace.sh" "$@" 2>/dev/null || true; }

usage() {
  sed -n '/^# Usage:/,/^# `retain`/p' "$0" >&2
  exit 1
}

CMD="${1:-}"
[ -n "$CMD" ] || usage
shift

# --- state file resolution ----------------------------------------------------
# Explicit flags win, then the environment exported by sprint.env, then a lookup
# through sprint.env itself. Never a `ls .scratch/*/sprint-state.json | head -1` glob:
# that picks the alphabetically-first feature, which is the wrong sprint in any repo
# that has ever run two.
FEATURE_SLUG_ARG=""
STATE_FILE_ARG=""
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --feature-slug) FEATURE_SLUG_ARG="${2:-}"; shift 2 ;;
    --state-file) STATE_FILE_ARG="${2:-}"; shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

MAIN_ROOT="${MAIN_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

resolve_state_file() {
  if [ -n "$STATE_FILE_ARG" ]; then
    printf '%s\n' "$STATE_FILE_ARG"; return 0
  fi
  if [ -n "$FEATURE_SLUG_ARG" ]; then
    printf '%s\n' "$MAIN_ROOT/.scratch/$FEATURE_SLUG_ARG/sprint-state.json"; return 0
  fi
  if [ -n "${STATE_FILE:-}" ]; then
    printf '%s\n' "$STATE_FILE"; return 0
  fi
  if [ -f "$MAIN_ROOT/.scratch/sprint.env" ]; then
    # shellcheck disable=SC1091
    . "$MAIN_ROOT/.scratch/sprint.env"
    if [ -n "${STATE_FILE:-}" ]; then printf '%s\n' "$STATE_FILE"; return 0; fi
  fi
  return 1
}

SF=$(resolve_state_file) || die "cannot resolve the sprint state file — pass --feature-slug or source .scratch/sprint.env"
[ -f "$SF" ] || die "sprint state file not found: $SF (run session-init.sh first)"
command -v jq >/dev/null 2>&1 || die "jq is required"

edit_state() {
  local tmp="$SF.tmp.$$"
  jq "$@" "$SF" > "$tmp" && mv "$tmp" "$SF"
}

flag() {
  # flag <name> <default> "$@" — read --name from the remaining args
  local want="$1" out="$2"; shift 2
  while [ $# -gt 0 ]; do
    if [ "$1" = "--$want" ]; then out="${2:-}"; fi
    shift
  done
  printf '%s\n' "$out"
}

csv() { jq -r "$1 | join(\",\")" "$SF"; }

case "$CMD" in
  model)
    alias_name="${1:?state.sh model <alias>}"
    edit_state --arg m "$alias_name" '.model = $m'
    trace MODEL "resolved=$alias_name"
    echo "MODEL: $alias_name"
    ;;

  round)
    n="${1:?state.sh round <n>}"
    issues=$(flag issues "" "$@")
    edit_state --argjson n "$n" '.round = $n | .rounds = ([.rounds // 0, $n] | max)'
    trace ROUND "round=$n${issues:+ issues=$issues}"
    echo "ROUND: $n${issues:+ issues=$issues}"
    ;;

  complete)
    slug=$(flag slug "" "$@"); branch=$(flag branch "" "$@")
    [ -n "$slug" ] || die "complete requires --slug"
    [ -n "$branch" ] || die "complete requires --branch"
    # Retention is cleared here so a stale branch is never offered for resume, and so
    # the branch moves out of cleanup's --retain list into its --merged list.
    edit_state --arg s "$slug" --arg b "$branch" '
      .completed_slugs = ((.completed_slugs // []) + [$s] | unique)
      | .merged_branches = ((.merged_branches // []) + [$b] | unique)
      | .retained_branches = ((.retained_branches // {}) | del(.[$s]))
      | .retention = ((.retention // {}) | del(.[$s]))
      | .blocked_slugs = ((.blocked_slugs // []) - [$s])'
    trace STATE "complete slug=$slug branch=$branch"
    echo "STATE: complete slug=$slug branch=$branch"
    ;;

  retain)
    slug=$(flag slug "" "$@"); branch=$(flag branch "" "$@"); reason=$(flag reason "" "$@")
    [ -n "$slug" ] || die "retain requires --slug"
    [ -n "$branch" ] || die "retain requires --branch"
    [ -n "$reason" ] || die "retain requires --reason (partial | verification-failed | criteria-unmet | review-not-run | merge-failed | blocked)"
    edit_state --arg s "$slug" --arg b "$branch" --arg r "$reason" '
      .retained_branches[$s] = $b
      | .retention[$s] = {branch: $b, reason: $r}
      | .completed_slugs = ((.completed_slugs // []) - [$s])
      | .merged_branches = ((.merged_branches // []) - [$b])'
    trace STATE "retain slug=$slug branch=$branch reason=$reason"
    echo "STATE: retain slug=$slug branch=$branch reason=$reason"
    ;;

  blocked)
    slug=$(flag slug "" "$@"); branch=$(flag branch "" "$@"); reason=$(flag reason "blocked" "$@")
    [ -n "$slug" ] || die "blocked requires --slug"
    edit_state --arg s "$slug" '.blocked_slugs = ((.blocked_slugs // []) + [$s] | unique)'
    if [ -n "$branch" ]; then
      edit_state --arg s "$slug" --arg b "$branch" --arg r "blocked — $reason" '
        .retained_branches[$s] = $b | .retention[$s] = {branch: $b, reason: $r}'
    fi
    trace STATE "blocked slug=$slug${branch:+ branch=$branch}"
    echo "STATE: blocked slug=$slug${branch:+ branch=$branch}"
    ;;

  coverage-gap)
    slug=$(flag slug "" "$@"); cats=$(flag categories "" "$@")
    [ -n "$slug" ] || die "coverage-gap requires --slug"
    [ -n "$cats" ] || die "coverage-gap requires --categories"
    edit_state --arg s "$slug" --arg c "$cats" '.coverage_gaps[$s] = $c'
    trace STATE "coverage-gap slug=$slug categories=$cats"
    echo "STATE: coverage-gap slug=$slug categories=$cats"
    ;;

  resume)
    # Does this issue have a branch from an earlier round that still exists?
    # Both halves are mechanical — a recorded branch name and a ref lookup — and both
    # used to sit in the prompt as a jq call plus `git branch --list`. A worker told to
    # resume on a branch that no longer exists starts over and silently loses the WIP.
    slug=$(flag slug "" "$@")
    [ -n "$slug" ] || die "resume requires --slug"
    prior=$(jq -r --arg s "$slug" '.retained_branches[$s] // empty' "$SF")
    if [ -n "$prior" ] && [ -n "$(git -C "$MAIN_ROOT" branch --list "$prior")" ]; then
      echo "resume: $prior"
    else
      echo "no prior branch"
    fi
    ;;

  retention)
    # A retained branch's *reason* is what tells the orchestrator whether the branch's
    # content needs another worker pass or only another review attempt — resume answers
    # "is there a branch", this answers "why was it retained". Read from `.retention`,
    # never inferred from `.retained_branches` alone: a blocked issue is retained too, but
    # with a "blocked — ..." reason that must never be mistaken for a review-only retry.
    slug=$(flag slug "" "$@")
    [ -n "$slug" ] || die "retention requires --slug"
    reason=$(jq -r --arg s "$slug" '.retention[$s].reason // empty' "$SF")
    if [ -n "$reason" ]; then
      echo "reason: $reason"
    else
      echo "no retention record"
    fi
    ;;

  get)
    field="${1:?state.sh get <field>}"
    case "$field" in
      merged) csv '(.merged_branches // [])' ;;
      retained) csv '((.retained_branches // {}) | [.[]] | unique)' ;;
      completed) csv '(.completed_slugs // [])' ;;
      partial) csv '((.retention // {}) | [to_entries[] | select(.value.reason | startswith("blocked") | not) | .key])' ;;
      blocked) csv '(.blocked_slugs // [])' ;;
      model) jq -r '.model // "sonnet"' "$SF" ;;
      round) jq -r '.round // 1' "$SF" ;;
      rounds) jq -r '.rounds // .round // 1' "$SF" ;;
      feature-slug) jq -r '.feature_slug // empty' "$SF" ;;
      state-file) printf '%s\n' "$SF" ;;
      *) die "unknown field: $field" ;;
    esac
    ;;

  show) cat "$SF" ;;

  *) usage ;;
esac
