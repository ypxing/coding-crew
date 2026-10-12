#!/usr/bin/env bash
set -uo pipefail

# issue-labels.sh — the one writer of crew-afk's status labels on a GitHub issue (none under local).
# Usage: issue-labels.sh claim|release|block <issue-number> | sweep <feature-slug>
# claim/release add/remove `in-progress`, display only: the feature lease decides dispatch. block
# adds `blocked`, which selectDispatchable skips until a human removes it. sweep, run by a new lease
# holder, clears `in-progress` a dead run left. Exit 1 only when a gh call fails.

MAIN_ROOT="${MAIN_ROOT:-.}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tracker-cli.sh
. "$SCRIPT_DIR/tracker-cli.sh"
resolve_tracker_cli "$MAIN_ROOT" || exit 1

CMD="${1:-}"
ARG="${2:-}"
USAGE="Usage: issue-labels.sh claim|release|block <issue-number> | sweep <feature-slug>"
case "$CMD" in
  claim|release|block)
    case "$ARG" in
      ''|*[!0-9]*) [ "$TRACKER_KIND" = "github" ] || exit 0
        echo "issue-labels.sh: expected a GitHub issue number, got: $ARG" >&2; exit 1 ;;
    esac ;;
  sweep)
    if [ -z "$ARG" ]; then echo "$USAGE" >&2; exit 1; fi ;;
  *) echo "$USAGE" >&2; exit 1 ;;
esac

[ "$TRACKER_KIND" = "github" ] || exit 0

# The label first, idempotently: --add-label and --remove-label fail on a label the repo lacks.
ensure_label() {
  local name="$1" description="$2" out
  if ! out="$(gh label create "$name" --force --description "$description" 2>&1)"; then
    echo "issue-labels.sh: gh label create $name failed: $out" >&2
    exit 1
  fi
}
ensure_blocked() { ensure_label blocked "crew-afk stopped on this issue; remove the label to put it back in the queue"; }
ensure_in_progress() { ensure_label in-progress "A crew-afk run is working this issue (display only)"; }

edit() {
  local out
  if ! out="$(gh issue edit "$1" "${@:2}" 2>&1)"; then
    echo "issue-labels.sh: gh issue edit failed for #$1: $out" >&2
    exit 1
  fi
}

case "$CMD" in
  claim)
    ensure_in_progress
    edit "$ARG" --add-label in-progress
    echo "LABELLED: in-progress #$ARG" ;;
  release)
    ensure_in_progress
    edit "$ARG" --remove-label in-progress
    echo "RELEASED: in-progress #$ARG" ;;
  block)
    ensure_blocked
    ensure_in_progress
    edit "$ARG" --add-label blocked --remove-label in-progress
    echo "LABELLED: blocked #$ARG" ;;
  sweep)
    if ! OUT="$(node "$TRACKER_CLI" feature-issues --feature-slug "$ARG" --state all --main-root "$MAIN_ROOT")"; then
      echo "issue-labels.sh: reading feature $ARG's issues failed" >&2
      exit 1
    fi
    COUNT=0
    FAILED=0
    for N in $(printf '%s' "$OUT" | jq -r '.[] | select(any(.labels[]?; .name == "in-progress")) | .number'); do
      if OUT2="$(gh issue edit "$N" --remove-label in-progress 2>&1)"; then
        COUNT=$((COUNT + 1))
      else
        echo "issue-labels.sh: gh issue edit failed for #$N: $OUT2" >&2
        FAILED=1
      fi
    done
    echo "SWEPT: $COUNT"
    [ "$FAILED" -eq 0 ] || exit 1 ;;
esac
