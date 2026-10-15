#!/usr/bin/env bash
# crew-afk.sh dispatch|status|wait — start one /solve-feature run in a feature's own worktree, and say how each run ended.
#   dispatch <slug> [--to local|orca|herdr] [--branch <name>]
#       prepares (or reuses) the slug's worktree, starts the run there with the agent CLI that ran this script
#       (passing --branch on to solve-feature), and returns; prints worktree=, and log= and pid= for a local run, session= on claude
#   status [<slug>]
#       one line per worktree crew-afk dispatched to: the run's outcome line, or why there is none
#   wait <slug>
#       blocks until the slug's latest run has ended (an outcome written, or a local process gone), then prints what
#       status prints for it
# A destination is scripts/destinations/<name>.sh: MODE=headless|interactive, the agent's mode there; `prepare
# <slug> <base-branch>` prints the worktree path; `launch <slug> <worktree> <argv…>` starts the run there, and a
# headless one writes its pid to <worktree>/.solve-feature/run.pid. Exit: 0 ok; 1 a stop; 2 a usage error.
set -euo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { echo "crew-afk: $*" >&2; exit 1; }
usage() {
  [ -z "${1:-}" ] || echo "crew-afk: $1" >&2
  echo "usage: crew-afk.sh dispatch <slug> [--to local|orca|herdr] [--branch <name>] | status [<slug>] | wait <slug>" >&2
  exit 2
}

# agent — the CLI that ran this script: the nearest parent process that is claude, copilot, codex or pi, run
# directly or by an interpreter (`node …/copilot`); CREW_AGENT, when set, names it instead (the smoke run sets it).
agent() {
  local pid=$PPID line a0 a1 a
  [ -z "${CREW_AGENT:-}" ] || { echo "$CREW_AGENT"; return; }
  while [ "$pid" -gt 1 ] 2>/dev/null && line=$(ps -o ppid= -o args= -p "$pid"); do
    read -r pid a0 a1 _ <<<"$line"
    for a in "${a0##*/}" "${a1##*/}"; do case "$a" in claude | copilot | codex | pi) echo "$a"; return ;; esac; done
  done
  return 1
}

# launch_argv <agent> <headless|interactive> <run-args> — sets ARGV, and SESSION for a headless claude run; returns
# 1 for an agent with no case here. <run-args> is solve-feature's: `<slug> [--branch <name>]`. The local destination
# adds the 1h cap.
launch_argv() {
  local agent="$1" mode="$2" args="$3" prompt="Use the solve-feature skill on $3"
  SESSION=""
  case "$agent:$mode" in
    claude:headless)
      SESSION=$(node -e 'console.log(require("crypto").randomUUID())') || die "node not found: it makes the session id"
      ARGV=(claude -p "/solve-feature $args" --output-format json --session-id "$SESSION" --dangerously-skip-permissions) ;;
    claude:interactive) ARGV=(claude --dangerously-skip-permissions "/solve-feature $args") ;;
    # --allow-all, not --allow-all-tools: the skill's scripts are outside the worktree, and an unattended run's path
    # check has no one to approve it.
    copilot:headless) ARGV=(copilot -p "$prompt" --allow-all) ;;
    copilot:interactive) ARGV=(copilot -i "$prompt" --allow-all) ;;
    codex:headless) ARGV=(codex exec --dangerously-bypass-approvals-and-sandbox "$prompt") ;;
    codex:interactive) ARGV=(codex --dangerously-bypass-approvals-and-sandbox "$prompt") ;;
    pi:headless) ARGV=(pi -p "/skill:solve-feature $args") ;;
    pi:interactive) ARGV=(pi "/skill:solve-feature $args") ;;
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
    [ ! -e "$wt/$entry" ] || continue
    mkdir -p "$(dirname "$wt/$entry")"
    if [ "$entry" = .env ]; then cp "$MAIN/.env" "$wt/.env"; else ln -s "$MAIN/$entry" "$wt/$entry"; fi
    # An ignore pattern with a trailing slash (`node_modules/`) matches no link, and solve-feature refuses an
    # unclean tree, so a link nothing ignores is excluded for every worktree.
    git -C "$wt" check-ignore -q "$entry" || echo "/$entry" >>"$COMMON/info/exclude"
  done
}

live_pid() { # <logs-dir> — prints the run's pid while it is alive
  local pid
  pid=$(cat "$1/run.pid" 2>/dev/null) && [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && echo "$pid"
}

dispatch() {
  local to=local branch="" agent slug="" base wt logs pid
  while [ $# -gt 0 ]; do case "$1" in
    --to) [ $# -ge 2 ] || usage "--to needs a value"; to="$2"; shift 2 ;;
    --branch) [ $# -ge 2 ] || usage "--branch needs a value"; branch="$2"; shift 2 ;;
    -*) usage "unknown flag: $1" ;;
    *) [ -z "$slug" ] || usage "unexpected argument: $1"; slug="$1"; shift ;;
  esac; done
  # The tracker's own slug rule: the slug reaches a path and an argv, so nothing else gets through.
  [[ "$slug" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || usage "invalid feature slug: '$slug'"
  # A repo's branch-name rule (a ticket key, say) can refuse solve-feature's default; the branch reaches a prompt.
  [ -z "$branch" ] || { [[ "$branch" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] && git check-ref-format --branch "$branch" >/dev/null 2>&1; } ||
    usage "invalid --branch: '$branch'"
  [[ "$to" =~ ^[a-z]+$ && -f "$SELF/destinations/$to.sh" ]] || usage "unknown --to '$to': one of $(cd "$SELF/destinations" && ls | sed 's/\.sh$//' | paste -sd' ' -)"
  # shellcheck source=/dev/null
  source "$SELF/destinations/$to.sh"
  agent=$(agent) || die "no agent CLI (claude, copilot, codex or pi) among this script's parent processes: run /crew-afk from one, or set CREW_AGENT"
  launch_argv "$agent" "$MODE" "$slug${branch:+ --branch $branch}" || die "unknown agent '$agent': one of claude copilot codex pi"

  # git refuses a branch checked out twice, but a detached second run would race the first on one checkout.
  pid=$(live_pid "$WORKTREES/$slug/.solve-feature") && die "a run for $slug is still going (pid $pid)"
  base=$(git -C "$MAIN" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || true)
  wt=$(prepare "$slug" "${base:-main}")
  include "$wt"
  logs="$wt/.solve-feature"
  mkdir -p "$logs" && echo '*' >"$logs/.gitignore"
  # A stale outcome would read as this run's result until solve-feature's start clears it.
  rm -f "$logs/outcome" "$logs/run.pid" "$logs/run.session" "$logs/run.log" "$logs/run.branch"
  echo "$to" >"$logs/run.dest"
  echo "$slug" >"$logs/run.slug"
  [ -z "$SESSION" ] || echo "$SESSION" >"$logs/run.session"
  [ -z "$branch" ] || echo "$branch" >"$logs/run.branch"
  launch "$slug" "$wt" "${ARGV[@]}"
  echo "worktree=$wt"
  if [ -f "$logs/run.pid" ]; then echo "log=$logs/run.log"; echo "pid=$(cat "$logs/run.pid")"; fi
  [ -z "$SESSION" ] || echo "session=$SESSION"
}

# report <worktree> <slug> — what status prints for one worktree's run: its outcome line, or why there is none
report() {
  local wt="$1" slug="$2" logs="$1/.solve-feature" pid branch
  if [ -s "$logs/outcome" ]; then echo "$slug: $(head -n 1 "$logs/outcome")"
  elif pid=$(live_pid "$logs"); then echo "$slug: running (pid $pid)"
  elif [ ! -f "$logs/run.pid" ]; then echo "$slug: no outcome yet — $(cat "$logs/run.dest") run, see its terminal"
  else
    # Capped or crashed alike: solve-feature skips the issues it closed and reuses the branch and PR.
    branch=$(cat "$logs/run.branch" 2>/dev/null || true)
    echo "$slug: ended without an outcome — log: $logs/run.log; re-run /crew-afk $slug${branch:+ --branch $branch} to continue"
    [ ! -s "$logs/run.session" ] || echo "  resume: cd $wt && claude --resume $(cat "$logs/run.session")"
  fi
}

worktrees() { git -C "$MAIN" worktree list --porcelain | sed -n 's/^worktree //p'; }

status() {
  local filter="${1:-}" wt slug found=0
  [ $# -le 1 ] || usage
  while IFS= read -r wt; do
    # dispatch writes run.slug on every run: without it, the worktree's run is not crew-afk's to report. The
    # slug comes from it, not the directory: orca names its worktree after the repo too.
    [ "$wt" != "$MAIN" ] && slug=$(cat "$wt/.solve-feature/run.slug" 2>/dev/null) || continue
    [ -z "$filter" ] || [ "$slug" = "$filter" ] || continue
    found=1
    report "$wt" "$slug"
  done < <(worktrees)
  [ "$found" -eq 1 ] || echo "no crew-afk run${filter:+ for $filter}"
}

wait_for() {
  local slug="${1:-}" wt run="" out
  [ $# -eq 1 ] || usage "wait needs a slug"
  # Only the slug's latest dispatch, the newest run.slug: an older worktree's run whose terminal closed with no
  # outcome stays `no outcome yet` for good, and would keep the wait from ever seeing this run end.
  while IFS= read -r wt; do
    [ "$wt" != "$MAIN" ] && [ "$(cat "$wt/.solve-feature/run.slug" 2>/dev/null)" = "$slug" ] || continue
    [ -z "$run" ] || [ "$wt/.solve-feature/run.slug" -nt "$run/.solve-feature/run.slug" ] || continue
    run=$wt
  done < <(worktrees)
  [ -n "$run" ] || { echo "no crew-afk run for $slug"; return; }
  # report reads the outcome and run.pid as status does: keep asking until the run is neither live nor waiting
  # on a terminal.
  while out=$(report "$run" "$slug"); do
    case "$out" in *": running (pid "* | *": no outcome yet — "*) sleep "${CREW_AFK_WAIT_INTERVAL:-5}" ;; *) break ;; esac
  done
  echo "$out"
}

CMD="${1:-}"; [ $# -eq 0 ] || shift
case "$CMD" in dispatch | status | wait) ;; *) usage ;; esac
COMMON=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || die "not inside a git repository"
MAIN=$(dirname "$COMMON")
# One worktree per slug, beside the main checkout: never inside it, where the user's own tools would scan it.
WORKTREES="$(dirname "$MAIN")/$(basename "$MAIN")-worktrees"
if [ "$CMD" = wait ]; then wait_for "$@"; else "$CMD" "$@"; fi
