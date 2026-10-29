#!/usr/bin/env bash
# crew-afk.sh dispatch|status|wait — start one /solve-feature run in a feature's own worktree, and say how each run ended.
#   dispatch <slug> [--to local|orca|herdr] [--branch <name>] -- <argv…>
#       prepares (or reuses) the slug's worktree, starts <argv…> there verbatim (the host agent's own command for a
#       solve-feature session on the slug), and returns; prints worktree=, and log= and pid= for a local run.
#       --branch is recorded for status's re-run hint: the argv carries it to solve-feature
#   status [<slug>]
#       one line per worktree crew-afk dispatched to: the run's outcome line, or why there is none
#   wait <slug>
#       blocks until the slug's latest run has ended, then prints what status prints for it: a run with a run.pid
#       (local) once its process is gone, so the line carries the cost from the JSON result line that ends the log;
#       one without, once the outcome is written, its pane or terminal is gone, or its state cannot be read
# A destination is scripts/destinations/<name>.sh: `prepare <slug> <base-branch>` prints the worktree path;
# `launch <slug> <worktree> <argv…>` starts the run there and records its id in the logs dir
# (<worktree>/.coding-crew/solve-feature): a detached run's pid in run.pid, a pane's or terminal's in run.pane;
# `live <logs-dir>` says whether that run is still going: prints its id and returns 0 while it is, returns 1 once
# it is gone (or recorded no id), and returns 2 printing the CLI's stderr when it cannot tell.
# Exit: 0 ok; 1 a stop; 2 a usage error.
set -euo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { echo "crew-afk: $*" >&2; exit 1; }
usage() {
  [ -z "${1:-}" ] || echo "crew-afk: $1" >&2
  echo "usage: crew-afk.sh dispatch <slug> [--to local|orca|herdr] [--branch <name>] -- <argv…> | status [<slug>] | wait <slug>" >&2
  exit 2
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

# run_live <logs-dir> — the live step of the destination that launched the run; a subshell, as every destination
# defines the same functions.
run_live() {
  local dest
  dest=$(cat "$1/run.dest" 2>/dev/null) && [[ "$dest" =~ ^[a-z]+$ && -f "$SELF/destinations/$dest.sh" ]] || return 1
  # shellcheck source=/dev/null
  (source "$SELF/destinations/$dest.sh" && live "$1")
}

worktrees() { git -C "$MAIN" worktree list --porcelain | sed -n 's/^worktree //p'; }

slug_worktrees() { # <slug> — every worktree crew-afk dispatched the slug to: orca names its own after the repo
  local wt
  while IFS= read -r wt; do
    [ "$wt" != "$MAIN" ] && [ "$(cat "$wt/.coding-crew/solve-feature/run.slug" 2>/dev/null)" = "$1" ] || continue
    echo "$wt"
  done < <(worktrees)
}

dispatch() {
  local to=local branch="" slug="" base wt logs
  while [ $# -gt 0 ]; do case "$1" in
    --) shift; break ;;
    --to) [ $# -ge 2 ] || usage "--to needs a value"; to="$2"; shift 2 ;;
    --branch) [ $# -ge 2 ] || usage "--branch needs a value"; branch="$2"; shift 2 ;;
    -*) usage "unknown flag: $1" ;;
    *) [ -z "$slug" ] || usage "unexpected argument: $1"; slug="$1"; shift ;;
  esac; done
  [ $# -gt 0 ] || usage "the launch command is missing: pass it after --"
  # The tracker's own slug rule: the slug reaches a path and an argv, so nothing else gets through.
  [[ "$slug" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || usage "invalid feature slug: '$slug'"
  # A repo's branch-name rule (a ticket key, say) can refuse solve-feature's default; the branch reaches a prompt.
  [ -z "$branch" ] || { [[ "$branch" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] && git check-ref-format --branch "$branch" >/dev/null 2>&1; } ||
    usage "invalid --branch: '$branch'"
  [[ "$to" =~ ^[a-z]+$ && -f "$SELF/destinations/$to.sh" ]] || usage "unknown --to '$to': one of $(cd "$SELF/destinations" && ls | sed 's/\.sh$//' | paste -sd' ' -)"
  # shellcheck source=/dev/null
  source "$SELF/destinations/$to.sh"

  # Two runs of a slug race each other on its branch and issues, whichever destinations they use. Checked before
  # prepare, so a refused dispatch creates nothing.
  local prev rc id noun
  while IFS= read -r prev; do
    prev="$prev/.coding-crew/solve-feature"
    [ ! -s "$prev/outcome" ] || continue
    id=$(run_live "$prev") && rc=0 || rc=$?
    case "$rc" in
      0) # An interactive run's id is "<cli> <pane|terminal> <id>"; a local one, "pid <n>", has nothing to close.
        read -r _ noun _ <<<"$id"
        [[ "$id" == "pid "* ]] && noun="" || noun=", or close that $noun"
        die "a run for $slug is still going ($id): wait for it to end$noun, then re-run" ;;
      2) die "could not tell whether $slug's $(cat "$prev/run.dest") run is still going: $id" ;;
    esac
  done < <(slug_worktrees "$slug")
  # A slug dispatched before worktrees moved under ~/.coding-crew keeps its worktree beside the checkout: a second
  # one would stop on git's refusal to check out the feature branch it holds.
  local legacy; legacy="$(dirname "$MAIN")/$(basename "$MAIN")-worktrees"
  # No -q: grep quitting at a match would fail the pipeline under pipefail, reading as no match.
  ! worktrees | grep -xF "$legacy/$slug" >/dev/null || WORKTREES=$legacy
  base=$(git -C "$MAIN" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || true)
  wt=$(prepare "$slug" "${base:-main}")
  include "$wt"
  logs="$wt/.coding-crew/solve-feature"
  mkdir -p "$logs" && echo '*' >"$logs/.gitignore"
  # A stale outcome would read as this run's result until solve-feature's start clears it, and a stale run id
  # as this run still going when its launch fails.
  rm -f "$logs/outcome" "$logs/run.pid" "$logs/run.pane" "$logs/run.log" "$logs/run.branch"
  echo "$to" >"$logs/run.dest"
  echo "$slug" >"$logs/run.slug"
  [ -z "$branch" ] || echo "$branch" >"$logs/run.branch"
  launch "$slug" "$wt" "$@"
  echo "worktree=$wt"
  if [ -f "$logs/run.pid" ]; then echo "log=$logs/run.log"; echo "pid=$(cat "$logs/run.pid")"; fi
}

# cost <logs-dir> — ` cost=$<n.nn> (<m> min)` from the JSON result line that ends a local run's log, or nothing
cost() {
  local last usd ms
  last=$(grep '^{' "$1/run.log" 2>/dev/null | tail -n 1) || return 0
  usd=$(sed -n 's/.*"total_cost_usd":\([0-9.eE+-]*\).*/\1/p' <<<"$last")
  [ -n "$usd" ] || return 0
  ms=$(sed -n 's/.*"duration_ms":\([0-9]*\).*/\1/p' <<<"$last")
  awk -v usd="$usd" -v ms="$ms" 'BEGIN { printf " cost=$%.2f", usd; if (ms != "") printf " (%d min)", (ms + 30000) / 60000 }'
}

# report <worktree> <slug> — what status prints for one worktree's run: its outcome line, or why there is none
report() {
  local slug="$2" logs="$1/.coding-crew/solve-feature" dest id rc branch where to=""
  dest=$(cat "$logs/run.dest" 2>/dev/null || true)
  if [ -s "$logs/outcome" ]; then echo "$slug: $(head -n 1 "$logs/outcome")$(cost "$logs")"; return; fi
  id=$(run_live "$logs") && rc=0 || rc=$?
  if [ "$rc" -eq 0 ] && [ "$dest" = local ]; then echo "$slug: running ($id)"
  elif [ "$rc" -eq 0 ]; then echo "$slug: no outcome yet — $dest run, see its terminal"
  elif [ "$rc" -eq 2 ]; then echo "$slug: run state unknown — $dest query failed: $(head -n 1 <<<"$id")"
  else
    # Capped, crashed or closed alike: solve-feature skips the issues it closed and reuses the branch and PR.
    branch=$(cat "$logs/run.branch" 2>/dev/null || true)
    if [ "$dest" = local ]; then where="log: $logs/run.log"; else where="its $dest terminal is gone"; to=" --to $dest"; fi
    echo "$slug: ended without an outcome — $where; re-run /crew-afk $slug$to${branch:+ --branch $branch} to continue"
  fi
}

status() {
  local filter="${1:-}" wt slug found=0
  [ $# -le 1 ] || usage
  while IFS= read -r wt; do
    # dispatch writes run.slug on every run: without it, the worktree's run is not crew-afk's to report. The
    # slug comes from it, not the directory: orca names its worktree after the repo too.
    [ "$wt" != "$MAIN" ] && slug=$(cat "$wt/.coding-crew/solve-feature/run.slug" 2>/dev/null) || continue
    [ -z "$filter" ] || [ "$slug" = "$filter" ] || continue
    found=1
    report "$wt" "$slug"
  done < <(worktrees)
  [ "$found" -eq 1 ] || echo "no crew-afk run${filter:+ for $filter}"
}

wait_for() {
  local slug="${1:-}" wt run="" out live
  [ $# -eq 1 ] || usage "wait needs a slug"
  # Only the slug's latest dispatch, the newest run.slug: an older worktree's run is not the one being waited on.
  while IFS= read -r wt; do
    [ -z "$run" ] || [ "$wt/.coding-crew/solve-feature/run.slug" -nt "$run/.coding-crew/solve-feature/run.slug" ] || continue
    run=$wt
  done < <(slug_worktrees "$slug")
  [ -n "$run" ] || { echo "no crew-afk run for $slug"; return; }
  # report reads the outcome and the run's liveness as status does: keep asking until the run is neither live
  # nor waiting on a live terminal; a query that fails returns too, as looping on it could hang for good. solve-feature writes its outcome before the session prints the JSON result line, with the cost,
  # that ends the log, so a live process keeps the wait going past the outcome. Liveness is read before the
  # report: a process that exits in between has its whole log read by the report.
  while :; do
    live=$(live_pid "$run/.coding-crew/solve-feature") || live=""
    out=$(report "$run" "$slug")
    case "$out" in *": running (pid "* | *": no outcome yet — "*) ;; *) [ -n "$live" ] || break ;; esac
    sleep "${CREW_AFK_WAIT_INTERVAL:-5}"
  done
  echo "$out"
}

CMD="${1:-}"; [ $# -eq 0 ] || shift
case "$CMD" in dispatch | status | wait) ;; *) usage ;; esac
COMMON=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || die "not inside a git repository"
MAIN=$(dirname "$COMMON")
# One worktree per slug, under the user's ~/.coding-crew: never inside the checkout, where the user's own tools would
# scan it. The path's hash keeps apart two repos with one name.
WORKTREES="$HOME/.coding-crew/worktrees/$(basename "$MAIN")-$(printf '%s' "$MAIN" | git hash-object --stdin | cut -c1-8)"
if [ "$CMD" = wait ]; then wait_for "$@"; else "$CMD" "$@"; fi
