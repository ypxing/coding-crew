#!/usr/bin/env bash
# crew-afk.sh dispatch|status — start one /solve-feature run in a feature's own worktree, and say how each run ended.
#   dispatch <slug> --agent <claude|copilot|codex|pi> [--to local|orca|herdr]
#       prepares (or reuses) the slug's worktree, starts the run there and returns; prints worktree=, and log= and
#       pid= for a local run, session= on claude
#   status [<slug>]
#       one line per slug worktree with a .solve-feature/ dir: the run's outcome line, or why there is none
# A destination is scripts/destinations/<name>.sh with two functions: `prepare <slug> <base-branch>` prints the
# worktree path; `launch <worktree> <argv…>` starts the run there. Exit: 0 ok; 1 a stop; 2 a usage error.
set -euo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { echo "crew-afk: $*" >&2; exit 1; }
usage() {
  [ -z "${1:-}" ] || echo "crew-afk: $1" >&2
  echo "usage: crew-afk.sh dispatch <slug> --agent <claude|copilot|codex|pi> [--to local|orca|herdr] | status [<slug>]" >&2
  exit 2
}

# launch_argv <agent> <headless|interactive> <slug> — sets ARGV, and SESSION for a headless claude run; returns 1
# for an agent with no case here. The $10 cap is claude's own flag; the local destination adds the 1h one.
launch_argv() {
  local agent="$1" mode="$2" slug="$3" prompt="Use the solve-feature skill on $3"
  SESSION=""
  case "$agent:$mode" in
    claude:headless)
      SESSION=$(node -e 'console.log(require("crypto").randomUUID())') || die "node not found: it makes the session id"
      ARGV=(claude -p "/solve-feature $slug" --output-format json --session-id "$SESSION" --max-budget-usd 10 --dangerously-skip-permissions) ;;
    claude:interactive) ARGV=(claude --dangerously-skip-permissions "/solve-feature $slug") ;;
    copilot:headless) ARGV=(copilot -p "$prompt" --allow-all-tools) ;;
    copilot:interactive) ARGV=(copilot -i "$prompt" --allow-all-tools) ;;
    codex:headless) ARGV=(codex exec --dangerously-bypass-approvals-and-sandbox "$prompt") ;;
    codex:interactive) ARGV=(codex --dangerously-bypass-approvals-and-sandbox "$prompt") ;;
    pi:headless) ARGV=(pi -p "/skill:solve-feature $slug") ;;
    pi:interactive) ARGV=(pi "/skill:solve-feature $slug") ;;
    *) return 1 ;;
  esac
}

# include <worktree> — each .worktreeinclude entry of the main checkout linked in, and .env copied: a container
# that bind-mounts only the worktree cannot follow a link out of it. An entry already there is left alone.
include() {
  local wt="$1" entry
  { [ ! -f "$MAIN/.worktreeinclude" ] || cat "$MAIN/.worktreeinclude"; echo .env; } | while IFS= read -r entry; do
    entry=$(printf '%s' "$entry" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's|/*$||')
    case "$entry" in '' | '#'*) continue ;; esac
    [ -e "$MAIN/$entry" ] || continue
    if [ -L "$wt/$entry" ] && [ ! -e "$wt/$entry" ]; then rm -f "$wt/$entry"; fi
    [ ! -e "$wt/$entry" ] || continue
    mkdir -p "$(dirname "$wt/$entry")"
    if [ "$entry" = .env ]; then cp "$MAIN/.env" "$wt/.env"; else ln -s "$MAIN/$entry" "$wt/$entry"; fi
  done
}

live_pid() { # <logs-dir> — prints the run's pid while it is alive
  local pid
  pid=$(cat "$1/run.pid" 2>/dev/null) && [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && echo "$pid"
}

dispatch() {
  local to=local agent="" slug="" mode base wt logs pid
  while [ $# -gt 0 ]; do case "$1" in
    --agent | --to) [ $# -ge 2 ] || usage "$1 needs a value"; if [ "$1" = --to ]; then to="$2"; else agent="$2"; fi; shift 2 ;;
    -*) usage "unknown flag: $1" ;;
    *) [ -z "$slug" ] || usage "unexpected argument: $1"; slug="$1"; shift ;;
  esac; done
  # The tracker's own slug rule: the slug reaches a path and an argv, so nothing else gets through.
  [[ "$slug" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || usage "invalid feature slug: '$slug'"
  [[ "$to" =~ ^[a-z]+$ && -f "$SELF/destinations/$to.sh" ]] || usage "unknown --to '$to': one of $(cd "$SELF/destinations" && ls | sed 's/\.sh$//' | paste -sd' ' -)"
  if [ "$to" = local ]; then mode=headless; else mode=interactive; fi
  [ -n "$agent" ] || usage "--agent is required"
  launch_argv "$agent" "$mode" "$slug" || usage "unknown --agent '$agent': one of claude copilot codex pi"

  # git refuses a branch checked out twice, but a detached second run would race the first on one checkout.
  pid=$(live_pid "$WORKTREES/$slug/.solve-feature") && die "a run for $slug is still going (pid $pid)"
  base=$(git -C "$MAIN" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || true)
  SLUG="$slug"
  # shellcheck source=/dev/null
  source "$SELF/destinations/$to.sh"
  wt=$(prepare "$slug" "${base:-main}")
  include "$wt"
  logs="$wt/.solve-feature"
  mkdir -p "$logs" && echo '*' >"$logs/.gitignore"
  # A stale outcome would read as this run's result until solve-feature's start clears it.
  rm -f "$logs/outcome" "$logs/run.pid" "$logs/run.session" "$logs/run.log"
  echo "$to" >"$logs/run.dest"
  [ -z "$SESSION" ] || echo "$SESSION" >"$logs/run.session"
  launch "$wt" "${ARGV[@]}"
  echo "worktree=$wt"
  if [ -f "$logs/run.pid" ]; then echo "log=$logs/run.log"; echo "pid=$(cat "$logs/run.pid")"; fi
  [ -z "$SESSION" ] || echo "session=$SESSION"
}

status() {
  local filter="${1:-}" wt slug logs pid dest found=0
  [ $# -le 1 ] || usage
  while IFS= read -r wt; do
    logs="$wt/.solve-feature"
    [ "$wt" != "$MAIN" ] && [ -d "$logs" ] || continue
    slug=$(basename "$wt")
    [ -z "$filter" ] || [ "$slug" = "$filter" ] || continue
    found=1
    if [ -s "$logs/outcome" ]; then echo "$slug: $(head -n 1 "$logs/outcome")"
    elif pid=$(live_pid "$logs"); then echo "$slug: running (pid $pid)"
    elif dest=$(cat "$logs/run.dest" 2>/dev/null) && [ "$dest" != local ]; then
      echo "$slug: no outcome yet — $dest run, see its terminal"
    else
      echo "$slug: ended without an outcome (capped or crashed) — log: $logs/run.log"
      [ ! -s "$logs/run.session" ] || echo "  resume: cd $wt && claude --resume $(cat "$logs/run.session")"
      # A capped run is a checkpoint: solve-feature skips the issues it closed and reuses the branch and PR.
      if grep -q '"subtype": *"error_max_budget_usd"' "$logs/run.log" 2>/dev/null ||
        grep -qx 'crew-afk: exit 124' "$logs/run.log" 2>/dev/null; then
        echo "  capped at \$10/1h — re-run /crew-afk $slug to continue"
      fi
    fi
  done < <(git -C "$MAIN" worktree list --porcelain | sed -n 's/^worktree //p')
  [ "$found" -eq 1 ] || echo "no crew-afk run${filter:+ for $filter}"
}

CMD="${1:-}"; [ $# -eq 0 ] || shift
case "$CMD" in dispatch | status) ;; *) usage ;; esac
COMMON=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || die "not inside a git repository"
MAIN=$(dirname "$COMMON")
# One worktree per slug, beside the main checkout: never inside it, where the user's own tools would scan it.
WORKTREES="$(dirname "$MAIN")/$(basename "$MAIN")-worktrees"
"$CMD" "$@"
