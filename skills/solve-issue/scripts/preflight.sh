#!/usr/bin/env bash
# preflight.sh — every fact solve-issue needs before it reads any code, resolved in one call.
#
# Usage:
#   bash scripts/preflight.sh --project-root <path> --main-root <path> [--issue <path>]
#
# Prints, exit 0:
#   OK
#   ISSUE_SLUG=<issue file name without .md>
#   PRD=<absolute path, or empty when there is none — normal>
#   ORCHESTRATED=0|1       1: another program closes the issue; write nothing to it (Step 7)
#   DEP_SCRIPTS=<dir>      dep-install's scripts (resolve-mode.sh, run.sh); empty if not installed
#
# Or one line and exit 1 — stop, report it verbatim:
#   BLOCKED: on default branch (<name>) — create or switch to a feature branch first
#   BLOCKED: depends on <file> which is not yet done
#
# --issue is optional because a caller may hand the issue over inline: with no file there is
# no Blocked-by section to check and no Context Documents line to read the PRD from, so only
# the feature-slug fallback for the PRD applies, and only when a path was given at all.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT_ROOT=""
MAIN_ROOT=""
ISSUE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root|--main-root|--issue)
      if [ $# -lt 2 ]; then echo "Error: $1 requires a value" >&2; exit 2; fi
      case "$1" in
        --project-root) PROJECT_ROOT="$2" ;;
        --main-root) MAIN_ROOT="$2" ;;
        --issue) ISSUE="$2" ;;
      esac
      shift 2
      ;;
    --help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$PROJECT_ROOT" ] || [ -z "$MAIN_ROOT" ]; then
  echo "Error: --project-root and --main-root are required" >&2
  exit 2
fi

# ─── Step 0: never on the default branch ─────────────────────────────────────
CURRENT_BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
DEFAULT_BRANCH=$(git -C "$PROJECT_ROOT" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
[ -n "$DEFAULT_BRANCH" ] || DEFAULT_BRANCH="main"
if [ "$CURRENT_BRANCH" = "$DEFAULT_BRANCH" ]; then
  echo "BLOCKED: on default branch ($DEFAULT_BRANCH) — create or switch to a feature branch first"
  exit 1
fi

# ─── Step 1: every Blocked-by file is in the sibling done/ ───────────────────
# Entries name issue files (`.scratch/<slug>/issues/open/01-x.md`, or bare `01-x.md`); only
# the file name matters, looked up in done/. "None", or a GitHub `Issue #<n>` entry, names no
# file — a tracker that filters blocked issues before dispatch owns that case.
if [ -n "$ISSUE" ] && [ -f "$ISSUE" ]; then
  DONE_DIR="$(dirname "$ISSUE")/../done"
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    if [ ! -f "$DONE_DIR/$dep" ]; then
      echo "BLOCKED: depends on $dep which is not yet done"
      exit 1
    fi
  done < <(awk '/^## Blocked by/{f=1;next} /^## /{f=0} f' "$ISSUE" \
    | grep -oE '[A-Za-z0-9._-]+\.md' | awk '!seen[$0]++')
fi

# ─── Step 1.5: the PRD ───────────────────────────────────────────────────────
PRD=""
if [ -n "$ISSUE" ]; then
  if [ -f "$ISSUE" ]; then
    PRD_REL=$(awk '/^## Context Documents/{f=1;next} /^## /{f=0} f' "$ISSUE" | sed -n 's/.*PRD: *`\([^`]*\)`.*/\1/p' | head -1)
    [ -n "$PRD_REL" ] && [ -f "$MAIN_ROOT/$PRD_REL" ] && PRD="$MAIN_ROOT/$PRD_REL"
  fi
  if [ -z "$PRD" ]; then
    case "$ISSUE" in
      *.scratch/*)
        FEATURE_SLUG=$(printf '%s' "$ISSUE" | sed 's|.*\.scratch/||; s|/.*||')
        [ -f "$MAIN_ROOT/.scratch/$FEATURE_SLUG/PRD.md" ] && PRD="$MAIN_ROOT/.scratch/$FEATURE_SLUG/PRD.md"
        ;;
    esac
  fi
fi

# ─── Step 7's question, answered now: who closes the issue ───────────────────
ORCHESTRATED=0
if [ "${CREW_ORCHESTRATED:-}" = 1 ] || ls "$MAIN_ROOT"/.scratch/*/.orchestrated >/dev/null 2>&1; then
  ORCHESTRATED=1
fi

# ─── dep-install's scripts ───────────────────────────────────────────────────
# Installed as a sibling skill on every platform; the platform-neutral asset copy covers a
# user-level install whose skills live somewhere else.
DEP_SCRIPTS=""
for d in "$SELF_DIR/../../dep-install/scripts" \
         "$MAIN_ROOT/.coding-crew/dep-install/scripts" \
         "$PROJECT_ROOT/.coding-crew/dep-install/scripts"; do
  if [ -f "$d/resolve-mode.sh" ] && [ -f "$d/run.sh" ]; then
    DEP_SCRIPTS="$(cd "$d" && pwd)"
    break
  fi
done

ISSUE_SLUG=""
[ -n "$ISSUE" ] && ISSUE_SLUG="$(basename "$ISSUE" .md)"

echo "OK"
echo "ISSUE_SLUG=$ISSUE_SLUG"
echo "PRD=$PRD"
echo "ORCHESTRATED=$ORCHESTRATED"
echo "DEP_SCRIPTS=$DEP_SCRIPTS"
