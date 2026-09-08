#!/usr/bin/env bash
set -uo pipefail

# ensure-codegraph.sh — give a worktree its own codegraph index, if codegraph is in use.
#
# Usage:
#   ensure-codegraph.sh --dir <path> [--slug <issue-slug>] [--timeout <sec, default 300>]
#
# Output — exactly one `CODEGRAPH:` line, always exit 0:
#
#   CODEGRAPH: present       .codegraph already there (reused worktree, or a prior run)
#   CODEGRAPH: initialized   `codegraph init -i` ran and succeeded
#   CODEGRAPH: unavailable   CREW_CODEGRAPH=on but the codegraph CLI is not on PATH
#   CODEGRAPH: skipped       CREW_CODEGRAPH is not "on" (the default)
#   CODEGRAPH: failed (exit N) (see <log>)
#
# Why this exists
#   codegraph (https://github.com/colbymchenry/codegraph) indexes a project into a
#   `.codegraph/` directory that an MCP-connected agent can query for structural context
#   (symbol definitions, call graphs, impact radius) instead of grep/glob exploration. Its
#   own index resolution walks up from cwd to the *nearest* `.codegraph/` — so a worktree
#   with no local index of its own silently inherits the main checkout's, which is wrong
#   the moment a worker edits a file the shared index has never seen (codegraph's own PR
#   #312 documents exactly this: a git worktree nested under the indexed root borrows the
#   parent's index unless it has run `codegraph init -i` for itself). Giving each worktree
#   its own isolated index closes that gap, and nearest-wins resolution means it closes it
#   regardless of where the worktree lives on disk — no need to relocate
#   `.scratch/worktrees` outside the project root to get correct behaviour.
#
# Why CREW_CODEGRAPH defaults off
#   Indexing is a real, guaranteed cost — a full pass per worktree, every round, for as
#   many worktrees as run concurrently — paid for a benefit (fewer exploration tool-calls
#   inside a single-issue dispatch) that is plausible but unproven for this orchestrator's
#   shape. Mirrors CREW_DEPS/CREW_DOCKER_INSTALL's escape hatch, inverted: those default
#   "on" because the cost is near zero once a dep dir already exists; this defaults "off"
#   because the cost is paid every time regardless of what came before.
#
# Never exits non-zero
#   Same rule as ensure-deps.sh: an optional capability's absence, or its own failure, must
#   never stall a sprint. A worker with no codegraph index just falls back to the
#   exploration tools it already has.

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DIR=""
SLUG=""
TIMEOUT=300

_usage() {
  echo "Usage: $0 --dir <path> [--slug <issue-slug>] [--timeout <sec>]" >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dir|--slug|--timeout)
      # Guard before reading $2: under `set -u` a bare flag would abort with an
      # unbound-variable error instead of the usage message.
      if [ $# -lt 2 ]; then echo "ERROR: $1 requires a value" >&2; _usage; exit 1; fi
      case "$1" in
        --dir) DIR="$2" ;;
        --slug) SLUG="$2" ;;
        --timeout) TIMEOUT="$2" ;;
      esac
      shift 2
      ;;
    -h|--help) sed -n '3,10p' "$0"; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; _usage; exit 1 ;;
  esac
done

# A usage error is still an error: exiting 0 on a typo'd flag would report "codegraph is
# fine" about a directory nobody looked at. The always-exit-0 rule is about init *outcomes*.
if [ -z "$DIR" ]; then echo "ERROR: --dir <path> is required" >&2; _usage; exit 1; fi
if [ ! -d "$DIR" ]; then echo "ERROR: directory does not exist: $DIR" >&2; exit 1; fi
DIR="$(cd "$DIR" && pwd -P)"

TRACE_SCRIPT="$SELF_DIR/trace.sh"

# _report <outcome-line> — the single exit point. Prints the one CODEGRAPH: line, traces,
# and exits 0.
_report() {
  local line="$1"
  echo "CODEGRAPH: $line"
  if [ -f "$TRACE_SCRIPT" ]; then
    bash "$TRACE_SCRIPT" CODEGRAPH "dir=$DIR${SLUG:+ slug=$SLUG} $line" 2>/dev/null || true
  fi
  exit 0
}

# ─── 1. escape hatch ─────────────────────────────────────────────────────────
# Off by default — see header comment. Mirrors CREW_DEPS=off/CREW_DOCKER_INSTALL=off, just
# inverted: an operator opts *in* here instead of opting out.
if [ "${CREW_CODEGRAPH:-off}" != "on" ]; then
  _report "skipped"
fi

# ─── 2. the presence guard ───────────────────────────────────────────────────
# A reused worktree (ensureWorktree's reuse path) already has its own index from an
# earlier round — nothing to do. codegraph's own incremental sync (its file watcher) keeps
# it current from here; this script's job ends at giving a worktree one to sync.
if [ -d "$DIR/.codegraph" ]; then
  _report "present"
fi

# ─── 3. the CLI itself ───────────────────────────────────────────────────────
if ! command -v codegraph >/dev/null 2>&1; then
  _report "unavailable"
fi

# ─── 4. init ──────────────────────────────────────────────────────────────────
# Capped, because an index build that hangs would hang the whole sprint behind it.
# `timeout` is not on every host (macOS ships none), so run uncapped rather than fail when
# it is absent — the cap is a safety net, not the contract.
TIMEOUT_BIN=""
for _t in timeout gtimeout; do
  command -v "$_t" >/dev/null 2>&1 && { TIMEOUT_BIN="$_t"; break; }
done

OUT_FILE="$(mktemp)"
trap 'rm -f "$OUT_FILE"' EXIT

# Run from inside $DIR with no path argument, exactly as codegraph's own docs recommend
# ("run codegraph init -i in the worktree") — not `codegraph init -i "$DIR"` from outside
# it, which is not the invocation their own guidance describes.
if [ -n "$TIMEOUT_BIN" ]; then
  "$TIMEOUT_BIN" "$TIMEOUT" bash -c 'cd "$1" && codegraph init -i' _ "$DIR" >"$OUT_FILE" 2>&1
else
  bash -c 'cd "$1" && codegraph init -i' _ "$DIR" >"$OUT_FILE" 2>&1
fi
RC=$?

if [ "$RC" -eq 0 ]; then
  _report "initialized"
fi

# The verbatim tail, so whoever reads the round's log sees codegraph's own words and not a
# paraphrase of them. Same fallback location as ensure-deps.sh's own debug log.
CODEGRAPH_LOG="$DIR/.scratch/codegraph-init.log"
mkdir -p "$(dirname "$CODEGRAPH_LOG")" 2>/dev/null || true
{ printf '--- %s ---\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; cat "$OUT_FILE"; } >"$CODEGRAPH_LOG" 2>/dev/null || true
echo "--- codegraph init -i output (tail) ---" >&2
tail -n 20 "$OUT_FILE" >&2
echo "--- end; full output saved to $CODEGRAPH_LOG ---" >&2
_report "failed (exit $RC) (see $CODEGRAPH_LOG)"
