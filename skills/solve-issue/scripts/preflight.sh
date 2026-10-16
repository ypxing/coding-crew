#!/usr/bin/env bash
# preflight.sh — every fact solve-issue needs before it reads any code, resolved in one call.
#
# Usage:
#   bash scripts/preflight.sh --project-root <path> [--issue <issue-ref>]
#
# Prints, exit 0:
#   OK
#   ISSUE_SLUG=<the ref's base name without .md: a file's name, or a tracker number>
#   PRD=<absolute path of a file PRD, or empty when there is none — normal>
#
# Or one line and exit 1 — stop, report it verbatim:
#   BLOCKED: on default branch (<name>) — create or switch to a feature branch first
#   BLOCKED: depends on <file> which is not yet done
#   BLOCKED: requires: <cmd>          then check-requires.sh's output tail
#   BLOCKED: checks library missing from scripts/checks — re-install coding-crew
# --issue is optional: an issue handed over inline has no Blocked by or PRD to resolve, and no slug. A PRD path is
# resolved against the checkout that holds the issue's .scratch/, then against --project-root.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT_ROOT=""
ISSUE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root|--issue)
      if [ $# -lt 2 ]; then echo "Error: $1 requires a value" >&2; exit 2; fi
      case "$1" in
        --project-root) PROJECT_ROOT="$2" ;;
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

if [ -z "$PROJECT_ROOT" ]; then
  echo "Error: --project-root is required" >&2
  exit 2
fi

CURRENT_BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
DEFAULT_BRANCH=$(git -C "$PROJECT_ROOT" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
[ -n "$DEFAULT_BRANCH" ] || DEFAULT_BRANCH="main"
if [ "$CURRENT_BRANCH" = "$DEFAULT_BRANCH" ]; then
  echo "BLOCKED: on default branch ($DEFAULT_BRANCH) — create or switch to a feature branch first"
  exit 1
fi

# A relative ref names a path in --project-root, else in the main checkout: .scratch/ is gitignored, so in a
# linked worktree the tracker's `.scratch/…` refs exist only there.
case "$ISSUE" in
  "" | /*) ;;
  *)
    if [ -f "$PROJECT_ROOT/$ISSUE" ]; then
      ISSUE="$PROJECT_ROOT/$ISSUE"
    else
      COMMON_DIR=$(git -C "$PROJECT_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
      [ -z "$COMMON_DIR" ] || [ ! -f "$(dirname "$COMMON_DIR")/$ISSUE" ] || ISSUE="$(dirname "$COMMON_DIR")/$ISSUE"
    fi
    ;;
esac

# Blocked-by entries name issue files; only the file name is looked up in done/. A GitHub
# `Issue #<n>` entry names no file: a tracker that filters blocked issues owns that case.
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

# .scratch/ is gitignored, so it lives in the checkout that wrote the issue, not always this one.
ISSUE_ROOT="$PROJECT_ROOT"
case "$ISSUE" in */.scratch/*) ISSUE_ROOT="${ISSUE%%/.scratch/*}" ;; esac

PRD=""
if [ -n "$ISSUE" ]; then
  if [ -f "$ISSUE" ]; then
    PRD_REL=$(awk '/^## Context Documents/{f=1;next} /^## /{f=0} f' "$ISSUE" | sed -n 's/.*PRD: *`\([^`]*\)`.*/\1/p' | head -1)
    if [ -n "$PRD_REL" ]; then
      for root in "$ISSUE_ROOT" "$PROJECT_ROOT"; do
        if [ -f "$root/$PRD_REL" ]; then PRD="$root/$PRD_REL"; break; fi
      done
    fi
  fi
  if [ -z "$PRD" ]; then
    case "$ISSUE" in
      */.scratch/*)
        FEATURE_SLUG=$(printf '%s' "$ISSUE" | sed 's|.*/\.scratch/||; s|/.*||')
        [ -f "$ISSUE_ROOT/.scratch/$FEATURE_SLUG/PRD.md" ] && PRD="$ISSUE_ROOT/.scratch/$FEATURE_SLUG/PRD.md"
        ;;
    esac
  fi
fi

if [ -n "$ISSUE" ] && [ -f "$ISSUE" ]; then
  REQ_OUT=$(bash "$SELF_DIR/check-requires.sh" --project-root "$PROJECT_ROOT" --issue "$ISSUE")
  if [ $? -ne 0 ]; then
    REQ_FAIL=$(printf '%s\n' "$REQ_OUT" | sed -n "s|^REQUIRE: fail $ISSUE ||p" | head -1)
    echo "BLOCKED: requires: ${REQ_FAIL:-see below}"
    printf '%s\n' "$REQ_OUT" | grep -v '^REQUIRE: pass '
    exit 1
  fi
fi

# The checks library, shipped as a copy in this skill's scripts/: Steps 2, 4 and 5 run through it.
if [ ! -f "$SELF_DIR/checks/run-checks.sh" ] || [ ! -f "$SELF_DIR/checks/run.sh" ]; then
  echo "BLOCKED: checks library missing from scripts/checks — re-install coding-crew"
  exit 1
fi

ISSUE_SLUG=""
[ -n "$ISSUE" ] && ISSUE_SLUG="$(basename "$ISSUE" .md)"

echo "OK"
echo "ISSUE_SLUG=$ISSUE_SLUG"
echo "PRD=$PRD"
